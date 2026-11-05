//! 唯一的工具：按文字搜照片（Immich smart search），只读。

use std::sync::Arc;

use base64::Engine;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{CallToolResult, ContentBlock, ServerCapabilities, ServerConfig};
use rmcp::{ErrorData as McpError, ServerHandler, tool, tool_handler, tool_router};
use rmcp::schemars;
use serde::Deserialize;

use crate::immich::{self, Client};

/// 一次最多带几张缩略图；多了总线要换算成说明文字，列表照给全。
const MAX_THUMBNAILS: usize = 5;
/// 缩略图块上限：规范里超过 1 MiB 的块会被总线换掉。
const THUMBNAIL_LIMIT_BYTES: usize = 1024 * 1024;

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
            .map_err(|e| McpError::invalid_params(format!("工具还没准备好：{e}"), None))?;
        Ok(Client::new(self.base.clone(), key))
    }

    #[tool(
        annotations(read_only_hint = true, title = "按内容搜照片"),
        description = "在主人的照片库里按画面内容搜照片（Immich 的语义搜索）。query 用一句自然语言描述想找的画面，比如“海滩上的日落”“白色的猫”。返回文件名、拍摄时间和缩略图；张数用 limit 限制，默认 5。只搜没进回收站的照片。"
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
            .map_err(|e| McpError::internal_error(e, None))?;

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
                asset.taken_at.chars().take(10).collect()
            };
            listing.push_str(&format!("{}. {}（{taken}）\n", index + 1, asset.file_name));
        }
        let mut content = vec![ContentBlock::text(format!(
            "找到 {} 张和“{query}”相关的照片：\n{listing}",
            assets.len()
        ))];
        for asset in assets.iter().take(MAX_THUMBNAILS) {
            // 缩略图是锦上添花：拿不到或太大就在文字列表里说明，不影响结果。
            if let Ok(Some((bytes, mime))) = client.thumbnail(&asset.id).await
                && bytes.len() <= THUMBNAIL_LIMIT_BYTES
            {
                let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                content.push(ContentBlock::image(encoded, mime));
            }
        }
        Ok(CallToolResult::success(content))
    }
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
                "只读的照片搜索。主人的照片库在 Immich 里；问“找某类照片”就用 search_photos。",
            )
    }
}
