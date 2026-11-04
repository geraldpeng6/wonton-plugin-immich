# Immich：sso=oidc；清单没有 mcp。
SSO=oidc
MCP=0

web_assert() { grep -qi 'immich'; }   # 标准输入：应用真实页面

# 走应用自己的 OAuth 端点（浏览器里 SPA 走的就是这套）：authorize → Hydra（核心会话自动登录）→
# 回调地址拿 code/state → 应用 callback 换会话 → 应用自己的“当前用户”接口确认是用户管理员。
identity_check() {
  local r url final state body me
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"redirectUri\":\"$SMOKE_WEB_URL/auth/login\"}" "$SMOKE_WEB_URL/api/oauth/authorize")" ||
    { echo "authorize 失败：$r"; return 1; }
  url="$(jq -r '.url // empty' <<<"$r")"
  [[ -n "$url" ]] || { echo "authorize 没给 url：$r"; return 1; }
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' "$url")" || { echo "OAuth 授权链失败"; return 1; }
  state="$(python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)["state"][0])' "$final")" ||
    { echo "回调地址没有 state：$final"; return 1; }
  body="$(jq -nc --arg u "$final" --arg s "$state" '{url:$u,state:$s}')"
  r="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$SMOKE_WEB_URL/api/oauth/callback")" || { echo "callback 失败：$r"; return 1; }
  me="$(web_get /api/users/me -H 'Accept: application/json')" || { echo "/api/users/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.isAdmin == true and (.email | startswith($u + "@"))' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$me"; return 1; }
}
