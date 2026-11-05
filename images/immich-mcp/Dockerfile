# 只读搜索服务的镜像：Rust 的官方 MCP SDK rmcp，编成静态二进制，最终镜像 scratch，
# 没有 shell 和运行时。健康检查用二进制自己的 healthcheck 子命令。
#
# 构建要访问 crates.io。Docker 在另一台机器上时把 http_proxy、https_proxy 传进来：
# docker build --network host --build-arg https_proxy=... -t wonton-immich-mcp:dev .
FROM rust:1.99-alpine@sha256:7e9e2d068a107a2adafd19930011178d14a78326053cd4c3a9f7ad3fd049557d AS build

ARG http_proxy
ARG https_proxy

WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM scratch

COPY --from=build /build/target/release/wonton-immich-mcp /wonton-immich-mcp

# 固定一个非 root 用户；API key 文件只读挂载，进程不需要写任何地方。
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/wonton-immich-mcp"]
