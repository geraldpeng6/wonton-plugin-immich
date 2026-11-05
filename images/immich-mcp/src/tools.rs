//! 唯一的工具：按文字搜照片（Immich smart search），只读。

use std::sync::Arc;

use base64::Engine;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ContentBlock, ServerCapabilities, ServerConfig};
use rmcp::{ErrorData as McpError, ServerHandler, tool, tool_handler, tool_router};
use rmcp::schemars;
use serde::Deserialize;

use crate::immich::{self, ApiError, Client};

/// 缩略图最多带几张；文字列表给全，缩略图超了预算就说明。
const MAX_THUMBNAILS: usize = 5;
/// 缩略图的原始字节总预算：总线的 1 MiB 上限是整个结果（base64 还要膨胀 4/3），
/// 留足文字和结构，原始字节按 600 KiB 算。
const THUMBNAIL_BUDGET_BYTES: usize = 600 * 1024;
/// 单张缩略图再大也不带：超过它多半是拿错了尺寸。
const THUMBNAIL_LIMIT_BYTES: usize = 512 * 1024;

#[derive(Debug, Deserialize, schemars::JsonSchema)]
pub struct SearchPhotos {
    /// 想找什么，用一句自然语言描述画面，如“海滩上的日落”“白色的猫”。
    pub query: String,
    /// 最多返回几张，默认 5，最多 20。
    pub limit: Option<u32>,
}

#[derive(Clone)]
pub struct SearchServer {
    base: String,
    apikey_path: Arc<std::path::PathBuf>,
    tool_router: ToolRouter<Self>,
}

#[tool_router]
impl SearchServer {
    pub fn new(base: String, apikey_path: std::path::PathBuf) -> Self {
        Self {
            base,
            apikey_path: Arc::new(apikey_path),
            tool_router: Self::tool_router(),
        }
    }

    fn client(&self) -> Result<Client, McpError> {
        let key = immich::read_apikey(&self.apikey_path)
            .map_err(|e| McpError::internal_error(e, None))?;
        Ok(Client::new(self.base.clone(), key))
    }

    #[tool(
        annotations(read_only_hint = true, title = "按内容搜照片"),
        description = "在用户的照片库里按画面内容搜照片（Immich 的语义搜索）。query 用一句自然语言描述想找的画面，比如“海滩上的日落”“白色的猫”。返回文件名、拍摄时间和缩略图；张数用 limit 限制，默认 5。只搜没进回收站的照片。"
    )]
    pub async fn search_photos(
        &self,
        Parameters(SearchPhotos { query, limit }): Parameters<SearchPhotos>,
    ) -> Result<CallToolResult, McpError> {
        let query = query.trim().to_owned();
        if query.is_empty() {
            return Err(McpError::invalid_params("query 不能为空", None));
        }
        let size = limit.unwrap_or(5).clamp(1, 20);
        let client = self.client()?;
        let assets = client
            .smart_search(&query, size)
            .await
            .map_err(api_error)?;
        if assets.is_empty() {
            return Ok(CallToolResult::success(vec![ContentBlock::text(format!(
                "没有找到和“{query}”相关的照片。库里的照片要先经过 Immich 的机器学习建好索引，新上传的要等一会儿。"
            ))]));
        }

        let mut listing = String::new();
        for (index, asset) in assets.iter().enumerate() {
            let taken = if asset.taken_at.is_empty() {
                "未知时间".to_owned()
            } else {
                crate::immich::truncate(&asset.taken_at, 10)
            };
            listing.push_str(&format!("{}. {}（{taken}）\n", index + 1, asset.file_name));
        }
        let mut content = vec![ContentBlock::text(format!(
            "找到 {} 张和“{query}”相关的照片：\n{listing}",
            assets.len()
        ))];

        // 缩略图按总预算带：带不上的张数在文字里如实说明，不静默丢弃。
        let mut fetched = Vec::new();
        let mut missing = 0usize;
        for asset in assets.iter().take(MAX_THUMBNAILS) {
            match client.thumbnail(&asset.id).await {
                Ok(Some((bytes, mime))) => fetched.push((bytes, mime)),
                Ok(None) => missing += 1,
                // 凭据失效必须整次失败（重启插件才能好）；Immich 别的错只影响那一张，
                // 文字列表照常给，缺的算进“没带上”。
                Err(error @ ApiError::Auth(_)) => return Err(api_error(error)),
                Err(ApiError::Upstream(_)) => missing += 1,
            }
        }
        let (chosen, skipped) = select_thumbnails(
            &fetched.iter().map(|(bytes, _)| bytes.len()).collect::<Vec<_>>(),
            THUMBNAIL_BUDGET_BYTES,
        );
        for index in chosen {
            let (bytes, mime) = &fetched[index];
            let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
            content.push(ContentBlock::image(encoded, mime.clone()));
        }
        let unavailable = missing + skipped;
        if unavailable > 0 {
            content.push(ContentBlock::text(format!(
                "另有 {unavailable} 张的缩略图没带上（超过结果大小上限，或照片还没生成好缩略图）；文字列表是全的，需要看图可以让用户在 Immich 网页里打开。"
            )));
        }
        Ok(CallToolResult::success(content))
    }
}

/// 按预算挑缩略图：返回带上的下标和因超预算被跳过的张数。单张超过
/// `THUMBNAIL_LIMIT_BYTES` 的直接算跳过。
fn select_thumbnails(sizes: &[usize], budget: usize) -> (Vec<usize>, usize) {
    let mut chosen = Vec::new();
    let mut used = 0usize;
    let mut skipped = 0usize;
    for (index, size) in sizes.iter().enumerate() {
        if *size > THUMBNAIL_LIMIT_BYTES || used + size > budget {
            skipped += 1;
            continue;
        }
        used += size;
        chosen.push(index);
    }
    (chosen, skipped)
}

/// 凭据失效和 Immich 出错都在错误文字里说清：前者重启插件就能好，后者要去 Immich 那边看。
fn api_error(error: ApiError) -> McpError {
    McpError::internal_error(error.to_string(), None)
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for SearchServer {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(rmcp::model::Implementation::new(
                "wonton-immich-mcp",
                env!("CARGO_PKG_VERSION"),
            ))
            .with_instructions(
                "只读的照片搜索。用户的照片库在 Immich 里；问“找某类照片”就用 search_photos。",
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbnails_within_budget_are_all_kept() {
        let (chosen, skipped) = select_thumbnails(&[100, 200, 300], 1000);
        assert_eq!(chosen, vec![0, 1, 2]);
        assert_eq!(skipped, 0);
    }

    #[test]
    fn thumbnails_over_budget_are_counted() {
        // 600+500 > 1000：第二张开始超预算，要如实说跳过几张。
        let (chosen, skipped) = select_thumbnails(&[600, 500, 100], 1000);
        assert_eq!(chosen, vec![0, 2]);
        assert_eq!(skipped, 1);
    }

    #[test]
    fn oversized_single_thumbnail_is_skipped() {
        let (chosen, skipped) = select_thumbnails(&[600 * 1024 + 1, 10], 600 * 1024);
        assert_eq!(chosen, vec![1]);
        assert_eq!(skipped, 1);
    }

    #[test]
    fn oversized_budget_means_text_only() {
        let (chosen, skipped) = select_thumbnails(&[700, 700], 100);
        assert!(chosen.is_empty());
        assert_eq!(skipped, 2);
    }

    #[test]
    fn api_errors_render_distinctly() {
        let auth = ApiError::Auth("Immich 的 API key 权限失效（/api/search/smart 返回 401）：重启插件会重建，再试一次".to_owned());
        let upstream = ApiError::Upstream("Immich /api/search/smart 返回 500：x".to_owned());
        assert!(auth.to_string().contains("重启插件会重建"));
        assert!(!upstream.to_string().contains("重启插件"));
    }
}
