# shellcheck shell=bash disable=SC2034

# Immich：OIDC（核心签发方，重装后按新签发方自动换会话）；清单声明了 mcp（只读 search_photos）。

web_assert() { grep -qi 'immich'; }   # 标准输入：应用真实页面

# Bot 的 search_photos：装好后 ML 容器要先下载识别模型，第一次调用可能还没就绪；在窗口内重试，
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
  local r url final state body me mt="${SMOKE_WEB_MAX_TIME:-120}"
  r="$(curl -sS --noproxy '*' --max-time "$mt" -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "{\"redirectUri\":\"$SMOKE_WEB_URL/auth/login\"}" "$SMOKE_WEB_URL/api/oauth/authorize")" ||
    { echo "authorize 失败：$r"; return 1; }
  url="$(jq -r '.url // empty' <<<"$r")"
  [[ -n "$url" ]] || { echo "authorize 没给 url：$r"; return 1; }
  final="$(curl -sS --noproxy '*' --max-time "$mt" -o /dev/null -L -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Accept: text/html' \
    -w '%{url_effective}' "$url")" || { echo "OAuth 授权链失败"; return 1; }
  state="$(python3 -c 'import sys,urllib.parse as u;print(u.parse_qs(u.urlparse(sys.argv[1]).query)["state"][0])' "$final")" ||
    { echo "回调地址没有 state：$final"; return 1; }
  body="$(jq -nc --arg u "$final" --arg s "$state" '{url:$u,state:$s}')"
  r="$(curl -sS --noproxy '*' --max-time "$mt" -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$SMOKE_WEB_URL/api/oauth/callback")" || { echo "callback 失败：$r"; return 1; }
  me="$(web_get /api/users/me -H 'Accept: application/json' --fail-with-body)" ||
    { echo "/api/users/me 失败：$me"; return 1; }
  jq -e --arg u "$SMOKE_OWNER" '.isAdmin == true and (.email | startswith($u + "@"))' <<<"$me" >/dev/null ||
    { echo "当前用户不是用户管理员：$me"; return 1; }
}

# ---------- 数据钩子（升级/重装保数据）----------
# 上传用一张带标记 tEXt 块的 1x1 PNG：字节级唯一（immich 按用户+checksum 判重，同字节会拿到旧 id）。
core_login() { # <jar> <base>：主人令牌登核心，再跟一次应用入口跳转——网关的会话 Cookie 要落在插件主机上，OAuth 端点才认
  curl -sS --noproxy '*' -o /dev/null -b "$1" -c "$1" \
    --data-urlencode "token=$SMOKE_TOKEN" "$SMOKE_BASE/_wonton/login" &&
    curl -sS --noproxy '*' -o /dev/null -L -b "$1" -c "$1" -H 'Accept: text/html' "${2%/}/"
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

data_write() { # 走 OAuth 拿会话，上传一张带标记的 1x1 PNG，资产 id 和标记写进 $SMOKE_STATE
  local base marker png out id
  base="$SMOKE_WEB_URL"
  core_login "$SMOKE_JAR" "$base" || { echo "核心会话建不了"; return 1; }
  immich_login "$SMOKE_JAR" "$base" || return 1
  marker="wonton-smoke-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  png="$(mktemp)"
  immich_marker_png "$marker" "$png" || { rm -f "$png"; echo "生成标记 PNG 失败"; return 1; }
  out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" \
    -F "assetData=@$png;type=image/png;filename=$marker.png" \
    -F "fileCreatedAt=$(date -u +%Y-%m-%dT%H:%M:%S%:z)" \
    -F "fileModifiedAt=$(date -u +%Y-%m-%dT%H:%M:%S%:z)" \
    "$base/api/assets")"
  local rc=$?
  rm -f "$png"
  ((rc == 0)) || { echo "上传失败：$out"; return 1; }
  id="$(jq -r '.id // empty' <<<"$out")"
  [[ -n "$id" ]] || { echo "上传响应没有 id：$out"; return 1; }
  printf '%s\n%s\n' "$id" "$marker" >"$SMOKE_STATE"
}

data_check() { # 升级/重装后读回资产：GET /api/assets/{id}，originalFileName 带标记（不等 ML 生成缩略图）
  local base id marker me
  base="$SMOKE_WEB_URL"
  {
    read -r id
    read -r marker
  } <"$SMOKE_STATE" 2>/dev/null
  [[ -n "${id:-}" && -n "${marker:-}" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  me="$(curl -sS --noproxy '*' -b "$SMOKE_JAR" -H 'Accept: application/json' "$base/api/assets/$id")"
  if ! jq -e --arg m "$marker" '.originalFileName == $m + ".png"' <<<"$me" >/dev/null 2>&1; then
    # 会话可能因重装失效：重走一遍核心登录和 OAuth 再试一次
    core_login "$SMOKE_JAR" "$base" || { echo "核心会话建不了"; return 1; }
    immich_login "$SMOKE_JAR" "$base" || return 1
    me="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Accept: application/json' "$base/api/assets/$id")" ||
      { echo "读资产失败：$me"; return 1; }
  fi
  jq -e --arg m "$marker" '.originalFileName == $m + ".png"' <<<"$me" >/dev/null ||
    { echo "资产不见了或对不上：$(head -c 200 <<<"$me")"; return 1; }
}

# ---------- 邮件（notify）：测试信经核心内部邮箱投进主人私聊 ----------
# Immich 管理端有同步的测试信端点（POST /api/admin/notifications/test-email，上游 notification-admin.controller），
# 发给请求者自己=主人的内部地址，成功回 messageId，SMTP 连不上 400；SMTP 参数用配置文件里同一套值传给端点，
# 证明这组值真发得出信。核心投进私聊的正文以插件名开头，投递等套件的通知房间助手（断言“Immich”）。
# 给新用户发的欢迎信（成功路径的另一半）要第二个家庭成员才触发，冒烟里不可脚本化，不写假断言。
immich_session() { # 走一遍 OAuth 链把应用会话放进 $SMOKE_JAR（同 identity_check 的走法，不做断言）
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
  curl -sS --noproxy '*' -b "$SMOKE_JAR" -c "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    "$SMOKE_WEB_URL/api/oauth/callback" >/dev/null || { echo "callback 失败"; return 1; }
}

_container() { # <插件 id> <服务名>：本实例里这个服务的容器
  local inst="${SMOKE_INSTANCE:-}" args=(--filter "label=wonton.plugin=$1" --filter "label=wonton.service=$2")
  if [[ -z "$inst" && -n "${SMOKE_BASE:-}" ]]; then
    inst="${SMOKE_BASE#http://}"; inst="${inst%%.*}"
  fi
  [[ -z "$inst" ]] || args+=(--filter "label=wonton.instance=${inst//-/}")
  docker ps --format '{{.Names}}' "${args[@]}" | head -1
}

extra_check() {
  local base server cfg out mail_host mail_port mail_from pid rc
  base="$SMOKE_WEB_URL"
  server="$(_container "$SMOKE_PLUGIN_ID" server)"
  [[ -n "$server" ]] || { echo "找不到 immich server 容器"; return 1; }

  # 0) 三个 SMTP 变量进了 server 容器（compose 显式透传，值快照进配置文件）
  mail_host="$(docker exec "$server" printenv WONTON_SMTP_HOST)" || { echo "server 容器没有 WONTON_SMTP_HOST"; return 1; }
  mail_port="$(docker exec "$server" printenv WONTON_SMTP_PORT)" || { echo "server 容器没有 WONTON_SMTP_PORT"; return 1; }
  mail_from="$(docker exec "$server" printenv WONTON_MAIL_FROM)" || { echo "server 容器没有 WONTON_MAIL_FROM"; return 1; }
  [[ "$mail_host" == "smtp.wonton.internal" && "$mail_port" == "25" &&
    "$mail_from" == "${SMOKE_PLUGIN_ID}@plugins.wonton.internal" ]] ||
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

  # 1) 先挂上投递等待再发测试信（发给主人账号的内部地址；消息可能在等待开始后马上到）
  probes_owner_room_wait 150 "Immich" & pid=$!
  immich_session
  rc=$?
  if ((rc == 0)); then
    out="$(curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
      -d "{\"enabled\":true,\"from\":\"$mail_from\",\"replyTo\":\"\",\"transport\":{\"host\":\"$mail_host\",\"port\":$mail_port,\"secure\":false,\"ignoreCert\":false,\"username\":\"\",\"password\":\"\"}}" \
      "$base/api/admin/notifications/test-email")"
    rc=$?
    if ((rc == 0)) && jq -e '.messageId | length > 0' <<<"$out" >/dev/null; then
      echo "测试信已发出（messageId 回执）"
    else
      rc=1
      echo "测试信没发出去或回执没有 messageId：$out"
    fi
  else
    echo "应用会话建不了"
  fi
  if ((rc != 0)); then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi

  # 2) 等核心把测试信投进主人的 Wonton 私聊（投递在核心日志里静默）
  wait "$pid" || { echo "投递没等到：上面是通知房间的最新消息"; return 1; }
  echo "核心已把 Immich 的测试信投进主人的 Wonton 私聊"
}
