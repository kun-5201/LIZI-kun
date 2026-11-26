# liziair 网易云后端 Swift 移植规格

> 来源：`/home/hatch/workspace/liziair-check/server.mjs`（4476 行，全文已读）、
> `services/netease-api/start.mjs`（274 行）、`services/netease-api/harvest-core.mjs`（212 行）、
> `wallpaper-api.mjs`（679 行，粗读）。
> 规则：数值、URL、常量、字段名一律从源码抄录；源码没有的写「源码未规定」，不脑补。
> 本文档只写规格，不含 Swift 代码，不改源码。
>
> 架构总览（移植时必须先理解的分工）：
> - 网易云分**两条并存的通道**：(a) `server.mjs` 手写的 weapi/eapi 直连 `music.163.com`（通用 `/api/*` 转发）；
>   (b) 边车 `services/netease-api/` 跑 npm 包 `@neteasecloudmusicapienhanced/api@4.41.1`（见 `services/netease-api/package.json`），
>   主服务经 `handleNetease` 以 `/api/netease/*` 代理它。扫码登录前端走的是 (b)，(a) 的扫码路因上游回 8821 已被弃用但仍可达。
> - 除网易云外，QQ/汽水/波点/Spotify/酷我各有边车，与本规格无关，只在分发顺序里出现。
> - 服务只绑 `127.0.0.1`（`server.listen(PORT, '127.0.0.1')`）；端口取 `process.env.PORT`，否则读 `.port` 文件（读后立即删除），否则 `0`（系统分配），拿到后写回 `.port`。

---

## 1. 路由表：`/api/<name>` → 网易云 weapi 路径

`server.mjs` 中 `ROUTES` 常量（`const ROUTES = {...}`）的完整抄录。`channel` 未注明者走 weapi；注明 `eapi` 者走 eapi。

| 本地名（`name`） | 上游路径（`path`，不含 `https://music.163.com/weapi` 前缀） | channel |
|---|---|---|
| `login/qr/key` | `/login/qrcode/unikey` | **eapi** |
| `login/qr/check` | `/login/qrcode/client/login` | **eapi** |
| `login/cellphone` | `/login/cellphone` | weapi |
| `login/status` | `/w/nuser/account/get` | weapi |
| `logout` | `/logout` | weapi |
| `user/playlist` | `/user/playlist` | weapi |
| `user/detail` | `/v1/user/detail/:uid` | weapi |
| `playlist/detail` | `/v6/playlist/detail` | weapi |
| `playlist/track/all` | `/v6/playlist/detail`（与上一条同一上游路径，区别只在响应归一化，见 §6） | weapi |
| `song/url` | `/song/enhance/player/url/v1` | weapi |
| `song/detail` | `/v3/song/detail` | weapi（但见 §6：此路由不走通用 `weapiRequest`，直接调 `fetchTrackDetails`） |
| `song/wiki` | `/song/play/about/block/page` | weapi |
| `lyric` | `/song/lyric/v1` | weapi |
| `search` | `/search/get` | weapi |
| `personalized` | `/personalized/newsong` | weapi |
| `recommend/songs` | `/v1/discovery/recommend/songs` | weapi |
| `top/playlist` | `/personalized/playlist` | weapi |
| `artist/:id` | `/v1/artist/:id` | weapi |
| `artist/albums/:id` | `/artist/albums/:id` | weapi |
| `artist/songs` | `/v1/artist/songs` | weapi |
| `album/:id` | `/v1/album/:id` | weapi |

补充说明（源码注释原意）：

- `top/playlist`：实探结论——`/top/playlist`、`/v3/top/playlist`、`/top/playlist/highquality` 均返回 404，
  `/v1/discovery/recommend/resource` 返回 301，**只有 `/personalized/playlist` 匿名可用**。
- `song/wiki`：带 BPM、语言、风格标签、获奖等元数据；匿名可用；网易云常规歌曲接口没有 BPM 字段，只有此接口有。
- `lyric` 用 `/song/lyric/v1` 而不用 `/song/lyric`：前者多给 `klyric/tlyric/romalrc`，登录后下发逐字歌词 `yrc`。
- `artist/:id`、`artist/albums/:id`、`album/:id` 的 `:id`、`:uid` 由 `matchRoute` + dispatch 占位符替换处理（见 §2、§6）。
- `ROUTES` 里**没有** `dj/recommend`、`dj/program`、`album/sublist`。前端 `public/api.js` 调的
  `netease/dj/recommend`、`netease/dj/program`、`netease/album/sublist`、`netease/recommend/songs`
  走的是 `/api/netease/*` 边车透传（见 §2、§6.17），其上游路径与参数由 npm 包 `@neteasecloudmusicapienhanced/api@4.41.1`
  内部决定，**本仓库源码里没有定义**；且本 checkout 下 `services/netease-api/node_modules/` 不存在，无法从本地核对。
  注意勿与 `ROUTES` 里的 `recommend/songs`（`/v1/discovery/recommend/songs`，走 `/api/recommend/songs`）混淆。

### 路由匹配规则（`matchRoute(name)`）

1. 先精确匹配 `ROUTES[name]`；
2. 找不到则按含 `:` 的 key 逐段匹配：段数必须相等，`:xxx` 段捕获为 `params`，其余段必须字面相等；
3. 匹配失败返回 `null`，通用转发回 `404 { error: 'unknown api: ' + name }`。

---

## 2. `createServer` 里的分发顺序

`http.createServer` 回调内按以下顺序逐个 `if` 判断，**先匹配者胜出并 `return`**。顺序如下（`url = new URL(req.url, 'http://' + req.headers.host)`）：

1. `url.pathname === '/api/img'` → `proxyImage`（图片代理，见 §7）。
2. `url.pathname === '/api/wallpaper'` 或以 `/api/wallpaper/` 开头 → `handleWallpaper`（见 §9）。
   注释明确写：必须排在 `/api/` 通用转发之前，否则会被当成 unknown api 直接 404。
3. `url.pathname === '/api/qq/audio'` → `proxyQQAudio`。
4. `url.pathname === '/api/qq'` 或以 `/api/qq/` 开头 → `handleQQ`。
5. `url.pathname === '/api/lx/song/url'` → `handleLxSongUrl`；
   `url.pathname === '/api/lx/health'` → 回 `{ code: 0, sources: ['wy','tx','kg','kw','mg'], tiers: TIERS, via }`；
   `url.pathname === '/api/lx/audio'` → `proxySourceAudio(..., 'lx')`。
6. 循环 `[['qishui', handleQishui], ['bodian', handleBodian], ['spotify', handleSpotify], ['kuwo', handleKuwo]]`：
   每组先判 `url.pathname === '/api/<name>/audio'` → `proxySourceAudio`，再判 `=== '/api/<name>'` 或以 `/api/<name>/` 开头 → 对应 handler。
   注意：音频代理必须单独一步，因为它要拿完整 URL 做白名单，不能进 handler 的路径分发。
7. `url.pathname === '/api/netease/audio'` → `proxySourceAudio(..., 'netease')`。
   必须排在下面 `handleNetease` 的兜底转发之前，否则会被当成边车路径。
8. `url.pathname === '/api/netease'` 或以 `/api/netease/` 开头 → `handleNetease`（边车代理，见 §6.17）。
9. `url.pathname === '/api/login/harvest' && req.method === 'POST'` → `handleLoginHarvest`。
10. `url.pathname === '/api/session/import' && req.method === 'POST'` → `handleSessionImport`。
11. `url.pathname === '/api/session'`（不限 method）→ 会话状态（见 §5）。
12. `url.pathname === '/api/login/qr/last'` → 扫码诊断（见 §6）。
13. `url.pathname.startsWith('/api/')` → 通用网易云 weapi/eapi 转发（`ROUTES` + `matchRoute` + 参数整形 + `normalize`，见 §1、§6）。
14. `url.pathname.startsWith('/creative/')` → 创意站点只读文件服务（注入 `data-chrome="off"` 与桥接脚本；与网易云无关）。
15. 其余 → `public/` 静态文件（`/` → `/index.html`，目录尾斜杠补 `index.html`，`..` 越界回 403，缺文件回 404 纯文本 `404`）。

要点：

- `/api/netease/*`（含 `login/qr/key`、`login/qr/check` 的边车版）优先于通用 `/api/*`；
  但通用转发里也存在同名的 `login/qr/key`、`login/qr/check`（eapi 版），两者路径不同（`/api/login/qr/*` vs `/api/netease/login/qr/*`），前端用的是边车版。
- `/api/logout` 不在任何前置分支，走通用转发 → `ROUTES['logout']` → weapi `/logout`，无参数整形、无 `normalize` case（原样返回上游 JSON）。
- `/api/session`、`/api/login/qr/last` 不限 method；`harvest` 与 `session/import` 限定 POST（GET 会落到通用转发 → `unknown api` 404）。

---

## 3. weapi 加密（完整细节）

位置：`server.mjs` 顶部，`weapi 加密（复刻 NeteaseCloudMusicApi 的两段式：AES-CBC → RSA）` 一节。

### 3.1 常量（逐字抄录）

```js
const PRESET_KEY = '0CoJUm6Qyw8W8jud';            // 16 字符
const IV         = '0102030405060708';            // 16 字符，用作 AES-CBC 的 IV（ASCII 字符串本身，非 hex 解码）
const PUB_KEY    = '010001';                      // RSA 公钥指数，hex，即 65537
const MODULUS    = '00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';
const BASE62     = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
```

### 3.2 AES 加密（`aesEncrypt(text, key)`）

- 算法：`aes-128-cbc`，key 为 16 字符 ASCII 字符串，IV 为 `IV` 常量字符串 `'0102030405060708'`。
- 输入 `text` 为 UTF-8，输出 base64 字符串：`Buffer.concat([c.update(text,'utf8'), c.final()]).toString('base64')`。
- Node 的 `crypto.createCipheriv('aes-128-cbc', key, IV)`：key/IV 以字符串传入时按 UTF-8 编码（各 16 字节）。

### 3.3 随机密钥（`randomKey()`）

- 从 `BASE62` 中随机取 16 个字符拼接：`Array.from({length:16}, () => BASE62[Math.floor(Math.random()*62)]).join('')`。

### 3.4 RSA 加密（`rsaEncrypt(text)`）

步骤（逐字对应源码）：

1. 把 `text`（即随机密钥）按字符**倒序**，再以 UTF-8 转 hex：`Buffer.from(text.split('').reverse().join(''), 'utf8').toString('hex')`。
2. 模幂：`modPow(BigInt('0x'+reversed), BigInt('0x'+PUB_KEY), BigInt('0x'+MODULUS))`。
   `modPow` 为手写平方-乘（square-and-multiply）：`result=1n; base%=mod; while(exp>0n){ if(exp&1n) result=(result*base)%mod; base=(base*base)%mod; exp>>=1n; }`。
3. 结果转 16 进制字符串，左补 `0` 到 **256 位**：`.toString(16).padStart(256,'0')`。

### 3.5 双层 AES 流程（`weapi(object)`）

```js
function weapi(object) {
  const text = JSON.stringify(object);
  const key = randomKey();
  return {
    params: aesEncrypt(aesEncrypt(text, PRESET_KEY), key),  // 先 PRESET_KEY 加密，再用随机 key 加密
    encSecKey: rsaEncrypt(key),                             // 随机 key 经 RSA 加密
  };
}
```

即：`params = AES-CBC(key, AES-CBC(PRESET_KEY, JSON))`（base64），`encSecKey = RSA(key)`（256 位 hex）。

### 3.6 请求发送（`weapiRequest(apiPath, payload = {})`）

- 先算 `data = weapi({ ...payload, csrf_token: cookies.__csrf || '' })`；
- 请求体：`new URLSearchParams({ ...data, csrf_token: cookies.__csrf || '' }).toString()`，
  即最终字段为 **`params`、`encSecKey`、`csrf_token`** 三个（`csrf_token` 既在加密明文内，也在体外明文里出现一次）。
- URL：`'https://music.163.com/weapi' + apiPath`（`apiPath` 为 `ROUTES` 里的 `/...` 形式）。
- 方法 POST，请求头（逐字抄录）：
  - `Content-Type: application/x-www-form-urlencoded`
  - `Referer: https://music.163.com`
  - `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36`
    （注意：与 §3.7 的 `NETEASE_UA` 不同；weapi 直连用这个 Chrome/120 UA）
  - `Cookie: cookieHeader()`（见 §5）
  - `X-Real-IP: 118.88.88.88`
  - `X-Forwarded-For: 118.88.88.88`
- 响应：先 `saveCookies(res.headers.getSetCookie?.() || [])`，再 `res.text()`；能 `JSON.parse` 则返回解析结果，
  否则返回 `{ code: 500, raw: text.slice(0, 500) }`。
- 传输层（`fetchUpstream(url, init = {}, tries = 3)`）：`fetch(url, { ...init, signal: AbortSignal.timeout(15000) })`，
  失败重试最多 3 次，间隔 `400*(i+1)` ms（即第 1 次重试前 400ms，第 2 次前 800ms），3 次都失败则抛出最后一次异常。

### 3.7 其它相关常量

- `NETEASE_UA = 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.17.204416'`
  （PC 版客户端 UA；用于边车请求与扫码参数 `ua`，**不**用于 `weapiRequest` 的请求头）。
- `gmt8Timestamp()`：把本地时间换算成东八区 `YYYY-MM-DD HH:mm:ss`（`new Date(d.getTime() + (480 + d.getTimezoneOffset())*60000).toISOString().replace('T',' ').slice(0,19)`）。
  源码中定义后**没有任何调用处**（全文仅定义行出现一次）——移植时可不实现，或实现后不用。

---

## 4. eapi 加密（完整细节）

位置：`server.mjs` 的 `eapi 加密（只给登录扫码两条路用）` 一节。用途：weapi 版扫码被上游回 8821
「请切换其他登录方式或升级新版本再试」，eapi 是 App/PC 客户端通道，对称加密，上游据此把请求方当 PC 客户端 8.9.70。

### 4.1 常量

```js
const EAPI_KEY = Buffer.from('e82ckenh8dichen8');   // 16 字节，AES-128-ECB 固定对称密钥
const EAPI_SEP = '-36cd479b6b5-';                   // 明文分隔符，两段都用同一个
const EAPI_DEVICE_ID = crypto.randomBytes(16).toString('hex').toUpperCase();  // 进程启动时生成一次，32 位大写 hex，不落盘
```

### 4.2 header（`eapiHeader()`，每次调用重新生成）

返回对象（字段顺序与值逐字抄录）：

```js
{
  osver: 'Microsoft-Windows-10-Professional-build-19045-64bit',
  deviceId: EAPI_DEVICE_ID,                       // 见 4.1，进程内固定、重启即变
  appver: '8.9.70',
  versioncode: '140',
  mobilename: '',
  buildver: String(Date.now()).slice(0, 10),     // 当前时间戳的秒级前 10 位（每次调用都变）
  resolution: '1920x1080',
  __csrf: cookies.__csrf || '',
  os: 'pc',
  channel: 'netease',
  requestId: `${Date.now()}_${String(Math.floor(Math.random() * 1000)).padStart(4, '0')}`,
  // requestId 格式：<毫秒时间戳>_<0~999 左补 0 到 4 位>，例如 1763..._0042
}
```

源码注释：上游判断客户端主要看这个 header，`os=pc + appver=8.9.70` 是关键。

### 4.3 加密流程（`eapi(apiPath, object)`）

设 `apiPath` 为 `/api/...` 形式（见 4.4 的约定），步骤：

1. `text = JSON.stringify({ ...object, header: eapiHeader() })`（header 合并进明文 JSON 的顶层）。
2. `digest = md5('nobody' + apiPath + 'use' + text + 'md5forencrypt')` 的 hex 小写摘要
   （`crypto.createHash('md5').update(`nobody${apiPath}use${text}md5forencrypt`, 'utf8').digest('hex')`）。
3. 明文串：`` `${apiPath}${EAPI_SEP}${text}${EAPI_SEP}${digest}` ``，即
   `<apiPath>-36cd479b6b5-<json>-36cd479b6b5-<md5>`。
4. AES-128-ECB 加密：`crypto.createCipheriv('aes-128-ecb', EAPI_KEY, null)`（IV 为 `null`），
   输出转 hex 再转大写：`.toString('hex').toUpperCase()`。
5. 返回 `{ params: <大写 hex> }`（只有 `params` 一个字段，无 `encSecKey`）。

### 4.4 请求发送（`eapiRequest(apiPath, payload = {})`）

- `signedPath = apiPath.startsWith('/api') ? apiPath : '/api' + apiPath`；
  注意：`ROUTES` 里扫码两条的 `path` 是 `/login/qrcode/unikey`、`/login/qrcode/client/login`（不带 `/api` 前缀），
  所以签名用 `/api/login/qrcode/unikey`、`/api/login/qrcode/client/login`。
- 请求体：`new URLSearchParams(eapi(signedPath, payload)).toString()`，即只有 `params=<大写 hex>`。
- 实际请求 URL：`'https://music.163.com/eapi' + apiPath`（即 `https://music.163.com/eapi/login/qrcode/unikey` 等；
  **加密/签名里的路径是 `/api/...` 形式，实际打到 `/eapi/...`，这是 eapi 的约定**）。
- 方法 POST，请求头：
  - `Content-Type: application/x-www-form-urlencoded`
  - `Referer: https://music.163.com`
  - `Origin: https://music.163.com`
  - `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36`
    （与 weapiRequest 相同；不是 `NETEASE_UA`）
  - `Cookie: cookieHeader()`
  - **故意不带** `X-Real-IP` / `X-Forwarded-For`（源码注释：扫码 key 在本机建、确认在用户手机上，
    伪造外地 IP 会让建 key 的 IP 与确认的 IP 对不上，触发风控 8821；实测去掉后 unikey/check 仍稳定 801）。
- 响应处理与 weapiRequest 相同：先 `saveCookies`，再解析 JSON，解析失败回 `{ code: 500, raw: text.slice(0, 500) }`。
- 分发选择：通用转发里 `const send = route.channel === 'eapi' ? eapiRequest : weapiRequest`。
  只有 `ROUTES` 中 `login/qr/key`、`login/qr/check` 两条走 eapi，其余走 weapi。

---

## 5. 登录态

### 5.1 存储：`.session.json`

- 文件位置：`path.join(__dirname, '.session.json')`（与 `server.mjs` 同目录）。
- 启动时读取：文件存在则 `JSON.parse`，失败则 `cookies = {}`。
- 写入：`saveCookies` 每次收到上游 `Set-Cookie` 后写盘（`JSON.stringify(cookies, null, 2)`）；
  `sessionApply`（登录收尾/粘贴导入）整份替换后写盘；`sessionRestore`（校验失败回滚）按快照恢复（快照含原始文件文本；原先无文件则删除文件）。
- 内容：一个扁平的 `{ cookie名: cookie值 }` 对象。**本 checkout 下实测文件内容只有 `{"NMTID": "00OVSweuAnkulkES0PSjozmm29ROKwAAAGh5dlR4A"}` 一个键**（值为示例，移植文档不复述真实值以外的信息）——即当前处于未登录态。
- 源码各处明确提到/使用的 cookie 键：`MUSIC_U`（登录凭证，核心）、`__csrf`（随请求发送，见 §3.6、§4.2）、`NMTID`（匿名游客标识）。
  其余键名源码未枚举：`saveCookies` 会原样保存上游下发的任何键；`sessionApply` 会原样保存粘贴/收下来的任何键。

### 5.2 `MUSIC_U` 的作用

- 唯一被代码当作「已登录」判据的键：`/api/session` 先判 `if (!cookies.MUSIC_U) return { loggedIn: false }`；
  `recordQrCheck` 与 `/api/login/qr/last` 的 `hasMusicU`/`loggedIn` 均为 `!!cookies.MUSIC_U`；
  通用转发 `normalize('login/qr/check')` 的 `loggedIn` 也是 `!!cookies.MUSIC_U`。
- 注释原文：「803 只代表『手机上授权了』。真正的登录态是 cookie 里的 MUSIC_U」。
- `harvest` 流程以「拿到 `MUSIC_U`」为成功标准；没有 `MUSIC_U` 时绝不动现有会话（见 §6）。

### 5.3 Cookie 发送（`cookieHeader()`）

```js
const cookieHeader = () => {
  const jar = Object.entries(cookies).map(([k, v]) => `${k}=${v}`);
  const d = deviceCookie();
  for (const [k, v] of Object.entries(d)) if (cookies[k] === undefined) jar.push(`${k}=${v}`);
  return jar.join('; ');
};
```

即：先拼 `.session.json` 里的全部键值对，再补上设备信息里**尚未在 jar 中**的键。分隔符为 `'; '`。

### 5.4 设备指纹（`deviceCookie()`，`.netease-device.json`）

- 文件：与 `server.mjs` 同目录的 `.netease-device.json`，首次运行生成并持久化（每个安装一个固定值）。
- 默认值（逐字抄录）：
  ```js
  { os: 'pc', osver: 'Microsoft-Windows-10-Professional-build-19045-64bit',
    appver: '3.1.17.204416', versioncode: '140', mobilename: '',
    resolution: '1920x1080', channel: 'netease', deviceId: '' }
  ```
- `deviceId` 为空时生成：`crypto.randomUUID()`（存在时）否则 `crypto.randomBytes(16).toString('hex')`，再转大写；
  本 checkout 下实测值为一个大写 UUID 形式（具体值不复述）。
- 注意：`deviceCookie()` 的 `appver`（`3.1.17.204416`）与 eapi header 的 `appver`（`8.9.70`）不同，见 §10 矛盾点。

### 5.5 `saveCookies(setCookie)`

- 入参为响应头 `getSetCookie()` 返回的数组（每条形如 `K=V; Path=/; Expires=...`）。
- 每条只取第一个 `;` 之前的 `K=V`；`V` 为空或 `'""'` 时删除该键，否则写入 `cookies[K]=V`；随后写盘。
- 源码注释：`saveCookies` 理论上可能把 `MUSIC_U` 覆盖掉（`sessionVerify` 注释原话），见 §10。

### 5.6 `sessionVerify()`：两条验证路径

```js
async function sessionVerify() {
  // 路径 1：边车 /login/status（优先）
  // 路径 2：自家 weapi /w/nuser/account/get（边车挂了也得能验）
}
```

路径 1（边车优先）：

- 取 `scPort('netease')`（读 `services/netease-api/.port` 文件）；若端口存在且 `scPing('netease', port)`（GET `http://127.0.0.1:<port>/lizi/health`，1.5s 超时）通过，
  则 `ncRequest('/login/status', { params: {}, cookie: cookieHeader(), timeout: 12000 })`；
- 取 `d = (r.data && r.data.data) || {}`，`p = profileOf(d.profile)`；若 `d.code === 200` 且 `p` 非空，返回 `{ loggedIn: true, profile: p }`。
- **注意：边车没活着时不去拉起它**（注释：`/api/session` 开屏就问，不能为了验一次登录态把启动卡住 25 秒）；路径 1 任何异常都静默落到路径 2。

路径 2（自家 weapi）：

- `weapiRequest(ROUTES['login/status'].path, {})`，即 weapi POST `/w/nuser/account/get`；
- 再 `normalize('login/status', d)`；若结果 `loggedIn === true` 则返回该结果。
- `normalize('login/status')`：`data.profile` 存在则 `{ loggedIn: true, profile: { userId, nickname, avatar: avatarUrl, vipType } }`，否则 `{ loggedIn: false }`。

两条都不通/都不认：返回 `null`（调用方再转成 `{ loggedIn: false }`）。

`profileOf(p)`：`p` 为空或无 `userId` 返回 `null`；否则 `{ userId: p.userId, nickname: p.nickname, avatar: p.avatarUrl || p.avatar || '', vipType: p.vipType }`。

### 5.7 未登录时的降级行为

- `/api/session`：无 `MUSIC_U` 直接回 `{ loggedIn: false }`，不发任何上游请求。
- `song/url`：未登录时上游**仍然降级到 exhigh 320kbps**（源码注释原话：「不是我们吞掉的」）；返回体的 `level`/`br` 原样透传，界面据此如实显示实际拿到的音质。
- `lyric`：逐字歌词 `yrc` 网易云只在**已登录**时下发；匿名请求即使带 `kv/yv` 开关，返回也只有 `lrc/tlyric/romalrc`（源码注释称已实测：`yrc` 字段始终缺失）。
- `recommend/songs`（边车版）：未登录时上游回空，调用方（前端 `app.js`）自己降级；`ROUTES` 版 `/v1/discovery/recommend/songs` 同样需登录才有内容。
- `user/detail`（`/v1/user/detail/:uid`）：匿名可读公开信息；最近播放（`/v1/play/record`）和动态要登录（该接口不在 `ROUTES` 里）。
- 其余匿名可用：`search`、`playlist/detail`、`top/playlist`（`/personalized/playlist`）、`song/wiki`、`personalized`。
- 扫码登录失败不影响匿名浏览；`harvest` 校验失败时会话原样回滚（见 §6）。

## 6. 每个核心路由的请求参数整形和响应映射

约定：

- 通用转发（`/api/*`，非 `/api/netease/*`）的参数来源：`POST` 取 JSON body，`GET` 取 query（`Object.fromEntries(url.searchParams.entries())`）。
- 参数整形在 `switch (routeKey)` 里完成；未列出的路由 payload 原样透传。
- 路径占位符替换：对 `route.path` 中每个 `:xxx`，取值顺序为 `pathParams[xxx] ?? payload[xxx]`（`pathParams` 来自 URL 路径段，如 `/api/artist/6452` 的 `6452`；`payload` 来自 body/query，如 `user/detail` 的 `uid`）；取不到回 `400 { error: '<key> required' }`；替换后把该键从 `payload` 里删除（路径参数不进 body）。
- `normalize(name, data, channel)`：通用转发的响应归一化；`default` 分支原样返回 `data`（即 `login/cellphone`、`logout` 等未列出 case 的路由——见各条注明）。
- `json(res, code, data)`：HTTP 状态 `code`，`Content-Type: application/json; charset=utf-8`，body 为 `JSON.stringify(data)`。
- 下文「前端」指 `public/api.js` / `public/app.js` 的调用方式，仅作调用上下文，不属于服务端规格。

### 6.1 `search` —— `/api/search` → weapi `/search/get`

参数整形：

```js
payload = { s: payload.s || payload.keywords || '', type: 1, limit: Number(payload.limit || 30), offset: Number(payload.offset || 0) };
```

- `s`：关键词（也接受 `keywords` 别名）；`type` 固定 `1`（单曲）；`limit` 默认 30；`offset` 默认 0。
- 响应归一化（`normalize('search')`）：
  - 取 `data.result`，`raw = result.songs || []`，先 `raw.map(toTrack)`。
  - 封面补齐：搜索接口只给 `album.picId`，没有 `picUrl`，且 `picId` 拼不出封面 URL（实测文件名与 `picId` 不一致，拼出来是 404）。
    所以若 `tracks.some(t => !t.cover)`，则 `fetchTrackDetails(tracks.map(t => t.id))` 批量查详情，
    按 id 合并：`{ ...t, cover: t.cover || f.cover, fee: f.fee ?? t.fee, duration: t.duration || f.duration }`；
    补封面失败（异常）不影响搜索本身（`catch` 空）。
  - 返回 `{ code: data.code ?? 200, tracks, songCount: r.songCount ?? tracks.length }`。

### 6.2 `song/url` —— `/api/song/url` → weapi `/song/enhance/player/url/v1`

参数整形：

```js
const LEVELS = ['standard', 'higher', 'exhigh', 'lossless', 'hires', 'jymaster', 'jyeffect'];
const level = LEVELS.includes(payload.level) ? payload.level : 'exhigh';
const encodeType = level === 'standard' || level === 'higher' ? 'mp3' : 'flac';
payload = { ids: JSON.stringify(ids), level, encodeType };
```

- `ids`：`idList(payload.ids)`——把 `payload.ids` 按 `,` 切分、每段 `Number(trim)`、过滤 falsy，得到数字数组，再 `JSON.stringify`。
  前端传法：`API.songUrl(ids, level)`，`ids` 为数组时 `join(',')`，`level` 默认取 `window.LIZI_QUALITY`，再默认 `'exhigh'`。
- 档位列表（按 `LEVELS` 数组顺序）：`standard`、`higher`、`exhigh`、`lossless`、`hires`、`jymaster`、`jyeffect`；非法值回落 `exhigh`。
- `encodeType` 规则：`standard`/`higher` → `'mp3'`，其余（`exhigh`/`lossless`/`hires`/`jymaster`/`jyeffect`）→ `'flac'`。
  源码注释：`lossless`/`hires` 必须配 `flac`，否则上游按 mp3 回（实测：`encodeType=mp3` 时请求 `lossless` 只会拿到 `exhigh`）。
- 未登录降级：上游仍降级到 `exhigh` 320kbps（见 §5.7）；返回的 `level`/`br` 原样透传。
- 响应归一化（`normalize('song/url')`）：
  ```js
  { code: data.code ?? 200,
    data: (Array.isArray(data.data) ? data.data : []).map(s => ({
      id: s.id, url: s.url || null, br: s.br, size: s.size, fee: s.fee ?? 0,
      reason: s.url ? null : (s.code === -110 ? 'vip' : 'unavailable'),
      freeTrialInfo: s.freeTrialInfo || null, level: s.level || null })) }
  ```
  - `url` 为 `null` 即拿不到版权/VIP 地址；`code === -110` 表示无版权/需付费，前端据此决定降级（`reason: 'vip'`），否则 `'unavailable'`。
  - `br`：实际码率；`size`：文件字节数；`fee`：付费标记；`freeTrialInfo`：试听信息（上游原样透传）；`level`：实际拿到的档位。

### 6.3 `lyric` —— `/api/lyric` → weapi `/song/lyric/v1`

参数整形（全部固定值，前端只传 `id`）：

```js
payload = { id: Number(payload.id), cp: false, lv: -1, tv: -1, rv: -1, kv: -1, yv: -1, ytv: -1, yrv: -1 };
```

- `cp: false` 拿完整歌词；`lv/tv/rv` 为普通歌词、翻译、罗马音的开关；`kv/yv/ytv/yrv` 为逐字系列的开关（登录后才会真的下发）；值 `-1` 为源码写死的常量。
- 响应归一化（`normalize('lyric')`）：
  ```js
  { code: data.code ?? 200,
    lyric: <richLyricToLrc(data?.lrc?.lyric ?? data?.lyric ?? '')>,
    yrc: data?.yrc?.lyric ?? '',
    tlyric: data?.tlyric?.lyric ?? '',
    ytlrc: data?.ytlrc?.lyric ?? '',
    romalrc: data?.romalrc?.lyric ?? '',
    nolyric: !!data.nolyric,
    format: yrc ? 'yrc' : (lrc ? 'lrc' : 'none') }
  ```
- `yrc` 与 `lrc` 的关系：`yrc` 为逐字歌词（`[行起点,行时长](字起点,字时长,0)字…` 格式），只在已登录时下发；
  无 `yrc` 时前端退回整行 `lrc` 渲染。`tlyric` 为翻译，`ytlrc` 为逐字翻译，`romalrc` 为罗马音，`nolyric` 为纯音乐判定。
- 富文本行转换（`richLyricToLrc`）：上游会把创作信息（作词/作曲/编曲/制作名单）以 NDJSON 塞进 `lrc.lyric`，
  每行一个 JSON 对象 `{"t":0,"c":[{"tx":"作词: "},{"tx":"周杰伦","li":"…","or":"orpheus://…"}]}`，
  其中 `tx` 为文字（同行多个 `tx` 顺序拼接），`li`（艺人头像）、`or`（orpheus 链接）丢弃。
  转换规则：只改能解析成 `{c:[{tx:String}]}` 的行，其余行（含普通 LRC）原样保留；纯文本 LRC 恒等返回；
  `t` 缺失时沿用上一条时间 +1000ms（首条缺失落到 0）；`t` 为负按 0 算；时间格式 `[mm:ss.xx]`（两位小数、秒补到 5 位，先落到 10ms 再格式化，避免 59.999s 进成 `60.00`）；
  整串为 JSON 数组时逐项转；任何一步失败退回原串、绝不抛异常。
  关键限制：`c` 项只有 `tx/li/or` 三种键，**没有字级时间**，所以这里只产整行 LRC，不伪造 `yrc`。

### 6.4 `song/detail` —— `/api/song/detail`（特殊：不走通用 weapiRequest）

- 通用转发里 `case 'song/detail'` 直接短路返回，不经过 `normalize`：
  ```js
  const ids = idList(payload.ids);
  const tracks = await fetchTrackDetails(ids);
  return json(res, 200, { code: 200, tracks: tracks.map(toTrack).filter(Boolean) });
  ```
- `fetchTrackDetails(ids)`：每批最多 500 个 id（上游限制约 1000，留余量），
  每批 `weapiRequest('/v3/song/detail', { c: JSON.stringify(batch.map(id => ({ id }))) })`，
  收集各批 `d.songs`（数组才追加）。`ROUTES['song/detail'].path` 为 `/v3/song/detail`，但此路由实际不走 `ROUTES` 分发。
- `normalize` 里另有一个 `case 'song/detail'`（`{ code, tracks: (data.songs||[]).map(toTrack) }`），
  但通用转发中 `song/detail` 已提前返回，**该 case 在当前代码路径下不可达**（除非将来改动分发）。

### 6.5 `playlist/detail` / `playlist/track/all` —— `/api/playlist/detail`、`/api/playlist/track/all` → weapi `/v6/playlist/detail`

参数整形（两条相同）：

```js
payload = { id: Number(payload.id), n: 1000, s: 8 };
```

- 注释：`v6/detail` 一次最多给 1000 首，够用；不要传 `limit/offset`（这个接口不认）。
- 响应归一化（`normalize`，两条共用一个 case）：
  - `p = data.playlist || {}`；`tracks = p.tracks || []`；`ids = (p.trackIds || []).map(t => t.id)`。
  - 若 `ids.length > tracks.length` **或** `name === 'playlist/track/all'`，则 `tracks = await fetchTrackDetails(ids)`（每批 500，见 §8）。
    原因：`v6/detail` 的 `playlist.tracks` 只给 6 首试听，完整曲目在 `trackIds` 里。
  - 返回：
    ```js
    { code: data.code ?? 200,
      playlist: { id: p.id, name: p.name, cover: p.coverImgUrl, trackCount: p.trackCount,
                  playCount: p.playCount, description: p.description,
                  creator: p.creator ? { nickname: p.creator.nickname, avatar: p.creator.avatarUrl } : null },
      tracks: tracks.map(toTrack).filter(Boolean) }
    ```

### 6.6 `user/playlist` —— `/api/user/playlist` → weapi `/user/playlist`

参数整形：

```js
payload = { uid: Number(payload.uid), limit: 1000, offset: 0, includeVideo: true };
```

响应归一化：

```js
{ code: data.code ?? 200,
  playlists: (data.playlist || []).map(p => ({
    id: p.id, name: p.name, cover: p.coverImgUrl, trackCount: p.trackCount,
    playCount: p.playCount, subscribed: !!p.subscribed,
    specialType: Number(p.specialType) || 0 })) }
```

- `specialType: 5` 为「我喜欢的音乐」系统歌单（源码注释：原来被抹掉，前端 `specialType !== 5 / === 5` 的过滤实际一直没生效）。

### 6.7 `user/detail` —— `/api/user/detail` → weapi `/v1/user/detail/:uid`

参数整形：`payload = { uid: Number(payload.uid || payload.userId || 0) }`；
路径占位符 `:uid` 取 `pathParams.uid ?? payload.uid`，替换后 `uid` 从 body 删除。
响应归一化：

```js
{ code: data.code ?? 200, level: data.level ?? 0, listenSongs: data.listenSongs ?? 0,
  createDays: data.createDays ?? 0, canSeePlayRecord: !!data.peopleCanSeeMyPlayRecord,
  profile: { userId: p.userId, nickname: p.nickname || '', avatar: p.avatarUrl || '',
    background: p.backgroundUrl || '', signature: p.signature || '', description: p.description || '',
    follows: p.follows ?? 0, followeds: p.followeds ?? 0, playlistCount: p.playlistCount ?? 0,
    eventCount: p.eventCount ?? 0, createTime: p.createTime ?? 0, province: p.province ?? 0,
    city: p.city ?? 0, gender: p.gender ?? 0, vipType: p.vipType ?? 0,
    auth: (p.allAuthTypes || []).map(x => x && x.desc).filter(Boolean) } }
```

其中 `p = data.profile || {}`。注释：`backgroundUrl` 不吃 `?param=` 尺寸参数（实测 md5 与原图一致，937×832），`avatarUrl` 吃（`?param=200y200` → 200×200）。

### 6.8 `personalized` —— `/api/personalized` → weapi `/personalized/newsong`

- 无参数整形（payload 原样透传；前端 `API.personalized()` 不传参）。
- 响应归一化：`{ code: data.code ?? 200, tracks: (data.result || []).map(it => toTrack(it.song || it)).filter(Boolean) }`。

### 6.9 `top/playlist` —— `/api/top/playlist` → weapi `/personalized/playlist`

参数整形：

```js
payload = { cat: payload.cat || '全部', order: payload.order || 'hot',
            limit: Number(payload.limit || 12), offset: Number(payload.offset || 0), total: true };
```

- `cat` 分类、`order` 排序（`hot`/`new`）、`limit` 默认 12。
- 响应归一化：取 `list = data.playlists || data.result || data.recommend || []`；
  ```js
  { code: data.code ?? 200, more: !!(data.more ?? data.hasMore),
    playlists: list.map(p => ({ id: p.id, name: p.name,
      cover: p.coverImgUrl || p.picUrl || p.pic || '',
      count: p.playCount || p.playcount || 0,
      creator: (p.creator && p.creator.nickname) || '',
      tracks: p.trackCount || 0 })).filter(p => p.id) }
  ```

### 6.10 `song/wiki` —— `/api/song/wiki` → weapi `/song/play/about/block/page`

参数整形：`payload = { songId: Number(payload.id) }`（注意字段名由 `id` 改为 `songId`）。
响应归一化：

```js
{ code: data.code ?? 200,
  bpm, language, tags, bizTags, awards, similarIds }
```

- 取 `blocks = data?.data?.blocks || data?.blocks || []`；`basic = blocks.find(b => b.code === 'SONG_PLAY_ABOUT_SONG_BASIC')`；
  `creatives = basic?.creatives || []`；`pick(type)` 按 `creativeType` 找；`textOf(c) = c?.uiElement?.textLinks?.[0]?.text ?? null`；
  `listOf(c) = (c?.resources || []).map(r => r.text || r.name).filter(Boolean)`。
- `bpm`：`textOf(pick('bpm'))`，仅当全数字字符串时转 `Number`，否则 `null`（网易云给的权威 BPM，没有则为 `null`）。
- `language = textOf(pick('language'))`；`tags = listOf(pick('songTag'))`；`bizTags = listOf(pick('songBizTag'))`；
  `awards = listOf(pick('songAward'))`。
- `similarIds`：`blocks.find(b => b.code === 'SONG_PLAY_ABOUT_SIMILAR_SONG')` 的各 `creative.resources` 的 `resourceId || id` 展平过滤。

### 6.11 `netease/recommend/songs`（边车版）—— `/api/netease/recommend/songs` → 边车 `/recommend/songs`

- **不在 `ROUTES` 里**，走 `handleNetease` 兜底透传（见 §6.20）：GET 时 `params` 取 query（前端 `API.neteaseDaily()` 不传参），
  POST 时 `params = { ...query, ...body }`；随后 `ncRequest('/recommend/songs', { params, cookie: cookieHeader(), timeout: 25000 })`；
  响应**原样返回**（不经过 `normalize`；HTTP 状态：边车 200 则回 200，否则回边车状态）。
- 上游实现在 npm 包内，本仓库无定义。前端 `app.js` 注释：登录账号的「每日推荐」（30+ 首，带推荐理由）；未登录时上游回空，调用方自己降级。
- 勿与 `ROUTES` 的 `recommend/songs`（`/v1/discovery/recommend/songs`，`normalize` 取 `data.recommend` 映射为 `toTrack`，
  返回 `{ code, tracks }`）混淆；前端实际调的是边车版。

### 6.12 `netease/dj/recommend` 与 `netease/dj/program`（边车版）

- 同 §6.11 的透传机制：`/api/netease/dj/recommend` → 边车 `/dj/recommend`；`/api/netease/dj/program` → 边车 `/dj/program`。
- 前端调用（`public/api.js`）：`neteaseDjRecommend: (limit = 8) => call('netease/dj/recommend', { limit }, 'GET')`；
  `neteaseDjPrograms: (rid, limit = 50) => call('netease/dj/program', { rid, limit }, 'GET')`。
- 前端 `app.js` 注释：网易云 `/dj/recommend`（频道）+ `/dj/program`（节目，匿名/登录都可）。
- 上游路径、参数名、响应字段均由 npm 包内模块定义，**本仓库源码未规定**；响应原样透传，无本地归一化。
  （`handleNetease` 透传时唯一改动：删 `cookie/randomCNIP/realIP`，`login/*` 才加 `checkToken`，统一加 `ua`——见 §6.20。）

### 6.13 `netease/album/sublist`（边车版）

- 同 §6.11 的透传机制：`/api/netease/album/sublist` → 边车 `/album/sublist`。
- 前端调用：`neteaseAlbumSublist: (limit = 100, offset = 0) => call('netease/album/sublist', { limit, offset }, 'GET')`；
  `api.js` 注释称返回 `{ data:[{id,name,picUrl,size,artists:[{name}]}], count, hasMore }`——**该形状是前端的期望，服务端不做归一化**，
  实际字段以边车/上游返回为准；QQ/波点的「我收藏的专辑」在各自 handler 里对齐成同一套 `{ data, hasMore }`（见 server.mjs 的 `qqUserAlbum`/`bodianUserAlbum` 注释）。
- 需登录（「我的专辑」层）；上游实现在 npm 包内，本仓库无定义。

### 6.14 `login/qr/key` —— 两条并存的路径

**(a) 边车版（前端实际用）：`GET /api/netease/login/qr/key` → `handleNetease`**

- `ncRequest('/login/qr/key', { params: { type: 1, checkToken: 'v3', ua: NETEASE_UA }, cookie: cookieHeader(), timeout: 20000 })`。
- 取 `unikey = (d.data && d.data.unikey) || d.unikey || null`；拿不到回 `{ code: d.code || k.status || 502, key: null, channel: 'netease-api', message: d.message || '拿不到二维码 key' }`。
- 二维码图：再调 `ncRequest('/login/qr/create', { params: { key: unikey, qrimg: 'true', checkToken: 'v3', ua: NETEASE_UA }, cookie: cookieHeader(), timeout: 12000 })`，
  取 `qrimg = (c.data && c.data.data && c.data.data.qrimg) || ''`（边车直接给 `data:image/png;base64,...`）；异常则 `qrimg = ''`，
  前端退回 `https://music.163.com/login?codekey=<unikey>`。
- 成功回 `{ code: 200, key: unikey, qrimg, channel: 'netease-api' }`。

**(b) 手写 eapi 版（通用转发）：`/api/login/qr/key` → eapi `/login/qrcode/unikey`**

- 参数整形强制 `payload = { type: 1 }`；走 `eapiRequest`；`normalize('login/qr/key')` 返回 `{ code: data.code ?? 200, key: data.unikey || null, message: data.message }`。
- 源码注释：此路被上游稳定回 8821，已弃用；前端不用。

### 6.15 `login/qr/check` —— 两条并存的路径；状态码含义

状态码（两条路径、QQ 也沿用同一组数字，含义以网易云注释为准）：

| code | 含义 |
|---|---|
| `801` | 等待扫码 |
| `802` | 待确认（已扫码，待手机上点确认） |
| `803` | 成功（手机上已授权） |
| `800` | 过期（二维码不存在或已过期；二维码 key 是一次性的，803 之后同一 key 再 check 必回 800） |

**(a) 边车版（前端实际用）：`GET /api/netease/login/qr/check?key=...` → `handleNetease`**

- 参数：`ncRequest('/login/qr/check', { params: { key, type: 1, checkToken: 'v3', ua: NETEASE_UA }, cookie: cookieHeader(), timeout: 20000 })`；
  `key` 为空回 `400 { code: 400, message: 'key required' }`。
- `code = Number(d.code ?? r.status) || 0`。
- `code === 803` 时**当场抓 cookie**（见 §6.16）：`extractCookie(d, r.setCookies)`；抓到含 `MUSIC_U` 的则 `qrCacheSet(key, pairs, field)` 再 `runHarvest(key)`，
  返回：
  ```js
  { code, message: d.message || d.msg || '授权登陆成功', hasMusicU: true, cookieKeys: h.keys || [],
    channel: 'netease-api', loggedIn: h.ok === true, profile: h.ok ? h.profile : null,
    harvest: { tried: h.tried || [], gotCookie: true, field: h.field || null } }
  ```
  并 `recordQrCheck({ code, message }, 'netease-api')`。
- 非 803：取 `keys = Object.keys(extractCookie(d, r.setCookies).pairs)`，返回
  `{ code, message: d.message || d.msg || '', hasMusicU: keys.includes('MUSIC_U'), cookieKeys: keys, channel: 'netease-api' }`，
  并 `recordQrCheck`。响应里只有 code/message/键名，**不含 cookie 值**。

**(b) 手写 eapi 版（通用转发）：`/api/login/qr/check` → eapi `/login/qrcode/client/login`**

- 参数整形：`payload = { key: payload.key, type: 1 }`；走 `eapiRequest`。
- `normalize('login/qr/check')`：
  ```js
  { code: data.code ?? null, message: data.message ?? data.msg ?? data.errmsg ?? '' || null,
    nickname: data.nickname, avatar: data.avatarUrl,
    loggedIn: !!cookies.MUSIC_U }
  ```
  注释：`code`/`message` 原样透出（上游偶尔给字符串 `"803"`，缺 code 就是 `null`），不再用 `?? 200` 把真实状态抹掉；
  前端统一 `Number()` 归一后判断；`803` 只代表手机上授权了，登录态以 `MUSIC_U` 为准。
  同时 `recordQrCheck(data, channel)`（`channel` 为 `'eapi'`）。

### 6.16 `login/harvest` —— `POST /api/login/harvest` → `handleLoginHarvest` + `harvest-core.mjs`

- 请求体：`{ key }`（二维码 key）；`key` 为空回 `400 { ok: false, reason: 'no-key', message: '缺少扫码 key' }`。
- 核心逻辑在 `services/netease-api/harvest-core.mjs` 的 `harvest(deps)`（纯逻辑，不读盘、不联网，I/O 由调用方注入）；
  `server.mjs` 的 `runHarvest(key)` 注入：
  - `cache`: `qrCookies` Map（`key → { pairs, field, at }`），TTL `QR_COOKIE_TTL = 10*60*1000`（10 分钟），读写时清理过期项；
  - `recheck`: `ncRequest('/login/qr/check', { params: { key, type: 1, checkToken: 'v3', ua: NETEASE_UA }, cookie: cookieHeader(), timeout: 20000 })`；
  - `status`: `ncRequest('/login/status', { params: {}, timeout: 12000 })`（注意：此处**不传** cookie）；
  - `verify`: `sessionVerify`（见 §5.6）；
  - `session`: `{ snapshot: sessionSnapshot, apply: sessionApply, restore: sessionRestore }`；
  - `record`: 写 `lastHarvest = { at: ISO 时间, ok, reason, code, tried, gotCookie, field, cookieKeys }`（只有键名，无值）。
- `harvest` 步骤（按顺序，`tried` 数组记录实际试过的来源）：
  1. 缓存：`cache.get(key)` 有含 `MUSIC_U` 的 `pairs` 则采用（`tried.push('cache')`）。803 当场缓存的最可信，因为 key 一次性，重查必 800。
  2. 重查：无 `MUSIC_U` 才调 `recheck`（`tried.push('check')`）；从响应中 `extractCookie`，有 `MUSIC_U` 则采用并写回缓存。
     `code` 取 `r.body.code`（若存在）。
  3. 状态：仍无则调 `status`（`tried.push('status')`），同样 `extractCookie`。
  4. 无 `MUSIC_U`：返回失败 `{ ok: false, reason, code, gotCookie: false, field, keys, tried, message }`；
     `reason` 为 `code !== null && code !== 803 ? 'not-authorized' : 'no-music-u'`；
     `message` 对应为 `上游这次回的是 ${code}（不是 803）：二维码 key 已被用过或已过期` 或 `扫码已确认，但上游这次没下发 MUSIC_U`。
     **此时绝不动现有会话。**
  5. 有 `MUSIC_U`：`snapshot = session.snapshot()`，`session.apply(slim(pairs))`（`slim` 只保留非空值；`sessionApply` 为**整份替换** jar 并写盘），
     再 `verify()`；校验无 profile 则 `session.restore(snap)` 回滚，返回 `{ ok: false, reason: verifyError ? 'error' : 'invalid', ... }`，
     `message` 为 `拿到了 MUSIC_U，但校验时出错了：...` 或 `拿到了 MUSIC_U，但用它校验没通过（可能已过期）`；
     校验通过返回 `{ ok: true, code, gotCookie: true, field, keys, tried, profile }`。
- `extractCookie(body, setCookies)`（三种来源，按优先顺序，优先返回含 `MUSIC_U` 的那份）：
  1. `body.cookie`（字符串）——包的 `/login/qr/check` 803 的正规位置；
  2. `body.data.cookie`——有的版本/转发层多包一层 `data`；
  3. `Set-Cookie` 响应头（数组 `join('; ')`）。
  无任何来源返回 `{ field: null, pairs: {} }`；有来源但无 `MUSIC_U` 时返回第一个非空来源。
- `parseCookieInput(raw)`（宽容解析）：
  - 去首尾空白；去掉 `Cookie:` 前缀（不区分大小写）；去掉首尾引号；
  - 不含 `=` 且不含 `;` 的裸值 → `{ MUSIC_U: <整串> }`；
  - 否则按 `;` 切分，每段按第一个 `=` 分键值；键或值为空跳过；键小写后属于
    `COOKIE_ATTRS = { path, domain, expires, max-age, secure, httponly, samesite, version, priority, comment, partitioned }` 的跳过（即 `Path=/` 这类属性不是 cookie）。
- `handleLoginHarvest` 的 HTTP 响应：
  - 成功：`200 { ok: true, profile, harvest: { tried, gotCookie, field }, cookieKeys }`；
  - 失败：`400 { ok: false, reason, code: out.code ?? null, message, harvest, cookieKeys: out.keys || [] }`；
  - `runHarvest` 抛异常：`400 { ok: false, reason: 'sidecar', message: '边车没给出登录结果：' + e.message }`。

### 6.17 `session/import` —— `POST /api/session/import` → `handleSessionImport`（粘贴 cookie 登录）

- 请求体：`body.cookie ?? body.value ?? ''`，经 `parseCookieInput` 解析；`keys = Object.keys(pairs)`（只回键名）。
- 无 `MUSIC_U`：`400 { ok: false, reason: 'no-music-u', keys, cookieKeys: keys, message: '这段内容里没有 MUSIC_U（F12 → Application → Cookies → music.163.com 里那一项）' }`。
- 有 `MUSIC_U`：快照 → `sessionApply(pairs)`（整份替换）→ `sessionVerify()`；
  校验失败则回滚快照，回 `400 { ok: false, reason: err ? 'error' : 'invalid', keys, cookieKeys: keys, message: err ? '校验登录态失败：' + err.message : '这段 cookie 无效或已过期（MUSIC_U 不是当前账号的，或已经登出过）' }`；
  成功回 `200 { ok: true, profile: v.profile, cookieKeys: keys }`，并控制台记 `登录成功（cookie 导入）· 用户 <userId>`。
- 注释：这是最稳的备用登录路。

### 6.18 `/api/session` —— 会话状态查询

- 不限 method。`if (!cookies.MUSIC_U) return json(res, 200, { loggedIn: false })`（不发上游请求）。
- 否则 `v = await sessionVerify()`（见 §5.6），回 `v || { loggedIn: false }`；异常回 `{ loggedIn: false }`。
- 成功时返回 `{ loggedIn: true, profile: { userId, nickname, avatar, vipType } }`（经 `profileOf` 整形）。

### 6.19 `/api/login/qr/last` —— 扫码诊断（只读）

- 返回 `{ ...(lastQrCheck || { at: null, channel: null, code: null, message: '还没有 check 过' }), hasMusicU: !!cookies.MUSIC_U, loggedIn: !!cookies.MUSIC_U, cookieKeys: Object.keys(cookies), harvest: lastHarvest }`。
- `lastQrCheck` 由 `recordQrCheck(raw, channel)` 写入：`{ at: ISO 时间, channel, code: raw.code ?? null, message: raw.message ?? raw.msg ?? '', hasMusicU: !!cookies.MUSIC_U, loggedIn: !!cookies.MUSIC_U, cookieKeys: Object.keys(cookies) }`；
  `channel` 取值为 `'eapi'`（通用转发扫码路）、`'weapi'`（默认值）或 `'netease-api'`（边车版 check）。
- `lastHarvest` 见 §6.16。响应只有 code/message/键名，**无任何 cookie 值与 token**。

### 6.20 `handleNetease` 兜底透传（`/api/netease/<其余>` → 边车 `/<其余>`）

- 前置分支：`part === 'health'` 单独处理（见下）；`login/qr/key`、`login/qr/check` 单独处理（见 §6.14、§6.15）。
- 其余 `part` 一律：
  ```js
  const body = req.method === 'POST' ? await readBody(req) : {};
  const params = { ...Object.fromEntries(q.entries()), ...body };  // body 覆盖 query
  delete params.cookie; delete params.randomCNIP; delete params.realIP;
  if (/^login\//.test(part)) params.checkToken = 'v3';
  params.ua = NETEASE_UA;
  const target = '/' + part.replace(/^\/+/, '');
  if (target === '/') return json(res, 404, { error: 'unknown netease api' });
  const r = await ncRequest(target, { params, cookie: cookieHeader(), timeout: 25000 });
  return json(res, r.status === 200 ? 200 : r.status, r.data && typeof r.data === 'object' ? r.data : { raw: r.data });
  ```
- 要点：客户端传来的 `cookie`/`randomCNIP`/`realIP` 一律丢掉（cookie 用服务自己的；IP 参数不许客户端指定）；
  一律 POST + JSON body（cookie 不进 URL，边车日志里不会出现凭证）；登录类接口必须带易盾反作弊 token `checkToken='v3'`
  （注释：包专门加了 `X-antiCheatToken` 支持，但取码模块自己不传 `checkToken`，得由调用方指定；不带则 unikey 照拿，但手机扫码确认时网易云判定异常）；
  响应原样透传，无 `normalize`。
- `health` 分支：`ensureSidecar('netease')` 拉起边车 → `ncRequest('/lizi/health', { method: 'GET', timeout: 4000 })`，
  成功回 `{ code: 200, ok: true, port, health: h.data }`，失败回 `502 { code: 502, ok: false, error }`。

### 6.21 `ncRequest`（主服务 ↔ 边车，`handleNetease`/`sessionVerify` 共用）

- 边车地址：`http://127.0.0.1:<port><pathname>`，端口由 `ensureSidecar('netease')` 取得（见 §6.22）。
- 请求头固定带 `x-apicache-bypass: 1`（包里挂了 2 分钟的 apicache，扫码 check 每 2 秒问一次，被缓存住就永远停在 801）。
- `GET`：`params` 拼进 query（空/undefined/null 的值跳过）；只有 `/lizi/health` 走这条。
- `POST`（默认）：`Content-Type: application/json`，body 为 `JSON.stringify({ ...params, ...(cookie ? { cookie } : {}) })`——
  **cookie 走 JSON body，绝不走 query**（包的 logger 会把 `req.originalUrl` 打进自己的 `.log`，`?cookie=` 等于把凭证明文落盘；body 不进日志）。
- 响应：解析 JSON（失败则 `{ raw: text.slice(0, 300) }`），并带出 `setCookies`（`getSetCookie()`，老版本退回单条 `set-cookie`）。
  返回 `{ status, data, setCookies }`。

### 6.22 边车 `services/netease-api/start.mjs`（扫码登录边车）

- 包：`@neteasecloudmusicapienhanced/api@4.41.1`（`services/netease-api/package.json` 的唯一依赖），
  由 `serveNcmApi({ port, host: '127.0.0.1', checkVersion: false })` 启动；`checkVersion: false` 表示不 spawn `npm info`。
- 端口：`NETEASE_API_PORT` 环境变量 > 上次的 `.port` 文件（读后删除）> `3215`（避开 QQ 3210 / 汽水 3212 / 波点 3213 / Spotify 3214）；
  占用/`EACCES` 时改用系统分配（`server.listen(0, '127.0.0.1')`）；就绪后写 `.port` 文件并打印 `NETEASE_API_READY <port>`。
- 只绑 `127.0.0.1`：显式传 `host`，另给 `net.Server.prototype.listen` 打一次性补丁（仅当第一个参数为纯端口号时补 `127.0.0.1`）。
- 登录态**不落盘**：`MUSIC_U` 由主服务自己保管（`.session.json`），每次请求把 cookie 串通过 body 传进来；边车只认 `?cookie=a=b; c=d` 形式的传入（注释原话如此，但主服务实际走 JSON body，见 §6.21——此处存在表述出入，见 §10）。
- IP 补丁（关键，`start.mjs` 注释）：
  - 环境变量 `ENABLE_RANDOM_CN_IP=true`；
  - 在 `require` 主包**之前**替换 `util/option.js` 的导出为强制 `opts.randomCNIP = true` 的包装（调用方写 `randomCNIP=false` 也不放行）；
  - `global.cnIp`：默认 `''`（空字符串）；包内 `request.js` 的逻辑是 `ip = options.realIP || options.ip || ''; if (ip) { headers['X-Real-IP']=ip; headers['X-Forwarded-For']=ip }`，
    所以 `cnIp` 为空时**两个头一个都不发**，网易云按真实 TCP 源地址判定。`NETEASE_CN_IP=1.2.3.4` 可手动指定一个 IP（此时重新带上这两个头）。
  - 原因（注释）：同一账号几分钟内从不同城市 IP 反复登录会被风控判「操作异常」；真机客户端绝不会带 `X-Forwarded-For`，自报 IP 等于承认伪造客户端。
  - 启动后复核：包的 `generateConfig()` 会在启动时把 `global.cnIp` 改回随机 IP，`start.mjs` 在 `serveNcmApi` 之后再清一次空（未设 `NETEASE_CN_IP` 时）。
  - `detectPublicIP()` 函数存在（依次探 `https://myip.ipip.net`、`https://api.ipify.org?format=json`、`https://ifconfig.me/ip`，过滤私网段），
    但**在当前 `start.mjs` 中没有任何调用处**（仅定义）——不要按「优先上报真实公网 IP」去实现。
- 其它：`os.tmpdir()/anonymous_token` 占位空文件（包在加载时读，不存在会 ENOENT 崩掉）；
  `/lizi/health` 探针回 `{ code: 200, ok: true, node: process.versions.node, ipMode: 'randomCNIP', cnIpSeeded: !!global.cnIp }`；
  日志超 2MB 轮换（`.log` → `.log.1`）；父进程退出检测（`NETEASE_PARENT_PID`，每 5 秒 `process.kill(pid, 0)`，父进程没了则退出）；
  `uncaughtException`/`unhandledRejection` 中 `EPIPE`/`ERR_STREAM_DESTROYED` 直接忽略，其余记 FATAL 后退出。
- `services/netease-api/README.md`（104 行）与 `harvest-selftest.mjs` 未展开：前者为边车说明，后者为 `harvest-core` 的自测脚本（与移植规格无关）。

### 6.23 其余 `ROUTES` 路由的归一化（补全）

- `login/cellphone`：无参数整形、无 `normalize` case → 上游 JSON 原样返回。
- `logout`：同上，原样返回。
- `artist/:id`：无参数整形（`id` 只用于路径占位符替换）；`normalize` 返回
  `{ code, artist: { id, name: a.name || a.nickname || '', nickname, avatar: a.img1v1Url || a.cover || a.picUrl || '', cover: a.cover || a.img1v1Url || '', briefDesc, albumSize, musicSize, alias, trans }, hotSongs: (data.hotSongs||[]).map(toTrack) }`，
  其中 `a = data.artist || {}`；`hotSongs` 为热门 50 首。
- `artist/albums/:id`：参数整形 `{ limit: Number(payload.limit || 12), offset: Number(payload.offset || 0), total: true }`；
  `normalize` 返回 `{ code, more: !!(data.more ?? data.hasMore), albums: (data.hotAlbums || data.albums || []).map(a => ({ id, name, cover: a.picUrl || a.blurPicUrl || a.coverImgUrl || '', publishTime: a.publishTime ?? 0, size: a.size ?? a.songCount ?? 0 })).filter(a => a.id) }`。
- `artist/songs`：参数整形 `{ id: Number(payload.id), limit: Number(payload.limit || 100), offset: Number(payload.offset || 0), order: payload.order === 'time' ? 'time' : 'hot' }`；
  `normalize` 返回 `{ code, total: data.total ?? (data.songs||[]).length, more: !!(data.more ?? data.hasMore), songs: (data.songs||[]).map(toTrack) }`。
- `album/:id`：无参数整形；`normalize` 返回
  `{ code, album: { id, name, cover: al.picUrl || al.blurPicUrl || '', company, description, publishTime: al.publishTime ?? 0, size: al.size ?? (data.songs||[]).length, artists: (al.artists || al.ar || []).map(x => ({ id: x.id, name: x.name })) }, songs: (data.songs||[]).map(toTrack) }`，
  其中 `al = data.album || {}`。
- `login/status`：见 §5.6 路径 2 的 `normalize`。

---

## 7. 代理

### 7.1 `proxyImage` —— `GET /api/img?url=<完整图片 URL>`

- URL 解析失败回 `400 { error: 'bad url' }`。
- 白名单（`IMAGE_HOSTS` 精确集合 + `IMAGE_HOST_SUFFIX` 后缀集合，任一命中即放行）：
  - 精确：`p1.music.126.net`、`p2.music.126.net`、`p3.music.126.net`、`p4.music.126.net`、`p5.music.126.net`、`p6.music.126.net`、
    `y.gtimg.cn`、`music-file.y.qq.com`、`qpic.y.qq.com`、`i.scdn.co`。
  - 后缀：`.douyinpic.com`、`.douyincdn.com`、`.huoshanimg.com`、`.kuwo.cn`、`.scdn.co`、`.spotifycdn.com`、
    `.y.qq.com`、`.qlogo.cn`、`.qpic.cn`。
  - 不在白名单回 `403 { error: 'host not allowed' }`。
- 上游请求：`fetch(u, { headers: { Referer: 'https://music.163.com/', 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(20000) })`。
  注释：网易云封面有防盗链，`<img referrerpolicy>` 不好控，所以走代理。
- 跟随重定向后**再校验一次**最终 URL 的 host（`upstream.url`），不通过回 `403 { error: 'redirect host not allowed' }`。
- 内容类型：`content-type` 必须以 `image/` 开头，否则 `415 { error: 'not an image' }`。
- 大小上限：`IMAGE_MAX_BYTES = 10 * 1024 * 1024`（10MB）；`content-length` 声明超限或实际 body 超限均回 `413 { error: 'image too large' }`。
- 成功：按上游状态码原样回，响应头 `Content-Type: <上游 type 或 image/jpeg>`、`Cache-Control: public, max-age=86400`，body 为完整图片字节（非流式，先 `arrayBuffer` 再 `res.end(buf)`）。
- 异常回 `502 { error: <message> }`。
- 前端用法：`API.img(u, size)` 把封面 URL 加 `?param=<size>y<size>` 后包成 `/api/img?url=...`。

### 7.2 `proxySourceAudio` —— 各源音频代理（转发 Range）

入口（见 §2）：`/api/netease/audio`、`/api/lx/audio`、`/api/qishui/audio`、`/api/bodian/audio`、`/api/spotify/audio`、`/api/kuwo/audio`，
均为 `?url=<完整音频 URL>`，共用 `proxySourceAudio(req, res, url, source)`。

- URL 解析失败回 `400 { error: 'bad url' }`；协议非 `http:`/`https:` 回 `400 { error: 'bad protocol' }`。
- `AUDIO_HOSTS` 白名单（正则数组，`re.test(u.hostname)` 任一命中即放行）：
  | source | 白名单正则 |
  |---|---|
  | `qishui` | `/\.365yg\.com$/i`、`/\.douyinvod\.com$/i`、`/\.byteicdn\.com$/i`、`/\.pstatp\.com$/i`、`/\.douyinpic\.com$/i`、`/\.snssdk\.com$/i` |
  | `bodian` | `/\.kuwo\.cn$/i`、`/\.bodian\.com$/i` |
  | `kuwo` | `/\.kuwo\.cn$/i`、`/\.kuwo\.com$/i` |
  | `spotify` | `[]`（空数组，本期不接音频，直接拒） |
  | `netease` | `/\.music\.126\.net$/i` |
  | `lx` | `/\.music\.126\.net$/i`、`/\.126\.net$/i`、`/\.163\.com$/i`、`/\.qqmusic\.qq\.com$/i`、`/\.tc\.qq\.com$/i`、`/\.kuwo\.cn$/i`、`/\.kuwo\.com$/i`、`/\.migu\.cn$/i`、`/\.music\.migu\.cn$/i` |
- 白名单为空（`spotify`）回 `403 { error: 'no audio for source spotify' }`；host 不匹配回 `403 { error: 'host not allowed: ' + u.hostname }`。
- `AUDIO_REFERER`（只有三条有值，其余源**不带** Referer）：
  - `qishui: ''`（空串——注释：汽水 CDN `*.365yg.com` 认了 Referer 反而回 403，不带才是 206；此条留空，别「顺手补上」）
  - `bodian: 'https://www.bodian.com/'`
  - `netease`、`lx`、`kuwo`、`spotify`：`AUDIO_REFERER` 中无对应键 → 不发 Referer。
- 上游请求头：`User-Agent: Mozilla/5.0`；有 Referer 则带；客户端的 `Range` 头原样转发（`if (req.headers.range) headers.Range = req.headers.range`）；
  `redirect: 'follow'`。
- 响应：状态码原样透传；响应头固定 `Content-Type: <上游 content-type 或 audio/mpeg>`、`Cache-Control: no-store`、`Accept-Ranges: bytes`，
  另透传上游的 `content-length`、`content-range`（有才带）；body 用 `pipeUpstream` 流式转发（见下）。
- 异常回 `502 { code: 502, error: <message> }`。
- 必须走代理的原因（源码注释）：网易云 CDN（`*.music.126.net`）不回 `Access-Control-Allow-Origin`（实测 m704/m804 五档全部 ACAO 缺失，
  同一对象换 m701/m801 才回 `*`）；播放器 `<audio>` 必须设 `crossOrigin='anonymous'`（Web Audio 取 analyser 用），直接挂 CDN 会被 CORS 拦成 `net::ERR_FAILED` → error 4。
- `pipeUpstream(upstream, res, label)`：`Readable.fromWeb(upstream.body)`  pipe 到响应；上游读失败 → 记一行 warn 日志并 `res.end()`；
  客户端断开（`res` 的 `close`）→ 销毁上游流，不当作错误；`res` 的 `error` 同样收敛；全程不让未捕获异常导致进程退出
  （背景：实测曾因 `TypeError: terminated [cause]: SocketError: other side closed` 导致整个进程退出）。

### 7.3 `proxyQQAudio` —— `GET /api/qq/audio?url=...`（独立实现，不走 `proxySourceAudio`）

- URL 解析失败回 `400 { error: 'bad url' }`；协议非 `http:`/`https:` 回 `400 { error: 'bad protocol' }`。
- 白名单：`/ (^|\.)qq\.com$/i`（仅腾讯域名）；不通过回 `403 { error: 'host not allowed' }`。
- 上游请求头：`User-Agent: Mozilla/5.0`、`Referer: https://y.qq.com/`；`Range` 原样转发；`redirect: 'follow'`。
- 响应头与 `proxySourceAudio` 相同：`Content-Type`（默认 `audio/mpeg`）、`Cache-Control: no-store`、`Accept-Ranges: bytes`，
  透传 `content-length`、`content-range`；状态码原样；body 经 `pipeUpstream` 流式转发；无 body 时直接 `res.end()`。
- 异常回 `502 { code: 502, error: <message> }`。
- 注释：直链形如 `http://aqqmusic.tc.qq.com/RS....mp3?vkey=...`；vkey 会过期、CDN 有 referer 策略，且凭证不应塞进 DOM；必须转发 Range，否则 `<audio>` 拖进度条会整段重下。

---

## 8. `fetchTrackDetails` / `toTrack` 的曲目归一化字段

### 8.1 `fetchTrackDetails(ids)`

- 入参为空数组直接回 `[]`。
- 分批：每批最多 **500** 首（`for (let i = 0; i < ids.length; i += 500)`）。
- 每批：`weapiRequest('/v3/song/detail', { c: JSON.stringify(batch.map(id => ({ id }))) })`；
  若 `d.songs` 为数组则追加到结果。返回合并后的原始歌曲对象数组（未归一化）。

### 8.2 `toTrack(s)`

输入为上游原始歌曲对象（字段名各接口不同：`artist/artists/ar`、`album/al`、`duration/dt`），输出统一形状：

```js
{
  id: s.id,
  name: s.name,
  artists: (s.ar || s.artists || []).map(a => a.name).join(' / ') || '未知歌手',
  artistIds: (s.ar || s.artists || []).map(a => a.id),
  album: (s.al || s.album || {}).name || '',
  albumId: (s.al || s.album || {}).id || null,
  cover: coverOf(s, album),
  duration: s.dt || s.duration || 0,
  fee: s.fee ?? 0,
}
```

- `coverOf(s, album) = album.picUrl || album.blurPicUrl || s.picUrl || s.coverImgUrl || ''`。
- `albumId` 为附加字段（曲目行里的专辑名 → `/api/album/:id` 入口用，不影响老代码）。
- `duration` 单位为**毫秒**；`fee` 为付费标记（缺失时 `0`）。
- 注意：`toTrack` 的输出**没有 `source` 字段**（与 `qqTrack` 等各源映射函数不同，后者会加 `source: 'qq'` 等）；
  网易云曲目的来源由调用方/前端默认处理，服务端不补。
- 封面坑（源码注释）：`/v3/song/detail` 与 `/playlist/detail` 给 `al.picUrl`（完整 URL）；
  `/search/get` 只给 `album.picId`，拼不出 URL，须经 `fetchTrackDetails` 补（见 §6.1）。

---

## 9. `wallpaper-api.mjs`：用途、主播放器是否依赖、移植结论

**结论：不用移植。主播放器（播放、搜索、歌单、登录、歌词）完全不依赖它；它只服务于两个可选的创意视觉形态（657/658）与若干实验舞台的背景功能，且是 Windows + Wallpaper Engine 专属的本地文件功能。**

依据：

- `wallpaper-api.mjs` 的职责：读本机 Wallpaper Engine 安装（注册表 `HKCU\Software\Valve\Steam` 的 `SteamPath`、
  `steamapps/libraryfolders.vdf`、候选目录 `steamapps/common/wallpaper_engine` 及 C/D/E/F 盘兜底），解析当前壁纸的 `project.json`
  （`file` 为正片视频，`preview` 为预览图），提供 4 个只读接口：
  - `GET /api/wallpaper` → 当前壁纸元数据 JSON（2 秒缓存）；
  - `GET /api/wallpaper/media` → 当前壁纸视频字节流（支持 Range / 206）；
  - `GET /api/wallpaper/preview` → 当前壁纸预览图；
  - `GET /api/wallpaper/list` → 壁纸库列表（30 秒缓存）；`preview?id=` / `media?id=` 按 id 查表取指定壁纸（id 只查表，绝不参与路径拼接；恶意 `project.json` 的 `..` 路径不认）。
  - 仅支持 `GET`/`HEAD`，其余方法回 `405 { ok: false, error: 'method not allowed' }`；未知路径回 `404 { ok: false, error: 'unknown wallpaper api' }`。
  - 视频扩展名：`.mp4`、`.webm`、`.mkv`；图片：`.jpg`、`.png`（预览另认 `.gif`）；MIME 表见文件顶部 `MIME` 常量。
- 依赖方核查（`grep` 全仓库）：
  - 调 `/api/wallpaper*` 的只有 `public/stages/519-prism-euphoria.html`、`public/stages/assets/custom-bg.js`
    （背景源切换逻辑）以及 `app.js` 里注册的两个创意形态条目：`657 壁纸接入实验`、`658 壁纸融合`
    （描述：把 Wallpaper Engine 当前壁纸铺满整屏当背景，视频直接播放、场景图缓慢推拉，歌词按机位换位）。
  - `public/api.js`、`public/player.js`、`public/app.js` 的主播放流程（播放/搜索/歌单/登录）**没有任何**对 `/api/wallpaper` 的调用。
  - `server.mjs` 只在分发顺序第 2 位挂载 `handleWallpaper`（见 §2），与网易云逻辑无数据往来。
- 移植建议：iOS 侧无 Wallpaper Engine、无 Windows 注册表、无 Steam 库，此模块无对应物；跳过即可。
  若将来要在 iOS 上实现「壁纸当背景」，那是新的本地图片/视频背景功能，与本模块无继承关系。

---

## 10. 源码中互相矛盾或含糊的地方（已标明，不脑补）

1. **两条扫码登录并存**：通用转发 `/api/login/qr/*`（手写 eapi，注释称被上游稳定回 8821）与边车版 `/api/netease/login/qr/*`（前端实际用）同时存在；
   另有 `login/cellphone`（weapi）只在 `ROUTES` 里，无任何前端调用与 `normalize`，其可用性源码未验证。
2. **设备身份三处不一致**：eapi header 的 `deviceId` 为进程启动时随机生成的 32 位大写 hex（`EAPI_DEVICE_ID`，重启即变）；
   `cookieHeader` 补的 `deviceId` 是 `.netease-device.json` 里持久化的大写 UUID；
   eapi header 的 `appver` 是 `8.9.70`，而 `deviceCookie()` 与 `NETEASE_UA` 的 `appver` 是 `3.1.17.204416`；
   `weapiRequest`/`eapiRequest` 的 UA 是 Chrome/120，`NETEASE_UA` 是 Chrome/91 + `NeteaseMusicDesktop/3.1.17.204416`。
   同一个「PC 客户端」在三条通道里自报了不同的身份，源码注释称「必须和 cookie 里的 os=pc/appver 对得上」，但实际并不统一。
3. **IP 头策略表述矛盾**：`start.mjs` 的 `/lizi/health` 回 `ipMode: 'randomCNIP'`，但同文件注释与代码实际做的是 `global.cnIp = ''`（不发 `X-Real-IP`/`X-Forwarded-For`）；
   `ENABLE_RANDOM_CN_IP=true` 与强制 `randomCNIP=true` 的包装仍保留，但因 `cnIp` 为空而不产生任何头。健康接口的 `ipMode` 字段是过时标签。
4. **边车 cookie 传入方式表述出入**：`start.mjs` 注释称边车「每次请求把 cookie 串通过 query 传进来（这个包认 `?cookie=a=b; c=d`）」，
   但 `server.mjs` 的 `ncRequest` 实际把 cookie 放进 POST JSON body（注释称 query 会进边车日志），且 `scRequest`（边车）才用 query 传 cookie。
   以 `ncRequest` 的实际行为为准。
5. **「只取 MUSIC_U / __csrf」与实现不符**：`handleNetease` 顶部的注释称 803 之后「只取 MUSIC_U / __csrf 写进我们自己的 `.session.json`」，
   但 `harvest` 的 `session.apply(slim(pairs))` 会把 `extractCookie` 抠出的**全部**非空键值对整份写入（`slim` 只过滤空值，不过滤键名）。
6. **`detectPublicIP()` 未被调用**：`start.mjs` 中定义了公网 IP 探测函数，注释称「10-31 改：优先上报真实公网 IP」，但全文无任何调用处；
   实际行为是 `global.cnIp = ''`（不发 IP 头）。不要按注释的字面意思实现「优先上报真实 IP」。
7. **`gmt8Timestamp()` 未被调用**：定义后无调用处；注释称「服务端时区必须按东八区算，否则登录接口会因为时间偏差拒绝」，但没有任何请求使用它。
8. **`normalize` 的 `song/detail` case 不可达**：通用转发中 `song/detail` 已提前 `return`（见 §6.4），`normalize` 里的同名 case 当前走不到。
9. **边车版路由无本地定义**：`/api/netease/dj/recommend`、`/api/netease/dj/program`、`/api/netease/album/sublist`、`/api/netease/recommend/songs`
   的上游路径、参数、响应字段均由 npm 包 `@neteasecloudmusicapienhanced/api@4.41.1` 内部模块决定，本仓库无定义；
   且本 checkout 下 `services/netease-api/node_modules/` 不存在，无法本地核对。移植这四条路由时须以该包 4.41.1 的源码/实测为准，不能以本规格文档为准。
   （`api.js` 对 `album/sublist` 返回形状的注释是前端期望，不是服务端保证。）
10. **文件头注释与实现出入**：`server.mjs` 文件头称 weapi 是「把明文参数加密成 CSRFToken + params」，但实际请求体字段是 `params`、`encSecKey`、`csrf_token`（无 `CSRFToken` 这个字段名）。
11. **`sessionVerify` 的 weapi 路径有覆盖风险**：源码注释自认「weapi 那条会 `saveCookies`，理论上可能把 `MUSIC_U` 覆盖掉」；
    路径 1（边车）被注释为「不碰我们自己的 jar」，是优先用边车验证的原因之一。
12. **`eapiHeader` 的 `buildver` 与 `requestId` 每次调用都变**：`buildver` 为秒级时间戳前 10 位，`requestId` 含毫秒时间戳与随机数；
    移植时须每次请求重新生成，不可缓存复用。
13. **`search` 的补封面条件**：注释称「搜索接口只给 `album.picId`……所以拿到 id 后再查一次 song/detail 补封面」，
    但代码条件是 `tracks.some(t => !t.cover)`（任一缺封面才补），而非无条件补；且合并时只覆盖 `cover`（缺时）、`fee`、`duration`（缺时），其余字段保留搜索结果。
14. **`/api/session` 不限 method**：源码未校验 method，GET/POST 均可；`/api/login/qr/last` 同样不限 method。
15. **当前 checkout 的登录态**：`.session.json` 仅含 `NMTID` 一个键，无 `MUSIC_U`、`__csrf`——即本机当前未登录；文档中凡称「已登录才有」的功能均以此为准，未做登录态实测。
