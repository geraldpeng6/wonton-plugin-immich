//! Immich API 的最小客户端：只发请求，不做重试和缓存，错误原样带状态码交上去。

use std::path::Path;

const USER_AGENT: &str = concat!("wonton-immich-mcp/", env!("CARGO_PKG_VERSION"));

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    base: String,
    apikey: String,
}

/// 读 API key 文件；bootstrap 写入，属主是主人身份，其他插件和 Bot 读不到。
pub fn read_apikey(path: &Path) -> Result<String, String> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| format!("读不了 Immich API key（{}）：{e}", path.display()))?;
    let key = raw.trim();
    if key.is_empty() {
        return Err(format!("Immich API key（{}）是空的", path.display()));
    }
    Ok(key.to_owned())
}

impl Client {
    pub fn new(base: String, apikey: String) -> Self {
        let http = reqwest::Client::builder()
            .user_agent(USER_AGENT)
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .expect("HTTP 客户端构造失败");
        Self { http, base, apikey }
    }

    async fn get(&self, path: &str) -> Result<reqwest::Response, String> {
        self.http
            .get(format!("{}{path}", self.base))
            .header("x-api-key", &self.apikey)
            .send()
            .await
            .map_err(|e| format!("请求 Immich {path} 失败：{e}"))
    }

    async fn post_json(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response, String> {
        self.http
            .post(format!("{}{path}", self.base))
            .header("x-api-key", &self.apikey)
            .json(body)
            .send()
            .await
            .map_err(|e| format!("请求 Immich {path} 失败：{e}"))
    }

    /// Immich 没起来或者 key 失效都要在健康检查里看出来。
    pub async fn ping(&self) -> Result<(), String> {
        let response = self.get("/api/server/ping").await?;
        if !response.status().is_success() {
            return Err(format!("Immich /api/server/ping 返回 {}", response.status()));
        }
        Ok(())
    }

    /// key 被主人在 Immich 里吊销时，工具还没被调到就该在健康检查上红出来，并写明怎么恢复。
    pub async fn validate_key(&self) -> Result<(), String> {
        let response = self.get("/api/users/me").await?;
        match response.status() {
            reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN => Err(
                "Immich API key 已失效（被吊销或改过）：删除插件数据重装，搜索服务会重建它".to_owned(),
            ),
            status if status.is_success() => Ok(()),
            status => Err(format!("Immich /api/users/me 返回 {status}")),
        }
    }

    /// smart search：按自然语言搜照片（Immich 的机器学习服务给的语义搜索）。
    /// 返回 assets 列表（不含被删的），按相关度排序。
    pub async fn smart_search(
        &self,
        query: &str,
        size: u32,
    ) -> Result<Vec<AssetSummary>, String> {
        let body = serde_json::json!({ "query": query, "size": size, "withDeleted": false });
        let response = self.post_json("/api/search/smart", &body).await?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| format!("读 Immich 搜索响应失败：{e}"))?;
        if !status.is_success() {
            return Err(format!("Immich /api/search/smart 返回 {status}：{}", truncate(&text, 200)));
        }
        let value: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| format!("Immich 搜索响应不是 JSON：{e}；{}", truncate(&text, 200)))?;
        Ok(parse_assets(&value))
    }

    /// 缩略图字节（250px 小图，够 Agent 认出画面；preview 1440px 的几张就会撑爆总线的 1 MiB 结果上限）。
    pub async fn thumbnail(&self, id: &str) -> Result<Option<(Vec<u8>, String)>, String> {
        for size in ["thumbnail", "preview"] {
            let response = self
                .get(&format!("/api/assets/{id}/thumbnail?size={size}"))
                .await?;
            if response.status() == reqwest::StatusCode::NOT_FOUND {
                continue;
            }
            let status = response.status();
            if !status.is_success() {
                return Err(format!("Immich 缩略图 {id} 返回 {status}"));
            }
            let mime = response
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("image/jpeg")
                .split(';')
                .next()
                .unwrap_or("image/jpeg")
                .to_owned();
            let bytes = response
                .bytes()
                .await
                .map_err(|e| format!("读 Immich 缩略图 {id} 失败：{e}"))?;
            return Ok(Some((bytes.to_vec(), mime)));
        }
        Ok(None)
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AssetSummary {
    pub id: String,
    pub file_name: String,
    /// 拍摄时间（Immich 的 localDateTime），拿不到就留空。
    pub taken_at: String,
}

fn parse_assets(value: &serde_json::Value) -> Vec<AssetSummary> {
    // v3.x 的响应是 {"assets": {"items": [...]}}；兜底直接找数组，防上游调整。
    let items = value
        .pointer("/assets/items")
        .or_else(|| value.get("items"))
        .and_then(|v| v.as_array());
    items
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let id = item.get("id")?.as_str()?.to_owned();
            let file_name = item
                .get("originalFileName")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let taken_at = item
                .get("localDateTime")
                .and_then(|v| v.as_str())
                .or_else(|| item.get("fileCreatedAt").and_then(|v| v.as_str()))
                .unwrap_or("")
                .to_owned();
            (!id.is_empty()).then_some(AssetSummary { id, file_name, taken_at })
        })
        .collect()
}

fn truncate(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        text.to_owned()
    } else {
        format!("{}…", &text[..limit])
    }
}
