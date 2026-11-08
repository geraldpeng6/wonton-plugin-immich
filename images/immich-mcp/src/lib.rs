//! Immich 的只读 MCP 服务：一个工具，按内容（smart search）搜照片。
//!
//! 凭据是 bootstrap 建好的 Immich API key（文件挂载进容器），工具用它调 Immich 自己的
//! 搜索接口，不缓存、不写任何数据。

pub mod immich;
pub mod tools;

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

use axum::Router;
use axum::http::StatusCode;
use axum::routing::get;
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService, session::local::LocalSessionManager,
};
use tokio_util::sync::CancellationToken;

pub use tools::SearchServer;

pub const DEFAULT_PORT: u16 = 8080;

pub fn port_from_env() -> Result<u16, String> {
    match std::env::var("PORT") {
        Ok(value) => value.parse().map_err(|_| format!("PORT={value} 不是端口")),
        Err(_) => Ok(DEFAULT_PORT),
    }
}

/// Immich 的地址：compose 里就是 server 服务，按服务名连。
pub fn immich_base() -> String {
    std::env::var("IMMICH_URL").unwrap_or_else(|_| "http://server:2283".into())
}

/// API key 文件：bootstrap 在建好账号后写进挂载的目录。
pub fn apikey_path() -> std::path::PathBuf {
    std::env::var_os("APIKEY_FILE")
        .map(Into::into)
        .unwrap_or_else(|| "/mcp-data/apikey".into())
}

/// 健康检查只看进程活着和 Immich 的 ping：key 失效不影响照片网页，也不能把插件标红，
/// key 的问题在工具调用时报（401/403 单独报“权限失效，重启插件会重建”）。
pub async fn health() -> Result<(), String> {
    let client = immich::Client::new(immich_base(), String::new());
    client.ping().await
}

/// 起 Streamable HTTP 服务，`/mcp` 给总线，`/healthz` 给健康检查。
pub async fn serve(server: SearchServer, port: u16) -> std::io::Result<()> {
    let cancellation = CancellationToken::new();
    let config = StreamableHttpServerConfig::default()
        .with_cancellation_token(cancellation.child_token())
        // 核心经插件网络用服务名连进来；主机名校验交给网络隔离。
        .disable_allowed_hosts();
    let app = app(server, config);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    let shutdown = shutdown(cancellation);
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await
}

pub fn app(server: SearchServer, config: StreamableHttpServerConfig) -> Router {
    let handler = Arc::new(server);
    let mcp = StreamableHttpService::new(
        move || Ok(handler.clone()),
        Arc::new(LocalSessionManager::default()),
        config,
    );
    Router::new()
        .route("/healthz", get(healthz))
        .nest_service("/mcp", mcp)
}

async fn healthz() -> (StatusCode, &'static str) {
    match tokio::time::timeout(Duration::from_secs(8), health()).await {
        Ok(Ok(())) => (StatusCode::OK, "ok"),
        Ok(Err(reason)) => {
            eprintln!("healthz：{reason}");
            (StatusCode::SERVICE_UNAVAILABLE, "not ready")
        }
        Err(_) => (StatusCode::SERVICE_UNAVAILABLE, "timeout"),
    }
}

async fn shutdown(cancellation: CancellationToken) {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    let term = async {
        let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        else {
            std::future::pending::<()>().await;
            return;
        };
        signal.recv().await;
    };
    tokio::select! {
        _ = ctrl_c => {}
        _ = term => {}
    }
    cancellation.cancel();
}

/// 健康检查客户端：镜像里没有 curl，用二进制自己的这个子命令。
pub fn healthcheck(port: u16) -> bool {
    let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    if stream
        .write_all(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .is_err()
    {
        return false;
    }
    let mut buf = Vec::new();
    if stream.read_to_end(&mut buf).is_err() {
        return false;
    }
    let head = String::from_utf8_lossy(&buf);
    head.starts_with("HTTP/1.1 200") || head.starts_with("HTTP/1.0 200")
}
