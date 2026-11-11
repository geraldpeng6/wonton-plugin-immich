# shellcheck shell=bash disable=SC2034

# Immich：sso=oidc；清单声明了 mcp（只读 search_photos）。
SSO=oidc
MCP=1

web_assert() { grep -qi 'immich'; }   # 标准输入：应用真实页面

# Bot 的 search_photos：装好后 ML 容器要先下载模型，第一次调用可能还没就绪；在窗口内重试，
# 空库返回“没有找到…”也算通过，工具真报错才算失败。
mcp_check() {
  local out i url=() slug="${SMOKE_SLUG:-${E2E_SLUG:-}}"
  # 插件的 smoke.sh 里 mcp() 自带总线地址；e2e 的 mcp() 要去显式给（E2E_MCP_URL）。
  [[ -n "$slug" ]] || { echo "没有插件 slug（SMOKE_SLUG/E2E_SLUG）"; return 1; }
  if [[ -n "${E2E_MCP_URL:-}" ]]; then url=("$E2E_MCP_URL"); fi
  for i in $(seq 1 20); do
    out="$(mcp call "${url[@]}" "${slug}__search_photos" '{"query":"photo","limit":3}')" || { sleep 30; continue; }
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

# ---------- 数据钩子（e2e 六项冒烟用）----------
# 数据项跑在网页/身份项之前（套件先装旧 tag 就写数据），web_url 和会话都还没有：自己拿。
# 上传用一张带标记 tEXt 块的 1x1 PNG：字节级唯一（immich 按用户+checksum 判重，同字节会拿到旧 id）。
smoke_base_url() { printf '%s' "${E2E_BASE:-${SMOKE_BASE:-}}"; }
smoke_token() { printf '%s' "${E2E_TOKEN:-${SMOKE_TOKEN:-}}"; }

smoke_core_login() { # <jar> <base>：核心登录，再走一次插件的登录跳转——网关的会话 Cookie 要落在插件主机上，OAuth 端点才认
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$(smoke_token)" "$(smoke_base_url)/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
}

smoke_web_url() { # <插件 id>：从核心 API 查插件 web_url，剥到 scheme://host（应用都在根路径）
  local list url
  list="$(curl -sS --noproxy '*' --fail-with-body -H "Authorization: Bearer $(smoke_token)" \
    "$(smoke_base_url)/_wonton/api/plugins")" || return 1
  url="$(jq -er --arg id "$1" --arg json "$list" \
    '$json | fromjson | .plugins[] | select(.id==$id) | .web_url // empty' <<<"$list")" || return 1
  sed -E 's#^(https?://[^/]+).*#\1#' <<<"$url"
}

smoke_marker() { # <名字>：标记文件路径（SMOKE_STATE 是文件不是目录，标记放同名的 .d 目录里）
  local d="${SMOKE_STATE:-${TMPDIR:-/tmp}}.d"
  mkdir -p "$d" && printf '%s' "$d/$1"
}

smoke_app_url() { # 数据钩子用的应用地址：先取套件已设的（尾斜杠归一化），没有就自己查
  local u="${E2E_WEB_URL:-${SMOKE_WEB_URL:-}}"
  [[ -n "$u" ]] || u="$(smoke_web_url "${E2E_NAME_ID:-${SMOKE_PLUGIN_ID:-}}")" || return 1
  [[ -n "$u" ]] || { echo "查不到插件 web_url"; return 1; }
  printf '%s' "${u%/}"
}

immich_login() { # <jar> <base>：走应用自己的 OAuth 链（authorize → Hydra → callback），会话落进 jar
  local jar="$1" base="$2" r url final state body
  r="$(curl -sS --noproxy '*' -b "$jar" -c "$jar" -H 'Content-Type: application/json' \
    -d "{\"redirectUri\":\"$base/auth/login\"}" "$base/api/oauth/authorize")" || return 1
  url="$(jq -r '.url // empty' <<<"$r")"
  [[ -n "$url" ]] || { echo "authorize 没给 url：$r"; return 1; }
  final="$(curl -sS --noproxy '*' -o /dev/null -L -b "$jar" -c "$jar" -H 'Accept: text/html' \
    -w '%{url_effective}' "$url")" || return 1
  state="$(python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)["state"][0])' "$final")" ||
    { echo "回调地址没有 state：$final"; return 1; }
  body="$(jq -nc --arg u "$final" --arg s "$state" '{url:$u,state:$s}')"
  r="$(curl -sS --noproxy '*' -b "$jar" -c "$jar" -H 'Content-Type: application/json' -d "$body" \
    "$base/api/oauth/callback")" || { echo "callback 失败：$r"; return 1; }
}

immich_marker_png() { # <标记> <文件>：1x1 PNG 在 IEND 前插一个带标记的 tEXt 块（CRC 重算），字节级唯一
  python3 - "$1" "$2" <<'PY'
import base64, struct, sys, zlib
marker, path = sys.argv[1], sys.argv[2]
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")
text = b"Comment\x00" + marker.encode()
chunk = struct.pack(">I", len(text)) + b"tEXt" + text + struct.pack(">I", zlib.crc32(b"tEXt" + text))
with open(path, "wb") as f:
    f.write(png[:-12] + chunk + png[-12:])   # IEND 固定 12 字节且必在末尾
PY
}

data_write() { # 走 OAuth 拿会话，上传一张带标记的 1x1 PNG，记下资产 id
  local jar base marker png out id
  jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  base="$(smoke_app_url)" || return 1
  smoke_core_login "$jar" "$base" || { echo "核心会话建不了"; return 1; }
  immich_login "$jar" "$base" || return 1
  marker="wonton-smoke-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  png="$(smoke_marker immich-asset.png)"
  immich_marker_png "$marker" "$png" || { echo "生成标记 PNG 失败"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" \
    -F "assetData=@$png;type=image/png;filename=$marker.png" \
    -F "fileCreatedAt=$(date -u +%Y-%m-%dT%H:%M:%S%:z)" \
    -F "fileModifiedAt=$(date -u +%Y-%m-%dT%H:%M:%S%:z)" \
    "$base/api/assets")" || { echo "上传失败：$out"; return 1; }
  id="$(jq -r '.id // empty' <<<"$out")"
  [[ -n "$id" ]] || { echo "上传响应没有 id：$out"; return 1; }
  printf '%s\n%s\n' "$id" "$marker" >"$(smoke_marker immich-asset)"
}

data_check() { # 升级/重装后读回资产：GET /api/assets/{id}，originalFileName 带标记（不等 ML）
  local jar base id marker me
  base="$(smoke_app_url)" || return 1
  {
    read -r id
    read -r marker
  } <"$(smoke_marker immich-asset)" 2>/dev/null
  [[ -n "${id:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  jar="${E2E_JAR:-${SMOKE_JAR:-}}"
  me="$(curl -sS --noproxy '*' -b "$jar" -H 'Accept: application/json' "$base/api/assets/$id")"
  if ! jq -e --arg m "$marker" '.originalFileName == $m + ".png"' <<<"$me" >/dev/null 2>&1; then
    # 会话可能因重装失效：重走一遍 OAuth 再试一次
    smoke_core_login "$jar" "$base" || { echo "核心会话建不了"; return 1; }
    immich_login "$jar" "$base" || return 1
    me="$(curl -sS --noproxy '*' --fail-with-body -b "$jar" -H 'Accept: application/json' "$base/api/assets/$id")" ||
      { echo "读资产失败：$me"; return 1; }
  fi
  jq -e --arg m "$marker" '.originalFileName == $m + ".png"' <<<"$me" >/dev/null ||
    { echo "资产不见了或对不上：$(head -c 200 <<<"$me")"; return 1; }
}

# ---------- 邮件（notify）：测试信经核心内部邮箱投进主人私聊 ----------
# Immich 管理端有同步的测试信端点（POST /api/notifications/test-email，发给请求者自己=主人的内部
# 地址，成功回 messageId，SMTP 连不上 400），SMTP 参数用配置文件里同一套值传给端点，证明这组值
# 真发得出信；成功投递在核心日志里静默，再以主人身份读 Matrix 私聊里的 app.wonton.plugin_mail 消息。
# 给新用户发的欢迎信（成功路径的另一半）要第二个家庭成员才触发，冒烟里不可脚本化，不写假断言。
immich_session() { # 走一遍 OAuth 链把应用会话放进 $SMOKE_JAR（同 identity_check 的走法，不做断言）
  local r url final state body base
  base="${SMOKE_WEB_URL%/}"
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
}

extra_check() {
  local base server cfg out mail_host mail_port mail_from mtok before_ts found json seen_room
  base="${SMOKE_WEB_URL%/}"
  declare -F owner_access_token >/dev/null ||
    { echo "需要 e2e 套件的 owner_access_token（读主人私聊拿投递证据用）"; return 1; }
  server="$(docker ps --format '{{.Names}}' | grep -E "wonton-${SMOKE_INSTANCE}--app-immich-immich--server$" | head -1)"
  [[ -n "$server" ]] || { echo "找不到 immich server 容器"; return 1; }

  # 0) 三个 SMTP 变量进了 server 容器（compose 显式透传，值快照进配置文件）
  mail_host="$(docker exec "$server" printenv WONTON_SMTP_HOST)" || { echo "server 容器没有 WONTON_SMTP_HOST"; return 1; }
  mail_port="$(docker exec "$server" printenv WONTON_SMTP_PORT)" || { echo "server 容器没有 WONTON_SMTP_PORT"; return 1; }
  mail_from="$(docker exec "$server" printenv WONTON_MAIL_FROM)" || { echo "server 容器没有 WONTON_MAIL_FROM"; return 1; }
  [[ "$mail_host" == "smtp.wonton.internal" && "$mail_port" == "25" &&
    "$mail_from" == "app.immich.immich@plugins.wonton.internal" ]] ||
    { echo "SMTP 变量不对：host=$mail_host port=$mail_port from=$mail_from"; return 1; }
  echo "SMTP 变量已注入：$mail_host:$mail_port from=$mail_from"

  # 0b) 配置文件里的 notifications.smtp 就是核心注入的值
  cfg="$(docker exec "$server" cat /usr/src/app/wonton-config.json)" || { echo "读不到 immich 配置文件"; return 1; }
  jq -e '.notifications.smtp.enabled == true and .notifications.smtp.from == $f and
    .notifications.smtp.transport.host == "smtp.wonton.internal" and
    .notifications.smtp.transport.port == 25 and .notifications.smtp.transport.secure == false' \
    --arg f "$mail_from" <<<"$cfg" >/dev/null ||
    { echo "配置文件的 SMTP 不是核心注入的值：$(head -c 300 <<<"$cfg")"; return 1; }
  echo "配置文件 notifications.smtp = 核心注入的值"

  # 1) 应用会话 + 同步测试信（发给主人账号的内部地址）
  immich_session || return 1
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"enabled\":true,\"from\":\"$mail_from\",\"replyTo\":\"\",\"transport\":{\"host\":\"$mail_host\",\"port\":$mail_port,\"secure\":false,\"ignoreCert\":false,\"username\":\"\",\"password\":\"\"}}" \
    "$base/api/notifications/test-email")" || { echo "测试信没发出去：$out"; return 1; }
  jq -e '.messageId | length > 0' <<<"$out" >/dev/null || { echo "测试信回执没有 messageId：$out"; return 1; }
  echo "测试信已发出（messageId 回执）"

  # 2) 以主人身份读私聊，等 app.wonton.plugin_mail 消息（成功投递在核心日志里静默）
  mtok="$(owner_access_token)" || { echo "主人 Matrix 登录失败（读私聊拿投递证据用）"; return 1; }
  before_ts="$(date +%s000)"
  found=""
  for _ in $(seq 1 50); do
    seen_room="$(matrix_curl -H "Authorization: Bearer $mtok" \
      "http://tuwunel.wonton.internal:8008/_matrix/client/v3/joined_rooms" 2>/dev/null | jq -r '.joined_rooms[]' 2>/dev/null)" || { sleep 3; continue; }
    while IFS= read -r room; do
      [[ -n "$room" ]] || continue
      json="$(matrix_curl -H "Authorization: Bearer $mtok" \
        "http://tuwunel.wonton.internal:8008/_matrix/client/v3/rooms/$(printf '%s' "$room" | sed 's/!/%21/g;s/:/%3A/g')/messages?dir=b&limit=30" 2>/dev/null)" || continue
      if jq -e --arg p "app.immich.immich" --argjson t "$before_ts" '.chunk[] |
          select(.type == "m.room.message" and .origin_server_ts >= $t and
          .content["app.wonton.plugin_mail"].plugin_id == $p)' <<<"$json" >/dev/null 2>&1; then
        found="$room"
        break
      fi
    done <<<"$seen_room"
    [[ -n "$found" ]] && break
    sleep 3
  done
  [[ -n "$found" ]] || { echo "主人的 Wonton 私聊里没有 Immich 的测试信（150 秒）"; return 1; }
  echo "核心已把 Immich 的测试信投进主人的 Wonton 私聊（房间 $found）"
}
