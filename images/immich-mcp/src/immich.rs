//! Immich API 的最小客户端：只发请求，不做重试和缓存，错误原样带状态码交上去。

use std::path::Path;

const USER_AGENT: &str = concat!("wonton-immich-mcp/", env!("CARGO_PKG_VERSION"));

#[derive(Debug, Clone)]
pub enum ApiError {
    /// Immich 认了请求但拒绝这把 key（401/403）：权限失效，重启插件会重建。
    Auth(String),
    /// Immich 不可达或返回了别的错误。
    Upstream(String),
}

impl core::fmt::Display for ApiError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ApiError::Auth(message) => write!(f, "{message}"),
            ApiError::Upstream(message) => write!(f, "{message}"),
        }
    }
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    base: String,
    apikey: String,
}

/// 读 API key 文件（bootstrap 写入，0400，属主就是运行本服务的用户）。
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

    async fn get(&self, path: &str) -> Result<reqwest::Response, ApiError> {
        self.http
            .get(format!("{}{path}", self.base))
            .header("x-api-key", &self.apikey)
            .send()
            .await
            .map_err(|e| ApiError::Upstream(format!("请求 Immich {path} 失败：{e}")))
    }

    async fn post_json(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<reqwest::Response, ApiError> {
        self.http
            .post(format!("{}{path}", self.base))
            .header("x-api-key", &self.apikey)
            .json(body)
            .send()
            .await
            .map_err(|e| ApiError::Upstream(format!("请求 Immich {path} 失败：{e}")))
    }

    /// Immich 起没起来，健康检查只看这个。
    pub async fn ping(&self) -> Result<(), String> {
        let response = self.get("/api/server/ping").await.map_err(|e| e.to_string())?;
        if !response.status().is_success() {
            return Err(format!("Immich /api/server/ping 返回 {}", response.status()));
        }
        Ok(())
    }

    /// 按 Immich 的状态码分错：401/403 是这把 key 的事（重启插件会重建），别的算 Immich 的问题。
    fn check_status(status: reqwest::StatusCode, what: &str, body: &str) -> Result<(), ApiError> {
        match status {
            reqwest::StatusCode::UNAUTHORIZED | reqwest::StatusCode::FORBIDDEN => {
                Err(ApiError::Auth(format!(
                    "Immich 的 API key 权限失效（{what} 返回 {status}）：重启插件会重建，再试一次"
                )))
            }
            status if status.is_success() => Ok(()),
            status => Err(ApiError::Upstream(format!(
                "Immich {what} 返回 {status}：{}",
                truncate(body, 160)
            ))),
        }
    }

    /// smart search：按自然语言搜照片（Immich 的机器学习服务给的语义搜索）。
    pub async fn smart_search(&self, query: &str, size: u32) -> Result<Vec<AssetSummary>, ApiError> {
        let body = serde_json::json!({ "query": query, "size": size, "withDeleted": false });
        let response = self.post_json("/api/search/smart", &body).await?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|e| ApiError::Upstream(format!("读 Immich 搜索响应失败：{e}")))?;
        Self::check_status(status, "/api/search/smart", &text)?;
        let value: serde_json::Value = serde_json::from_str(&text)
            .map_err(|e| ApiError::Upstream(format!("Immich 搜索响应不是 JSON：{e}；{}", truncate(&text, 160))))?;
        parse_assets(&value)
    }

    /// 缩略图字节（250px 小图，够 Agent 认出画面）。
    pub async fn thumbnail(&self, id: &str) -> Result<Option<(Vec<u8>, String)>, ApiError> {
        let response = self
            .get(&format!("/api/assets/{id}/thumbnail?size=thumbnail"))
            .await?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        let status = response.status();
        let bytes = response
            .bytes()
            .await
            .map_err(|e| ApiError::Upstream(format!("读 Immich 缩略图 {id} 失败：{e}")))?;
        Self::check_status(status, &format!("/api/assets/{id}/thumbnail"), "")?;
        let mime = headers_mime(&bytes);
        Ok(Some((bytes.to_vec(), mime)))
    }
}

/// Immich 的小图接口按内容返回 jpeg 或 webp，响应头里的类型不完全可靠，看文件头。
fn headers_mime(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png".to_owned()
    } else if bytes.starts_with(b"RIFF") && bytes.len() > 11 && &bytes[8..12] == b"WEBP" {
        "image/webp".to_owned()
    } else {
        "image/jpeg".to_owned()
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct AssetSummary {
    pub id: String,
    pub file_name: String,
    /// 拍摄时间（Immich 的 localDateTime），拿不到就留空。
    pub taken_at: String,
}

/// 只认 v3.x 的响应形状：`{"assets": {"items": [...]}}`。认不出就是 Immich 出了问题，
/// 要如实报错，不能装作"没有找到照片"。
fn parse_assets(value: &serde_json::Value) -> Result<Vec<AssetSummary>, ApiError> {
    let items = value
        .pointer("/assets/items")
        .ok_or_else(|| {
            ApiError::Upstream(format!(
                "Immich 搜索响应的结构认不出来（没有 assets.items）：{}",
                truncate(&value.to_string(), 160)
            ))
        })?
        .as_array()
        .ok_or_else(|| {
            ApiError::Upstream(format!(
                "Immich 搜索响应的结构认不出来（assets.items 不是数组）：{}",
                truncate(&value.to_string(), 160)
            ))
        })?;
    items
        .iter()
        .map(|item| {
            let id = item
                .get("id")
                .and_then(|v| v.as_str())
                .ok_or_else(|| ApiError::Upstream("Immich 搜索结果的资产没有 id 字段".to_owned()))?;
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
            Ok(AssetSummary {
                id: id.to_owned(),
                file_name,
                taken_at,
            })
        })
        .collect()
}

/// 按字符截断：`&text[..limit]` 切在多字节字符中间会 panic。
pub(crate) fn truncate(text: &str, chars: usize) -> String {
    if text.chars().count() <= chars {
        text.to_owned()
    } else {
        let cut: String = text.chars().take(chars).collect();
        format!("{cut}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_real_response_shape() {
        let value = json!({
            "assets": {
                "total": 2,
                "items": [
                    {"id": "a1", "originalFileName": "IMG_0001.jpg", "localDateTime": "2026-11-03T10:01:00.000Z"},
                    {"id": "a2", "originalFileName": "IMG_0002.jpg", "localDateTime": "2026-11-03T10:02:00.000Z"}
                ]
            }
        });
        let assets = parse_assets(&value).expect("要能解析");
        assert_eq!(assets.len(), 2);
        assert_eq!(assets[0].id, "a1");
        assert_eq!(assets[0].file_name, "IMG_0001.jpg");
        assert_eq!(assets[1].taken_at, "2026-11-03T10:02:00.000Z");
    }

    #[test]
    fn rejects_unrecognized_shape() {
        for value in [json!({}), json!({"assets": {}}), json!({"items": []}), json!({"assets": {"items": 3}})] {
            let error = parse_assets(&value).expect_err("认不出的结构要报错");
            assert!(matches!(error, ApiError::Upstream(_)));
        }
    }

    #[test]
    fn missing_id_is_an_error() {
        let value = json!({"assets": {"items": [{"originalFileName": "x.jpg"}]}});
        assert!(parse_assets(&value).is_err());
    }

    #[test]
    fn truncate_cuts_on_char_boundary() {
        let text = "找到的照片有很多很多张，位置在 Beach 上"; // 多字节字符
        let cut = truncate(text, 5);
        assert!(cut.ends_with('…'));
        assert_eq!(cut.chars().count(), 6); // 5 个字符 + 省略号
    }

    #[test]
    fn truncate_short_text_is_untouched() {
        assert_eq!(truncate("短的", 10), "短的");
    }

    #[test]
    fn detects_mime_from_bytes() {
        assert_eq!(headers_mime(b"\x89PNG\r\n"), "image/png");
        assert_eq!(headers_mime(b"RIFF1234WEBPVP8"), "image/webp");
        assert_eq!(headers_mime(b"\xff\xd8\xff\xe0"), "image/jpeg");
    }
}
