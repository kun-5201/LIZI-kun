# LIZI 七边车 Swift 移植规格（sidecars.md）

> 来源：`/home/hatch/workspace/liziair-check/` —— `server.mjs`（4476 行）与
> `services/{qq,kuwo,qishui,bodian,spotify}-api/start.mjs` 及各目录 `README.md`、
> `services/qishui-api/qr.mjs`。本文只写规格，不写 Swift 代码，不改源码。
>
> 约定：
> - 「边车 HTTP 接口」= `start.mjs` 在 `127.0.0.1:<port>` 上暴露的路由，是 Swift 移植必须复现的对内契约。
> - 「主服务接口」= `server.mjs` 的 `/api/<平台>/*`，是前端看到的形状；移植时 Swift 端直接实现主服务接口的语义即可，不必保留边车这一层。
> - 「上游接口」= 边车/协议库实际打向第三方服务器的地址。**QQ 的包内上游、汽水/波点的协议库内上游不在仓库里**（`node_modules/` 未随仓库提交，本机也没有安装），本文只写源码里逐字出现的上游 URL；包内的其余上游地址标注为「库内，未在仓库中」，移植时须对照对应 npm 包版本实现，不得凭记忆编造。
> - 所有 URL、参数名、状态码、错误原文均从源码抄录。含糊处以「⚠️ 未在源码中明确」标出。
> - 网易云边车（`services/netease-api/`，端口 3215）与 LX（`services/lx-api/`）不在本文范围。

---

## 0. 通用边车机制（七边车共用，server.mjs + 各 start.mjs）

### 0.1 端口与拉起

| 边车 | 默认端口 | 环境变量覆盖 | ping 探针（server.mjs `SIDECARS`） | 需要 Node ≥ 24 |
|---|---|---|---|---|
| qq | 3210 | `QQ_API_PORT` | `GET /login/channels`（`qqPing`，超时 1500ms） | 否 |
| qishui | 3212 | `QISHUI_API_PORT` | `GET /health` | **是** |
| bodian | 3213 | `BODIAN_API_PORT` | `GET /health` | **是** |
| spotify | 3214 | `SPOTIFY_API_PORT` | `GET /health` | 否 |
| kuwo | 3216 | `KUWO_API_PORT` | `GET /health` | 否 |

端口优先级（各 `start.mjs` 的 `preferredPort()`，各边车同一套）：环境变量 → 上次写下的 `.port` 文件 → 默认端口。
`.port` 文件在读出后**立即删除**（`fs.unlinkSync(PORT_FILE)`），因为 server.mjs 靠「文件出现」判断子进程是否就绪，留着旧端口会误判。

server.mjs 拉起流程（`ensureSidecar(name)` / QQ 单独的 `ensureQQ()`）：

1. 读 `services/<dir>/.port`，ping 通就复用；并发请求共用同一次拉起（`starting` promise）。
2. 否则删 `.port`，`spawn(bin, [start.mjs])`，`cwd` 为边车目录，`stdio: ['ignore', fd, fd]`（子进程 stdout/stderr 直接追写进边车自己的 `.log`），环境变量带 `<ENV>_PARENT_PID=<主服务 pid>`（QQ 是 `QQ_PARENT_PID`，余者按 `SIDECARS[name].env`）。
3. 每 150ms 轮询 `.port` + ping，最长 **25 秒**；子进程提前退出或超时都抛错，错误里带边车日志尾巴（见 0.3）。
4. 端口不可用（`EADDRINUSE` / `EACCES`）时边车只重试一次：`server.listen(0, '127.0.0.1')` 用系统分配端口，并把真实端口写进 `.port`。
5. 子进程退出后 server.mjs 把句柄置空，下次请求自动重起。边车另盯父进程 pid：每 5 秒 `process.kill(parentPid, 0)`，父进程没了就自己退出（`log('父进程已退出，边车跟着收工')` 后 `process.exit(0)`）。
6. 就绪信号：边车写 `.port` 后在 stdout 打印 `QQ_API_READY <port>` / `QISHUI_API_READY <port>` / `BODIAN_API_READY <port>` / `SPOTIFY_API_READY <port>` / `KUWO_API_READY <port>`。
7. 日志：每个边车写本目录 `.log`，超过 **2MB** 就改名为 `.log.1`（`fs.renameSync`）。Node 20 的 `console.log` 在 stdout 管道被关时会抛 `EPIPE`，各 `start.mjs` 都先给 stdout/stderr 挂 `error` 忽略，并对 `uncaughtException` / `unhandledRejection` 中 `EPIPE` / `ERR_STREAM_DESTROYED` 直接 return，其余异常记 `FATAL` 后 `process.exit(1)`。

汽水/波点的 Node ≥ 24 约束（`server.mjs` 的 `resolveNode24()`）：

- 主服务自身是系统 node 且 ≥ 24 时直接用 `process.execPath`；否则用 `LIZI_NODE_BIN` 环境变量或 `node` 命令跑 `node --version` 探测。
- 找不到 node 或版本 < 24 时**不 spawn**，直接抛错，`err.reason = 'node-version'`，主服务回 `{ code: 502, ok: false, reason: 'node-version', error: '本机 node 版本不足：这个音源要求 ≥ 24，当前是 v…' }`，前端据此置灰该音源并隐藏登录键。
- 边车自身也有一道闸：版本 < 24 时打印 `QISHUI_API_UNSUPPORTED_NODE <ver>` / `BODIAN_API_UNSUPPORTED_NODE <ver>` 并 `process.exit(2)`。
- 背景：`server.mjs` 可能跑在 Electron 的 Node 20.18.3 下（`ELECTRON_RUN_AS_NODE=1`），此时 `process.execPath` 是 electron 可执行文件；非 node24 边车 spawn 时带 `ELECTRON_RUN_AS_NODE: '1'`。

### 0.2 server.mjs 与边车的通话格式

**通用边车（汽水/波点/Spotify/酷我）——`scRequest(name, pathname, { cookie, timeout, method, payload })`：**

- 默认 `timeout = 20000`（毫秒），`method = 'GET'`。
- cookie 走 **query**：`pathname` 后拼 `?cookie=<encodeURIComponent(cookie)>` 或 `&cookie=…`（已有 `?` 时用 `&`）。注释原文：「跟边车说话（cookie 用 query 传的 `cookie=k=v; k=v` 形式）」。
- 非 GET 时 cookie 同时放 `Cookie` 请求头；`payload` 有值时发 JSON body（`Content-Type: application/json`），写歌单路由靠这个传长 `data`。
- 返回 `{ status, data, setCookies }`；响应体按 JSON 解析，解析失败时 `data = { raw: text.slice(0, 300) }`；`setCookies` 取 `r.headers.getSetCookie()`，老版本退回单条 `set-cookie`。
- 超时用 `AbortSignal.timeout(timeout)`。

**QQ 单独——`qqRequest(pathname, { cookie, method, payload, timeout })`：**

- cookie 走 **`Cookie` 请求头**（注释：「边车不认 query 里的凭证，认 Cookie 头」），不走 query。
- 其余与 `scRequest` 相同（默认超时 20000，返回 `{ status, data, setCookies }`）。

**酷我登录 Cookie 例外：** `server.mjs` 的 `/api/kuwo/login/cookie` 不走 `scRequest`，而是直接 `fetch(http://127.0.0.1:<port>/login/cookie, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cookie }) })`，超时 15000。注释：「cookie 走 JSON body（不进 URL / 不进边车日志）」。

### 0.3 502 错误形状与日志尾巴

- `scLogTail(name, n = 14)`：读 `services/<dir>/.log`，取最后 14 行拼成字符串；读不到回 `'(还没有日志)'`。QQ 同款 `qqLogTail(n = 14)`。
- 各 handler 的 catch 统一回 HTTP 502，body 为 `{ code: 502, error: String(e.message), reason: e.reason || null, log: scLogTail('<name>') }`。QQ 的 catch 是 `{ code: 502, error, log: qqLogTail() }`（无 `reason` 字段）。
- `health` 路由失败时同样回 502（各平台字段见分节）。
- ⚠️ 注意：边车自身的业务失败很多时候仍回 **HTTP 200 + `code` 字段**（如汽水/波点 `failBody`、酷我 `code: 502` 的业务体），不要只看 HTTP 状态码判断成败，一律以 body 里的 `code` 为准。

### 0.4 音频代理（server.mjs `proxySourceAudio` / QQ 的 `proxyQQAudio`）

主服务路由（`server.mjs` 分发段）：

- `GET /api/qq/audio?url=…` → `proxyQQAudio`
- `GET /api/<qishui|bodian|spotify|kuwo|kugou>/audio?url=…` → `proxySourceAudio(req, res, url, name)`
- 注意 `/api/<name>/audio` 在分发里排在 `handle<Name>` 之前，因为它要拿完整 URL 做白名单，不能进路径分发。

`proxySourceAudio` 规则（逐字照抄）：

- `url` 参数解析失败 → HTTP 400 `{ error: 'bad url' }`；协议不是 `http:`/`https:` → 400 `{ error: 'bad protocol' }`。
- 域名白名单 `AUDIO_HOSTS`（见下表），不匹配 → HTTP 403 `{ error: 'host not allowed: <hostname>' }`；白名单为空（Spotify）→ 403 `{ error: 'no audio for source spotify' }`。
- 上游请求头：`User-Agent: Mozilla/5.0`；`AUDIO_REFERER[source]` 非空时加 `Referer`；请求带 `Range` 时原样转发。
- 响应透传：`Content-Type`（缺省 `audio/mpeg`）、`Cache-Control: no-store`、`Accept-Ranges: bytes`，以及上游的 `content-length` / `content-range`；状态码原样透传；上游异常 → 502 `{ code: 502, error }`。

| source | `AUDIO_HOSTS`（正则，主机名全匹配后缀） | `AUDIO_REFERER` |
|---|---|---|
| qishui | `/\.365yg\.com$/i`、`/\.douyinvod\.com$/i`、`/\.byteicdn\.com$/i`、`/\.pstatp\.com$/i`、`/\.douyinpic\.com$/i`、`/\.snssdk\.com$/i` | `''`（空，**不加 Referer**；注释：汽水 CDN 认了 Referer 反而回 403，实测 `Referer: https://www.qishui.com/` → 403，不带 → 206） |
| bodian | `/\.kuwo\.cn$/i`、`/\.bodian\.com$/i`、`/\.kugou\.com$/i` | `https://www.bodian.com/` |
| kuwo | `/\.kuwo\.cn$/i`、`/\.kuwo\.com$/i` | （无条目，不加） |
| kugou | `/\.kugou\.com$/i`、`/\.kglink\.com$/i` | `https://www.kugou.com/` |
| spotify | `[]`（本期不接音频，直接拒） | （无） |
| qq（`proxyQQAudio` 单独实现） | 主机名必须匹配 `/(^|\.)qq\.com$/i`，否则 403 `{ error: 'host not allowed' }` | `https://y.qq.com/`，另 `User-Agent: Mozilla/5.0` |

### 0.5 前端统一形状（server.mjs 的翻译层）

- 各平台曲目统一成 `{ id, source, name, artists, artistIds, album, albumId, cover, duration(ms), fee, …平台键 }`；歌单统一成 `{ id, name, cover, trackCount, playCount, creator: { nickname }, source }`。
- `fee` 只用来打 VIP/付费小签，**不代表一定放不了**（QQ 注释原文：「`pay.pay_play=1` 基本等于『要会员/付费』，只用来打 VIP 小签提示，不代表一定放不了」）。
- 歌词统一成 `{ code, lyric, yrc, tlyric, format }`，`format` 取值 `yrc` / `lrc` / `none`；`yrc` 为空时 `lyric` 仍是整行 LRC。
- `song/url` 统一成 `{ code, url, preview, quality, reason }`；`reason` 取值见各节（`login` / `unavailable` / `preview` / `drm` / `region` 等）；`preview: true` 时 `quality` 常被改写为 `'preview'`（QQ）或保留实际档位（汽水/波点返回 `d.quality || quality`）。
- KRC → LRC/YRC 转换（server.mjs `krcToLrc` / `krcToYrc`，汽水与 Folia 酷狗用；KRC 行格式 `[起始ms,时长ms]<字偏移,字时长,0>字…`，字偏移为**相对行首**毫秒）：
  - `krcToLrc`：每行取 `[mm:ss.SS]`（`mm = floor(start/60000)`，`ss = ((start % 60000)/1000).toFixed(2).padStart(5,'0')`），去掉全部 `<…>` 得整行文本；不匹配 `^\[(\d+),(\d+)\](.*)$` 的行跳过。
  - `krcToYrc`：逐字三元组正则 `/<(\d+),(\d+),-?\d+>([^<]*)/g`，输出 `[行起点,行时长](字绝对起点,字时长,0)字…`；行时长取行头时长（>0 时）否则取 `max(off+dur)`；任一步对不上返回 `''`（调用方退回整行 LRC）。
  - 波点逐字是 AWLRC（`[mm:ss.xxx]<相对行首ms,字时长ms>字…`），用 `awlrcToYrc` 转：行时长取「最后一个字结束」，无字时长时取下一行起点差。

---

## 1. QQ 音乐（qq）

### 1.1 边车本体

- 目录 `services/qq-api/`；启动 `node services/qq-api/start.mjs`（平时由 server.mjs 按需 spawn）。
- `package.json`：`"name": "lizi-qq-api"`，`"type": "module"`，`scripts.start = "node start.mjs"`，依赖 `@yakult-green-tea/qq-music-api: 3.3.5`（MIT，Node ≥ 20）。
- 端口：`QQ_API_PORT` → `.port` → **3210**（注释：默认避开 Windows 保留段里的 3200）。
- 关键机制：`@yakult-green-tea/qq-music-api` 不是库，`require()` 的那一刻它就在 `app.listen()` 里开服务器了。`start.mjs` 在 require 之前做四件事：
  1. 设 `process.env.PORT = <wantPort>`、`QQ_DISABLE_UPDATE_CHECK = 'true'`（不在 require 期 spawn npm info）、删 `AUTO_OPEN_EXPLORER`（不要弹浏览器）；
  2. 给 `net.Server.prototype.listen` 打一次性补丁：第一次以「纯端口」形式 listen 时补上 `'127.0.0.1'`（包内是 `app.listen(port, cb)`，host 缺省 = `0.0.0.0`）；
  3. 登录态落盘（见 1.3）；
  4. require 失败 / 包里没有导出 `server` 句柄时记 `FATAL` 并 `process.exit(1)`（「包里没有导出 server 句柄（版本不匹配？本启动器按 3.3.5 写的）」）。
- 端口冲突重试：`EADDRINUSE` / `EACCES` 时关掉 server，80ms 后 `server.listen(0, '127.0.0.1')`；再失败记 FATAL 退出，并提示 `netsh int ipv4 show excludedportrange protocol=tcp`。
- ⚠️ 包内上游：`node_modules/` 未在仓库中，包内打向腾讯的上游地址（搜索/播放/歌词等）**不在本文档列出范围**，移植时须以 `@yakult-green-tea/qq-music-api@3.3.5` 的实际实现为准。源码里逐字出现的 QQ 上游只有 1.3 节末尾的两条公开接口（头像兜底用）。

### 1.2 server.mjs 拉起与通话

- `ensureQQ()`：先读 `.port` + `qqPing`（`GET http://127.0.0.1:<port>/login/channels`，超时 1500ms，`r.ok` 即活）；否则删 `.port` 后 spawn（`stdio: ['ignore', fd, fd]`，fd 为 `.log` 追写句柄；环境变量 `ELECTRON_RUN_AS_NODE: '1'` + `QQ_PARENT_PID`），25 秒内每 150ms 轮询 `.port` + ping；失败抛 `'QQ 边车直接退出了（code=…）\n<日志尾巴>'` 或 `'QQ 边车 25 秒内没有就绪\n<日志尾巴>'`；入口缺失时抛 `'QQ 边车没安装：缺少 services/qq-api/start.mjs（先在 services/qq-api 里 npm install）'`。
- `qqRequest`：cookie 走 `Cookie` 请求头（见 0.2）；`payload` 有值时发 JSON body。
- `cookieWith(setCookies, base)`：把 Set-Cookie 合进下一次请求的 Cookie 头（803 那一轮要立刻查昵称）。
- 搜索短缓存：`qqSearchCache`，key 为 `<auth|anon>|<词>|<limit>|<page>`，TTL **60 秒**，最多 24 条（超了删最老一条）；命中时回包多一个 `cached: true`。原因见 README：QQ 对匿名搜索限流，连续请求会一直回 `2001`（实测连续 10 次全部 2001，等半分钟才恢复）。
- 封面：`qqCover(albumMid) = 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + albumMid + '.jpg'`（无 mid 时 `''`）。

### 1.3 登录方式与登录态存放

- 扫码登录，三通道（`QQ_CHANNELS = {'qq','wechat','qqmusic'}`，`qqChannel(v)` 不认识的回默认 `'qqmusic'`）：
  | channel | 用哪个 App 扫 | 实现（README） |
  |---|---|---|
  | `qqmusic`（默认） | QQ 音乐 App | MQTT 长连接 |
  | `qq` | 手机 QQ | MQTT（网页登录兜底） |
  | `wechat` | 微信 | HTTP 轮询 |
- 状态码与网易云同一套：`801` 等待 / `802` 待确认 / `803` 成功 / `800` 过期。
- 登录态：包自己的机制，Node 是 `stored` 会话，cookie 名 **`qqmusic_session`**（httpOnly）。`start.mjs` 设：
  - `QQ_AUTH_SESSION_PATH = services/qq-api/.auth-session.json`
  - `QQ_SESSION_SECRET`：来自环境变量，否则读 `.auth-secret`（≥32 字符），没有就 `crypto.randomBytes(32).toString('hex')` 生成并以 `0o600` 写 `.auth-secret`，同时记日志「生成了新的会话密钥 .auth-secret（登录态加密用，删了就要重新扫码）」。密钥换了旧文件就解不开。
  - 两个都设了才会落盘；凭证本身没过期前会自己续期，但**浏览器那个 cookie 有 1 天 Max-Age**，过期后要重新扫码（README）。
- 二维码 15 秒冷却（包内 `QR_COOLDOWN_MS`）：15 秒内再要一张，key 拿得到但图是空的；主服务把上游的 `retryAfterMs` 带回去。`qqmusic` 通道偶尔在 `mqtt-listener` 阶段超时（`mqtt-packet-timeout`），重试即可。
- 失效会话的只读头像（`start.mjs` 挂在 Koa middleware 栈首的 `/lizi/cached-profile`，不依赖包内路由）：
  - 读请求 `Cookie` 里的 `qqmusic_session`（或 `x-qq-session` 头），用包内会话模块 `services/auth/fileAuthSessionRepository.js`（`createFileAuthSessionRepository(SESSION_FILE, secret)`）+ `services/auth/sessionState.js`（`createStoredSessionResolver({ repository, now: () => 0, randomBytes })`，不传 `refreshCredential`）只读解析；`now` 固定成 0 是刻意的，否则第一次取头像就会把过期会话清掉并回写文件。
  - 只返回 `{ code: 200, uid, nickname, avatar }`，绝不返回 musickey / token，也不把 `loggedIn` 改成 true；无凭据回 `{ code: 200, empty: true }`。
  - 头像过滤：非 `http(s)` 或含 `t_user_default` 的默认图不算，返回 `''`。
  - 公开主页兜底（`publicAvatarByUin`）：uin（正则 `/^[1-9]\d{0,19}$/`）→ `GET https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss?hostuin=<uid>&sin=0&size=5&format=json&inCharset=utf8&outCharset=utf-8&g_tk=5381&loginUin=0&hostUin=0&platform=yqq.json&needNewCode=0` 取前 2 个 `data.disslist[].tid` → `GET https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=<tid>&format=json&g_tk=5381&loginUin=0&hostUin=0&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0` 取 `cdlist[0].headurl || avatar`；每次请求 4 秒超时；头 `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36`、`Referer: https://y.qq.com/`。
- 有效登录态头像摊平（`start.mjs` 另一段 middleware，包在 `/login/status` 与 `/user/detail` 响应之后执行）：上游 `music.UserInfo.userInfoServer/GetLoginUserInfo` 把头像放在 `profile.info.logo`（实测 `https://thirdwx.qlogo.cn/…/132`），边车把 `info.logo` 摊平到 `profile.avatarUrl` / `profile.headpic`（仅当二者为空且 logo 为 http(s) 且不含 `t_user_default`），`info.nick` 补 `profile.nick`。server.mjs 的 `qqProfileAvatar(profile)` 按 `headpic → avatarUrl → avatar → info.logo` 顺序取第一个 http(s) 且不含 `t_user_default` 的值；明确**不用** `q1.qlogo.cn/g?b=qq&nk=<uin>` 兜底（实测和音乐头像不是同一张图）。

### 1.4 边车 HTTP 路由（包内路由，server.mjs 的调用面）

下表「主服务路由」是 `/api/qq/*`；「边车路由」是 `qqRequest` 实际打的路径。包内路由的上游实现在 npm 包内，本文只记录调用面。

| 主服务路由 | 边车路由（方法/参数） | 归一化（主服务回前端） | 备注 |
|---|---|---|---|
| `GET health` | `GET /login/channels`（超时 4000） | `{ code: 200, ok: true, port, channels: data.data.channels \|\| [], sessionMode: data.data.sessionMode \|\| null }`；失败 `{ code: 502, ok: false, error }` | `ensureQQ()` 先行 |
| `GET status` | `GET /login/status`（带 Cookie） | 无 `qqmusic_session` cookie 时直接 `{ code: 200, loggedIn: false }`（不 spawn 边车）；有 profile 时 `{ code: 200, loggedIn: true, nickname: p.nick \|\| p.nickname \|\| p.name \|\| info.nick \|\| 'QQ 音乐用户', avatar: qqProfileAvatar(p), uin: String(p.uin) }`；无 profile（上游 401）时 `{ code: 200, loggedIn: false }`，另调 `/lizi/cached-profile`，有头像则追加 `{ stale: true, nickname, avatar, uin }` | 失效会话 `loggedIn` 必须 false，只带昵称/头像 |
| `GET cached-profile` | `GET /lizi/cached-profile`（超时 6000） | 原样透传边车 body，无 cookie 时 `{ code: 200, empty: true }` | 见 1.3 |
| `GET login/qr/key?channel=` | `GET /login/qr/key?channel=<channel>`（超时 15000）；再 `GET /login/qr/create?key=<key>`（超时 35000，等 MQTT 监听器就绪） | key 取 `data.data.unikey`；无 key 回 `{ code: <边车码或502>, key: null, channel, retryAfterMs: <边车值或null>, error: <边车 message 或 '拿不到二维码 key'> }`；有 key 无图回 `{ code, key, qrimg: '', channel, retryAfterMs, error: <边车 message 或 '二维码生成失败（上游没给图片）'> }`；成功 `{ code: 200, key, qrimg, channel }`（`qrimg` 取 `data.data.qrimg`） | 二维码 15 秒冷却见 1.3 |
| `GET login/qr/check?key=` | `GET /login/qr/check?key=<key>`（带 Cookie，超时 25000） | `{ code: d.code ?? r.status, message: d.message \|\| '' }`；边车 Set-Cookie 原样经 `res.setHeader('Set-Cookie', …)` 发给浏览器；`code === 803` 时 `loggedIn: true`，并用合并后的 cookie 调 `/login/status` 补 `nickname` / `avatar`（查不到不影响登录） | 状态码 801/802/803/800 |
| `GET logout` | `GET /logout`（带 Cookie） | `{ code: 200, loggedIn: false }`，Set-Cookie 同样透传给浏览器 | |
| `GET search?s\|keyword=&limit=&page=` | `GET /search?keyword=<s>&limit=<limit>&page=<page>` | `limit`  clamp 1..20（包实测单次最多 20 条，`MAX_LIMIT=20`，超过会被压回 20），默认 20；`page` ≥ 1 默认 1；命中缓存加 `cached: true`；上游 `code !== 200` 时重试两次（等 1200ms、2500ms），仍失败回 `{ code, source: 'qq', tracks: [], error: <message \|\| errorKey \|\| 'QQ 搜索失败'> + (upstreamCode ? '（上游 <码>，稍后再试）' : ''), upstream: <边车原体> }`；成功 `{ code: 200, source: 'qq', tracks: items.map(qqTrack).filter(id), songCount: total ?? items.length, more: !!more }` | 匿名搜索限流回 `2001`，见 1.2 |
| `GET lyric?mid\|id=` | `GET /getLyric?songmid=<mid>` | `{ code: 200, lyric: response.lyric \|\| '', tlyric: response.trans \|\| '', yrc: '', format: lyric ? 'lrc' : 'none' }`；缺 mid → 400 `{ code: 400, error: 'mid required' }` | 标准 LRC，匿名可用 |
| `GET song/url?mid\|id=&quality=` | `GET /getMusicPlay/<mid>?quality=<quality>`；无 url 时再 `GET …?quality=<quality>&preview=1` | 见 1.5 | |
| `GET recommend/playlists?limit=` | `GET /recommend/playlists?limit=<limit>` | limit clamp 3..20 默认 9；失败 `{ code, source: 'qq', playlists: [], error }`；成功 `{ code: 200, source: 'qq', playlists: playlists.map(qqPlaylist).filter(id) }` | 匿名可用 |
| `GET recommend/new-songs?limit=` | `GET /recommend/new-songs?limit=<limit>` | limit clamp 1..60 默认 30；成功 `{ code: 200, source: 'qq', tracks: songs.map(qqTrack).filter(id) }` | 匿名可用 |
| `GET playlist/detail?id=` | `GET /getSongListDetail/<id>` | 取 `response.cdlist[0]`；无则 `{ code: <resp.code或502>, source: 'qq', name: '', cover: '', tracks: [], trackCount: 0, error: <'歌单取不到（<码>）'或'歌单不存在'> }`；成功 `{ code: 200, source: 'qq', id: String(cd.disstid \|\| id), name: cd.dissname \|\| 'QQ 歌单', cover: cd.logo \|\| '', creator: { nickname: cd.nickname \|\| cd.nick \|\| '' }, tracks: songlist.map(qqTrack).filter(id), trackCount }` | |
| `GET user/liked-songs?limit=` | `GET /user/liked-songs?limit=<limit>` | limit clamp 1..100 默认 100；失败时 401 回 error `'先在卡片上扫码登录 QQ 音乐'`，其余回边车 message；成功 `{ code: 200, source: 'qq', tracks, total }` | 需登录 |
| `GET user/playlists` | `GET /user/playlist`，有续读时 `GET /user/playlist?favoriteOffset=<n>` | 逐轮续读并去重，最多 **20 轮**；第 0 轮失败回 `{ code: <边车码或401>, source: 'qq', playlists: [], error: <401时'先在卡片上扫码登录 QQ 音乐'否则边车 message或'取我的歌单失败'> }`；停法：`more=false`、无可用续读位置、续读位置不前进、到轮数上限；成功 `{ code: 200, source: 'qq', playlists }` | 上游第一轮把收藏读到 1000 张就停（`more=true + nextFavoriteOffset`） |
| `GET user/albums?limit=&offset=` | `GET /user/albums?offset=<offset>&limit=<limit>` | limit clamp 1..100 默认 100，offset ≥ 0 默认 0；失败时 401 回 `'先在卡片上扫码登录 QQ 音乐'`；成功 `{ code: 200, source: 'qq', data: albums.map(qqUserAlbum).filter(id), hasMore: !!more, total }` | 字段为旧版 profile-asset CGI 写法，见 1.6 |
| `GET user/daily-songs` | `GET /user/daily-songs` | 失败时 401 回 `'登录 QQ 音乐后才有每日推荐'`；成功 `{ code: 200, source: 'qq', tracks }` | 需登录 |
| `GET recommend/radar?page=` | `GET /recommend/radar?page=<page>` | 匿名可用，作为「每日推荐」未登录时的兜底；失败 `{ code, source: 'qq', tracks: [], error }` | |
| `GET radio/categories` | `GET /radio/categories` | 把 `groups[].radios[]` 摊平成 stations：`{ id: String(it.id), source: 'qq', name: it.title \|\| it.name \|\| '未命名电台', cover: it.picurl \|\| it.picUrl \|\| it.pic \|\| '', trackCount: 0, playCount: Number(it.listenNum \|\| it.listenCount) \|\| 0, creator: { nickname: g.title \|\| '' } }` | 频道目录匿名可读 |
| `GET radio/tracks?id=` | `GET /radio/tracks?id=<id>` | 失败时 401 回 `'QQ 电台收听需要登录（并可能需要会员）'`；成功 tracks 取 `songs \|\| tracks` | 收听要登录 |
| `POST playlist/create`（body `{ name }` 或 `?name=`） | `POST /user/playlist/create`，body `{ name }`（超时 25000） | 无 `qqmusic_session` → `{ code: 401, error: '先在卡片上扫码登录 QQ 音乐' }`；名字先去控制字符（`[\u0000-\u001f\u007f]`）再按 Unicode 码点截 **20 字**（上游硬限制 ≤ 20 字符）；失败 `{ code, error: <401时'登录态已失效，重新扫码登录 QQ 音乐'否则边车 message>, upstream: { code, errorKey } }`；成功 `{ code: 200, tid: String(d.tid), dirId: String(d.dirId), playlist: { id: String(tid), dirId, name } }` | `playlist.id` 用 tid，加歌接口认 tid |
| `POST playlist/tracks` 或 `playlist/tracks/add`（body `{ tid\|pid, songs\|picks }`） | 先 `POST /song/batch`（body `{ songs: [{ mid }] }`，每批 20 首，超时 25000）补数字 id；再 `POST /user/playlist/tracks`（body `{ tid, op: 'add', songs: [{ id, type: 0 }] }`，每批 100 首，超时 30000） | `tid` 必须为正整数否则 400 `{ code: 400, error: 'tid required' }`；无会话 401；无歌 400 `'songs required'`；接受 `{id}` / `{songId}` / `{mid}` 三种形状，`songId=0` 视为缺失；补 id 后仍有 `id ≤ 0` 的回 400 `'有些曲目没有数字 songid，无法写入 QQ 歌单'`；某批失败回 `{ code, added: <已写入数>, error: <…> + (added ? '（前 <added> 首已写入）' : '') }`；成功 `{ code: 200, tid, added }` | 写接口只认数字 songid，不认 songmid |
| 未知路径 | — | `{ code: 404, error: 'unknown qq api: <part>' }` | |
| 任意异常 | — | HTTP 502 `{ code: 502, error, log: qqLogTail() }` | |

README 提到但主服务**未接**的包内路由（移植时如需再接，以包实现为准）：`/getSongInfo`、`/singer/*`（匿名可用）。

### 1.5 播放（song/url）与 pay/fee

- `qqPlayUrlOf(data, mid)`：取 `data.data.playUrl`；登录后是**字符串**直接用；匿名是一张 `{ songmid: { url, error, restriction } }` 表，取 `p[mid] || Object.values(p)[0]`，回 `{ url, preview: !!one.preview, reason: one.url ? null : (one.error || 'unavailable') }`；无 `playUrl` 时 `{ url: '', preview: false, reason: 'unavailable' }`。
- 主服务：先调正片；无 url 时调 `preview=1` 试听；`loginRequired` 为任一次 HTTP 401。最终回 `{ code: 200, mid, url, preview, quality: preview ? 'preview' : <请求档位>, reason: url ? null : (loginRequired ? 'login' : 'unavailable'), restriction: <无url时原样带上的 data.data.playUrl 或 null> }`。
- README 实测：匿名只有 **30~60 秒试听 mp3**（`preview=1`），正片返回 `104003`；部分歌（尤其海外版权）连试听都没有，返回 `104003 / url_unavailable`；没会员只能听试听片段，正片要登录 + 会员。
- 曲目归一化 `qqTrack(it)`：`{ id: it.mid, source: 'qq', name: it.name || it.title || '', artists: singer[].name.join(' / ') || '未知歌手', artistIds: singer[].mid, album: album.name || album.title || '', cover: qqCover(album.mid), duration: (it.interval || 0) * 1000（QQ 给秒，前端统一毫秒）, fee: it.pay && it.pay.pay_play ? 1 : 0, mid: it.mid, songId: Number(it.id) > 0 ? Number(it.id) : 0 }`。原始条目有 20 多个字段还塞整段歌词（`content`），翻译层不透传。
- 歌单归一化 `qqPlaylist(it)`：`{ id: String(it.dirId ?? it.dissid ?? it.tid ?? it.id ?? ''), name: it.dirName || it.dissname || it.title || '未命名歌单', cover: it.picUrl || it.picurl || it.cover || it.logo || it.pic || '', trackCount: Number(it.songNum ?? it.songnum ?? it.song_cnt ?? 0) || 0, playCount: Number(it.listenCount ?? it.play_cnt ?? it.playCount ?? 0) || 0, creator: { nickname: it.nickname || it.nick || creator.nickname || creator.nick || '' }, source: 'qq' }`。
- 收藏专辑归一化 `qqUserAlbum(it)`：`id` 优先 `albummid`（QQ 专辑接口认 mid），无 mid 才用数字 `albumid`；`name` 取 `albumname` 等；`artists: [{ name }]`（歌手取 `singername` 或 `singer[].name`）；`cover` 取 `albumcover` 等，无则按 `qqCover(mid)` 拼；`publishTime` 取 `pubtime` 等；`trackCount` 取 `songnum` 等。
- 音频代理：`/api/qq/audio?url=`，只放行 `*.qq.com`（见 0.4）；直链形如 `http://aqqmusic.tc.qq.com/RS....mp3?vkey=…`，vkey 会过期、CDN 有 referer 策略，不把凭证塞进 DOM；必须转发 Range。

### 1.6 明确返回空态 / 错误的路由

- `status` 无 cookie：`{ code: 200, loggedIn: false }`（不 spawn 边车）。
- `search` 空词：`{ code: 200, source: 'qq', tracks: [], songCount: 0 }`。
- `lyric` 无歌词：`lyric: ''`，`format: 'none'`（不报错）。
- `song/url` 拿不到：`url: ''`，`reason: 'login'`（401 过）或 `'unavailable'`，`preview: false`。
- `user/*` 未登录：401 + `'先在卡片上扫码登录 QQ 音乐'`（各路由文案见 1.4 表）。
- 搜索限流：如实回上游码，error 后缀 `（上游 2001，稍后再试）`。

---

## 2. 酷狗音乐（kugou）——Folia 移植版（r24）

酷狗没有 Node 边车（旧 `services/kugou-api/` 已删，见删旧报告
`~/workspace/kugou-del-r24/`）；本节是 Folia 酷狗实现的 Swift 移植规格，
唯一实现在 `ios/Sources/Lizi/Server/FoliaKugou.swift`（actor
`FoliaKugouService`）。流程只学 Folia，不抄代码（Folia AGPL-3.0）；
协议常数（盐、appid、RSA 公钥、x-router）是 KuGouMusicApi v1.6.0
（MIT）`util/` 里的协议事实，直接采用并注明来源。

### 2.1 出处

- Folia：`src/services/onlineMusic/kugou/kugouProvider.ts`（1822 行，36 个
  操作的 `KUGOU_OPERATIONS` 表）、`kugouTransport.ts`（549 行，匿名搜索
  与签名）、`kugouLyricProvider.ts`（377 行，歌词两步法）、
  `krcDecrypt.ts`、`kugouFailure.ts`、`kugouLoginFailure.ts`。
- 上游库：KuGouMusicApi v1.6.0 `util/config.json` / `util/request.js`
  （`createRequest`）/ `util/helper.js`（签名）/ `util/crypto.js`
  （RSA/AES）/ `util/util.js`（KRC 解码、mid 计算）/ `module/*.js`
  （各接口路径与参数）。
- 壳版路由面：`public/api.js` 调 `/api/kugou/*`，本节路由名与参数与壳版
  一致，否则壳版酷狗 404。

### 2.2 网关传输与签名（KuGouMusicApi 协议）

- 网关基址默认 `https://gateway.kugou.com`；lite appid 3116、clientver
  11440（标准 appid 1005、clientver 20489 只用于歌词搜索等个别调用）；
  srcappid 2919。
- 默认参数：dfid、mid、uuid=`-`、appid、clientver、clienttime（秒）；
  token/userid 登录后才加。请求头：dfid、clienttime、mid、`kg-rc:1`、
  `kg-thash:5d816a0`、`kg-rec:1`、
  `kg-rf:B9EDA08A64250DEFFBCADDEE00F8F25F`；UA
  `Android15-1070-11083-46-0-DiscoveryDRADprotocol-wifi`；
  各接口另带自己的 `x-router`（见 2.4 表）。
- 签名全为 MD5（已逐字核对库原文）：
  - web 盐 `NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt`：MD5(盐 + 排字母序的
    `key=value` 连串 + 盐)。
  - android-lite 盐 `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA`：MD5(盐 + 参数串 +
    body + 盐)，对象值先 JSON.stringify。
  - register 盐 `1014`：MD5("1014" + 排字母序的参数值连串 + "1014")。
  - `signParams` 盐 `R6snCXJgbCaj9WFRJKefTMIFp0ey6Gza`：MD5(排字母序的
    `key+value` 连串 + data + 盐)。
  - `signKey` lite 盐 `185672dd44712f60bb1736df5a377e82`：MD5(hash+盐+appid+mid+userid)。
  - `signCloudKey` 盐 `ebd1ac3134c880bda6a2194537843caa0162e2e7`：
    MD5(`musicclound`+hash+pid+盐)。
  - `signParamsKey` = MD5(appid+盐+clientver+data)。盐随环境走：lite 环境
    用 lite 盐 `LnT6xpN3khm36zse0QzvmgTZ3waWdRSA` + appid 3116 / clientver
    11440，标准环境用标准盐 `OIlwieks28dk2k092lksi2UIkp` + appid 1005 /
    clientver 20489。**key 与 body 的 appid / clientver 必须同族**：VM 实测
    fm.service 混用两族（body 标准 + lite key）报 20006，全标准与全 lite
    都通；本实现 body 一律标准 1005/20489，所以 key 走标准族。
- `encryptKey` 时 `key=signKey(params.hash, mid, userid, appid)`（先加 key
  再签名）。`notSign` 与 `notSignature` 键名不一致（`song_url.js` /
  `search_lyric.js` 写 `notSign:true`，实际仍会生成 signature）。
- 设备身份：guid 为 UUID v4 去横线（32 位 hex，持久化，删了等于换设备）；
  mid = MD5(guid) 作 16 进制大整数转十进制字符串；dfid 缺省 `"-"`。
- 判定：`status==0` 或 `error_code!=0` 判 502；errcode 20028 =
  `本次请求需要验证`（见 2.5 风控重试）。

### 2.3 登录方式与登录态存放

- 扫码（Folia `login_qr_key` → `login_qr_create` → `login_qr_check`）：
  - `login_qr_key`（无参，appid 1001，web 签名）：key 取 data 的 qrcode /
    qrkey / key / ticket；官方 `qrcode_img`（data URL）记内存 Map
    （key→qrimg，最多 64 张）。
  - `login_qr_create {key, qrimg: true}`：本地拼登录链接
    `https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=<key>`；
    优先回官方图，没有才按链接现画二维码（CoreImage）。
  - `login_qr_check {key, qrcode: key}`（web 签名）：上游 status 0 过期 /
    1 等待 / 2,3 已扫码 / 4 或带 token 为确认；映射到统一码 800/801/
    802/803；确认后才成对写 token+userid。
  - `logout`：库里没有 logout 模块——先发请求、本地凭证当即作废；
    Swift 侧只清本地 jar。
  - `user_detail` 验登录态（`status` 有 token 时调一次；失败不推翻登录态）。
- 登录态文件：`SessionStore.sidecarAuth("kugou")`（只收 token / userid /
  vip_type / vip_token / dfid）；设备身份另存 `sidecarAuth("kugou-device")`
  （guid / dev / mac）。`20028` 时先清 dfid、调 `register_dev`、再重试一次。
- `register_dev`：`POST https://userservice.kugou.com/risk/v2/r_register_dev`
  （params part=1、platid=1、p=RSA PKCS1 加密的 {aes key, uid, token}；
  body 为 AES 加密的设备信息 JSON；回包 AES 解密后取 `data.dfid`）。
  RSA：lite 公钥 1024 位（PEM base64 体见 `FoliaKugou.swift` 协议常数段）；
  `rsaEncrypt2` 为 RSAES-PKCS1-V1_5（回小写 hex）；`cryptoRSAEncrypt` 为
  原始 RSA——明文放进 128 字节缓冲的头部、其余补零（左对齐、尾部补零），
  回 hex（调用点再 `.toUpperCase()`）。
  AES：`playlistAesEncrypt`：6 位小写随机 key，AES-128-CBC/PKCS7，加密
  key=MD5(key)[0:16]（ASCII 字节）、iv=MD5(key)[16:32]，密文 base64。

### 2.4 边车 HTTP 路由与上游接口

| 路由（`/api/kugou/*`） | 上游 | 方法 / x-router / 关键参数 |
|---|---|---|
| `search` | 网关 `/v3/search/song`（登录态）；匿名 `http://complexsearch.kugou.com/v2/search/song`（Swift 侧改 https，因 ATS 拦 http） | GET；登录态搜索参数 albumhide 0、iscorrection 1、keyword、nocollect 0、page、pagesize、platform AndroidFilter，android 签名；匿名搜索参数 sorttype 0、keyword、pagesize、page、userid 0、appid 3116、token ""、clienttime（秒）、iscorrection 1、uuid "-"、mid = MD5(当前毫秒)、dfid "-"、clientver 11070、platform AndroidFilter，签名 = MD5(lite 盐 + 排字母序的 key=value 串 + lite 盐)，请求头 UA `Android14-1070-11070-201-0-SearchSong-wifi`、KG-Rec 1、KG-RC 1、KG-CLIENTTIMEMS（毫秒）、mid、x-router complexsearch.kugou.com |
| `song/url` | 网关 `/v5/url` | GET；x-router trackercdn.kugou.com；参数 album_id、area_code=1、hash（小写）、ssa_flag、version=11430、page_id（lite 967177915）、quality、album_audio_id、behavior=play、pid（lite 411）、cmd=26、pidversion=3001、IsFreePart、ppage_id（lite `356753938,823673182,967485191`）、cdnBackup=1、module=''、clientver=11430；`encryptKey:true` |
| `lyric` | `https://lyrics.kugou.com/v1/search` + `https://lyrics.kugou.com/download` | search：clearDefaultParams，参数 album_audio_id（有才传）/ duration（毫秒）/ hash / keyword（"歌手 - 歌名"）/ lrctxt 1 / man no，appid/clientver 取标准值 1005/20489；download：ver=1、client、id、accesskey、fmt=krc、charset=utf8；contenttype!=0 时 base64 直解，否则 KRC 解 |
| `status` / `login/status` | 网关 `/v3/get_my_info` | POST；x-router usercenter.kugou.com；body visit_time/usertype=1/p=RSA 原始加密 {token, clienttime} 大写 hex/userid；params plat=1 |
| `login/qr/key` | `https://login-user.kugou.com/v2/qrcode` | GET；appid：type=web 时 1014 否则 1001（Swift 取 1001），type=1，plat=4，qrcode_txt=`https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=<appid>&`，srcappid；web 签名 |
| `login/qr/create` | 本地拼串（见 2.3） | — |
| `login/qr/check` | `https://login-user.kugou.com/v2/get_userinfo_qrcode` | GET；plat=4、appid、srcappid、qrcode=key；web 签名；status==4 时回 token+userid |
| `logout` | 本地清 jar（库无 logout 模块） | — |
| `everyday/recommend` | 网关 `/everyday_song_recommend` | POST；x-router everydayrec.service.kugou.com；params platform 默认 ios |
| `everyday/history` | 网关 `/everyday/api/v1/get_history` | POST；x-router everydayrec.service.kugou.com |
| `top/songs` | 网关 `/musicadservice/container/v1/newsong_publish` | POST；body rank_id 默认 21608、userid、page、pagesize、tags=[] |
| `top/playlists` | 网关 `/v2/special_recommend` | POST；x-router specialrec.service.kugou.com；body 含 special_recommend 对象 + `key=signParamsKey(秒时间戳)` |
| `personal/fm` | 网关 `/v2/personal_recommend` | POST；x-router persnfm.service.kugou.com；body 含 action 默认 play、fakem=`ca981cfc583a4c37f28d2d49000013c16a0a`、`key=signParamsKey(毫秒时间戳)` |
| `recommend/songs` | 网关 `youth/v1/song/single_card_recommend`（Folia `top_card_youth`） | POST；body {tagid, u_info, source_mixsong}，params card_id 默认 3005、area_code 1、platform ios、module_id 1、ver v2、pagesize、clientver 11490 |
| `fm/class` | 网关 `/v1/class_fm_song` | POST；x-router fm.service.kugou.com；body kguid/clienttime/mid/platform=android/clientver/uid/get_tracker=1/key；**回包 data.class_list 是分类表，每类 {classid, classname, fmlist}，电台在各类的 fmlist 里 {fmid, fmname, fmtype, imgurl}——服务端展平成 stations 再回**（分类本身不是电台，直接归一化会因无 fmid 被滤掉、rail 全空）；imgurl 的 {size} 取 240（imgurl_size 所列 "480,400,240,150" 之一） |
| `fm/songs` | 网关 `/v1/app_song_list_offset` | POST；x-router fm.service.kugou.com；body data=[{fmid, fmtype 默认 2, offset 默认 -1, size 默认 20, singername}] |
| `user/playlists` | 网关 `/v7/get_all_list` | POST；x-router cloudlist.service.kugou.com；body userid/token/total_ver=979/type=2/page/pagesize；params plat=1、userid、token；未登录 401 |
| `playlist/tracks` | 网关 `/pubsongs/v2/get_other_list_file_nofilt` | GET；area_code=1、begin_idx=(page-1)*pagesize、plat=1、type=1、mode=1、personal_switch=1、extend_fields=`abtags,hot_cmt,popularization`、pagesize、global_collection_id=id |
| `playlist/detail` | 网关 `/v3/get_list_info` | POST；x-router pubsongs.kugou.com；body data=[{global_collection_id}]、userid、token |
| `playlist/create` | 网关 `/cloudlist.service/v5/add_list` | POST（AES+RSA，p 大写 hex） |
| `playlist/tracks/add` | 网关 `/cloudlist.service/v6/add_song` | POST |
| `playlist/tracks/del` | 网关 `/v4/delete_songs` | POST；x-router cloudlist.service.kugou.com |
| `playlist/del` | 网关 `/v2/delete_list` | POST；x-router cloudlist.service.kugou.com（AES+RSA，p 大写 hex） |
| `user/cloud` | 网关（云盘列表） | AES+RSA（同 register_dev 套路，body 是 AES 密文原始字节、clearDefaultParams、不签名） |
| `user/cloud_url` | 网关 `/bsstrackercdngz/v2/query_musicclound_url` | GET；hash 小写、ssa_flag、version=20102、ssl=0、album_audio_id、pid=20026、audio_id、kv_id=2、key=signCloudKey(hash,20026)、bucket=musicclound、name、with_res_tag=0 |
| `user/listen` | `https://listenservice.kugou.com/v2/get_list` | POST |
| `user/vip` | `https://kugouvip.kugou.com/v1/get_union_vip` | GET；Folia `normalizeKugouVipType` 判定 |
| `song/climax` | `https://expendablekmrcdn.kugou.com/v1/audio_climax/audio` | GET；params data=JSON([{hash}]) |
| `audio` | 网关代发 `POST https://gateway.kugou.com/v1/audio/audio` + x-router kmr.service.kugou.com（库内 baseURL 是 http://kmr.service.kugou.com；VM 实测该 host 的 443 端口不讲 TLS、https 直连必死、http 又撞 ATS，所以走网关代发，实测 HTTP 200 status 1） | POST；x-router kmr.service.kugou.com；body appid/clienttime/clientver/data=[{hash,audio_id:0}]/dfid/key=signParamsKey/token/userid/mid |
| `krm/audio` | 网关 `/kmr/v2/audio` | POST；x-router openapi.kugou.com、KG-TID 238 |
| `album/detail` | 网关 `/kmr/v2/albums` | POST |
| `album/songs` | 网关 `/v1/album_audio/lite` | POST |
| `artist/detail` | 网关 `/kmr/v3/author` | POST |
| `artist/albums` | 网关 `/kmr/v1/author/albums` | POST |
| `artist/audios` | `https://openapi.kugou.com/kmr/v1/audio_group/author` | POST；x-router openapi.kugou.com，kg-tid 255/36/220 |
| `health` | 本地 | `{ code: 200, loggedIn, platform: 'kugou' }` |
| 未知路径 | — | 404 `unknown kugou api: <part>`；异常 502 |

### 2.5 播放（song/url）与 pay/fee

- 档位映射（Folia `qualityValue`）：standard→`128`；high→`320`；
  ultra→`320`；lossless→`flac`；hires→`high`。回退 ladder（Folia
  `QUALITY_FALLBACKS`）：standard=[standard]；high=[high,standard]；
  ultra=[high,standard]；lossless=[lossless,high,standard]；
  hires=[hires,lossless,high,standard]。
- 每档先试带 album_id/album_audio_id 的 `song_url`，再试 hash-only；
  URL 取 payload（data[0] 或 data）的 play_url / playUrl / url，
  `audioUrlOf` 接受字符串或数组、逗号分隔拆、取第一条 http(s) 链。
- 云盘 variant 只走 `user_cloud_url`（{hash, id: fileId}）。
- 风控：匿名 `/v5/url` 回 20028（`本次请求需要验证`）时先调
  `register_dev` 再重试一次；仍 20028 则回 `reason:"login"` + 明文
  「需验证」，不再降档重试。401/403/152 立刻认登录失效；429/服务未配
  直接抛；超时停链但仍试 legacy。
- legacy 兜底：`GET https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=`，
  UA `Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0
  Mobile Safari/537.36`，取 url 或 backup_url。VM 实测：匿名 playInfo
  HTTP 200 但 status 0、url 为空——**匿名拿不到链**，Folia 只把它当最后
  兜底；播放必须登录（或 LX 兜底，见下）。
- `fee` 恒为 0（Folia 归一化不打 pay 标记；酷狗无云盘口，播放编排为
  官方 → LX（全失败直接报错，r31 提示音兜底已删），跳过云盘腿）。
- LX 兜底：`LX.swift` sourceMap `"kugou": "kg"` +
  `Router.handleLxSongUrl` kugou 分支（hash 为 32 位 hex 时传 hash，
  否则传「歌名 歌手」）+ `LXSources` kg 别名 + `/api/lx/health`
  sources 加 `kg`。r31 起 LX 兜底只认用户自加的自定义源（如 pdone 系）。

### 2.6 歌词（lyric）

- Folia 两步（`kugouLyricProvider.ts`）：`search_lyric`（候选在回包顶层
  `candidates`，取首个）→ `download` 解码；官方异常/空时按壳版约定再试
  LRCLIB 兜底（`Lrclib` 已有；LRCLIB 兜底是 Lizi 壳版约定，不是 Folia 流程）。
- KRC 解码（`util/util.js` decodeLyrics）：base64 → 跳过前 4 字节 →
  XOR 16 字节密钥 `[64,71,97,119,94,50,116,71,81,54,49,45,206,210,110,105]`
  循环 → zlib 解压 → UTF-8。contenttype!=0 时 base64 直解，否则 KRC 解。
- KRC 文本经已有 `krcToLrc` / `krcToYrc` 转 LRC/YRC（与汽水共用，见 0.5）。
- 归一化（Folia `normalizeKugouSong` 等）：id 即大写 hash；歌名取
  SongName / OriSongName / FileName（无歌手字段时拆「歌手 - 歌名」；
  有歌手时歌名前的「歌手 - 」前缀去掉）；时长秒（<10000）转毫秒；
  albumAudioId / mixSongId / fileId 另存；originalName（OriSongName 或
  去后缀）与 title 不同时存下供歌词重试。`normalizeArtists`：Singers /
  singerinfo / authors / artists 数组取 name；无数组时 SingerName 按
  `、,&/` 切。封面：`KUGOU_CANONICAL_COVER_SIZE = 1024`（`union_cover`
  的 `{size}` 换成 1024；纯数字文件名拼
  `https://c1.kgimg.com/stdmusic/1024/<前8位>/<文件名>`；`//` 补 https，
  http 升 https）。
- 歌单归一化（`normalizeCollection`）：歌单 id 取 global_collection_id /
  specialid / id；专辑取 album_id / musiclib_id / list_create_listid；
  歌手取 author_id；曲数取 song_count / count / m_count / total。
  `getKugouUserCollectionType`：source==2 或带 musiclib_id 即专辑。
  `canAddToKugouPlaylist`：自有歌单且 listId != "2"、名字不是「我喜欢」/
  「我喜欢的音乐」。

### 2.7 明确返回空态 / 错误的路由

- `search` 空词：`{ code: 200, source: 'kugou', tracks: [], songCount: 0 }`。
- `lyric` 无歌词：`lyric: ''`，`format: 'none'`（不报错）。
- `song/url` 拿不到：`url: ''`，`reason: 'login'`（20028/401 过）或
  `'unavailable'`，`preview: false`。
- `user/*` 未登录：401 + 明文（各路由文案见 2.4 表）。
- `user/playlists` 匿名：HTTP 200 status 0 errcode 20010、data 为 null——
  须登录（VM 实测）。
- VM 实测（2026-11-20，`/tmp/kg-probe.py`）：匿名搜索 complexsearch/v2
  HTTP 200 status 1，5 条，首条「发如雪」hash
  `1F7E7659B9FFF4FB6F71562A61BBC25F`、AlbumID 958909、Duration 299 秒；
  歌词 search_lyric 候选 1 个（id 164610279，有 accesskey），download
  HTTP 200 contenttype 0，KRC 解码实测解出真 LRC；网关
  everyday_recommend 匿名 POST HTTP 200 status 1，song_list 30 首；
  网关 `/v3/search/song` 匿名 HTTP 200 status 1，lists 5；网关 `/v5/url`
  匿名 HTTP 200 status 0 errcode 20028；top/songs（rank_id 21608）
  HTTP 200 status 1；top/playlists HTTP 200 status 1，special_list 8；
  playlist/tracks HTTP 200 status 1，songs 3；fm/class HTTP 200 status 1，
  class_list 14；fm/songs HTTP 200 status 1；personal/fm 匿名 HTTP 200
  status 1，song_list 5；QR key（web 签名）HTTP 200，拿到 qrcode
  `d543469c809b2d8b3853e1e890e82b821001` + 官方 `qrcode_img` data URL。
- 未测：登录态下的 song/url、user_detail、user_playlists、playlist 写操作、
  真机播放、register_dev 端到端（需 RSA/AES，VM 未跑）、top/songs 与 fm/class
  等回包的内层字段名（实现里用宽容读法兜底；top/songs 与 everyday 的首项全字段
  已核对，kugouTrack 的读法全覆盖；fm/class 的 class_list 结构已确认
  classid/fmlist/fmname，kugouStation 的读法待对）。
- 已解决（2026-11-20 补充探针）：`audio`（kmr）https 直连必死（443 端口不讲
  TLS），已改走网关代发并实测通；fm/class 的 key 必须与 body 同族（全标准
  1005/20489/标准盐才通，混用报 20006），signParamsKey 已改标准默认；
  login_qr_key 的 appid 1001 与 1014 在带默认参数（dfid/mid/uuid/appid/
  clientver/clienttime）时都回 qrcode + qrcode_img，不带则 20010。

---

## 3. 酷我音乐（kuwo）

### 3.1 边车本体

- 目录 `services/kuwo-api/`；启动 `node services/kuwo-api/start.mjs`（平时由 server.mjs 按需 spawn）。
- `package.json`：`"name": "lizi-kuwo-api"`，`"type": "module"`，`scripts.start = "node start.mjs"`，**零运行时依赖**（自写的最小 HTTP 壳，只用 Node 内置 `http` / `fs` / `zlib`）。
- 端口：`KUWO_API_PORT` → `.port` → **3216**（避开 3211–3215 的其它边车）。
- 只绑 `127.0.0.1`；日志 / `.port` / Cookie 都落在本目录，Cookie 只写盘不打印。
- 能力总述（文件头注释）：搜索 / 歌单 / 推荐 / 榜单 / 电台目录走 `www.kuwo.cn` 的 www 接口；播放直链走 `mobi.kuwo.cn` 的 `convert_url2`（`q` 参数用酷我客户端的自定义 DES 变体加密）；歌词走 `newlyric.kuwo.cn` 的 PC 歌词（lrcx 逐字，解压后 XOR + gb18030 解码）；登录只接收用户粘贴的 Cookie，**不伪造二维码、不伪造登录态**。
- 常量（逐字照抄）：
  - `UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36'`
  - `UA_OK = 'okhttp/3.10.0'`
  - `UA_MOBILE = 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36'`
  - `COOKIE_PREFIX = 'Hm_Iuvt_'`；`COOKIE_FALLBACK = 'Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324'`
  - `CRED = 'user=0&corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1'`
  - DES 密钥 `'ylzsxkwm'`（标准 DES 库解不开，文件内自带实现；算法来源注释：公开逆向实现 JayZorn-LJZ/GetFreeMusicYourself / kwmc-q- 的 JS 移植）。

### 3.2 token 与 Secret（www 接口鉴权）

- `Hm_Iuvt_*` 是网页端下发的匿名 token；www 接口要 `Secret: h(token, cookieName)`，算法来自公开逆向实现（listen1 / 酷我网页），只在本机请求里用。`secretFor(token, name)`（逐字逻辑，不展开 S 盒以外的细节）：
  - 把 `name` 每个字符的 charCode 拼成十进制串 `n`；`r = floor(n.length / 5)`；`o = parseInt(n.charAt(r) + n.charAt(2*r) + n.charAt(3*r) + n.charAt(4*r) + n.charAt(5*r))`；`l = ceil(name.length / 2)`；`c = 2147483647`；`d = Math.round(1e9 * Math.random()) % 1e8`；`o >= 2` 否则抛 `'酷我 Secret 算法参数异常'`；`n += d` 后反复折叠到长度 ≤ 10；`n = (o*n + l) % c`；对 token 每个字符 `h = parseInt(token.charCodeAt(i) ^ floor((n / c) * 255))`，转两位 hex 拼接，`n` 每步更新；最后 `d` 转 16 进制补足 8 位接在后面。
- `refreshToken()`：`GET https://www.kuwo.cn/`，头只有 `User-Agent: UA_WEB`，超时 20000，跟随重定向；从 `Set-Cookie` 里找第一个以 `Hm_Iuvt_` 开头的 `name=value`（`parseTokenCookie`；无 `getSetCookie` 时按 `/,(?=\s*[^;=]+=[^;]*)/` 切单条头）；拿不到抛 `'酷我首页没有下发 Hm_Iuvt_ token（上游可能改了鉴权）'`；成功记 `tokenState = { token, name, secret: secretFor(value, name), at: Date.now() }`。
- `www(pathname, { retry = true, timeout = 20000, referer = 'https://www.kuwo.cn/' })`：token 为空或超过 **5 分钟**就先刷新；请求 `https://www.kuwo.cn + pathname`，头为 `User-Agent: UA_WEB`、`Referer: <referer>`、`Cookie: cookieHeader()`、`Secret: tokenState.secret`，跟随重定向；响应文本含 `The request is illegal`（不区分大小写）时刷新 token 后**重试一次**（`retry: false`），并记日志「www 接口回 illegal，刷新 token 后重试一次」。
- `cookieHeader()`：用户 Cookie（排除 `Hm_Iuvt_*` 开头的键）逐个 `k=v`，再加 `<tokenName>=<token>`，用 `'; '` 连接。
- `parseJson(text)`：去首尾空白后，若首尾是单引号 `'…'` 则剥掉，再 `JSON.parse`，失败回 `null`。

### 3.3 登录方式与登录态存放

- **只有 Cookie 登录，没有扫码。**酷我 Web 只有登录后下发 Cookie，没有扫码接口。
- 文件：`services/kuwo-api/.auth-cookies.json`（`0o600` 写盘；空时删文件）。只存键值，日志里不出现值；`Hm_Iuvt_*` 开头的键不存进用户 Cookie（`loadCookies` / 保存时都跳过）。
- `parseCookieInput(raw)`：去 `cookie:` 前缀；以 `{` 开头时按 JSON 解析（失败则按 `;` 分）；否则按 `;` 切、`=` 分，去引号。`userUid()` 取 `userid || userId || uid`；`userSid()` 取 `sid || websid`。
- 登录判定（`statusBody()`）：`loggedIn = !!(uid && sid)`；`uid` 为空时 `hasCookie: false`。返回 `{ code: 200, loggedIn, uid: uid || '', nickname: '', avatar: '', vip: false, verified: false, hasCookie: !!uid, note: <见下> }`，其中 `note`：
  - 已登录：`'登录态来自粘贴的 Cookie；酷我 Web 没有可用的校验接口，播放时会自动带上'`
  - 只有 userid 缺 sid：`'Cookie 里只有 userid，缺 sid/websid —— 请复制整段 Cookie'`
  - 未登录：`'还没粘贴酷我 Cookie'`
  - ⚠️ 注意：`nickname` / `avatar` / `vip` 恒为空/false——**没有可用的校验接口**，不要编。
- `/login/cookie` 校验：`userid` 与 `sid`（或 `websid`）缺一不可，否则不落盘，回 `{ code: 200, loggedIn: false, error: 'Cookie 里没有 userid / sid（或 websid）。请登录 www.kuwo.cn 后复制整段 Cookie' }`。成功时清空旧 Cookie 后全量保存新解析的键（排除 `Hm_Iuvt_*`），记日志「已保存酷我 Cookie 键名：<逗号分隔的键名>」，回 `statusBody()`。
- `/logout`：清空并删文件，记日志「已清除酷我 Cookie」，回 `{ code: 200, loggedIn: false }`。
- `/login/qr/*`：明确不伪造，见 2.5。

### 3.4 边车 HTTP 路由与上游接口

通用：未知路径回 HTTP 404 `{ code: 404, error: 'unknown kuwo api: <p>' }`；任意异常记日志后回 HTTP 502 `{ code: 502, error }`；`send()` 统一 `Content-Type: application/json; charset=utf-8`、`Cache-Control: no-store`。

| 边车路由 | 上游接口（方法 / URL / 头 / 参数） | 边车返回（给 server.mjs） | 备注 |
|---|---|---|---|
| `GET /health` 或 `GET /` | 本地，不碰上游 | `{ code: 200, ok: true, node: process.versions.node }` | |
| `GET /status` 或 `GET /login/status` | 本地读 Cookie 文件 | `statusBody()`（见 2.3） | |
| `POST /login/cookie`（也接受 `?cookie=` 或请求 `Cookie` 头；GET 时 body 为空） | 本地写盘 | 见 2.3 | body 超 256KB 时 `req.destroy()` |
| `GET /logout` | 本地清盘 | `{ code: 200, loggedIn: false }` | |
| `GET /login/qr/key`、`/login/qr/create`、`/login/qr/check` | 无上游 | `{ code: 501, error: '酷我 Web 端不提供扫码登录；请在浏览器登录 www.kuwo.cn 后粘贴 Cookie' }` | HTTP 200 + code 501 |
| `GET /search?s\|key\|keywords=&limit=&page=` | `GET https://www.kuwo.cn/search/searchMusicBykeyWord?vipver=1&client=kt&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&mobi=1&issubtitle=1&show_copyright_off=1&pn=<page-1>&rn=<limit>&all=<encodeURIComponent(s)>`，经 `www()`，`referer: 'https://www.kuwo.cn/search'` | 空词 `{ code: 200, total: 0, list: [] }`；`limit` clamp 1..50 默认 20，`page` ≥ 1 默认 1；上游 `abslist` 非数组回 `{ code: 502, total: 0, list: [], error: '酷我搜索返回无法解析' }`；成功 `{ code: 200, total: Number(j.TOTAL) \|\| abslist.length, list: j.abslist }`（原样透传，不归一化） | README 实测：TOTAL 3600 |
| `GET /playlist/tracks?id=&limit=&page=` | `GET https://www.kuwo.cn/api/www/playlist/playListInfo?pid=<id>&pn=<page>&rn=<limit>&httpsStatus=1` | 缺 id → 400 `{ code: 400, error: 'id required' }`；limit clamp 1..200 默认 100；上游 `code !== 200` 回 `{ code: <上游码或502>, id, list: [], error: <上游 msg \|\| message 或 '取歌单失败'> }`；成功 `{ code: 200, id: String(d.id \|\| id), name: d.name \|\| '', cover: d.img \|\| '', creator: d.uname \|\| d.userName \|\| '', total: Number(d.total) \|\| musicList.length, list: d.musicList \|\| [] }` | README 实测：歌单 2867496601，177 首 |
| `GET /playlist/search?key\|s=&limit=&page=` | `GET https://www.kuwo.cn/api/www/search/searchPlayListBykeyWord?key=<key>&pn=<page>&rn=<limit>&httpsStatus=1` | 空词 `{ code: 200, total: 0, list: [] }`；失败同上（`'搜索歌单失败'`）；成功 `{ code: 200, total: Number(d.total) \|\| list.length, list: d.list \|\| [] }` | README 实测：142 个 |
| `GET /recommend/playlists?limit=&id=` | `GET https://www.kuwo.cn/api/www/rcm/index/playlist?id=<id，默认'37'>&pn=1&rn=<limit>&httpsStatus=1` | limit clamp 1..50 默认 12；失败 `'取推荐歌单失败'`；成功 `{ code: 200, list: (j.data && j.data.list) \|\| [] }` | |
| `GET /rank/list` | `GET https://www.kuwo.cn/api/www/bang/bang/bangMenu?&httpsStatus=1`，`referer: 'https://www.kuwo.cn/rankList'` | 失败 `'取榜单目录失败'`；成功 `{ code: 200, list: j.data \|\| [] }` | 含官方/特色/分类 |
| `GET /rank/tracks?id=&limit=&page=` | `GET https://www.kuwo.cn/api/www/bang/bang/musicList?bangId=<id，默认'16'>&pn=<page>&rn=<limit>&httpsStatus=1`，`referer: 'https://www.kuwo.cn/rankList'` | 失败 `'取榜单失败'`；成功 `{ code: 200, total: Number(d.num) \|\| musicList.length, list: d.musicList \|\| [] }` | 热歌榜=16，300 首 |
| `GET /radio/stations` | `GET https://www.kuwo.cn/api/www/radio/index/radioList?&httpsStatus=1`，`referer: 'https://www.kuwo.cn/rankList'` | 失败 `'取电台目录失败'`；成功 `{ code: 200, list: (j.data && j.data.albumList) \|\| [] }` | **只有栏目目录，没有单集曲目接口** |
| `GET /album/tracks?id=&limit=&page=` | `GET https://www.kuwo.cn/api/www/album/albumInfo?albumId=<id>&pn=<page>&rn=<limit>&httpsStatus=1` | 缺 id → 400；失败 `'取专辑失败'`；成功 `{ code: 200, id: String(d.albumid \|\| id), name: d.album \|\| '', cover: d.pic \|\| '', total: Number(d.total) \|\| 0, list: d.musicList \|\| [] }` | README 实测：专辑 29593612，12 首 |
| `GET /daily` | 先 `GET https://www.kuwo.cn/api/www/rcm/index/playlist?id=37&pn=1&rn=10&httpsStatus=1`，挑 `name` 含「每日」或「推荐」的歌单（否则取第 1 个），再 `GET https://www.kuwo.cn/api/www/playlist/playListInfo?pid=<pick.id>&pn=1&rn=20&httpsStatus=1`；任一步失败/无曲目则退 `GET https://www.kuwo.cn/api/www/bang/bang/musicList?bangId=16&pn=1&rn=20&httpsStatus=1` | 成功（歌单路）`{ code: 200, name: pick.name \|\| '每日最新单曲推荐', source: 'playlist', list: tracks }`；退榜单 `{ code: 200, name: '酷我热歌榜', source: 'rank', list: musicList \|\| [] }` | README：官方「每日最新单曲推荐」歌单 1082685104，失败退热歌榜 |
| `GET /song/url?id\|mid=&quality=` | 见 2.5（mobi `convert_url2` + web `playUrl` 兜底） | 缺 id → 400；`{ code: 200, id, ...hit }`，hit 见 2.5 | |
| `GET /lyric?id\|mid=` | 见 2.6（PC `newlyric.lrc` + H5 兜底） | 缺 id → 400；`{ code: 200, lyric, yrc, format: yrc ? 'yrc' : (lyric ? 'lrc' : 'none'), source: 'kw-pc' \| 'kw-h5', error: <有词时 null，否则上游错或 '酷我没给这首歌歌词（或上游限流）'> }` | |

主服务 `/api/kuwo/*` 的翻译（`handleKuwo`，前端实际看到的形状）：

- `health` → `{ code: 200, ok: !!h.data.ok, port, node, audio: true, login: 'cookie' }`。
- `status` / `logout` 透传边车 body。
- `login/cookie`：非 POST 回 405 `{ code: 405, error: '请用 POST 提交 Cookie' }`；空 cookie 回 `{ code: 200, loggedIn: false, error: 'Cookie 是空的' }`；取 `body.cookie || body.value`。
- `login/qr/*`：主服务直接回 `{ code: 501, error: '酷我 Web 端不提供扫码登录；请登录 www.kuwo.cn 后粘贴 Cookie' }`（不调边车）。
- `search`：调边车 `/search?s=<s>&limit=&page=`（超时 25000），回 `{ code, source: 'kuwo', tracks: list.map(kuwoTrack).filter(id && name), songCount: Number(total) || 0, error }`；空词 `{ code: 200, source: 'kuwo', tracks: [], songCount: 0 }`。
- `playlist/tracks`：回 `{ code, source: 'kuwo', id, name, cover, creator, total, tracks, error }`。
- `playlist/search`：回 `{ code, source: 'kuwo', playlists: list.map(kuwoPlaylist).filter(id && name), total, error }`。
- `recommend/playlists`：回 `{ code, source: 'kuwo', playlists, error }`。
- `rank/list`：把 `d.list`（分组数组）里每组的 `list[]` 用 `kuwoPlaylist` 摊平成 playlists；回 `{ code, source: 'kuwo', playlists, error }`。
- `rank/tracks`：默认 `id='16'`；回 `{ code, source: 'kuwo', id, total, tracks, error }`。
- `album/tracks`：回 `{ code, source: 'kuwo', id, name, cover, total, tracks, error }`。
- `radio/stations`：回 `{ code, source: 'kuwo', playable: false, stations: list.map(it => ({ id: String(it.rid), source: 'kuwo', name: it.album || '未命名电台', cover: it.pic || '', creator: { nickname: it.artist || '' }, playCount: Number(it.listencnt) || 0, playable: false })), error, note: '酷我只开放电台栏目目录，没有单集曲目接口' }`。注释原文：「只有栏目目录，没有单集曲目接口：`playable=false`，前端不会拿它冒充可播电台」。
- `daily`：回 `{ code, source: 'kuwo', name: d.name || '每日推荐', from: d.source || '', tracks, error }`。
- `song/url`：`quality` 取 `q.quality || '320'` 原样透传；回 `{ code, id, url, quality: d.quality || '', format: d.format || '', preview: false, source: d.source || 'kuwo', reason: url ? null : (d.reason || 'unavailable'), error: url ? null : (d.error || '上游没给播放地址') }`。
- `lyric`：回 `{ code, lyric, yrc: d.yrc || '', tlyric: '', format: yrc ? 'yrc' : (d.format || (lyric ? 'lrc' : 'none')), source: d.source || '', error: (lyric || yrc) ? null : (d.error || '酷我没给这首歌歌词') }`。
- `user/playlists` / `liked`：**上游确实没有这两个接口**（www / wapi / mobile wapi 全 404），直接回空态 + 原因（见 2.7），不调边车。
- 未知路径 `{ code: 404, error: 'unknown kuwo api: <part>' }`；异常 502 + `log`。

### 3.5 播放直链（song/url）

- 档位映射 `QUALITY = { '128': '128kmp3', '320': '320kmp3', flac: '2000kflac' }`；`resolveSongUrl(id, quality)`：`want = QUALITY[quality] || QUALITY['320']`；尝试顺序 `[want]`，若 `want !== '320kmp3'` 再加 `'320kmp3'`，若 `want !== '128kmp3'` 再加 `'128kmp3'`。
- 主链 `mobiUrl(id, br)`：
  - 明文 `plain = CRED + '&type=convert_url2&sig=0&format=<flac|mp3>&br=<br>&rid=<id>'`；已登录（`userUid() && userSid()`）时追加 `&loginUid=<uid>&loginSid=<sid>`。
  - `q = encryptKuwoQuery(plain)`：DES 变体加密（密钥 `'ylzsxkwm'`，模式 0）后标准 base64。
  - `GET https://mobi.kuwo.cn/mobi.s?f=kuwo&q=<encodeURIComponent(q)>`，头 `User-Agent: okhttp/3.10.0`（`UA_OK`），超时 20000。
  - 响应为文本，用正则 `/url=(https?:\/\/[^\s]+)/` 提取第一条 url；提不到回 `''`。
  - 成功回 `{ url, quality: br.replace('kmp3','').replace('kflac',''), format: br.includes('flac') ? 'flac' : 'mp3', source: 'mobi' }`。注意 `quality` 是从 `br` 派生的（`'128'` / `'320'` / `'2000'`——`'2000kflac'.replace('kflac','')` 得 `'2000'`），不是请求的 `quality` 原值。
- 兜底 `webPlayUrl(id)`：经 `www()` 调 `GET /api/v1/www/music/playUrl?mid=<id>&type=music&httpsStatus=1&plat=web_www&from=&br=128kmp3`，取 `j.data.url`；成功回 `{ url, quality: 'web', format: 'mp3', source: 'web' }`。
- 全部失败回 `{ url: '', reason: 'unavailable', error: <最后一次错误或 '上游没给播放地址'> }`。
- 直链域名：实测返回 `kw-er.kuwo.cn` / `kw-lv.kuwo.cn`（都带 Range 206）；代理白名单只放行 `*.kuwo.cn` / `*.kuwo.com`（见 0.4）。
- README 明确：**没有使用 `anti.s`**。它对付费歌固定返回 11.31 秒的试听片段（多个 rid 返回同一份 181521 字节文件），拿它当播放地址属于造假，故意不用。mobi 链拿到的是**完整时长**直链，付费歌也能拿到试听/播放地址，匿名请求即可；web 链免费歌可用，付费歌返回错误，作为兜底。
- 曲目归一化 `kuwoTrack(it)`：`rid` 取 `it.rid || it.DC_TARGETID || MUSICRID 去 'MUSIC_' 前缀 || it.id`；`name` 取 `name || NAME || SONGNAME`；`artists` 取 `artist || ARTIST || FARTIST`；`cover` 取 `pic || albumpic || albumpic_short || web_albumpic_short`，相对路径时拼 `'https://img1.kuwo.cn/star/albumcover/' + 去前导 '/' 后的路径`（搜索接口只给相对路径如 `120/s3s94/93/211513640.jpg`，歌单给完整 URL）；`albumId` 取 `albumid || ALBUMID`；`duration` 取 `(duration || DURATION) * 1000`（秒→毫秒）；`fee: 0`（注释：酷我直链匿名就能拿到完整时长，不拿 pay 字段吓人）。搜索是 PascalCase（`NAME` / `ARTIST` / `DURATION` 秒），歌单/榜单是 camelCase（`name` / `rid` / `album`）。
- 歌单归一化 `kuwoPlaylist(it)`：`{ id: String(it.sourceid || it.id || ''), source: 'kuwo', name: it.name || '未命名歌单', cover: it.img || it.img500 || it.img300 || it.pic || '', trackCount: Number(it.total) || 0, playCount: Number(it.listencnt) || 0, creator: { nickname: it.uname || it.userName || '' }, rank: !!it.sourceid }`。注释：榜单的播放入参是 menu 项里的 `sourceid`（热歌榜=16），不是 489927（指榜单分组里的 `id` 字段）。

### 3.6 歌词（lyric）

- PC 通道 `lyricPc(id)`：
  - 参数构造 `buildLyricParams(id, lrcx=true)`：明文 `user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_<id>&lrcx=1`，逐字节 XOR 密钥 `'yeelion'`（循环），再 base64。
  - `GET https://newlyric.kuwo.cn/newlyric.lrc?<base64参数>`，头 `User-Agent: UA_WEB`，超时 20000；非 2xx 抛 `'歌词 HTTP <status>'`。
  - 响应体须以 `tp=content` 开头（前 12 字节比对），否则抛 `'歌词返回格式不是 tp=content'`；找 `\r\n\r\n` 分隔头，缺失抛 `'歌词返回缺分隔头'`；分隔头之后 `zlib.inflateSync` 解压。
  - 解压后文本若以 `[` 开头，直接 gb18030 解码；否则先 base64 解码再 XOR `'yeelion'`，最后 gb18030 解码（`TextDecoder('gb18030')`，失败退 utf8）。
  - 再经 `convertLrcx(raw)`（见下）。
- H5 兜底 `lyricH5(id)`：`GET http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId=<id>`（注意是 `http:`），头 `User-Agent: UA_MOBILE`、`Referer: https://m.kuwo.cn/`，超时 15000；取 `j.data.lrclist[]`，每项 `[secToLrc(x.time)]<lineLyric>` 拼接；`secToLrc(t)` 为 `mm:ss.cs`（`cs` 为百分秒，两位）。
- `convertLrcx(raw)`：
  - lrcx 里的 `<左,右>` 不是翻译标记，而是**逐字时间**：`[kuwo:NNN]` 给出两个系数（**八进制**），左/右是「起点 + 时长」的混合编码。解码：`factors = parseInt(tag[1], 8)`；`startFactor = trunc(factors / 10)`；`durationFactor = factors % 10`；任一为 0 则不解；`<A,B>` → `<trunc(|(A+B)/(2*startFactor)|), trunc(|(A-B)/(2*durationFactor)|)>`；先删 `[kuwo:…]` 标签。没有 `[kuwo:…]` 标签的旧歌词，`<…>` 本来就是毫秒，原样保留。
  - 行解析：PC 通道是 `[mm:ss.SSS]`，个别老歌只有 1~2 位小数，都收（正则 `/^\[(\d{2}):(\d{2})(?:[.:](\d{1,3}))?\](.*)$/`，小数补足 3 位）；`[ti|ar|al|by|offset]:` 元信息行保留进 LRC。
  - 翻译行整行都是 `<0,0>`（没有时间轴），原文行才带真实逐字时间；同一时间点已有原文时翻译行不重复铺（`isTrans && time === lastTime` 时跳过 LRC 行）。
  - 输出两份：`lyric`（整行 LRC）、`yrc`（逐字 YRC：`[行起点ms,行时长ms](字绝对起点,字时长,0)字…`，行时长取 `max(off+dur)`，翻译行不进 YRC）。
  - 主服务注释：「边车把 lrcx 里的 `<...>` 解成了逐字时间轴（以前当翻译标记整段删掉）。解出来就放 yrc；边车若退回 H5 整行歌词，就没有 yrc。」
- 失败路径：PC 抛错时记 `error`，再试 H5；H5 也无词时 `error` 保留第一次错误；最终 `source` 为 `'kw-pc'` 或 `'kw-h5'`。

### 3.7 明确返回空态 / 错误的路由

- `/login/qr/*`：`{ code: 501, error: '酷我 Web 端不提供扫码登录；请在浏览器登录 www.kuwo.cn 后粘贴 Cookie' }`（边车与主服务都回这个原文，**不画假二维码**）。
- `/login/cookie` 缺 userid/sid：`{ code: 200, loggedIn: false, error: 'Cookie 里没有 userid / sid（或 websid）。请登录 www.kuwo.cn 后复制整段 Cookie' }`。
- 主服务 `user/playlists`：`{ code: 200, source: 'kuwo', playlists: [], tracks: [], error: '酷我 Web 没有用户歌单接口，不编内容' }`。
- 主服务 `liked`：`{ code: 200, source: 'kuwo', playlists: [], tracks: [], error: '酷我 Web 没有「我喜欢的音乐」接口，不编内容' }`。
- `radio/stations`：只有目录，`playable: false` + `note: '酷我只开放电台栏目目录，没有单集曲目接口'`。
- `search` 上游无法解析：`{ code: 502, total: 0, list: [], error: '酷我搜索返回无法解析' }`。
- `song/url` 拿不到：`{ url: '', reason: 'unavailable', error: <最后一次错误或 '上游没给播放地址'> }`。
- `lyric` 无词：`lyric: ''`、`yrc: ''`、`format: 'none'`、`error: '酷我没给这首歌歌词（或上游限流）'`（或上游原始错误）。

---

## 4. 汽水音乐（qishui）

### 4.1 边车本体

- 目录 `services/qishui-api/`；启动 `node services/qishui-api/start.mjs`（server.mjs 按需 spawn，优先用系统 node ≥ 24）。
- `package.json`：`"name": "lizi-qishui-api"`，`"type": "module"`，`engines: { node: ">=24" }`，`scripts.start = "node start.mjs"`，依赖 `qishui-music-api: 0.2.2`（MIT，零依赖）、`qrcode-generator: 2.0.4`。
- 端口：`QISHUI_API_PORT` → `.port` → **3212**。
- 库是**纯协议库，不是 HTTP 服务**：导出 `createQishuiApi` / `QISHUI_OPERATIONS` / `createQishuiDeviceId` / `isAccountId`（README 另写 `isQishuiDeviceId`；`start.mjs` 实际用的是 `createQishuiApi, createQishuiDeviceId, isQishuiDeviceId`）。报文要求 ByteDance 的 guard 签名（`deviceId` / `ticket` / `guardKey` / `guardCert` / `guardTsSign` / `accessCode`），需要 BigInt 与 crypto 的 P-256 / PKCS#8。`start.mjs` 是很薄的 HTTP 壳，把库的 `api.request(op, params)` 摊成路由，形状照 QQ 那套（`{ code, … }`），只绑 `127.0.0.1`，端口写 `.port`。
- Node 版本闸门在 `start.mjs` 顶部：`NODE_MAJOR < 24` 时写日志、打印 `QISHUI_API_UNSUPPORTED_NODE <ver>`、`process.exit(2)`，不静默降级。
- ⚠️ 库内上游：`qishui-music-api@0.2.2` 的协议细节（具体上游域名/路径/签名算法）**不在仓库中**；本文只记录 `start.mjs` 的 HTTP 壳与 `api.request(op, params)` 的 op 名、参数与返回映射。移植时须按该库 0.2.2 的实现重做 guard 签名报文，不得凭记忆编造上游地址。源码中逐字出现的上游地址只有二维码接口 `https://open.douyin.com/oauth/get_qrcode/`（见 3.3）。

### 4.2 server.mjs 拉起与通话

- `SIDECARS.qishui = { dir: 'qishui-api', env: 'QISHUI', port: 3212, node24: true, ping: '/health' }`；走通用 `ensureSidecar` / `scRequest`（cookie 走 query；汽水各路由实际不带 cookie，登录态在边车本地）。
- `health` 先行：主服务 `health` 路由先 `ensureSidecar('qishui')`，再 `scRequest('qishui', '/health', { timeout: 5000 })`，回 `{ code: 200, ok: true, port, node: h.data.node || '', loggedIn: !!h.data.loggedIn }`；失败回 `{ code: 502, ok: false, error, reason, log: scLogTail('qishui') }`。
- 错误映射 `failBody(error)`（边车内）：`error.code`（库的错误码）→ HTTP code：`'auth-required': 401`、`'not-playable': 403`、`unavailable: 502`、`network: 502`、`'invalid-response': 400`、`unsupported: 400`，其余 502。返回 `{ code, ok: false, error: error.message || '汽水接口失败', upstreamCode: error.upstreamCode || null, stage: error.stage || null }`（「上游数字码（28001008 之类）原样带出去，排查时不用猜」）。
- `api.request(op, params)` 返回 `{ ok, data }` 或 `{ ok: false, error }`；前端只看 `code` / `error` 两个字段（`start.mjs` 注释）。

### 4.3 登录方式与登录态存放

- 扫码登录（抖音扫码）。流程：
  1. `GET /login/qr/key` → `api.request('login_qr_key')` → `{ code: 200, key: r.data.key }`；失败回 HTTP 502 `failBody`。
  2. `GET /login/qr/create?key=` → `api.request('login_qr_create', { key })` → `{ code: 200, qrimg: r.data.imageUrl || '' }`；缺 key → 400 `{ code: 400, error: 'key required' }`。库给的就是 `data:image/png;base64,...` 的整串，前端直接塞 `<img src>`。
  3. `GET /login/qr/check?key=` → `api.request('login_qr_check', { key })` → 状态映射（照 QQ/网易云那套）：库的状态词 `waiting` / `scanned` / `confirmed` / `expired` / `error` 映射为 `801` / `802` / `803` / `800` / `800`；回 `{ code: MAP[state] || 801, state }`；`confirmed` 时追加 `{ loggedIn: true, nickname, avatar, vip }`（取自落盘的 `current.user`）；`error` 时追加 `error: '扫码被拒绝，或授权码已失效'`。库调用失败（`!r.ok`）时回 HTTP 200 `{ code: 500, error: failBody(r.error).error }`（注意：HTTP 200 包 500）。
- 二维码瘦身（`qr.mjs` 的 `wrapQrFetch`，只拦 `open.douyin.com/oauth/get_qrcode/`）：
  - 上游一次返回两样东西：`data.qrcode`（base64 PNG，77×77、ECC M、3px/模块的 256px PNG）与 `data.qrcode_index_url`（PNG 里编码的原始字符串，356 字节的 `aweme://` 深链）。
  - 只删空值参数（`certification_scope=` / `openid=` / `optional_scope_check=` / `optional_scope_uncheck=` / `user_ticket=`），356 → 268 字节；`token` / `scopes` / `client_key` 原样保留；`/login/qr/check` 轮询完全不变。
  - 再用 ECC L 重画成 57×57、8px/模块、4 模块留白的 520px PNG（`qrcode-generator`）。任何一步失败都原样返回上游响应。设 `QISHUI_QR_SIMPLIFY=0` 可退回上游原图（此时 `fetch` 用原生 `globalThis.fetch`）。
- 登录态存放：
  - 设备 ID：`services/qishui-api/.auth-device.json`，`{ deviceId, createdAt }`，`0o600`；由库的 `createQishuiDeviceId()` 生成，`isQishuiDeviceId()` 校验；README 说是 **19 位数字**；删了 = 汽水当新设备（换设备 ID 等于换一台车机）。包本身不碰磁盘（README 明确说宿主负责存储/加密），由 `start.mjs` 代劳。
  - 会话：`services/qishui-api/.auth-session.json`，`0o600`；须同时有 `ticket`、`guardKey`、`guardCert`、`guardTsSign`、`accessCode` 才算有效会话（`loadSession()` 的校验条件），否则视为没登录过。`sessions` 对象：`get()` / `set(value)`（写盘并记日志「登录态已落盘 .auth-session.json（userid=<userId>）」，同时 `revision++`）/ `clear()`（删文件，记「登录态已清除」）；`revision` 供库判断会话是否变化。
  - `/status`（边车内）：无 `current` 直接 `{ code: 200, loggedIn: false }`；有则调 `api.request('login_status')`：失败时库会自己 `clear()`，所以再读一次 `current`——已清则 `{ code: 200, loggedIn: false, error: r.error.message }`，未清则 `{ code: 200, loggedIn: true, nickname, avatar, vip: !!user.isVip, stale: r.error.message }`；成功回 `{ code: 200, loggedIn: true, nickname: u.nickname || '', avatar: avatarUrl(u.avatar) || avatarUrl(current.user.avatar), vip: !!u.isVip, userId: u.id || current.userId || '' }`。
  - 头像归一化 `avatarUrl(value)`：`/me/info` 给的不是字符串，而是图片对象 `{ need_complete_url: true, urls: ['https://p26-sign.douyinpic.com/...jpeg?...'], uri, template_prefix }`；只有 `need_complete_url === true` 的 `urls` 才是带签名的完整地址；歌手简介那种 `urls: ['https://p3-luna.douyinpic.com/img/']` + `need_complete_url: false` 的基址缺签名，拼出来实测 400（`fail to get template`），不能拿来冒充头像；字符串时只接受路径非 `/` 且不以 `/img/` 结尾的 http(s) 地址。
  - `/logout`：`api.request('logout')`（库内清会话），回 `{ code: 200, loggedIn: false }`。

### 4.4 边车 HTTP 路由（`api.request(op, params)` 的 op 名即移植契约）

| 边车路由 | 库 op / 参数 | 边车返回 | 主服务 `/api/qishui/*` 的归一化 |
|---|---|---|---|
| `GET /health` 或 `GET /` | 本地 | `{ code: 200, ok: true, node, deviceId, loggedIn: !!current, userId: current.userId \|\| null, nickname: current.user.nickname \|\| '' }` | 见 3.2 |
| `GET /status` 或 `GET /login/status` | `login_status` | 见 3.3 | 透传边车 body |
| `GET /login/qr/key` | `login_qr_key` | `{ code: 200, key }` / 失败 HTTP 502 `failBody` | 透传（超时 25000） |
| `GET /login/qr/create?key=` | `login_qr_create`, `{ key }` | `{ code: 200, qrimg }`；缺 key → 400 | 透传 |
| `GET /login/qr/check?key=` | `login_qr_check`, `{ key }` | 见 3.3 | 透传（超时 25000） |
| `GET /logout` | `logout` | `{ code: 200, loggedIn: false }` | 透传 |
| `GET /search?q\|keywords=&limit=&offset=` | `search`, `{ query, limit, offset }` | limit clamp 1..100 默认 20，offset ≥ 0 默认 0；空 query `{ code: 200, items: [], hasMore: false, nextOffset: 0 }`；失败 HTTP 502 `failBody`；成功 `{ code: 200, items: r.data.items \|\| [], hasMore: !!r.data.hasMore, nextOffset: r.data.nextOffset \|\| 0 }` | 空词 `{ code: 200, source: 'qishui', tracks: [], songCount: 0 }`；limit clamp 1..50 默认 20（主服务层）；`d.code !== 200` 回 `{ code, source: 'qishui', tracks: [], error }`；成功 `{ code: 200, source: 'qishui', tracks: items.map(qishuiTrack).filter(id && name), songCount: items.length, more: !!hasMore }` |
| `GET /song/detail?id=` | `song_detail`, `{ id }` | 缺 id → 400；失败 502；成功 `{ code: 200, track: r.data }` | 主服务未接此路由（⚠️ 边车有，主服务无） |
| `GET /audio?id=&quality=` | `audio`, `{ id, quality }` | quality 仅认 `standard` / `high` / `lossless` / `hires`，其余回 `standard`；缺 id → 400；失败回 **HTTP 200** `{ code: 200, url: '', reason: r.error.code, error: r.error.message }`；成功 `{ code: 200, url: r.data.url, quality: r.data.quality, preview: !!r.data.preview, clipStartMs: r.data.clipStartMs \|\| 0, expiresAt: r.data.expiresAt \|\| 0 }` | 主服务 `song/url`：quality 同样白名单，默认 `standard`（超时 25000）；回 `{ code: 200, id, url, preview, clipStartMs: d.clipStartMs \|\| 0, quality: d.quality \|\| quality, reason: url ? (preview ? 'preview' : null) : (d.reason \|\| 'unavailable'), error: url ? null : (d.error \|\| null) }`；缺 id → 400 |
| `GET /lyrics?id=` | `lyrics`, `{ id }` | 缺 id → 400；失败回 HTTP 200 `{ code: 200, lyric: '', error: r.error.message }`；成功 `{ code: 200, lyrics: r.data }`（注意字段名是 **`lyrics`**，内容为库的原始 `r.data`） | 主服务 `lyric`：取 `r.data.lyrics.lyric_entity.content`；`isKrc = /^\[\d+,\d+\]/m` 时 `lyric = krcToLrc(content)`、`yrc = krcToYrc(content)`，否则原样当 LRC；回 `{ code: 200, lyric: lrc, yrc, tlyric: '', format: yrc ? 'yrc' : (lrc ? 'lrc' : 'none') }`；缺 id → 400 |
| `GET /feed/modes` | `feed_modes` | 失败 502；成功 `{ code: 200, modes: r.data }` | 主服务 `feed/modes`：`d.code !== 200` 回 `{ code, source: 'qishui', stations: [], error }`；成功 `{ code: 200, source: 'qishui', stations: modes.map(qishuiScene).filter(id) }` |
| `GET /feed?scene=&preference=&first=&limit=` | `feed`, `{ scene, preference, first: q.first === '1', limit }` | limit clamp 1..100 默认 20；失败 502；成功 `{ code: 200, items: r.data.items \|\| r.data \|\| [], more: !!r.data.hasMore }` | 主服务 `feed`：`limit` clamp 1..60 默认 20，`mode` 参数作 `scene` 透传；`d.code !== 200` 回 `{ code, source: 'qishui', tracks: [], error: d.error \|\| '汽水推荐流没拿到' }`；成功 tracks 取 `qishuiTrack` |
| `GET /user/playlists?limit=&offset=` | `user_playlists`, `{ limit, offset }` | limit clamp 1..500 默认 100，offset ≥ 0 默认 0；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, items: r.data.items \|\| [], total: r.data.total \|\| 0, hasMore: !!r.data.hasMore, nextOffset: r.data.nextOffset \|\| 0 }` | 主服务按 offset 翻页去重，最多 20 页（limit clamp 1..500 默认 100）；第 0 页失败时 401 回 `'先在卡片上扫码登录汽水音乐'`；停法：空页、`hasMore=false`、offset 不前进、到页数上限；成功 `{ code: 200, source: 'qishui', playlists, total }` |
| `GET /liked_songs` 或 `/liked-songs` | `liked_songs` | 失败回 `failBody` 的 HTTP code；成功 `{ code: 200, ids: r.data.ids \|\| [], total: r.data.total \|\| 0, whole: !!r.data.whole }` | 主服务 `liked_songs`：失败时 401 回 `'先在卡片上扫码登录汽水音乐'`；成功 `{ code: 200, source: 'qishui', ids: d.ids \|\| [], total: d.total \|\| 0 }`（只返回 id 数组，不展开曲目） |
| `GET /playlist/detail?id=` | `playlist_detail`, `{ id }` | 缺 id → 400；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, playlist: r.data }` | 主服务：失败 `{ code, source: 'qishui', playlist: null, error }`；成功 `{ code: 200, source: 'qishui', playlist: qishuiPlaylist(d.playlist \|\| {}) }` |
| `GET /search/playlists?q\|keywords=&limit=&offset=` | `search_playlists`, `{ query, limit, offset }` | 空 query `{ code: 200, items: [], hasMore: false, nextOffset: 0 }`；失败回 `failBody` 的 HTTP code；成功同 search 形状 | 主服务 `search/playlists`：空词 `{ code: 200, source: 'qishui', playlists: [] }`；limit clamp 1..50 默认 20；成功 playlists 取 `qishuiPlaylist` |
| `GET /recent_played?limit=&offset=` | `recent_played`, `{ limit, offset }` | limit clamp 1..100 默认 50；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, items: r.data.items \|\| [], hasMore: !!r.data.hasMore }` | 主服务固定调 `/recent_played?limit=50`；失败时 401 回 `'先在卡片上扫码登录汽水音乐'`；成功 tracks 取 `qishuiTrack` |
| `GET /artist/songs?id=&limit=&offset=` | `artist_songs`, `{ id, limit, offset }` | 缺 id → 400；limit clamp 1..100 默认 50；失败回 `failBody` 的 HTTP code；成功同上 | 主服务固定调 `limit=50`；成功 tracks 取 `qishuiTrack` |
| `GET /playlist/tracks?id=&limit=&offset=` | `playlist_tracks`, `{ id, limit, offset }` | 缺 id → 400；limit clamp 1..100 默认 50；失败 HTTP 502 `failBody`；成功 `{ code: 200, items: r.data.items \|\| [], hasMore: !!r.data.hasMore }` | 主服务 `playlist/tracks`：limit clamp 1..100 默认 50；`d.code !== 200` 回 `{ code, source: 'qishui', tracks: [], error: d.error \|\| '歌单取不到' }`；成功 `{ code: 200, source: 'qishui', tracks, more: !!hasMore }` |
| 未知路径 | — | HTTP 404 `{ code: 404, error: 'unknown qishui api: <p>' }` | 主服务未知路径 `{ code: 404, error: 'unknown qishui api: <part>' }`；任意异常 502 + `log` |

### 4.5 播放与特殊行为、pay/fee

- 未登录**只有 30 秒试听**：`/audio` 匿名回 `preview: true` + `clipStartMs`（片段在原曲的起点，例如 145344ms，README 实测）；主服务 `song/url` 的 `reason` 为 `'preview'`；LIZI 打「试听片段」角标，不假装整首。
- 只发**未加密**资源；`higher` / `highest` / `lossless` 档位在车机接口里是加密的，包里直接不支持，所以最高只能拿到 `standard` / `high`（README）。边车 quality 白名单仍是 `standard` / `high` / `lossless` / `hires`（非法值回 `standard`），但上游实际只给到 `high`。
- 音频容器是 `ftypM4A`（AAC）；代理必须转发 Range，否则拖进度条会整段重下；CDN 不加 Referer（见 0.4）。
- `qishuiTrack(it)`：字段全在 `base_info` / `related_info` / `display_info` 里：`{ id: String(b.id \|\| it.id), source: 'qishui', name: b.name \|\| '', artists: rel.artist_links[].name.join(' / ') \|\| '未知歌手', artistIds: rel.artist_links[].id, album: rel.album_link.name \|\| '', albumId: String(rel.album_link.id), cover: pickCover(d.cover_url), duration: Number(b.duration_ms) \|\| 0, fee: 0 }`。
- 封面 `pickCover(c)`：字符串直接用；`c.url` 直接用；否则取 `urls[0]`（数组）或 `urls` 字符串的首个空格分段 + `uri`，再加后缀：`template_prefix` 存在时 `~<template_prefix>-<template>`（`template` 为空时用 `~<template_prefix>-resize:480:480.image`，列表/跑马带只要 200~400px，原图 0.5~2MB 太大；实测 resize 图 38KB，缩图失败退回完整图）；**不带模板会 400**（实测 `https://p3-luna.douyinpic.com/img/<uri>` → 400，`…~tplv-…` → 200）。
- `qishuiPlaylist(it)`：`{ id: String(b.id), source: 'qishui', name: b.title \|\| b.name \|\| '未命名歌单', cover: pickCover(d.url_cover \|\| d.cover_url \|\| d.cover), trackCount: Number(b.resource_cnt ?? b.resource_count ?? stats.count ?? it.resource_cnt) \|\| 0, playCount: Number(stats.play_count ?? stats.playCount ?? b.play_count) \|\| 0, creator: { nickname: owner.nickname \|\| owner.name \|\| b.owner_nickname \|\| '' }, type: Number(b.type) \|\| 0 }`，其中 `b = it.base_info || it`，`d = it.display_info || {}`，`rel = it.relation_info || {}`；**`type=1` 是账号的「我喜欢的音乐」歌单**，前端据此挑红心。
- `qishuiScene(m)`：`{ id: String(m.id), source: 'qishui', name: m.name \|\| m.title \|\| '场景电台', cover: pickCover(m.coverUrl \|\| m.cover_url \|\| m.cover), trackCount: 0, playCount: 0, creator: { nickname: m.group \|\| '' } }`。
- `fee` 恒为 0（汽水曲目不打 pay 标记）。
- 歌词：库给的 `lyric_entity.content` 绝大多数是 KRC（`[ms,ms]<…>`），个别歌上游给的就是整行 LRC，原样透出；KRC 时转 LRC + YRC（见 0.5）。

### 4.6 明确返回空态 / 错误的路由

- `search` / `search/playlists` 空 query：`{ code: 200, items: [], hasMore: false, nextOffset: 0 }`。
- `/audio` 失败：**HTTP 200** `{ code: 200, url: '', reason: <库错误码，如 'auth-required' / 'not-playable'>, error: <库错误信息> }`（不是 HTTP 502）。
- `/lyrics` 失败：HTTP 200 `{ code: 200, lyric: '', error }`。
- `/login/qr/check` 库调用失败：HTTP 200 `{ code: 500, error }`；状态 `error` 时 `{ code: 800, state: 'error', error: '扫码被拒绝，或授权码已失效' }`。
- 账号类（`user/playlists` / `liked_songs` / `recent_played` 等）未登录：库回 `auth-required` → 401，主服务回 `'先在卡片上扫码登录汽水音乐'`。
- `/status` 会话失效但本地仍有 `current`：`{ loggedIn: true, …, stale: <错误信息> }`（带 `stale` 标记，不直接判未登录——⚠️ 移植时照此语义）。

---

## 5. 波点音乐（bodian）

### 5.1 边车本体

- 目录 `services/bodian-api/`；启动 `node services/bodian-api/start.mjs`（server.mjs 按需 spawn，优先用系统 node ≥ 24）。
- `package.json`：`"name": "lizi-bodian-api"`，`"type": "module"`，`engines: { node: ">=24" }`，`scripts.start = "node start.mjs"`，依赖 `bodian-music-api: 0.1.2`。
- 端口：`BODIAN_API_PORT` → `.port` → **3213**。
- 库同样是**纯协议库**（`createBodianApi` / `BODIAN_OPERATIONS`），不提供 HTTP 服务；`start.mjs` 结构和汽水壳「一模一样」：薄 HTTP 壳 + 只绑 `127.0.0.1` + 端口写 `.port` + 登录态落盘 + EPIPE + 盯父进程。
- **许可证注意（逐字照抄）：这个包是 AGPL-3.0（汽水是 MIT）。只在本机边车里调用它、不修改它，也不把它打进安装包（根 `package.json` 的 `build.files` 没带 `services/`）。要随包分发得先过许可这一关。** Swift 移植复现其协议时同样须注意该包的 AGPL-3.0 约束（本文只记录事实，不作法律判断）。
- Node ≥ 24 闸门同汽水：版本不够打印 `BODIAN_API_UNSUPPORTED_NODE <ver>` 并 `process.exit(2)`。
- ⚠️ 库内上游：`bodian-music-api@0.1.2` 的协议细节（具体上游域名/路径/签名算法）**不在仓库中**；本文只记录 HTTP 壳与 `api.request(op, params)` 的 op 名、参数与返回映射。

### 5.2 server.mjs 拉起与通话

- `SIDECARS.bodian = { dir: 'bodian-api', env: 'BODIAN', port: 3213, node24: true, ping: '/health' }`；走通用 `ensureSidecar` / `scRequest`。
- `health` 先行：`scRequest('bodian', '/health', { timeout: 5000 })`，回 `{ code: 200, ok: true, port, node, loggedIn: !!h.data.loggedIn, license: 'AGPL-3.0' }`；失败回 `{ code: 502, ok: false, error, reason, log: scLogTail('bodian') }`。
- 错误映射 `failBody(error)`（边车内）：`'auth-required': 401`、`'region-restricted': 451`、`'not-playable': 403`、`unavailable: 502`、`network: 502`、`'invalid-response': 400`、`unsupported: 400`，其余 502。返回 `{ code, ok: false, error: error.message || '波点接口失败', upstreamCode: error.upstreamCode || null, region: code === 'region-restricted' }`，注释：`407 = 地区限制（波点播放只放行中国大陆网络）`。

### 5.3 登录方式与登录态存放

- 扫码登录。流程与汽水同构，op 名相同：
  1. `GET /login/qr/key` → `api.request('login_qr_key')` → `{ code: 200, key: r.data.key }`；失败 HTTP 502 `failBody`。
  2. `GET /login/qr/create?key=` → `api.request('login_qr_create', { key })` → `{ code: 200, qrimg: r.data.imageUrl || '' }`；缺 key → 400。实测二维码 320×320、非空白像素 39.7%（README）。
  3. `GET /login/qr/check?key=` → `api.request('login_qr_check', { key })` → 状态映射 `waiting: 801` / `scanned: 802` / `confirmed: 803` / `expired: 800`（**没有 `error` 映射**，与汽水不同）；回 `{ code: MAP[state] || 801, state }`；`confirmed` 时追加 `{ loggedIn: true, nickname }`（取自 `current.user`；不带 avatar/vip，与汽水不同）。库调用失败时回 HTTP 200 `{ code: 500, error: failBody(r.error).error }`。
  4. `GET /login/qr/cancel?key=` → `api.request('login_qr_cancel', { key })` → `{ code: 200 }`。⚠️ **主服务 `handleBodian` 没有接这个路由**，只有边车有；移植时如需取消扫码，照边车形状实现。
- 登录态存放：
  - 设备 ID：`services/bodian-api/.auth-device.json`，`{ deviceId, createdAt }`，`0o600`；`crypto.randomBytes(16).toString('hex')`（**32 位 hex**，与汽水的 19 位数字不同），校验正则 `/^[0-9a-f]{32}$/i`；删了 = 波点当新设备。
  - 会话：`services/bodian-api/.auth-session.json`，`0o600`；须同时有 `token` 与 `uid` 才算有效（`loadSession` 条件与汽水不同：汽水要 ticket/guardKey/guardCert/guardTsSign/accessCode 五件套）。`sessions` 对象：`get()` / `set(value)`（写盘并记「登录态已落盘 .auth-session.json（uid=<uid>）」，`revision++`）/ `clear()`（删文件）。库本身只在内存里存会话，由 `start.mjs` 代劳落盘。
  - `/status`（边车内）：直接调 `api.request('login_status')`；失败回 `{ code: 200, loggedIn: !!current, error: r.error.message }`（不像汽水那样区分 stale）；成功回 `{ code: 200, loggedIn: !!current, nickname: u.nickname || current.user.nickname || '', avatar: u.avatarUrl || '', uid: u.id || current.uid || '' }`。
  - `/logout`：`api.request('logout')`，回 `{ code: 200, loggedIn: false }`。
  - `/health` 回 `{ code: 200, ok: true, node, loggedIn: !!current, uid: current.uid || null, nickname: current.user.nickname || '' }`。

### 5.4 边车 HTTP 路由（`api.request(op, params)` 的 op 名即移植契约）

| 边车路由 | 库 op / 参数 | 边车返回 | 主服务 `/api/bodian/*` 的归一化 |
|---|---|---|---|
| `GET /health` 或 `GET /` | 本地 | 见 4.3 | 见 4.2（含 `license: 'AGPL-3.0'`） |
| `GET /status` 或 `GET /login/status` | `login_status` | 见 4.3 | 透传边车 body |
| `GET /login/qr/key` | `login_qr_key` | `{ code: 200, key }` / 失败 502 | 透传（超时 25000） |
| `GET /login/qr/create?key=` | `login_qr_create`, `{ key }` | `{ code: 200, qrimg }`；缺 key → 400 | 透传 |
| `GET /login/qr/check?key=` | `login_qr_check`, `{ key }` | 见 4.3 | 透传（超时 25000） |
| `GET /login/qr/cancel?key=` | `login_qr_cancel`, `{ key }` | `{ code: 200 }`（不判断库结果） | ⚠️ 主服务未接 |
| `GET /logout` | `logout` | `{ code: 200, loggedIn: false }` | 透传 |
| `GET /search?q\|keywords=&limit=&offset=` | `search`, `{ query, limit, offset }` | 空 query `{ code: 200, items: [], total: 0 }`（**没有 `hasMore` / `nextOffset`**，与汽水不同）；limit clamp 1..100 默认 20，offset ≥ 0 默认 0；失败 502；成功 `{ code: 200, items: r.data.resultList \|\| [], total: r.data.total \|\| 0, hasMore: !!(r.data.bodianPagination && r.data.bodianPagination.hasMore), nextOffset: (r.data.bodianPagination && r.data.bodianPagination.nextOffset) \|\| 0 }` | 空词 `{ code: 200, source: 'bodian', tracks: [], songCount: 0 }`；limit clamp 1..50 默认 20；`d.code !== 200` 回 `{ code, source: 'bodian', tracks: [], error }`；成功 `{ code: 200, source: 'bodian', tracks: items.map(bodianTrack).filter(id && name), songCount: Number(d.total) \|\| items.length }` |
| `GET /song/detail?id=` | `song_detail`, `{ id }` | 缺 id → 400；失败 502；成功 `{ code: 200, track: r.data }` | 主服务未接此路由（⚠️ 边车有，主服务无） |
| `GET /audio?id=&quality=&freeSign=` | `audio`, `{ id, quality, freeSign: q.freeSign === '1' }` | quality 白名单同汽水（`standard` / `high` / `lossless` / `hires`，其余 `standard`）；缺 id → 400；失败回 **HTTP 200** `{ code: 200, url: '', reason: r.error.code, region: <failBody 的 region>, error: <failBody 的 error> }`；成功 `{ code: 200, url: r.data.url, quality: r.data.quality, preview: !!r.data.preview, previewRange: r.data.preview \|\| null }`（注释：波点的试听是一段**秒数区间** `{ startTime, endTime }`，不是起点毫秒——`preview` 字段本身就是区间对象，成功时原样回 `previewRange`） | 主服务 `song/url`：回 `{ code: 200, id, url, preview: !!d.preview, previewRange: d.previewRange \|\| null, quality: d.quality \|\| quality, reason: url ? (preview ? 'preview' : null) : (d.region ? 'region' : (d.reason \|\| 'unavailable')), error: url ? null : (d.error \|\| null) }`；缺 id → 400 |
| `GET /lyrics?id=` | `lyrics`, `{ id }` | 缺 id → 400；失败回 HTTP 200 `{ code: 200, lyric: '', error: r.error.message }`；成功 `{ code: 200, lyric: r.data.mainText \|\| '', wbw: r.data.wordByWordText \|\| '' }` | 主服务 `lyric`：`lyric = d.lyric \|\| ''`，`yrc = awlrcToYrc(d.wbw \|\| '')`（AWLRC 转 YRC，见 0.5）；回 `{ code: 200, lyric, yrc, tlyric: '', format: yrc ? 'yrc' : (lyric ? 'lrc' : 'none') }`；缺 id → 400 |
| `GET /playlist/tracks?id=&limit=&offset=&source=` | `playlist_tracks`, `{ id, limit, offset, source? }` | 缺 id → 400；limit clamp 1..100 默认 50；`source` 仅当 `Number(q.source)` 在 `[1,2,3,4,5,6]` 内才传（注释：歌单的 sourceType——自建/收藏一般是 4，红心歌单是 5；不传时库默认 4）；失败 502；成功时**空歌单上游只回分页对象（没有 songs/list 数组），这里统一成 `[]`**，否则主服务 `(d.items \|\| []).map` 会拿到对象直接抛异常：`items = Array.isArray(raw.songs) ? raw.songs : Array.isArray(raw.list) ? raw.list : Array.isArray(raw) ? raw : []`；回 `{ code: 200, items, more: !!(raw.bodianPagination && raw.bodianPagination.hasMore) }` | 主服务：`source` 同样只在 1..6 内透传；`d.code !== 200` 回 `{ code, source: 'bodian', tracks: [], error }`；成功 `{ code: 200, source: 'bodian', tracks: items.map(bodianTrack).filter(id && name), more: !!(d.more \|\| d.hasMore) }` |
| `GET /recommendations` | `recommendations` | 失败回 `failBody` 的 HTTP code；成功时 `lists = r.data.lists \|\| []`，`playlists` 为各组 `playLists`（或 `list`）摊平；回 `{ code: 200, lists, playlists }` | 主服务：失败 `{ code, source: 'bodian', playlists: [], error: d.error \|\| '波点推荐歌单失败' }`；成功 `{ code: 200, source: 'bodian', playlists: (d.playlists \|\| []).map(bodianPlaylist).filter(id) }` |
| `GET /home/module?moduleId=` | `home_module`, `{ moduleId: Number(q.moduleId) \|\| 1 }` | 失败回 `failBody` 的 HTTP code；成功 `{ code: 200, module: r.data }` | ⚠️ 主服务未接此路由 |
| `GET /ai/playlist?index=` | `ai_playlist_detail`, `{ index: Number(q.index) \|\| 0 }` | 失败回 `failBody` 的 HTTP code；成功 `{ code: 200, title: r.data.title \|\| '潮趣日推', subTitle: r.data.subTitle \|\| '', tracks: r.data.musicList \|\| [] }` | 主服务 `ai/playlist`：`index = max(0, Number(q.index) \|\| 0)`；失败 `{ code, source: 'bodian', tracks: [], error: d.error \|\| '波点日推失败' }`；成功 `{ code: 200, source: 'bodian', title: d.title \|\| '潮趣日推', subTitle: d.subTitle \|\| '', tracks: (d.tracks \|\| []).map(bodianTrack).filter(id && name) }` |
| `GET /personal/fm` | `personal_fm` | 失败回 `failBody` 的 HTTP code；成功 `{ code: 200, tracks: r.data.musicList \|\| [] }` | 主服务：失败 `{ code, source: 'bodian', tracks: [], error: d.error \|\| '波点私人 FM 失败' }`；成功 tracks 取 `bodianTrack` |
| `GET /user/playlists?limit=&offset=` | `user_playlists`, `{ limit, offset }` | limit clamp 1..100 默认 50；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, owned: r.data.owned \|\| null, liked: r.data.liked \|\| null, collected: r.data.collected \|\| null }`（三块原样透传；库的 `user_playlists` 只对 collected 走 catalog 分页，limit 1..100、offset 从 0 起） | 主服务：固定 `limit=100`，按 `collected.bodianPagination.nextOffset` 翻到底，最多 20 页；第 0 页只取 owned/liked（`liked` 有 id 时再加一次 `[liked]` 本身）；失败时第 0 页 401 回 `'先在卡片上扫码登录波点音乐'`；停法：`hasMore=false`、nextOffset 缺失或不前进、到页数上限；成功 `{ code: 200, source: 'bodian', playlists }`（三块按 `bodianPlaylistRows` 找数组：`playLists` / `list` / `info` / `data` / `result` / `rows`，或 `data` 下的同名字段） |
| `GET /liked_songs` 或 `/liked-songs` | `liked_songs` | 失败回 `failBody` 的 HTTP code；成功时 `items = r.data.list \|\| r.data.resultList \|\| r.data.items \|\| []`；回 `{ code: 200, items, total: r.data.total \|\| items.length, more: !!(r.data.bodianPagination && r.data.bodianPagination.hasMore) }` | 主服务：失败时 401 回 `'先在卡片上扫码登录波点音乐'`；成功 `{ code: 200, source: 'bodian', tracks: (d.items \|\| []).map(bodianTrack).filter(id && name) }` |
| `GET /playlist/detail?id=` | `playlist_detail`, `{ id }` | 缺 id → 400；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, playlist: r.data }` | 主服务：失败 `{ code, source: 'bodian', playlist: null, error }`；成功 `{ code: 200, source: 'bodian', playlist: bodianPlaylist(d.playlist \|\| {}) }` |
| `GET /user/albums` | `user_albums`（无参数） | 失败回 `failBody` 的 HTTP code；成功 `{ code: 200, data: r.data }`（原样透传；`data` 内为 `{ albumList, bodianPagination }`） | 主服务：失败时 401 回 `'先在卡片上扫码登录波点音乐'`；成功 `{ code: 200, source: 'bodian', data: albumList.map(bodianUserAlbum).filter(id), hasMore: false }`——注释：边车的 `/user/albums` 目前不把 offset/limit 转给库，永远只给第一页（默认 50 张），所以 `hasMore` 固定 false，否则前端会按 nextOffset 反复拿同一页，把列表叠成一堆重复项 |
| `GET /artist/songs?id=&limit=&offset=` | `artist_songs`, `{ id, limit, offset }` | 缺 id → 400；limit clamp 1..100 默认 50；失败回 `failBody` 的 HTTP code；成功 `{ code: 200, items: r.data.resultList \|\| r.data.list \|\| [], total: r.data.total \|\| 0 }` | 主服务固定调 `limit=50`；成功 tracks 取 `bodianTrack` |
| 未知路径 | — | HTTP 404 `{ code: 404, error: 'unknown bodian api: <p>' }` | 主服务未知路径 `{ code: 404, error: 'unknown bodian api: <part>' }`；任意异常 502 + `log` |

### 5.5 播放与特殊行为、pay/fee

- 未登录**只有 30 秒试听**：`/audio` 匿名回 `preview: { startTime: 0, endTime: 29 }`（README 实测），直链落在 `*.kuwo.cn` CDN；**URL 本身就是片段（不是整首 + 偏移）**，LIZI 打「试听片段」角标。主服务 `song/url` 的 `previewRange` 即该区间对象。
- **播放只放行中国大陆网络**：上游业务码 `407` → 库错误 `'region-restricted'` → 边车 `failBody` 的 `region: true`、HTTP 451 → 主服务 `song/url` 的 `reason: 'region'`，界面写「波点音乐 · 仅中国大陆网络」，**不自动跳歌**。
- `bodianTrack(it)`：PascalCase + 小写混着来，artist 直接给了字符串：`{ id: String(it.id \|\| it.musicRid \|\| ''), source: 'bodian', name: it.name \|\| it.songName \|\| it.FSONGNAME \|\| '', artists: it.artist \|\| artists[].name.join(' / ') \|\| '未知歌手', artistIds: [it.artistId].filter(Boolean).map(String), album: it.album \|\| '', albumId: String(it.albumId), cover: it.albumPic \|\| it.albumPic120 \|\| '', duration: (Number(it.duration) \|\| 0) * 1000（duration 是秒）, fee: it.payInfo && Number(it.payInfo.payType) > 0 ? 1 : 0 }`。
- `bodianPlaylist(it)`：推荐流给 `pic` / `musicCount` / `creatorName`，收藏页给别的名字，这里一起兜住：`{ id: String(it.id \|\| it.playlistId \|\| it.fid \|\| ''), source: 'bodian', name: it.name \|\| it.title \|\| it.playlistName \|\| '未命名歌单', cover: it.pic \|\| it.cover \|\| it.img \|\| it.coverUrl \|\| '', trackCount: Number(it.musicCount ?? it.songCount ?? it.total ?? it.count ?? it.songNum) \|\| 0, playCount: Number(it.playNum ?? it.play_count ?? it.playCount) \|\| 0, creator: { nickname: it.creatorName \|\| it.nickname \|\| it.userName \|\| '' }, sourceType: Number(it.sourceType) \|\| 0 }`（取曲目时上游要 source：红心歌单是 5，自建/收藏一般是 4）。
- `bodianUserAlbum(it)`：收藏歌单和收藏专辑在波点共用 `/service/collect/4/list`（靠 `sourceType=6` 分流），字段名和 `bodianPlaylist` 同一套；再补专辑可能用的 `albumName` / `singer` 写法：`{ id: String(it.id \|\| it.albumId \|\| it.albumIdStr \|\| it.rid \|\| it.musicRid \|\| ''), name: it.name \|\| it.title \|\| it.albumName \|\| it.album_name \|\| '未知专辑', artists: [{ name: <artist \|\| artistName \|\| singer \|\| singerName \|\| creatorName \|\| nickname \|\| '未知歌手'> }], cover: it.pic \|\| it.cover \|\| it.img \|\| it.coverUrl \|\| it.albumPic \|\| it.albumPic120 \|\| '', publishTime: Number(it.publishTime ?? it.pubTime ?? it.pubtime ?? it.releaseTime ?? 0) \|\| 0, trackCount: Number(it.musicCount ?? it.songCount ?? it.total ?? it.count ?? it.songNum ?? 0) \|\| 0 }`。
- 歌词：库给 `mainText`（行级 LRC，实测 1463 字）与逐字 `wordByWordText`（AWLRC：`[mm:ss.xxx]<相对行首ms,字时长ms>字…`）；边车把波点的编码对解成毫秒；主服务用 `awlrcToYrc` 转 YRC（见 0.5），转不出就还是整行 LRC。
- 封面在 `img*.kuwo.cn`（已加进 `/api/img` 后缀白名单 `*.kuwo.cn`）。
- 音频代理：`/api/bodian/audio?url=`，白名单 `*.kuwo.cn` / `*.bodian.com`，Referer `https://www.bodian.com/`。

### 5.6 明确返回空态 / 错误的路由

- `/audio` 失败：HTTP 200 `{ code: 200, url: '', reason: <库错误码>, region: <bool>, error }`；地区限制时 `reason` 在主服务层被转成 `'region'`。
- `/lyrics` 失败：HTTP 200 `{ code: 200, lyric: '', error }`。
- `/login/qr/check` 库调用失败：HTTP 200 `{ code: 500, error }`。
- `/playlist/tracks` 空歌单：上游只回分页对象，边车统一成 `items: []`（不回对象，不报错）。
- `/search` 空 query：`{ code: 200, items: [], total: 0 }`。
- 账号类未登录：库回 `auth-required` → 401，主服务回 `'先在卡片上扫码登录波点音乐'`。
- `user/albums`：`hasMore` 固定 `false`（只给第一页，见 4.4 表）。

---

## 6. Spotify

### 6.1 边车本体

- 目录 `services/spotify-api/`；启动 `node services/spotify-api/start.mjs`（零依赖，Node ≥ 18 即可）。
- `package.json`：`"name": "lizi-spotify-api"`，`"type": "module"`，`scripts.start = "node start.mjs"`，**零依赖**（只用 Node 内置 `http` / `crypto` / `fetch`）。
- 端口：`SPOTIFY_API_PORT` → `.port` → **3214**；另占一个 OAuth 回调端口 `127.0.0.1:5588`（`SPOTIFY_CALLBACK_PORT` 环境变量可改，改了要同步改 Spotify 后台登记的 Redirect URI）。
- 定位（文件头注释，逐字要点）：**可行性骨架，本期不接音频**。Spotify 的 Web API 够用（搜索/歌单/歌手元数据），但音频必须 `node-librespot` 原生二进制（59.4MB）+ Premium 账号，而且那是解密 DRM 的灰区。所以这里只做 PKCE 登录（官方 OAuth，回调 `127.0.0.1:5588`）+ 元数据读取，`/audio` 永远回 `{ url: '', reason: 'drm' }`，界面据此如实标「本期不接音频」。
- 没有内置 client_id：Spotify 不给第三方预置凭证。用户/开发者自己注册一个免费 App，把 Client ID 填进 `SPOTIFY_CLIENT_ID` 环境变量或本目录 `.client.json`：`{ "clientId": "xxxx", "clientSecret": "yyyy" }`。有 secret 时**不需要用户登录**也能搜（`client_credentials`）；只有 clientId 时走 PKCE 用户授权。没配就明确回「缺 Client ID」，不假装能用。
- Redirect URI 必须在 Spotify 后台登记成：`http://127.0.0.1:5588/callback`。

### 6.2 server.mjs 拉起与通话

- `SIDECARS.spotify = { dir: 'spotify-api', env: 'SPOTIFY', port: 3214, node24: false, ping: '/health' }`；走通用 `ensureSidecar` / `scRequest`。
- `health` 先行：`scRequest('spotify', '/health', { timeout: 5000 })`，回 `{ code: 200, ok: !!h.data.ok, port, hasClientId: !!h.data.clientId, hasSecret: !!h.data.hasSecret, loggedIn: !!h.data.loggedIn, callback: h.data.callback || '', audio: false, audioReason: <NEED 原文>, error: h.data.ok ? null : '缺少 SPOTIFY_CLIENT_ID：Spotify 不预置第三方凭证，需自己注册免费 App' }`，其中 `NEED = '需要 Premium + node-librespot 原生二进制（59.4MB），且属解密 DRM 的灰区；本期不接音频'`；失败回 `{ code: 502, ok: false, error, reason, log: scLogTail('spotify') }`。

### 6.3 登录方式与登录态存放

- OAuth 2.0 PKCE（官方授权码流程）：
  - `GET /login/url` → `authorizeUrl()`：`verifier = base64url(crypto.randomBytes(48))`，`state = base64url(crypto.randomBytes(12))`，`pendingPkce = { verifier, state, at: Date.now() }`（内存，不落盘）；`challenge = base64url(SHA256(verifier))`；授权地址 `https://accounts.spotify.com/authorize?client_id=<id>&response_type=code&redirect_uri=<REDIRECT_URI>&code_challenge_method=S256&code_challenge=<challenge>&state=<state>&scope=<SCOPES 空格连接>`。回 `{ code: 200, url, callback: REDIRECT_URI }`；无 clientId 时 `{ code: 400, error: '缺少 SPOTIFY_CLIENT_ID' }`。
  - `SCOPES = ['user-read-private', 'user-read-email', 'playlist-read-private']`。
  - `REDIRECT_URI = 'http://127.0.0.1:5588/callback'`（`CALLBACK_PORT = Number(process.env.SPOTIFY_CALLBACK_PORT || 5588)`）。
  - 回调服务：边车内另起一个 `http.createServer` 只监听 `127.0.0.1:5588`，只处理 `GET /callback`（其余路径 404 纯文本 `'not found'`）。校验：`error` 参数 → 显示「Spotify 授权被拒绝」；无 `code`、无 `pendingPkce` 或 `state` 对不上 → 显示「回调不匹配」（「state 对不上或没有 code，请重新点登录。」）；通过则 `POST https://accounts.spotify.com/api/token`（表单：`grant_type=authorization_code`、`code`、`redirect_uri`、`client_id`、`code_verifier=<verifier>`），成功后 `saveToken({ accessToken, refreshToken: r.data.refresh_token || '', expiresAt: Date.now() + (r.data.expires_in || 3600) * 1000, scope: r.data.scope || '' })`，`pendingPkce = null`，显示「Spotify 已登录」（「可以回 LIZI 了（本期不接音频，只有元数据）。」）；换 token 失败显示「换 token 失败」。回调端口起不来时只记日志（`回调端口 <port> 起不来（<code>）—— PKCE 登录会不可用`），不退出进程。
  - token 存放：`services/spotify-api/.auth-token.json`（`0o600` 写盘；`saveToken(null)` 时删文件）。字段 `{ accessToken, refreshToken, expiresAt, scope }`。
  - 凭证存放：`services/spotify-api/.client.json`（`{ clientId, clientSecret }`）；`readClient()` 先读环境变量 `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET`，无 clientId 时再读文件。
- `accessToken()`（取可用 token 的顺序，逐字照抄）：
  1. 无 `clientId` → 抛 `'缺少 SPOTIFY_CLIENT_ID：Spotify 不预置第三方凭证，需要自己注册一个免费 App'`。
  2. 存量 token 且 `expiresAt > Date.now() + 30000` → 直接用。
  3. 有 `refreshToken` → `POST https://accounts.spotify.com/api/token`（表单 `grant_type=refresh_token`、`refresh_token`、`client_id`），200 且有 `access_token` 时更新落盘（`expiresAt = Date.now() + (expires_in || 3600) * 1000`）。
  4. 有 `clientSecret` → `POST https://accounts.spotify.com/api/token`（表单 `grant_type=client_credentials`，头 `Authorization: Basic base64(clientId:clientSecret)`）；200 且有 `access_token` 时**直接返回，不落盘**（「客户端凭证 token 不代表用户，重启再取即可」）；失败抛 `'client_credentials 取 token 失败（' + (error_description || error || status) + '）'`。
  5. 否则抛 `'未登录 Spotify：点「登录」走 PKCE 授权（需要 Client ID；有 Client Secret 时可直接匿名搜）'`。
  - `postForm(url, body, headers)`：`POST`，`Content-Type: application/x-www-form-urlencoded`，body 为 `URLSearchParams`，超时 15000；响应按 JSON 解析，失败时 `{ raw: text.slice(0, 300) }`。
- `/status`（边车内）：
  - 无 clientId → `{ code: 200, loggedIn: false, error: '缺少 SPOTIFY_CLIENT_ID' }`。
  - 无 token：有 secret 时用 `client_credentials` 探一下，成功回 `{ code: 200, loggedIn: false, mode: 'client-credentials', nickname: 'Spotify（客户端凭证）' }`，失败回 `{ code: 200, loggedIn: false, error }`；无 secret 直接 `{ code: 200, loggedIn: false }`。
  - 有 token：调 `GET /me`；200 且有 `id` 回 `{ code: 200, loggedIn: true, mode: 'pkce', nickname: display_name || id, avatar: images[0].url || '', product: product || '' }`；401 且有 secret 时回 `{ code: 200, loggedIn: false, mode: 'client-credentials', nickname: 'Spotify（客户端凭证）' }`；其他失败回 `{ code: 200, loggedIn: true, mode: 'pkce', nickname: 'Spotify', error: '读取 /me 失败' }`；异常回 `{ code: 200, loggedIn: !!token, error }`。
- `/logout`：`saveToken(null)`，回 `{ code: 200, loggedIn: false }`。

### 6.4 边车 HTTP 路由与上游接口

| 边车路由 | 上游接口（方法 / URL / 头 / 参数） | 边车返回 | 主服务 `/api/spotify/*` 的归一化 |
|---|---|---|---|
| `GET /health` 或 `GET /` | 本地 | `{ code: 200, ok: !!client.clientId, clientId: client.clientId ? client.clientId.slice(0, 6) + '…' : '', hasSecret: !!client.clientSecret, loggedIn: !!(token && token.accessToken), expiresAt: (token && token.expiresAt) \|\| 0, callback: REDIRECT_URI, audio: false, reason: '音频需要 node-librespot 原生二进制（59.4MB）+ Premium 账号，且属解密 DRM 的灰区；本期不接' }`（注释：「本期硬限制，前端直接拿来显示，别在前端再写一份」） | 见 5.2 |
| `GET /login/url` | 本地生成 PKCE 地址（见 5.3） | `{ code: 200, url, callback }` / 无 clientId `{ code: 400, error }` | 透传边车 body |
| `GET /status` 或 `GET /login/status` | `GET https://api.spotify.com/v1/me`（头 `Authorization: Bearer <token>`） | 见 5.3 | 透传边车 body |
| `GET /logout` | 本地清 token | `{ code: 200, loggedIn: false }` | 透传边车 body |
| `GET /search?q=&limit=` | `GET https://api.spotify.com/v1/search?q=<s>&type=track&limit=<limit>`（头 `Authorization: Bearer <token>`，超时 15000） | 空 `q` 回 `{ code: 200, items: [], total: 0 }`；limit clamp 上限 50 默认 20；非 200 回 `{ code: r.status, error: <r.data.error.message 或 'Spotify 搜索失败 <status>'>, items: [] }`；成功 `{ code: 200, items: (r.data.tracks.items \|\| []).filter(Boolean), total: r.data.tracks.total \|\| 0 }`；异常 `{ code: 400, error, items: [] }` | 空词 `{ code: 200, source: 'spotify', tracks: [], songCount: 0 }`；limit clamp 1..50 默认 20（超时 20000）；回 `{ code: d.code \|\| 502, source: 'spotify', tracks: (d.items \|\| []).map(spotifyTrack).filter(id && name), songCount: Number(d.total) \|\| items.length, error: d.error \|\| null, note: '仅元数据 · 本期不接音频' }`（注释：每次搜索都提醒一次，这些结果点了不会有声音） |
| `GET /audio` | 无上游，明确不做 | `{ code: 200, url: '', reason: 'drm', error: '本期不接 Spotify 音频（需 Premium + node-librespot，且属 DRM 灰区）' }` | 主服务 `song/url` 直接回 `{ code: 200, id: q.id \|\| '', url: '', preview: false, reason: 'drm', error: <NEED 原文> }`（不调边车） |
| `GET /lyrics` | 无上游 | `{ code: 200, lyric: '', reason: 'no-lyrics-api' }` | 主服务 `lyric` 直接回 `{ code: 200, lyric: '', format: 'none', reason: 'no-lyrics-api' }`（不调边车） |
| 未知路径 | — | HTTP 404 `{ code: 404, error: 'unknown spotify api: <p>' }` | 主服务未知路径 `{ code: 404, error: 'unknown spotify api: <part>' }`；任意异常 502 + `log` |

- `sp(pathname, params)`（边车内通用 Web API 调用）：`GET https://api.spotify.com/v1 + pathname`，query 逐项 `set`（`v != null` 才传），头 `Authorization: Bearer <token>`，超时 15000；返回 `{ status, data }`，data 解析失败时 `{ raw: text.slice(0, 300) }`。
- ⚠️ 边车只实现了 `/search`（`type=track`）一个数据路由。README/文件头提到的「歌单/歌手元数据」在 `start.mjs` 里**没有对应路由**——不要按 README 的笼统说法编造 `/playlist`、`/artist` 路由。

### 6.5 特殊行为与 pay/fee

- 只有元数据，没有音频：`/audio` 永远 `{ url: '', reason: 'drm' }`，不是没实现，是不做；`spotifyTrack` 的 `preview_url` 大部分是空的，别指望靠它出声（server.mjs 注释）；主服务 `search` 每次都带 `note: '仅元数据 · 本期不接音频'`。
- 歌词：Spotify 官方 Web API 不提供歌词；Musixmatch 之类没有授权，不做假的。`/lyrics` 永远空 + `reason: 'no-lyrics-api'`；主服务 `lyric` 永远 `{ lyric: '', format: 'none', reason: 'no-lyrics-api' }`。
- `spotifyTrack(it)`：`{ id: String(it.id), source: 'spotify', name: it.name || '', artists: (it.artists || []).map(a => a.name).join(' / ') || '未知歌手', artistIds: artists[].id, album: album.name || '', albumId: String(album.id), cover: album.images[0].url || '', duration: Number(it.duration_ms) || 0, fee: 1, externalUrl: it.external_urls.spotify || '' }`。`fee: 1` 是打「仅元数据」小签用（server.mjs 注释），不是付费标记。
- 音频代理：`AUDIO_HOSTS.spotify = []`，`/api/spotify/audio` 一律 403 `{ error: 'no audio for source spotify' }`。
- 配置矩阵（README 表格逐字）：
  | 配了什么 | 能干什么 |
  |---|---|
  | 什么都没有 | `/health` 回 `ok:false`，`/search` 明确报「缺少 SPOTIFY_CLIENT_ID」 |
  | 只有 clientId | 点「去授权」走官方 OAuth PKCE（浏览器，回调 `127.0.0.1:5588`），登录后能搜 |
  | clientId + clientSecret | 不需要用户登录，用 `client_credentials` 直接搜公开元数据（token 不落盘） |

### 6.6 明确返回空态 / 错误的路由

- `/audio`：`{ code: 200, url: '', reason: 'drm', error: '本期不接 Spotify 音频（需 Premium + node-librespot，且属 DRM 灰区）' }`。
- `/lyrics`：`{ code: 200, lyric: '', reason: 'no-lyrics-api' }`。
- `/login/url` 无 clientId：`{ code: 400, error: '缺少 SPOTIFY_CLIENT_ID' }`。
- `/status` 无 clientId：`{ code: 200, loggedIn: false, error: '缺少 SPOTIFY_CLIENT_ID' }`。
- `/search` 未配置/未登录：`{ code: 400, error: '缺少 SPOTIFY_CLIENT_ID：Spotify 不预置第三方凭证，需要自己注册一个免费 App' }` 或 `'未登录 Spotify：点「登录」走 PKCE 授权（需要 Client ID；有 Client Secret 时可直接匿名搜）'`，`items: []`。

---

## 7. 横向对照（移植时一张表查完）

### 7.1 端口 / 启动 / 登录态文件

| 平台 | 端口 | 启动命令 | 登录方式 | 登录态文件（相对边车目录） | 设备文件 |
|---|---|---|---|---|---|
| qq | 3210 | `node services/qq-api/start.mjs` | 扫码（qqmusic/qq/wechat 三通道，MQTT/HTTP 轮询） | `.auth-session.json`（加密）+ `.auth-secret`（32 字节 hex 密钥） | README 提到 `.auth-state/qq-device.json`（设备身份，别删） |
| kuwo | 3216 | `node services/kuwo-api/start.mjs` | 粘贴 Cookie（无扫码） | `.auth-cookies.json`（`userid` + `sid`/`websid` 必备） | 无（匿名 `Hm_Iuvt_*` token 内存持有，5 分钟过期） |
| qishui | 3212 | `node services/qishui-api/start.mjs`（Node ≥ 24） | 扫码（抖音，`open.douyin.com`） | `.auth-session.json`（`ticket` / `guardKey` / `guardCert` / `guardTsSign` / `accessCode`） | `.auth-device.json`（19 位数字 deviceId） |
| bodian | 3213 | `node services/bodian-api/start.mjs`（Node ≥ 24） | 扫码（与汽水同族协议） | `.auth-session.json`（`token` / `uid`） | `.auth-device.json`（32 位 hex deviceId） |
| kugou | —（无 Node 边车；Swift 内嵌 `FoliaKugouService`） | — | 扫码（`login-user.kugou.com`，见 §2.3） | `SessionStore` `.auth-kugou.json`（token / userid / vip_type / vip_token / dfid） | `.auth-kugou-device.json`（guid 32 位 hex；删了等于换设备） |
| spotify | 3214 + 回调 5588 | `node services/spotify-api/start.mjs` | OAuth PKCE（浏览器授权）或 `client_credentials`（有 secret 时免登录） | `.auth-token.json`（`accessToken` / `refreshToken` / `expiresAt` / `scope`） | `.client.json`（自备 `clientId` / `clientSecret`） |

### 7.2 song/url 返回形状对照

| 平台 | 请求键 | 成功 | 试听（preview） | 拿不到 |
|---|---|---|---|---|
| qq | `mid`，`quality` 原样透传 | `{ url, preview: false, reason: null }`（登录后字符串直链；匿名是 `{songmid: {url…}}` 表） | `preview=1` 再取一次，`quality` 改写为 `'preview'` | `url: ''`，`reason: 'login'`（有过 401）或 `'unavailable'` |
| kuwo | `id`，`quality ∈ {128,320,flac}` 默认 320（映射 `128kmp3` / `320kmp3` / `2000kflac`） | `{ url, quality: <派生值，如 '2000'>, format: 'mp3'\|'flac', source: 'mobi'\|'web' }` | 无 preview 概念（mobi 给完整时长；`preview: false` 固定） | `{ url: '', reason: 'unavailable', error }` |
| qishui | `id`，`quality ∈ {standard,high,lossless,hires}` 默认 standard | `{ url, quality: <实际档位>, preview: false, clipStartMs: 0, expiresAt }` | 未登录只有 30 秒试听，`preview: true` + `clipStartMs`（毫秒，片段在原曲的起点） | HTTP 200 `{ url: '', reason: <库错误码>, error }` |
| bodian | `id`，`quality` 同汽水，另 `freeSign=1` 可选 | `{ url, quality, preview: false, previewRange: null }` | 未登录 30 秒试听，`preview: { startTime: 0, endTime: 29 }`（秒区间），`previewRange` 原样回该对象 | HTTP 200 `{ url: '', reason, region: <bool>, error }`；地区限制时主服务 `reason: 'region'` |
| kugou | `hash`（大写；`id` 即 hash）+ `albumId` + `albumAudioId`，`quality ∈ {standard,high,ultra,lossless,hires}` | `{ url, quality: <实际档位>, preview: false }`（每档先带 album 再 hash-only；云盘 variant 只走 `user_cloud_url`） | 无 preview 概念 | `{ url: '', reason: 'login' }`（20028/401 过）或 `'unavailable'`；匿名 playInfo 拿不到链 |
| spotify | `id` | 无 | 无 | `{ url: '', reason: 'drm', error: '本期不接 Spotify 音频…' }` |

### 7.3 扫码状态码对照（统一映射到 801/802/803/800）

| 平台 | 等待 | 待确认 | 成功 | 过期 | 其他 |
|---|---|---|---|---|---|
| qq | 801 | 802 | 803（Set-Cookie 透传给浏览器，`qqmusic_session`） | 800 | key 拿不到时带 `retryAfterMs`（15 秒冷却） |
| kuwo | — | — | — | — | 无扫码；`/login/qr/*` 一律 `code: 501` |
| qishui | 801（`waiting`） | 802（`scanned`） | 803（`confirmed`） | 800（`expired`） | `error` → 800 + `error: '扫码被拒绝，或授权码已失效'`；库失败 → HTTP 200 `{ code: 500, error }` |
| bodian | 801（`waiting`） | 802（`scanned`） | 803（`confirmed`） | 800（`expired`） | 无 `error` 映射；库失败 → HTTP 200 `{ code: 500, error }`；另有边车专属 `/login/qr/cancel`（主服务未接） |
| kugou | 801（上游 status 1） | 802（上游 status 2,3） | 803（上游 status 4 或带 token；成功后调 `/api/kugou/status` 确认 `loggedIn`，确认失败回 804） | 800（上游 status 0） | 无取消接口（key 自然过期）；`login_qr_key` 官方 `qrcode_img` 记内存 Map 优先回 |
| spotify | — | — | — | — | 非扫码：PKCE 浏览器授权，`/login/url` 返回授权地址 |

### 7.4 fee 标记对照

| 平台 | fee=1 的条件 | 含义 |
|---|---|---|
| qq | `pay.pay_play` 为真 | 基本等于要会员/付费，只打小签，不代表一定放不了 |
| kuwo | 恒为 0 | 直链匿名就能拿到完整时长，不拿 pay 字段吓人 |
| qishui | 恒为 0 | 不打 pay 标记 |
| bodian | `payInfo.payType > 0` | 付费标记 |
| kugou | 恒为 0 | 不打 pay 标记 |
| spotify | 恒为 1 | 打「仅元数据」小签用，不是付费标记 |

---

## 8. 含糊 / 未在源码中明确的点（移植前须核对）

1. **QQ 包内的上游接口**：`@yakult-green-tea/qq-music-api@3.3.5` 的 `node_modules/` 未在仓库中，包内各模块实际打向腾讯的上游域名、路径、签名与加密细节本文无法列出。移植时须以这个包的已安装实现为准（QQ 包的会话模块路径为 `services/auth/fileAuthSessionRepository.js` 与 `services/auth/sessionState.js`）。不要凭记忆编造上游地址。
2. **汽水/波点协议库的上游接口**：`qishui-music-api@0.2.2` 与 `bodian-music-api@0.1.2` 的 guard 签名报文细节（具体上游域名/路径、签名算法、报文结构）同样在库内，不在仓库中。本文只记录了 `api.request(op, params)` 的 op 名与参数。移植时须按这两个库的实现重做签名，否则请求会被上游拒绝。
3. **QQ `.auth-state/qq-device.json`**：只在 `services/qq-api/README.md` 的目录树里出现一次（「设备身份（**别删**），删了 QQ 当新设备，容易撞 20279 上限」），`start.mjs` 与 `server.mjs` 里没有读写它的代码。移植时设备身份如何生成/使用须对照 QQ 包实现。
4. **QQ `sessionMode`**：`health` 回的 `sessionMode` 取自边车 `/login/channels` 的 `data.data.sessionMode`，其取值集合源码中未列出，原样透传即可。
5. **酷我 `webPlayUrl` 的 `from=` 参数**：URL 里 `from=` 为空值，原样保留（`…&plat=web_www&from=&br=128kmp3`）。
6. **酷我搜索 `TOTAL`**：边车回 `total: Number(j.TOTAL) || abslist.length`，字段名全大写 `TOTAL`，不要写成 `total`。
7. **波点 `/audio` 的 `freeSign` 参数**：边车接受 `freeSign=1` 并透传给库，但其语义（免费签名？）在仓库源码中没有解释，移植时只保留透传行为。
8. **波点 `/home/module`**：边车有，主服务未接；`moduleId` 的取值含义（默认 1）在源码中未说明。
9. **汽水 `/song/detail`** 与 **波点 `/song/detail`**：边车有，主服务未接；返回 `{ code: 200, track: r.data }` 原样透传，字段结构以库实现为准。
10. **QQ `/getSongInfo`、`/singer/*`**：包里有，主服务未接（README 原话）；同上。
11. **Spotify「歌单/歌手元数据」**：README 与文件头笼统提到 Web API 够用，但 `start.mjs` 只实现了 `/search`（`type=track`）一个数据路由；移植时不要据此编造歌单/歌手路由。
12. **酷我 Hm_Iuvt_ fallback 值**：`COOKIE_FALLBACK = 'Hm_Iuvt_cdb524f42f23cer9b268564v7y735ewrq2324'` 只用作 `tokenState` 的初始 `name`，实际请求前 `www()` 一定会先 `refreshToken()` 刷新（token 为空时），不要把这个 fallback 值当作可用 token 发出去。
13. **汽水 `expiresAt`**：`/audio` 成功回 `expiresAt: r.data.expiresAt || 0`，单位与语义（毫秒时间戳？）在源码中未说明，原样透传，不要换算。
14. **QQ 搜索 `more` 字段**：主服务回 `more: !!r.data.more`，其语义（是否还有下一页）在包内未展开；移植时原样透传布尔值。
15. **酷狗 `audio`（kmr）与 `login_qr_key` appid**：`audio.js` 库内 baseURL 是 http，Swift 暂用 https——同一 host 的 https 是否通 VM 未验证；`login_qr_key` 的 appid 取 1001（Folia 不传 type 时的默认），VM 探针用 web 签名+1014 拿到 qrcode_img，1001 是否也回 qrcode_img 待验证（create 在无官方图时用 CoreImage 现画兜底，两种 appid 都能工作）。
16. **酷狗歌词 download 的 client 参数**：库默认值是 'android'（VM 探针已验证通），Folia lyric provider 传 'mobi'（未验证）；Swift 取 'android'。
