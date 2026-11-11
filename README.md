# 云吞插件：Immich 相册

开发流程见[插件开发指南](https://github.com/wontonapp/wonton-docs/blob/main/develop.md)。

云吞（Wonton）插件：Immich 相册，照片原件放共享文件夹 `photos`，缩略图和数据库等派生数据放插件自己的数据目录。登录走核心的
OIDC。

## 插件行为

- 登录走云吞的 OIDC：网页经核心网关打开时自动登录；Immich 自己的登录页只在不经网关的直连地址上可见（见“局域网直连”）。管理员由一次性服务在空库时按注入的用户名建好，之后每次启动按用户名认这个账号，只同步邮箱；显示名在 Immich 里改。
  首次建号被打断时，仅当库中有唯一且未绑定 OIDC 的管理员才补齐绑定；无法唯一确认就报错，不按邮箱认人。
- 局域网直连（默认关）：在 App 的插件详情页打开“在局域网开放”开关后，Immich 的 2283 端口开在局域网地址上，
  官方 Immich App 和第三方客户端可以直连备份。开关下面显示要填进客户端的地址、邮箱和密码（密码是建号时
  核心生成的 `admin_password`；在 Immich 里改了密码，这里显示的不会跟着变）。
  官方 App 的 OAuth 回调是 `app.immich://` 自定义 scheme，核心的 OIDC 客户端只登记网关上的回调路径，
  App 走不了 OAuth（实测：Hydra 拒绝未登记的回调地址），密码登录是 App 能用的路。
  取舍：密码登录在 Immich 里是全局开关，打开后经核心网关的网页登录仍由 OIDC 自动跳转接管，不受影响；
  不经网关直连 2283 的网页会自动跳去核心的登录页（局域网里到不了），Immich 内置了逃生参数，
  打开 `/auth/login?autoLaunch=0`（v3.3.6 源码）登录页才显示邮箱密码表单。不开开关时端口关闭，没有这条路径。
- 设置在 compose 的 `immich-config` 里，经 `IMMICH_CONFIG_FILE` 交给 Immich：OAuth、密码登录、存储模板、邮件发送、
  智能搜索模型五组。
  上游规定存在配置文件时管理界面只读；没写进配置的设置是 Immich 的默认值，在这里也改不了。
- 应用发的信走云吞的内部邮箱（`notify` 权限）：新用户欢迎信、共享相册的邀请和更新转进收件人的 Wonton 私聊。
  SMTP 写死在 `immich-config` 里：核心的 SMTP 不认证不加密，Immich 不填用户名密码就不发 AUTH（上游
  email.repository.ts 的 createTransport），`from` 用核心给的 `WONTON_MAIL_FROM`。
  收件人只能是家里人：共享相册本来就只在家用账号之间分享；给外部邮箱建用户这类操作，欢迎信在 SMTP 阶段
  被核心拒收（550），Immich 报发送失败，账号本身建得起来。
- 智能搜索默认模型是 `ViT-B-16-SigLIP2__webli`：中文、英文都能按内容搜（上游 docs 的检索评测：
  Crossmodal-3600 中文 recall 66.8%、英文 84.9%；v0.2.0 用的 `ViT-B-32__openai` 只认英文）。选它而不是
  nllb 系列，是因为 nllb 要按查询语言加语言码才准，而 Bot 的 `search_photos` 不传语言（见下），上游 docs
  也把这类模型归为“中英混搜”的推荐类。模型选择的数据见 PR。
- 机器学习经出网从 Hugging Face 默认地址下载模型；要换地址只能改 compose。
  内存按上游要求最低 6G、推荐 8G；磁盘：搜索模型首次下载约 1.5 GB（visual + textual，f32），落盘约 3.6 GB
  （onnxruntime 加载时会在模型目录写一份硬件优化的副本），缩略图、转码视频和
  索引库随照片数增长，都放插件数据目录，不占共享文件夹。
- 每次启动由 bootstrap 补排智能搜索和人脸检测的“缺失”任务（`force: false`），只处理没有结果的照片，不重做已有结果；模型下载失败后配好出网代理，重启插件即可补跑。
- 换模型会作废旧索引：bootstrap 记下已全量重建过的智能搜索模型名（插件数据目录 state/clip-rebuilt），
  启动时发现配置里的模型变了，就排一次全量重编码（`force: true`，管理页“全部”同款），重复启动不重复
  全量跑；从 v0.2.0 升级后第一次启动会重建一次，向量维度的迁移由 Immich 在启动时自己完成。
- Bot 按内容搜照片：本仓库的只读 MCP 服务（`images/immich-mcp/`）经核心的 MCP 总线给 Bot 一个
  `search_photos` 工具，按画面描述调 Immich 的 smart search，返回文件名、拍摄日期和缩略图，工具标了只读（`readOnlyHint`），Bot 调用不需要用户确认。
  搜索失败以 `isError` 区分服务不可达和上游错误；仅 ML 的限时 `/predict` 探针明确报告模型加载失败时提示配置出网代理，不把通用 500 或超时当作模型下载状态，也不修改照片。
  凭据是 Immich API key（名字 `wonton-tools`），bootstrap 每次启动都核对：插件数据目录里的 token 文件和
  库里的行一致就跳过，否则删掉旧行、重建 key、重写文件——中途崩溃、用户在 Immich 里吊销、换了库，重启插件
  就恢复，不用动照片。权限只给搜索和缩略图要的 `asset.read`、`asset.view`（实测：搜索和缩略图可用，
  同一把 key 删照片、上传返回 403）。token 文件属主和搜索服务是同一个用户、权限 0400，别的插件和 Bot 读不到。
  key 失效不影响照片网页（健康检查只看 Immich 的 ping），工具调用时会单独报“权限失效，重启插件会重建”。

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。

### 官方 App 怎么连（给用户的步骤）

1. 在云吞 App 的插件详情页打开“在局域网开放”，记下地址（形如 `http://192.0.2.10:2283`）、邮箱、密码。
2. 手机装官方 Immich App（App Store / Play Store / F-Droid），打开后点“登录”，服务器地址填上面的地址。
3. 邮箱、密码填开关下面的值，登录后时间线、备份开关都在 App 里。
4. 网页端（云吞里打开 Immich）几分钟内能看到手机上传的照片；备份是 App 后台行为，不用保持页面。

## 图标来源与许可

`icon.png` 是 Immich v3.3.5 的官方 512×512 PNG 图标，未用图片模型生成；来源、版权、处理方式、上游 AGPL-3.0 全文和商标说明见 [NOTICE](NOTICE)。
Immich 名称和标志是 Immich 项目的商标；本插件使用标志仅用于标识所集成的应用，不表示与 Immich 存在官方合作或获得其背书。

## 先跑起来

```bash
scripts/dev.sh up
scripts/dev.sh install
```

`up` 在本机起一套云吞并打印核心地址，用 `scripts/dev.sh token` 输出的用户令牌登录；`install` 装上本插件（会先列出权限），
打开它打印的插件网页地址，进去就是用户。Chrome、Firefox 和 curl 把 `*.localhost` 直接解析到本机，不用改 hosts。

## 仓库里有什么

| 路径 | 内容 |
| --- | --- |
| `docker-compose.yml` | 插件本身：compose 加上 `x-wonton` 清单 |
| `icon.png`、`screenshots/` | 商店图标和竖屏截图 |
| `bootstrap/bootstrap.cjs` | 一次性服务：建管理员，每次启动按用户名核对用户身份，并核对搜索服务的 Immich API key（对不上就重建） |
| `images/immich-mcp/` | 只读搜索服务的源码和 Dockerfile：一个 `search_photos` 工具，经核心的 MCP 总线给 Bot 用 |
| `scripts/check.sh` | 检查插件包，规则和安装时一样 |
| `scripts/dev.sh` | 开发环境：起一套云吞，装、重装、卸载插件，看日志 |
| `scripts/smoke-probes.sh` | `scripts/dev.sh smoke` 对这个插件逐项的探测 |
| `scripts/publish.sh` | 发布一个版本：构建自己的镜像、按摘要写回、打 tag、推送 |
| `AGENTS.md` | 给人和 AI 编程代理的规则 |
| `LICENSE`、`NOTICE` | 插件许可证、上游许可证和商标声明 |
| `.wonton/` | 开发环境的设置、密钥和数据，不提交 |
