# shellcheck shell=bash disable=SC2034

# Immich：sso=oidc；清单没有 mcp。
SSO=oidc
MCP=0

web_assert() { grep -qi 'immich'; }   # 标准输入：应用真实页面

# 走应用自己的 OAuth 端点（浏览器里 SPA 走的就是这套）：authorize → Hydra（核心会话自动登录）→
# 回调地址拿 code/state → 应用 callback 换会话。identity_check 和两个数据钩子共用。
_immich_login() {
  local r url final state body
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
}

identity_check() {
  local me
  _immich_login || return 1
  me="$(web_get /api/users/me -H 'Accept: application/json')" || { echo "/api/users/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.isAdmin == true and (.email | startswith($u + "@"))' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$me"; return 1; }
}

# 数据：建一个名字带随机标记的相册（落 Immich 数据库，升级后还在）。
data_write() {
  local marker id resp
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n')"
  _immich_login || return 1
  resp="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d '{"albumName":"'"$marker"'"}' "$SMOKE_WEB_URL/api/albums")" || { echo "建相册失败：$resp"; return 1; }
  id="$(jq -er '.id // empty' <<<"$resp")" || { echo "建相册响应里没有 id：$resp"; return 1; }
  jq -nc --arg id "$id" --arg marker "$marker" '{id:$id,marker:$marker}' >"$SMOKE_STATE"
}

data_check() {
  local state id marker resp code body seen
  [[ -n "${SMOKE_STATE:-}" ]] || { echo "SMOKE_STATE 没设"; return 1; }
  state="$(cat "$SMOKE_STATE")" || { echo "读不到 $SMOKE_STATE"; return 1; }
  id="$(jq -r '.id' <<<"$state")"
  marker="$(jq -r '.marker' <<<"$state")"
  _immich_login || return 1
  resp="$(curl -sS --noproxy '*' -w $'\n%{http_code}' -b "$SMOKE_JAR" -H 'Accept: application/json' \
    "$SMOKE_WEB_URL/api/albums/$id")"
  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  [[ "$code" == 200 ]] || { echo "相册 $id 读不到（HTTP $code）：$(head -c 200 <<<"$body")"; return 1; }
  seen="$(jq -r '.albumName // .name // empty' <<<"$body")"
  [[ "$seen" == "$marker" ]] || { echo "相册名对不上：写了 $marker，读到 $seen（$(head -c 200 <<<"$body")）"; return 1; }
}
