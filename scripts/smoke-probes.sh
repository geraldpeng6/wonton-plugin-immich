# shellcheck shell=bash disable=SC2034

# Immich：sso=oidc；清单声明了 mcp（只读 search_photos）。
SSO=oidc
MCP=1

web_assert() { grep -qi 'immich'; }   # 标准输入：应用真实页面

# Bot 的 search_photos：装好后 ML 容器要先下载模型，第一次调用可能还没就绪；在窗口内重试，
# 空库返回“没有找到…”也算通过，工具真报错才算失败。
mcp_check() {
  local out i
  for i in $(seq 1 20); do
    out="$(mcp call "${SMOKE_SLUG}__search_photos" '{"query":"photo","limit":3}')" || { sleep 30; continue; }
    grep -qE '找到|没有找到' <<<"$out" && return 0
    sleep 30
  done
  echo "search_photos 重试窗口内没有成功：$(head -c 200 <<<"$out")"
  return 1
}

# 走应用自己的 OAuth 端点（浏览器里 SPA 走的就是这套）：authorize → Hydra（核心会话自动登录）→
# 回调地址拿 code/state → 应用 callback 换会话 → 应用自己的“当前用户”接口确认是用户管理员。
identity_check() {
  local r url final state body me base
  base="${SMOKE_WEB_URL%/}"   # 网关 web_url 带尾斜杠，直接拼会得到 //api/...，immich 回 404 Cannot POST
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"redirectUri\":\"$base/auth/login\"}" "$base/api/oauth/authorize")" ||
    { echo "authorize 失败：$r"; return 1; }
  url="$(jq -r '.url // empty' <<<"$r")"
  [[ -n "$url" ]] || { echo "authorize 没给 url：$r"; return 1; }
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' "$url")" || { echo "OAuth 授权链失败"; return 1; }
  state="$(python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)["state"][0])' "$final")" ||
    { echo "回调地址没有 state：$final"; return 1; }
  body="$(jq -nc --arg u "$final" --arg s "$state" '{url:$u,state:$s}')"
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$base/api/oauth/callback")" || { echo "callback 失败：$r"; return 1; }
  # 不用套件的 web_get：它把路径拼在带尾斜杠的 SMOKE_WEB_URL 后面，同样会出 //api/...
  me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Accept: application/json' "$base/api/users/me")" ||
    { echo "/api/users/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.isAdmin == true and (.email | startswith($u + "@"))' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$me"; return 1; }
}
