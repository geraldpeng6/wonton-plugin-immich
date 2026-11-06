# 云吞插件：Immich 相册

云吞（Wonton）的插件就是一个 `docker-compose.yml`，顶层多一个 `x-wonton` 字段，写明插件在云吞里的身份、网页入口和要的
权限。一个插件一个 Git 仓库，仓库根目录就是插件包，发布就是打 tag。用户在 App 里装上插件，核心按清单起容器、接好登录，
插件的网页在 App 里作为小程序打开。

这个仓库是 Immich 相册的插件包：登录走核心的 OIDC，照片原件放共享文件夹 `photos`，缩略图和数据库等派生数据放插件自己的
数据目录。README 余下的部分是写插件的通用指南。

## 这个插件的行为

- 登录走云吞的 OIDC：网页经核心网关打开时自动登录；Immich 自己的登录页只在不经网关的直连地址上可见（见“局域网直连”）。管理员由一次性服务在空库时按注入的用户名建好，之后每次启动按用户名认这个账号，只同步邮箱；显示名在 Immich 里改。
  首次建号被打断时，仅当库中有唯一且未绑定 OIDC 的管理员才补齐绑定；无法唯一确认就报错，不按邮箱认人。
- 局域网直连（默认关）：在 App 的插件详情页打开“在局域网开放”开关后，Immich 的 2283 端口开在局域网地址上，
  官方 Immich App 和第三方客户端可以直连备份。开关下面显示要填进客户端的地址、邮箱和密码（密码是建号时
  核心生成的 `admin_password`；在 Immich 里改了密码，这里显示的不会跟着变）。
  官方 App 的 OAuth 回调是 `app.immich://` 自定义 scheme，核心的 OIDC 客户端只登记网关上的回调路径，
  App 走不了 OAuth（实测：Hydra 拒绝未登记的回调地址），密码登录是 App 能用的路。
  取舍：密码登录在 Immich 里是全局开关，打开后经核心网关的网页登录仍由 OIDC 自动跳转接管，不受影响；
  不经网关直连 2283 的网页会自动跳去核心的登录页（局域网里到不了），Immich 内置了逃生参数，
  打开 `/auth/login?autoLaunch=0`（v3.3.5 源码）登录页才显示邮箱密码表单。不开开关时端口关闭，没有这条路径。
- 设置在 compose 的 `immich-config` 里，经 `IMMICH_CONFIG_FILE` 交给 Immich：OAuth、密码登录、存储模板、
  智能搜索模型四组。
  上游规定存在配置文件时管理界面只读；没写进配置的设置是 Immich 的默认值，在这里也改不了。
- 智能搜索默认模型是 `ViT-B-16-SigLIP2__webli`：中文、英文都能按内容搜（上游 docs 的检索评测：
  Crossmodal-3600 中文 recall 66.8%、英文 84.9%；v0.2.0 用的 `ViT-B-32__openai` 只认英文）。选它而不是
  nllb 系列，是因为 nllb 要按查询语言加语言码才准，而 Bot 的 `search_photos` 不传语言（见下），上游 docs
  也把这类模型归为“中英混搜”的推荐类。模型选择的数据见 PR。
- 机器学习经出网从 Hugging Face 默认地址下载模型；要换地址只能改 compose。
  内存按上游要求最低 6G、推荐 8G；磁盘：搜索模型首次下载约 1.5 GB（visual + textual，f32），落盘约 3.6 GB
  （onnxruntime 加载时会在模型目录写一份硬件优化的副本），缩略图、转码视频和
  索引库随照片数增长，都放插件数据目录，不占共享文件夹。
- 每次启动由 bootstrap 补排智能搜索和人脸检测的“缺失”任务（`force: false`），只处理没有结果的照片，不重做已有结果；模型下载失败后配好出网代理，重启插件即可补跑。
- Bot 按内容搜照片：本仓库的只读 MCP 服务（`images/immich-mcp/`）经核心的 MCP 总线给 Bot 一个
  `search_photos` 工具，按画面描述调 Immich 的 smart search，返回文件名、拍摄日期和缩略图。它只调 Immich 的
  读接口（搜索、缩略图、ping），不做任何写操作，工具标了只读（`readOnlyHint`），Bot 调用不需要用户确认。
  凭据是 Immich API key（名字 `wonton-tools`），bootstrap 每次启动都核对：插件数据目录里的 token 文件和
  库里的行一致就跳过，否则删掉旧行、重建 key、重写文件——中途崩溃、用户在 Immich 里吊销、换了库，重启插件
  就恢复，不用动照片。权限只给搜索和缩略图要的 `asset.read`、`asset.view`（实测：搜索和缩略图可用，
  同一把 key 删照片、上传返回 403）。token 文件属主和搜索服务是同一个用户、权限 0400，别的插件和 Bot 读不到。
  key 失效不影响照片网页（健康检查只看 Immich 的 ping），工具调用时会单独报“权限失效，重启插件会重建”。

### 官方 App 怎么连（给用户的步骤）

1. 在云吞 App 的插件详情页打开“在局域网开放”，记下地址（形如 `http://192.0.2.10:2283`）、邮箱、密码。
2. 手机装官方 Immich App（App Store / Play Store / F-Droid），打开后点“登录”，服务器地址填上面的地址。
3. 邮箱、密码填开关下面的值，登录后时间线、备份开关都在 App 里。
4. 网页端（云吞里打开 Immich）几分钟内能看到手机上传的照片；备份是 App 后台行为，不用保持页面。

插件图标 `icon.png` 是 Immich v3.3.5 的官方 512×512 PNG 图标，未用图片模型生成；来源、版权、处理方式、上游 AGPL-3.0 全文和商标说明见 [NOTICE](NOTICE)。
Immich 名称和标志是 Immich 项目的商标；本插件使用标志仅用于标识所集成的应用，不表示与 Immich 存在官方合作或获得其背书。

## 准备

- Docker Engine 28 或更新的版本，带 Compose 插件（`docker compose`）。Linux 上的 Docker Engine、macOS 上的 Docker Desktop 和
  OrbStack 都行。
- `git`、`curl`（7.76 或更新）、`python3`。
- Docker 要在本机：开发环境的数据目录是这个仓库下的路径，网页也开在本机的端口上。在远程主机上开发见后面的
  “在远程主机上开发”。

不用装云吞，也不要 root：脚本用发布的核心镜像（`ghcr.io/geraldpeng6/wonton-core`）检查插件、起开发环境。

## 先跑起来

```bash
scripts/dev.sh up
```

```bash
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印核心地址。浏览器打开核心，用 `scripts/dev.sh token` 输出的用户令牌登录；再执行
`install` 装上本插件（会先列出权限），打开它打印的插件网页地址，进去就是用户。Chrome、Firefox 和 curl 把
`*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.png`、`screenshots/` | 商店图标和竖屏截图 |
| `bootstrap/bootstrap.cjs` | 一次性服务：建管理员，每次启动按用户名核对用户身份，并核对搜索服务的 Immich API key（对不上就重建） |
| `images/immich-mcp/` | 只读搜索服务的源码和 Dockerfile：一个 `search_photos` 工具，经核心的 MCP 总线给 Bot 用 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/publish.sh` | 发布一个版本：构建自己的镜像、按摘要写回、打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |

插件包是 `docker-compose.yml` 加上它引用的文件：`icon`、`settings`、`bot.avatar` 和顶层 `configs` 的 `file`。README、
截图、Dockerfile、源码都不在插件包里，核心不取。引用的路径相对仓库根目录，不能是绝对路径、不能含 `..`、不能用变量，
也不能经过软链接；单个文件不超过 1 MiB，整个插件包不超过 2 MiB。

## 写插件

按顺序改 `docker-compose.yml`，每改一步运行一次 `scripts/check.sh`，再 `scripts/dev.sh reinstall` 装上看效果。

### 1. 身份

```yaml
x-wonton:
  spec: "0.2"
  id: app.example.hello
  version: 0.1.0
  kind: app
  title: { zh: 你好, en: Hello }
  description: { zh: 向登录的人问好的示例网页, en: An example page that greets whoever is signed in }
  permissions: []
```

- `spec` 是清单按哪一版插件规范写的，要加引号（不然 YAML 读成数字）。
- `id` 是反向域名，全局唯一，装上后不能改：至少两段，每段由小写字母、数字和单个连字符组成，总长不超过 63。用你自己的
  域名或 GitHub 用户名开头，如 `app.alice.photos`。把 `.` 换成 `-` 就是插件的 slug（`app-alice-photos`），网页地址和
  Docker 里的资源名都用它。
- `version` 是插件包的版本（语义化版本），和应用、镜像的版本无关。
- `kind`：`app`（应用）、`agent`（Agent）、`channel`（第三方 IM 渠道）、`model`（模型服务）。`system` 只给随核心预装的
  官方插件。
- `title`、`description` 至少写 `zh` 和 `en`。
- `permissions` 必填，不要权限时写空列表。
- `requirements` 可选：`arch`（如 `[amd64, arm64]`，和用户的服务器架构不符时装不上）、`memory`（如 `2G`）、
  `gpu`（`required` 或 `optional`）。
- 插件的设置做在插件自己的网页里。清单的 `settings`（给 App 渲染原生表单的 JSON Schema）是预留的。
- 清单里有未知字段时装不上：拼错的字段不会被悄悄忽略。

### 2. 服务

`services` 照常写 compose，核心只认下面这些字段，其余的一律报错：

- 服务：`image`、`command`、`entrypoint`、`environment`、`volumes`、`configs`、`restart`（没写时是 `unless-stopped`）、
  `healthcheck`、`depends_on`、`user`、`working_dir`、`labels`（`wonton.` 开头的留给核心）、`hostname`、`expose`、`init`、
  `read_only`、`shm_size`、`tmpfs`、`stop_signal`、`stop_grace_period`、`pull_policy`（默认 `missing`）、
  `network_mode`（只能是 `none`），以及 `x-` 开头的扩展字段。
- 顶层：`name`、`services`、`volumes`（不带参数的本地卷）、`configs`、`x-wonton` 和 `x-` 开头的扩展字段。
- 不能用：`ports`、`networks`、`privileged`、`devices`、`cap_add`、`security_opt`、`pid`、`ipc`、`container_name`、`build`、
  `env_file`、`extends`、`links`、`external_links`、`volumes_from`，顶层的 `networks`、`secrets`，以及 `environment` 里只写
  键、不写值（取宿主的环境变量）的写法。网页一律经核心的网关访问，所以不发布端口。

服务之间用服务名互访。镜像用上游的官方镜像，不改它、不另发修改版；按摘要固定，写成 `名字:标签@sha256:…`，多架构镜像写
清单列表（index）的摘要：

```bash
docker buildx imagetools inspect nginx:1.30.6-alpine
```

输出开头的 `Digest:` 就是。没按摘要固定也能装，但检查会提醒，官方商店不收。

### 3. 网页入口和登录

```yaml
  webui:
    service: web
    port: 80
    sso: proxy
    proxy:
      headers:
        Remote-User: "{user}"
```

`webui` 指向一个服务的端口（`path` 默认 `/`）。插件网页的地址是 `http://<slug>.<基础域名>[:端口]/`，所有请求先经核心的
网关：没登录的请求到不了插件，网关去掉客户端伪造的 `X-Forwarded-*`，保留原始的 `Host`，支持 WebSocket。`sso` 决定
用户怎样登进应用：

- `oidc`：应用支持 OIDC 时首选，由核心的身份提供方登录，用户不会看到第二个登录页。写上应用登录回调的路径
  `oidc.redirect_paths`（如 `[/auth/callback]`），在 `environment` 里把注入的 `WONTON_OIDC_ISSUER`、
  `WONTON_OIDC_CLIENT_ID`、`WONTON_OIDC_CLIENT_SECRET` 交给应用；不支持发现文档的应用另有
  `WONTON_OIDC_AUTH_URL`、`WONTON_OIDC_TOKEN_URL`、`WONTON_OIDC_USERINFO_URL`。可以申请的 scope 有 `openid`、`profile`、
  `email`、`groups`（用户是 `["owner"]`）、`offline_access`。
- `proxy`：应用不支持 OIDC，但认反向代理传来的用户名（Navidrome、Paperless-ngx、Grafana 的 auth proxy）或一个固定的
  密钥时用。网关认出用户后，在转发给插件的请求上加上 `proxy.headers` 或 `proxy.cookies`，值里可以用 `{user}`、`{name}`、
  `{email}` 和 `{secret:<名字>}`（插件密钥里由核心生成、至少 16 字节的一项，见第 8 步）；Cookie 的值只能用
  `{secret:…}` 和固定文字。网关先删掉客户端发来的同名请求头和 Cookie，客户端伪造不了；插件网络里只有核心和插件自己的
  服务，所以应用“信任的代理地址”可以放宽到整个网络。示例就是这样拿到用户名的。
- `none`（默认）：网关只校验登录，应用保留自己的登录，或者本来就不需要登录。

### 4. 数据

```yaml
services:
  app:
    user: "${PUID}:${PGID}"
    volumes:
      - ${WONTON_APP_DATA}/config:/config
      - ${WONTON_SHARE_PHOTOS}:/photos:ro
```

- `${WONTON_APP_DATA}` 是插件自己的数据目录（宿主上的路径），挂它的子目录。核心安装前逐级建好这些目录，属主看挂载它的
  服务的 `user`：没写或是 root 时交给 `PUID:PGID`（以 root 启动、再按 `PUID`/`PGID` 降权的镜像就是这样，如
  LinuxServer.io 的镜像）；写成数字的 `uid:gid` 时交给它（镜像固定以某个 uid 运行时写上它）；写用户名或只写 uid 时装不上，
  几个服务以不同的属主挂载同一个目录时也装不上。能以任意 uid 运行的镜像写 `user: "${PUID}:${PGID}"`，宿主上的文件就归
  用户的用户。核心只改这些目录本身的属主，不递归改里面已有的文件。
- 开发环境里 `${WONTON_APP_DATA}` 是 `.wonton/data/apps/<slug>/`，可以直接看插件写了什么。
- 也可以用命名卷：在顶层 `volumes` 里声明，Docker 里叫 `wonton-<slug>--<卷名>`。
- 共享文件夹（照片、文档、音乐……）要在 `permissions` 里申请 `storage.share.<名称>:read` 或 `:write`，挂
  `${WONTON_SHARE_<名称大写>}`。只读的必须写 `:ro`，而且只能挂整个文件夹，不能挂子目录。
- 只能挂这几种宿主路径，不能有 `..`，不支持相对路径；同一个插件的绑定挂载不能一个套着另一个。
- 卸载时默认保留数据（数据目录、命名卷、插件密钥），再装时接着用；用户选了删除数据才删。共享文件夹永远不删。

### 5. 网络

- 插件默认不能出网：它的 Docker 网络是内部网络，访问不了外网和局域网，也解析不了外部域名。要出网（下载封面、同步、调
  第三方 API）就申请 `network.egress`，装的时候列在权限里。镜像由 Docker 拉取，不受这个限制。
- 插件之间互相访问不到。插件要用的核心的服务（身份提供方、模型网关、Matrix、MCP 总线）由核心在插件网络里提供，地址都在
  注入的变量里，不要自己拼。

### 6. 权限

| 权限 | 含义 |
| --- | --- |
| `storage.share.<名称>:read`、`:write` | 读或写一个共享文件夹，如 `photos`、`documents`、`music`、`downloads` |
| `network.egress` | 访问外网和局域网 |
| `models` | 经模型网关用大模型，注入 `WONTON_MODEL_*` |
| `tools` | 经核心的 MCP 总线调用核心和其他插件的工具，注入 `WONTON_MCP_URL` |
| `matrix.bot` | 以 Bot 的身份收发消息，注入 `WONTON_MATRIX_*` |
| `storage.home:read`、`:write`，`notify`，`network.host`，`devices.<路径>`，`docker.socket` | 规范里有，核心还不支持的，安装预览如实说装不了 |

安装时用户要确认清单里的全部权限，少一项多一项都装不上。只申请真用得到的：权限越少，用户越放心。

### 7. 注入的变量

核心在安装时提供下面这些变量，只用于 compose 插值（`${VAR}`、`${VAR:-默认值}`，`$$` 是字面的 `$`），不会自动进入容器：
要用的变量在服务的 `environment` 里显式写上，密钥只给用得到它的服务。引用了没提供的变量、又没写默认值时装不上。

| 变量 | 什么时候有 |
| --- | --- |
| `WONTON_APP_ID`、`WONTON_APP_DATA`、`TZ`、`PUID`、`PGID` | 总是 |
| `WONTON_APP_URL` | 有 `webui`：插件网页的地址，不带末尾的 `/`，应用生成链接和回调地址时用 |
| `WONTON_SHARE_<名称>` | 申请了这个共享文件夹 |
| `WONTON_OIDC_*` | `sso: oidc` |
| `WONTON_MODEL_BASE_URL`、`WONTON_MODEL_API_KEY`、`WONTON_MODEL_DEFAULT` 等 | `models` |
| `WONTON_MCP_URL` | `tools` |
| `WONTON_MATRIX_HOMESERVER`、`WONTON_MATRIX_USER_ID`、`WONTON_MATRIX_ACCESS_TOKEN` 等 | `matrix.bot` |
| `WONTON_SECRET_<名字>` | `secrets` 里核心生成的项 |
| `WONTON_BOT_NAME`、`WONTON_BOT_DATA` | `bots.services` 里的服务 |

### 8. 包里的文件和密钥

容器要用的包里的文件经 `configs` 交给它，不能用卷挂载：

```yaml
services:
  web:
    configs:
      - source: page
        target: /usr/share/nginx/html/index.html
configs:
  page:
    file: web/index.html
```

- 顶层 `configs` 只支持 `file`（包里的文件）和 `content`（内联的文本，按注入的变量插值）。
- 核心在创建容器后、启动前把文件写进容器，每次创建容器都重新写；`uid`、`gid`、`mode` 对 `file` 也生效（`mode`
  默认 `0444`）。`target` 不能落在这个服务的挂载点里，`read_only: true` 的服务不能用 `configs`。
- 应用自己会改写的配置，由一个一次性服务在首次启动前复制进数据目录、已经有了就不覆盖：

  ```yaml
  services:
    init:
      image: &image ghcr.io/example/app:1.2.3@sha256:…   # 两个服务用同一个镜像
      entrypoint: ["/bin/sh", "-c", "test -f /data/config.yaml || cp /seed/config.yaml /data/config.yaml"]
      volumes:
        - ${WONTON_APP_DATA}:/data
      configs:
        - source: config
          target: /seed/config.yaml
      network_mode: none
      restart: "no"
    app:
      image: *image
      depends_on:
        init:
          condition: service_completed_successfully
  ```

  一次性服务必须写 `restart: "no"`。核心每次创建插件的容器（安装、升级、重建）时都先运行它，所以它要幂等。

插件自己的密钥写在 `secrets` 里，存在核心的密钥库，卸载时保留数据就一起保留：

```yaml
x-wonton:
  secrets:
    db_password:
      generate: { bytes: 32 }   # 核心生成，注入为 WONTON_SECRET_DB_PASSWORD
    recovery_key:
      collect: { service: app, path: /data/recovery-key.txt }   # 插件运行中生成，核心读出来保管
```

`generate` 的 `bytes` 是 1 到 1024，默认 32；`encoding` 是 `hex`（默认）或 `base64`。生成过就不再变，改了 `bytes`、
`encoding` 也不重新生成。

### 9. 健康检查

长期运行的服务都要有健康检查，而且检查真正可用，不只是进程活着。写在 compose 里，带上 `start_period` 和
`start_interval`：安装时尽快判断就绪，启动慢时又不会误判失败。只能用镜像里有的命令：distroless 之类的镜像里没有
`curl`、`wget`。没有健康检查的插件照常能装，状态显示为“健康未知”；官方商店不收。

安装时核心按 `depends_on` 的顺序启动容器，等每个服务健康（或稳定运行）、一次性服务以 0 退出、网页入口能响应，任何一步
失败都回滚，错误里附上容器最近的日志。

### 10. 商店信息

商店、安装确认页和 App 主屏用到的信息也写在清单里，随插件版本一起固定：

| 字段 | 说明 |
| --- | --- |
| `icon` | 包里的 PNG 或 SVG，正方形、画面铺满，不留透明边、不画圆角和阴影（App 统一裁成圆角，重要内容放在中间 80%）。PNG 至少 256×256、建议 512×512、不超过 512 KiB。SVG 的 `viewBox` 是正方形、不超过 128 KiB；文字要转成路径；不能用 `<pattern>`、`<marker>`、`<filter>`；`<use>` 只写一个 `href="#id"`；`<style>` 里只用 `.cls-1`、`rect.a` 这样不带组合符的选择器（`g rect`、`g > rect` 不行）；不加载外部资源。核心在限了 512 MiB 内存、10 秒的进程里渲染，超出的图标装不上（很细的虚线这类写法渲染很慢）。`scripts/check.sh` 按同样的规则检查 |
| `screenshots` | 仓库里 1 到 6 张 PNG 或 JPEG，每张不超过 1 MiB，长边建议至少 1280，横屏竖屏不要混着用。不算插件包 |
| `category` | `ai`、`agent`、`photos`、`media`、`files`、`documents`、`productivity`、`communication`、`home`、`network`、`security`、`developer`、`downloads`、`tools` 之一 |
| `author` | 插件包的作者：`name`，可选 `url`（HTTPS） |
| `homepage` | 应用的主页，HTTPS |
| `license` | 应用的许可证，SPDX 表达式，如 `AGPL-3.0-only`。插件包自己的许可证写在仓库的 LICENSE 里 |
| `tags` | 搜索用的关键词，最多 8 个，每个 1 到 24 个字符 |
| `about` | 详细介绍，多语言纯文本，空行分段，每种语言不超过 4000 个字符 |
| `release_notes` | 这个版本的更新说明，多语言纯文本，每种语言不超过 2000 个字符，升级提示里显示；数据迁移不可逆时要写明 |

官方商店要求有 `icon`、`category`、`license` 和 `author`。

### 11. Agent、Bot、模型和工具

- 要以 Bot 身份收发消息的插件申请 `matrix.bot`，可以用 `bot.display_name`（多语言）、`bot.avatar`（包里的图片）定显示名
  和头像。核心替用户建好和 Bot 的加密私聊（`WONTON_MATRIX_HOME_ROOM`）；Bot 只接受 `WONTON_MATRIX_OWNER` 的指令。
  一个插件要几个 Bot 时用 `bots`，每个 Bot 一组容器。
- `kind: agent` 的插件要写 `agent.protocol`：`matrix`（Agent 自己登录 Matrix，要申请 `matrix.bot`）或 `acp`（经 ACP
  桥接入）。
- 用大模型的插件申请 `models`，只经注入的模型网关地址和凭据访问，不要自带第三方的 API key。
- 给 Agent 提供工具的插件写 `mcp`（`service`、`port`、`path` 默认 `/mcp`，`transport: streamable-http`）；要调用工具的
  插件申请 `tools`。

这几项的细节（多 Bot 的写法、模型凭据、工具的命名和权限）见插件规范的对应章节。

## 开发环境

| 命令 | 做什么 |
| --- | --- |
| `scripts/dev.sh up` | 起开发环境，等到都健康；再执行一次就是拉最新的核心镜像重启 |
| `scripts/dev.sh install [--yes] [<git 引用>]` | 预览、确认后安装；给了 tag、分支或提交就装那个版本（用你自己的 git 导出，私有仓库也行） |
| `scripts/dev.sh reinstall [--yes]` | 装着就先卸载（保留数据），再装上工作区里的：改了插件包后用 |
| `scripts/dev.sh uninstall [--purge]` | 卸载；`--purge` 连插件的数据一起删 |
| `scripts/dev.sh status` | 开发环境的服务和装着的插件 |
| `scripts/dev.sh logs [<服务>]` | 跟着看核心的日志；给了插件的服务名就看那个服务的 |
| `scripts/dev.sh token` | 用户令牌 |
| `scripts/dev.sh web [<路径> [<curl 参数>…]]` | 以用户的身份请求插件网页上的地址（默认 `/`），其余参数交给 curl：没有浏览器时验证网页和接口 |
| `scripts/dev.sh pair` | 终端里出配对二维码，App 扫码连上这套开发环境 |
| `scripts/dev.sh down` | 停下，数据都留着 |
| `scripts/dev.sh purge` | 删掉整个开发环境 |

开发环境和正式安装用同一份 compose（核心、身份提供方 Ory Hydra、Matrix 服务器 Tuwunel），只是项目名、核心的容器名
和实例名不同；核心起来后同样预装模型网关 magpie（`ai.usemagpie.magpie`）。第一次 `up` 时定下设置，写在 `.wonton/.env`：

- 实例名（`WONTON_INSTANCE`）：默认是目录名（去掉 `wonton-plugin-` 前缀）加 4 位随机数。核心建的容器、网络和卷都带上它，
  如 `wonton-hello3f2a--app-example-hello--web`，再打上 `wonton.instance` 标签。几个人或几个 Agent 共用一台 Docker 时各起
  各的开发环境，同一个插件也能在几套里同时装，卸载时只删自己那套的。
- 基础域名是 `<实例名>.wonton.localhost`，核心在 `http://<实例名>.wonton.localhost:<端口>/`，插件网页在
  `http://<slug>.<实例名>.wonton.localhost:<端口>/`。
- 端口：网页用一个随机挑的空闲端口，隧道（UDP）用下一个。
- 核心镜像：默认 `ghcr.io/geraldpeng6/wonton-core:beta`。第一次 `up` 时可以用 `WONTON_CORE_IMAGE` 换掉；本机构建的镜像再
  加上 `WONTON_PULL=never`，不去拉取。之后改 `.wonton/.env` 里的 `WONTON_CORE_SOURCE` 再 `up`。

几点要注意：

- `down` 只停核心、身份提供方和 Matrix 服务器，插件的容器由核心管，照常运行；不要了就 `uninstall` 或 `purge`。
- 实例名和基础域名定下后不能改：基础域名也是 Matrix 的服务器名，实例名改了就找不到已经装上的插件。要换就先 `purge`。
- 共用一台 Docker 时只用这些脚本起停和清理，不要 `docker system prune`、`docker volume prune`，也不要动名字里不是自己实例名
  的容器、网络和卷。
- 每套开发环境至少占 3 个 Docker 网络（核心一个，magpie 和每个插件各一个），Docker 默认的地址池大约 30 个。一台主机上
  开很多套、报 “all predefined address pools have been fully subnetted” 时，在 Docker 的 `daemon.json` 里把
  `default-address-pools` 配得更细（如 `/24`）。

### 排错

- 安装失败时，错误里有原因和失败的容器最近的日志。装上后用 `scripts/dev.sh logs <服务>` 看，或者进容器看：
  `docker exec -it wonton-<实例名>--<slug>--<服务> sh`。
- `scripts/dev.sh status` 列出插件的状态：`running healthy` 是每个长期运行的服务都有健康检查而且都通过了；
  `running unknown` 是只知道在运行（有服务没有健康检查，或者核心重启后检查未通过）；`degraded` 后面是原因。核心在
  安装时和每次启动时检查，两次检查之间不盯着插件，容器停了要看 `docker ps`。
- 管理接口用用户令牌调：

  ```bash
  curl -H "Authorization: Bearer $(scripts/dev.sh token)" http://<实例名>.wonton.localhost:<端口>/_wonton/api/plugins
  ```

### 在远程主机上开发

Docker 在另一台 Linux 主机上时，把仓库克隆到那台主机，在那里执行脚本。浏览器在自己的电脑上，用 SSH 把开发环境的端口转发
过来，再打开同样的地址：

```bash
ssh -L 21234:127.0.0.1:21234 <远程主机>
```

`*.localhost` 在自己的电脑上解析到本机，经转发到远程主机的开发环境，地址里的域名原样带到核心的网关。

### 在 App 里看

`scripts/dev.sh pair` 在终端里出配对二维码，用云吞 App 扫码，App 就连上这套开发环境，插件在主屏上。手机在局域网里时要能
访问这台主机的隧道端口（UDP，`.wonton/.env` 里的 `WONTON_TUNNEL_PORT`），在外面时经中继连上。

## 检查

```bash
scripts/check.sh
```

在核心镜像里执行 `wonton-core plugin check`，和安装时同一套解析和校验，再检查商店信息、图标和截图，最后列出插件包里的
文件和插件包摘要。不连 Docker 里的核心，也不联网。

- 插件包解析不了时只报这一条，和安装时报的一样。
- 不合格（退出码 1）：装不上的（核心不支持的权限、渲染不了的 compose），图标或截图处理不了。
- 提醒（退出码 0）：镜像没有按摘要固定，长期运行的服务没有健康检查，没有图标，图标的角是透明的，截图太小或横竖混用。

`scripts/check.sh --official` 按官方商店的要求：前三项提醒（镜像没按摘要固定、没有健康检查、没有图标）也算不合格，
还要有 `category`、`license` 和 `author`。

## 发布

1. 把清单的 `version` 改成新版本，写好 `release_notes`，提交。
2. 执行 `scripts/publish.sh`（要进官方商店加 `--official`）。它检查工作区干净、插件包合格，构建自己的镜像（下面），打 tag
   `v<版本>`，推送当前分支和 tag。

发布过的 tag 不要移动：已经装上的不受影响，但核心会提示用户这个 tag 被改过。带预发布后缀的版本（如 `v1.2.0-beta.1`）只能
按 tag 明确安装，不进商店，也不作为升级提示。

插件要用自己构建的镜像时，把 Dockerfile 放在 `images/<名字>/`，compose 里写 `image: ghcr.io/<你>/<名字>:<版本>`。
`publish.sh` 用 `docker buildx` 构建 linux/amd64 和 linux/arm64 的镜像，推上去，把 compose 里这一行改成新版本的摘要再
提交。这需要能构建多架构镜像的 buildx，和 `docker login` 登录镜像仓库；镜像要公开，用户的服务器才拉得到。核心不构建镜像，
所以 compose 里不能写 `build`。开发时先在本机构建同名的镜像（`docker build -t ghcr.io/<你>/<名字>:<版本> images/<名字>`），
本机有这个镜像时核心不去拉取。

仓库公开、加上 topic `wonton-plugin` 后，插件出现在商店的社区插件里，标为“未审核”。想进官方商店，按 `--official` 的
要求准备好，向官方索引提 PR。仓库私有时核心取不到，用 `scripts/dev.sh install <tag>` 从本地导出安装。

## 界面

> Avoid unnecessary secondary labels and descriptions. Let the layout do the explaining.

插件自己的网页也照这条做：分组、顺序、位置和图标已经说明了的，不再加副标题、说明文字或标签重复一遍。错误、权限这类提示
不算多余，照常写清楚。

## 规则以哪里为准

这里写的是[插件规范](https://github.com/geraldpeng6/wonton-docs/blob/main/plugin-spec.md) `x-wonton` v0.2 里写插件
要知道的部分，完整的规则和理由在规范里。规范和核心一起演进；说法对不上时以核心的检查为准：`scripts/check.sh` 通过、
`scripts/dev.sh install` 装得上，插件包才算写对了。
