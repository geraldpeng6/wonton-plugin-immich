//! 只读 Immich 搜索服务的入口：`healthcheck` 子命令给镜像的健康检查用。

use std::process::ExitCode;

use wonton_immich_mcp::{SearchServer, apikey_path, healthcheck, immich_base, port_from_env, serve};

#[tokio::main]
async fn main() -> ExitCode {
    let port = match port_from_env() {
        Ok(port) => port,
        Err(msg) => {
            eprintln!("{msg}");
            return ExitCode::FAILURE;
        }
    };

    if std::env::args().nth(1).as_deref() == Some("healthcheck") {
        return if healthcheck(port) {
            ExitCode::SUCCESS
        } else {
            ExitCode::FAILURE
        };
    }

    if let Err(reason) = wonton_immich_mcp::health().await {
        eprintln!("Immich 搜索服务不可用：{reason}");
        return ExitCode::FAILURE;
    }

    let server = SearchServer::new(immich_base(), apikey_path());
    if let Err(err) = serve(server, port).await {
        eprintln!("服务起不来：{err}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
