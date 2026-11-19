/**
 * 播放器引擎
 *
 * 三件事值得说明：
 *  1) 队列播放 + 播放模式（顺序 / 单曲 / 随机）
 *  2) 歌词：解析 LRC（含翻译行），按时间滚动并高亮
 *  3) 降级：网易云对大量歌曲返回 url:null（VIP/无版权）。这时不报错卡住，
 *     而是生成一段「演示音轨」继续放 —— 界面、歌词、进度条全都能正常走完，
 *     并在播放条上打一个「演示音轨」角标说明这不是真歌。
 */
const Player = (() => {
  /* ------------------------------------------------------------------ *
   * 双 deck
   *
   * 自动过渡需要两条真实音频同时出声：一条淡出、一条淡入。
   * 所以这里不再只有单个 Audio 单例，而是两条元素轮流当「活动元素」：
   *   audio    —— 当前活动元素。进度、歌词、暂停、拖动、上一首/下一首都作用在它身上。
   *   idleDeck —— 空闲元素，预载下一首；过渡时它是进场那条。
   * 过渡结束（Glide.commitIncoming）才交换两者，对外看到的仍然是同一个 Player。
   * 两条元素各自只会 createMediaElementSource 一次，见 beat.js 的 deckNodes。
   * ------------------------------------------------------------------ */
  function makeDeck() {
    const el = new Audio();
    el.preload = 'metadata';
    // 必须在设 src 之前设 crossOrigin：跨域音频没有 CORS 时，
    // Web Audio 的分析器会拿到全 0（画布/音频图被"污染"），节拍检测就废了。
    // 网易云 CDN 返回 Access-Control-Allow-Origin: *，所以这条路走得通。
    el.crossOrigin = 'anonymous';
    return el;
  }
  const deckA = makeDeck();
  const deckB = makeDeck();
  let audio = deckA;                 // 活动元素（外部读到的是它）
  let idleDeck = deckB;              // 空闲 / 预载 / 进场元素
  let prepareSeq = 0;                // 预载代次：自动预取和实验室试听撞车时，只保留最后一次

  /* ------------------------------------------------------------------ *
   * 后台影子元素（第 13 轮第 1 件：切到别的软件音乐还继续放）
   *
   * 根因（第 12 轮只修了回前台恢复，后台本身没做事）：全部声音都走 Beat 的
   * Web Audio 图（createMediaElementSource → gain → busIn → analyser →
   * destination），iOS 切后台会把页面的 AudioContext 挂起，图一停就静音。
   * 关键约束：createMediaElementSource 对同一个 <audio> 只能调一次，调过之
   * 后元素的声音就永远走图、再也回不去直出——所以“后台把 deck 从图上摘下来
   * 让它直出”这条路不存在（摘了就是静音）。唯一可行的办法是换一条从来没进
   * 过图的元素在后台接着放：
   *   bgAudio —— 永不进 Beat 图的影子元素。切后台瞬间把活动 deck 的
   *   src/进度/音量接过来继续播（系统直出 + audio 后台模式保活）；回前台
   *   再把进度接回 deck、经图继续播。节拍分析/均衡/交叉淡化只在前台跑，
   *   后台只保“声音不断 + 进度不丢”，图和两条 deck 原样不动。
   * 注意：bgAudio 不设 crossOrigin——直出不需要 CORS，设了反而会让不回
   * ACAO 的 CDN 在后台播不出；也不走 Beat，节拍时钟在后台本来就是停的。
   * ------------------------------------------------------------------ */
  const bgAudio = new Audio();
  bgAudio.preload = 'auto';      // 第 14 轮第 12 件：影子要预热缓冲，切后台时直接起播不顿
  let bgActive = false;        // 后台影子元素正在接管出声
  let bgBlobUrl = null;        // bg 正在放的 blob URL（演示音），换 src 时才 revoke
  let wantResume = false;      // 切后台/被中断时在播 → 回来/中断结束要续播
  let userPaused = false;      // 用户亲手点的暂停（锁屏/按钮）：回来也不许自动续

  /** 当前真正在出声的元素：后台是影子，前台是活动 deck。 */
  function sounding() { return bgActive ? bgAudio : audio; }

  /** 把影子指向某条地址（+ 起始进度）。blob 换掉时才 revoke 旧的——
   *  revokeDeckBlob 那边会跳过 bg 正在用的 blob，两边不会互相拆台。 */
  function retargetBg(url, startTime) {
    if (!url) return;
    if (bgBlobUrl && bgBlobUrl !== url) {
      try { URL.revokeObjectURL(bgBlobUrl); } catch { /* ignore */ }
      bgBlobUrl = null;
    }
    if (String(url).startsWith('blob:')) bgBlobUrl = url;
    try {
      if (bgAudio.src !== url) bgAudio.src = url;
      if (startTime > 0) {
        if (bgAudio.readyState >= 1) { try { bgAudio.currentTime = startTime; } catch { /* ignore */ } }
        else bgAudio.addEventListener('loadedmetadata', () => {
          try { bgAudio.currentTime = startTime; } catch { /* ignore */ }
        }, { once: true });
      }
    } catch { /* ignore */ }
  }

  /* 影子元素自己的事件：只在接管期间对外报状态（前台 deck 的事件不动）。
     播/停/进度/播完都和 deck 的 bindDeck 同款语义，app.js / 锁屏 / 岛收到的
     还是同一套 playstate/time，听不出后台换过元素。 */
  bgAudio.addEventListener('play', () => {
    if (!bgActive) return;
    state.playing = true;
    emit('playstate', true);
  });
  bgAudio.addEventListener('pause', () => {
    if (!bgActive) return;
    state.playing = false;
    emit('playstate', false);
  });
  bgAudio.addEventListener('timeupdate', () => {
    if (!bgActive) return;
    emit('time', { cur: bgAudio.currentTime, total: bgAudio.duration || 0 });
  });
  bgAudio.addEventListener('ended', () => {
    if (!bgActive) return;
    /* 和 deck 的 ended 同款规则：单曲循环就地重播，否则下一首。
       load() 是后台感知的（见下），下一首直接在影子上起播。 */
    if (window.Glide && window.Glide.isTransitioning && window.Glide.isTransitioning()) return;
    if (state.mode === 'single') { bgAudio.currentTime = 0; bgAudio.play().catch(() => {}); }
    else next(true);
  });
  bgAudio.addEventListener('error', () => {
    if (!bgActive) return;
    /* 这条地址前台刚播得好好的、后台突然报错，基本是网络抖一下：
       原地 reload 重试一次；还不行就停在原地等回前台——回前台时
       exitBackground 会把 deck 接到影子断掉的位置，deck 那边的 error
       重试链（代理兜底 → 下一档 → 演示音）自然接手，不在这里另起一套。 */
    postDiagAudio(`后台影子播放失败：code=${bgAudio.error ? bgAudio.error.code : 0} src=${bgAudio.src ? 'set' : 'empty'}`);
    try { bgAudio.load(); bgAudio.play().catch(() => {}); } catch { /* ignore */ }
  });

  /** 切后台：影子接管。deck 原地暂停（图停了它本来也出不了声），影子从
   *  同一进度直出续播。影子起不来（play 被拒）就原样退回：deck 不动，
   *  回前台走老路 resume，至少不比第 12 轮差。 */
  async function enterBackground() {
    if (bgActive) return;
    if (userPaused) { wantResume = false; return; }
    if (audio.paused || !audio.src) { wantResume = false; return; }
    wantResume = true;
    const url = audio.src;
    const t = audio.currentTime || 0;
    try { bgAudio.volume = audio.volume; bgAudio.muted = audio.muted; } catch { /* ignore */ }
    retargetBg(url, t);
    try {
      /* 第 14 轮第 12 件：影子已预热（readyState>=1）时，play 前按 deck
         最新进度再对一次表——retargetBg 用的 t 是读早了的旧值，deck 在
         影子缓冲那一下里还在往前走，旧 t 起播就是「往回跳约 1 秒」。 */
      if (bgAudio.readyState >= 1) { try { bgAudio.currentTime = audio.currentTime || 0; } catch { /* ignore */ } }
      await bgAudio.play();
    } catch {
      /* 影子没起来：不碰 deck（它还在“播着但静音”的状态，回来能接上），
         接管标记不立，回前台按前台逻辑续。 */
      return;
    }
    bgActive = true;
    try { audio.pause(); } catch { /* ignore */ }
    try { idleDeck.pause(); } catch { /* ignore */ }
    state.playing = true;
    emit('playstate', true);
  }

  /** 回前台：把进度接回 deck、经图继续播。deck 起不来就退回影子续播，
   *  不留静音。调用方不用 await（事件处理里直接调）。 */
  async function exitBackground() {
    if (!bgActive) return false;
    const t = bgAudio.currentTime || 0;
    const wasPlaying = !bgAudio.paused && !userPaused;
    const src = bgAudio.src;
    bgActive = false;               // 先翻回 deck，影子的 pause 事件就不会再动状态
    try { bgAudio.pause(); } catch { /* ignore */ }
    try { audio.volume = bgAudio.volume; audio.muted = bgAudio.muted; } catch { /* ignore */ }
    const startDeck = async () => {
      try { if (audio.readyState >= 1) audio.currentTime = t; } catch { /* ignore */ }
      if (wasPlaying || wantResume) {
        try { await audio.play(); } catch { /* deck 起不来：下面兜底回影子 */ }
      }
      try { Beat.resume(); } catch { /* ignore */ }
      if (audio.paused && (wasPlaying || wantResume) && src) {
        /* deck 还是没起来（手势/解码问题）：影子顶回去，别静音。 */
        bgActive = true;
        retargetBg(src, t);
        try { await bgAudio.play(); } catch { bgActive = false; }
      }
      wantResume = false;
    };
    if (!src || audio.src === src) {
      if (audio.readyState >= 1) await startDeck();
      else {
        await new Promise((resolve) => {
          let done = false;
          const fin = () => { if (!done) { done = true; resolve(); } };
          const to = setTimeout(() => { startDeck().finally(fin); }, 1500);
          audio.addEventListener('loadedmetadata', () => {
            clearTimeout(to);
            startDeck().finally(fin);
          }, { once: true });
          try { audio.load(); } catch { clearTimeout(to); fin(); }
        });
      }
    } else {
      /* 后台换过歌：deck 的 src 是旧歌（load 只换了影子那份除外——
         实际上 load 会同时写 deck，这里只是兜底），先换 src 再接进度。 */
      try { audio.src = src; } catch { /* ignore */ }
      await new Promise((resolve) => {
        let done = false;
        const fin = () => { if (!done) { done = true; resolve(); } };
        const to = setTimeout(() => { startDeck().finally(fin); }, 1500);
        audio.addEventListener('loadedmetadata', () => {
          clearTimeout(to);
          startDeck().finally(fin);
        }, { once: true });
      });
    }
    return true;
  }

  /* ------------------------------------------------------------------ *
   * 会员判定（第 13 轮第 5 件取链 + 第 7 件标识，共用，唯一定义）
   *
   * 用户 06:43 定死的二选一：只有「已登录 AND 有会员」才走平台官方优先；
   * 没登录、登录过期、登录了但没会员，全部走 LX 自定义音源。
   * “有会员”只认服务端 status 回来的字段，不猜、不读界面文案：
   *   netease：/api/session → profile.vipType > 0（黑胶 VIP）
   *   kugou：  /api/kugou/status → vip === true（vip_type > 0）
   *   qq：     /api/qq/status 没有 vip 字段 → 永远判不到会员
   *            （QQ 的 GetLoginUserInfo 也没把绿钻带出来；有字段了再接）
   *   kuwo：   /api/kuwo/status 写死 vip:false → 永远判不到会员
   *   qishui/bodian：status 没有 vip 概念 → 永远判不到会员
   *   spotify：/api/spotify/status → product === 'premium' 才算
   *   （Spotify 已下线、LX 也不支持它，这里只给标识用）
   * 到期时间：没有任何一家 status 回到期字段，所以标识不显示到期时间，
   *   不是漏了，是服务端没给。
   * accounts.js 的 normStatus 调的就是这个函数（见 hall/accounts.js），
   *   大厅个人卡 / 设置页账号行的标识和取链走同一套判定，不会两边对不上。
   * ------------------------------------------------------------------ */
  function membershipFromStatus(src, st) {
    if (!st || !st.loggedIn) return false;
    if (src === 'netease') {
      const p = st.profile || {};
      return (typeof p.vipType === 'number' ? p.vipType > 0 : !!p.vipType) || st.vip === true;
    }
    if (src === 'spotify') return st.product === 'premium';
    return st.vip === true;
  }
  try {
    window.__liziMembershipFromStatus = membershipFromStatus;
    window.PlayerMembershipFromStatus = membershipFromStatus;
  } catch { /* ignore */ }

  /* 会员状态缓存：每家 5 分钟。取链时只问当家那一家，不全量拉；
     状态接口是本机服务 + 一次上游校验，冷启动也控制在 2 秒内（超时就按
     “没会员”走 LX——LX 失败还会回落官方，不会把歌播死）。 */
  const MEMBER_TTL_MS = 5 * 60 * 1000;
  const MEMBER_TIMEOUT_MS = 2000;
  const memberCache = new Map();   // src → { at, member }
  function clearMembershipCache() { memberCache.clear(); }
  try { window.__liziClearMembershipCache = clearMembershipCache; } catch { /* ignore */ }
  async function fetchMembership(src) {
    const now = Date.now();
    const hit = memberCache.get(src);
    if (hit && now - hit.at < MEMBER_TTL_MS) return hit.member;
    let member = false;
    try {
      const st = await Promise.race([
        (async () => {
          if (src === 'netease') return API.session();
          if (src === 'qq') return API.qqStatus();
          return API.srcStatus(src);
        })(),
        new Promise((res) => setTimeout(() => res(null), MEMBER_TIMEOUT_MS)),
      ]);
      member = membershipFromStatus(src, st);
    } catch { member = false; }
    memberCache.set(src, { at: now, member });
    return member;
  }
  /* 预热：播放器建好就后台把五家的会员态都问一遍（不阻塞），用户点播放时
     缓存基本已经是热的，取链不用等状态接口。 */
  try {
    for (const s of ['netease', 'qq', 'kugou', 'kuwo', 'qishui']) fetchMembership(s).catch(() => {});
  } catch { /* ignore */ }

  const state = {
    queue: [],        // 当前曲目数组
    index: -1,        // 当前下标
    playing: false,
    fallbackRetried: false, // 取址后地址是死的时，只按优先级往下一档重试一次
    mode: 'order',    // order | single | shuffle
    lyric: [],        // [{ t, text, tr }]
    lyricIndex: -1,
    objectUrl: null,  // 演示音轨的 blob url，切换时要 revoke
    token: 0,         // 异步竞态令牌：快速切歌时丢弃过期回调
  };

  const listeners = {};
  const on = (evt, fn) => (listeners[evt] ||= []).push(fn);
  const emit = (evt, data) => (listeners[evt] || []).forEach((f) => { try { f(data); } catch (e) { console.warn('[player] listener failed:', evt, e); } });

  /* ------------------------------------------------------------------ *
   * 队列持久化
   *
   * 以前队列只在内存里：退出 / 刷新后 state.queue 是空的，大厅冷启动
   * 又只把「上次那首」塞回队列（app.js 的 playQueue([last])），于是
   * 下一首 / 上一首永远停在那一首上。这里把队列本身写进 localStorage，
   * 启动时恢复，但**不自动播放**（浏览器 / WebView 有自动播放限制，
   * 也尊重用户没点播放）。
   *
   * 只存曲目元数据：播放地址由 fetchTrackUrl 每次按 id 重新解析，
   * 所以网易云 / QQ 的临时直链过期不会把整个队列带坏。
   * ------------------------------------------------------------------ */
  const QUEUE_KEY = 'lizi.queue.v1';
  const QUEUE_VERSION = 1;
  const QUEUE_MODES = ['order', 'loop', 'single', 'shuffle'];

  /** 曲目的稳定身份：同 id 不同平台不能算同一首（酷我 / 网易云都是数字 id） */
  function trackIdentity(t) {
    if (!t || typeof t !== 'object') return '';
    const key = t.id != null ? t.id : (t.mid != null ? t.mid : t.hash);
    if (key == null || key === '') return '';
    return `${t.source || 'netease'}:${key}`;
  }

  /** 临时直链不落盘：恢复后 fetchTrackUrl 会按 id 重新取址 */
  function storableTrack(t) {
    const out = { ...t };
    delete out.url;
    delete out.audioUrl;
    delete out.playUrl;
    delete out.srcUrl;
    return out;
  }

  function saveQueue() {
    try {
      const q = state.queue;
      if (!Array.isArray(q) || !q.length) {
        localStorage.removeItem(QUEUE_KEY);
        return;
      }
      const cur = q[state.index];
      localStorage.setItem(QUEUE_KEY, JSON.stringify({
        v: QUEUE_VERSION,
        queue: q.map(storableTrack),
        index: state.index,
        mode: state.mode,
        current: trackIdentity(cur),
        at: Date.now(),
      }));
    } catch { /* 隐私模式 / 配额满：只影响下次启动 */ }
  }

  function restoreQueue() {
    let raw = null;
    try { raw = localStorage.getItem(QUEUE_KEY); } catch { return; }
    if (!raw) return;
    try {
      const data = JSON.parse(raw);
      if (!data || data.v !== QUEUE_VERSION || !Array.isArray(data.queue)) throw new Error('bad shape');
      /* 坏条目（缺 id / 不是对象）单独跳过，不能让一条脏数据废掉整个队列 */
      const q = data.queue.filter((t) => !!trackIdentity(t));
      if (!q.length) throw new Error('empty');
      let idx = Number.isInteger(data.index) ? data.index : 0;
      if (idx < 0 || idx >= q.length) idx = 0;
      /* 按当前曲目 id 再定位一次：过滤掉坏条目后下标可能已经漂了 */
      if (data.current) {
        const j = q.findIndex((t) => trackIdentity(t) === data.current);
        if (j >= 0) idx = j;
      }
      state.queue = q;
      state.index = idx;
      state.playing = false;                 // 恢复队列 ≠ 恢复播放
      if (QUEUE_MODES.includes(data.mode)) state.mode = data.mode;
    } catch {
      /* 旧版本 / 数据结构变了 / 存储损坏：静默清掉，不影响启动 */
      try { localStorage.removeItem(QUEUE_KEY); } catch { /* ignore */ }
    }
  }

  /* 演示音轨是 blob URL，按元素分开记：过渡期间两条 deck 可能各有一个。
     替换某条元素的 src 前必须先 revoke 它自己的旧 blob。 */
  const deckBlobs = new WeakMap();   // element → blob url
  function revokeDeckBlob(el) {
    const u = deckBlobs.get(el);
    if (!u) return;
    /* 影子正在放这条 blob（后台演示音）：revoke 会让影子当场断流，等它换歌
       时 retargetBg 自己会 revoke，这里跳过。 */
    if (u === bgBlobUrl) return;
    URL.revokeObjectURL(u);
    deckBlobs.delete(el);
    if (el === audio) state.objectUrl = null;
  }

  /** 交叉淡化用的 deck 增益。Beat 还没建图时返回 null，调用方要能接受。 */
  function setDeckGain(el, v) {
    try {
      const g = Beat.deckGain && Beat.deckGain(el);
      if (!g) return;
      g.gain.cancelScheduledValues(0);
      g.gain.value = v;
    } catch { /* 图还没建好就算了，下一次再设 */ }
  }

  function normalizeIndex(i) {
    return ((i % state.queue.length) + state.queue.length) % state.queue.length;
  }

  /** 用户手动操作（切歌/暂停/拖动）要先把进行中的过渡收掉，别让两条 deck 打架 */
  function cancelGlide(reason) {
    if (typeof window === 'undefined' || !window.Glide) return;
    try { window.Glide.cancel(reason); } catch { /* 过渡引擎自己的异常不能拦住播放 */ }
  }

  /* ------------------------------------------------------------------ *
   * 演示音轨：用 WebAudio 离线渲染一段和弦琶音，转成 wav blob
   * 只在拿不到真实播放地址时使用
   * ------------------------------------------------------------------ */
  /* 演示音缓存：seed -> Blob（同一首歌反复播不重新渲染；URL.createObjectURL
     每次新建，load() 里的 revokeDeckBlob 照常安全）。第 10 轮：旧同步版在主线程
     循环 882,000 采样 × 约 7 次 Math.sin，实测堵 395ms（手机上 1–3 秒），正好卡
     在「点卡→播」窗口的正前方；改异步离线渲染，不可用时回退同步版。 */
  const demoBlobCache = new Map();
  function encodeWav(float32, sr) {
    const n = float32.length, ab = new ArrayBuffer(44 + n * 2), dv = new DataView(ab);
    const wr = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
    wr(0, 'RIFF'); dv.setUint32(4, 36 + n * 2, true); wr(8, 'WAVE');
    wr(12, 'fmt '); dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
    dv.setUint32(24, sr, true); dv.setUint32(28, sr * 2, true); dv.setUint16(32, 2, true); dv.setUint16(34, 16, true);
    wr(36, 'data'); dv.setUint32(40, n * 2, true);
    for (let i = 0; i < n; i++) dv.setInt16(44 + i * 2, Math.max(-1, Math.min(1, float32[i])) * 32767, true);
    return new Blob([ab], { type: 'audio/wav' });
  }
  async function makeDemoTrackBlob(seconds = 40, seed = 1) {
    const key = `${seconds}:${seed >>> 0 || 1}`;
    if (demoBlobCache.has(key)) return demoBlobCache.get(key);
    const p = (async () => {
      const sr = 22050;
      const ctx = new OfflineAudioContext(1, Math.floor(sr * seconds), sr);
      const master = ctx.createGain();
      master.gain.setValueAtTime(0, 0);
      master.gain.linearRampToValueAtTime(1, 1.5);
      master.gain.setValueAtTime(1, Math.max(1.5, seconds - 2));
      master.gain.linearRampToValueAtTime(0, seconds);
      master.connect(ctx.destination);
      const chords = [[220, 261.63, 329.63], [174.61, 220, 261.63], [196, 246.94, 293.66], [164.81, 207.65, 246.94]];
      const bars = Math.ceil(seconds / 2);
      for (let b = 0; b < bars; b++) {
        const chord = chords[b % chords.length];
        const t0 = b * 2, t1 = Math.min(seconds, t0 + 2);
        for (const f of chord) {
          for (const [freq, g] of [[f, 0.13], [f * 1.004, 0.07]]) {
            const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.value = freq;
            const gn = ctx.createGain(); gn.gain.value = g;
            o.connect(gn); gn.connect(master); o.start(t0); o.stop(t1);
          }
        }
        for (let s = 0; s < 4; s++) {
          const t = t0 + s * 0.5; if (t >= seconds) break;
          const note = chord[s % chord.length] * 2;
          const o = ctx.createOscillator(); o.type = 'sine'; o.frequency.value = note;
          const gn = ctx.createGain();
          gn.gain.setValueAtTime(0.18, t);
          gn.gain.exponentialRampToValueAtTime(0.001, Math.min(seconds, t + 0.5));
          o.connect(gn); gn.connect(master); o.start(t); o.stop(Math.min(seconds, t + 0.5));
        }
      }
      // 空气感噪声：种子与旧同步版同一 LCG（seed 是 16 进制 hash 字符串时 >>> 0 得 0 → 1，与旧行为一致）
      let st = seed >>> 0 || 1;
      const rnd = () => ((st = (st * 1664525 + 1013904223) >>> 0) / 4294967296);
      const nbuf = ctx.createBuffer(1, sr, sr);
      const ch = nbuf.getChannelData(0);
      for (let i = 0; i < sr; i++) ch[i] = (rnd() - 0.5) * 2;
      const ns = ctx.createBufferSource(); ns.buffer = nbuf; ns.loop = true;
      const ng = ctx.createGain(); ng.gain.value = 0.003;
      ns.connect(ng); ng.connect(master); ns.start(0); ns.stop(seconds);
      const rendered = await ctx.startRendering();
      const blob = encodeWav(rendered.getChannelData(0), sr);
      if (demoBlobCache.size > 8) demoBlobCache.delete(demoBlobCache.keys().next().value);
      return blob;
    })().catch(() => null);
    demoBlobCache.set(key, p);
    return p;
  }
  // 旧同步实现（OfflineAudioContext 不可用时的回退）：返回值由 blob URL 改为 Float32Array，WAV 打包抽到 encodeWav。
  function makeDemoTrackSync(seconds = 40, seed = 1) {
    const sr = 22050;
    const n = Math.floor(sr * seconds);
    const buf = new Float32Array(n);

    // 用歌曲 id 当种子，不同的歌听起来不一样
    let s = seed >>> 0 || 1;
    const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);

    // 简单和弦进行（A 小调味道），每 2 秒换一次
    const chords = [[220, 261.63, 329.63], [174.61, 220, 261.63], [196, 246.94, 293.66], [164.81, 207.65, 246.94]];
    const barLen = 2;

    for (let i = 0; i < n; i++) {
      const t = i / sr;
      const bar = Math.floor(t / barLen) % chords.length;
      const chord = chords[bar];
      let v = 0;
      for (let k = 0; k < chord.length; k++) {
        v += Math.sin(2 * Math.PI * chord[k] * t) * 0.13;
        // 轻微失谐，听起来更像乐器而不是纯音
        v += Math.sin(2 * Math.PI * chord[k] * 1.004 * t) * 0.07;
      }
      // 每 0.5 秒一个琶音点缀
      const step = Math.floor(t / 0.5);
      const note = chord[step % chord.length] * 2;
      const env = Math.max(0, 1 - ((t % 0.5) / 0.5)) ** 3;
      v += Math.sin(2 * Math.PI * note * t) * 0.18 * env;

      // 整体包络：淡入淡出，避免爆音
      const fade = Math.min(1, t / 1.5, (seconds - t) / 2);
      v *= Math.max(0, fade);
      // 加一点噪声当"空气感"
      v += (rnd() - 0.5) * 0.006;
      buf[i] = Math.max(-1, Math.min(1, v));
    }

    return buf;
  }
  // 对外签名由同步改异步：唯一调用点 fetchTrackUrl 已是 async，改一行 await 即可。
  async function makeDemoTrack(seconds = 40, seed = 1) {
    try {
      if (typeof OfflineAudioContext !== 'undefined') {
        const blob = await makeDemoTrackBlob(seconds, seed);
        if (blob) return URL.createObjectURL(blob);
      }
    } catch { /* 回退同步版 */ }
    return URL.createObjectURL(encodeWav(makeDemoTrackSync(seconds, seed), 22050));
  }

  /* ------------------------------------------------------------------ *
   * 从封面取色
   * 取色必须走 canvas，而网易云封面有防盗链（缺 CORS 头），
   * 直接用原图会污染 canvas、getImageData 抛 SecurityError。
   * 所以走自己的 /api/img 代理：同源，画布不会被污染。
   * ------------------------------------------------------------------ */
  const colorCache = new Map();
  const pendingPalette = new Map();
  const COLOR_SIDE = 32;

  /* ------------------------------------------------------------------ *
   * 封面取色（2026-11-08 起全站统一用「OKLCH 聚类 k=4」）
   *
   * 和 color-lab.html 的 C 算法逐行一致：
   *   1. 32×32 采样，丢掉低透明度和纯白高光；
   *   2. 所有有效像素转成真实 OKLCH（不是 RGB 欧氏距离）；
   *   3. k=4，初始中心按明度四分位给；最多迭代 10 次；
   *   4. 4 个中心按明度排好，沿折线均匀取 5 档；
   *   5. 墨色按中间三档的平均相对亮度选深/浅场。
   *
   * 旧版 30° 色相桶 + RGB 平均色已经删掉。三条取色结果（行渐变 / 播放页 /
   * 大厅铺色）必须来自同一张封面、同一次聚类，才能保证转场不变色。
   * ------------------------------------------------------------------ */
  const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
  const normHue = (h) => ((h % 360) + 360) % 360;
  const hueDelta = (a, b) => ((a - b + 540) % 360) - 180;

  const srgbToLin = (c) => {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  const linToSrgb = (c) => (c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);

  const rgbToHex = (rgb) =>
    '#' + rgb.map((v) => Math.round(clamp(v, 0, 255)).toString(16).padStart(2, '0')).join('');
  const hexToRgb = (hex) => {
    const h = String(hex || '').replace('#', '').trim();
    const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
    if (!/^[0-9a-f]{6}$/i.test(full)) return [0, 0, 0];
    return [parseInt(full.slice(0, 2), 16), parseInt(full.slice(2, 4), 16), parseInt(full.slice(4, 6), 16)];
  };

  /** 真实 OKLab/OKLCH 转换（标准矩阵）。纯转换，不夹明度/彩度。 */
  function rgbToOklch(rgb) {
    const r = srgbToLin(rgb[0]);
    const g = srgbToLin(rgb[1]);
    const b = srgbToLin(rgb[2]);
    const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
    const l_ = Math.cbrt(l);
    const m_ = Math.cbrt(m);
    const s_ = Math.cbrt(s);
    const L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    const A = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    const B = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    const C = Math.sqrt(A * A + B * B);
    const H = C > 1e-7 ? normHue((Math.atan2(B, A) * 180) / Math.PI) : 0;
    return { L, C, H };
  }

  function oklchToRgbRaw(L, C, H) {
    const hr = (H * Math.PI) / 180;
    const A = C * Math.cos(hr);
    const B = C * Math.sin(hr);
    const l_ = L + 0.3963377774 * A + 0.2158037573 * B;
    const m_ = L - 0.1055613458 * A - 0.0638541728 * B;
    const s_ = L - 0.0894841775 * A - 1.2914855480 * B;
    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;
    const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    return [linToSrgb(r), linToSrgb(g), linToSrgb(b)];
  }

  const inGamut = (rgb) =>
    rgb[0] >= -0.0006 && rgb[0] <= 1.0006 &&
    rgb[1] >= -0.0006 && rgb[1] <= 1.0006 &&
    rgb[2] >= -0.0006 && rgb[2] <= 1.0006;

  /** OKLCH -> #hex。超出 sRGB 色域只降彩度（二分），不粗暴截断 RGB。 */
  function oklchToHex(L, C, H) {
    L = clamp(L, 0, 1);
    C = Math.max(0, C);
    H = normHue(H);
    let c = C;
    if (!inGamut(oklchToRgbRaw(L, c, H))) {
      let lo = 0;
      let hi = C;
      for (let i = 0; i < 16; i++) {
        const mid = (lo + hi) / 2;
        if (inGamut(oklchToRgbRaw(L, mid, H))) lo = mid;
        else hi = mid;
      }
      c = lo;
    }
    return rgbToHex(oklchToRgbRaw(L, c, H).map((v) => v * 255));
  }

  const relLum = (rgb) => {
    const r = srgbToLin(rgb[0]);
    const g = srgbToLin(rgb[1]);
    const b = srgbToLin(rgb[2]);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (a, b) => {
    const la = relLum(a);
    const lb = relLum(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
  };

  /** OKLCH 距离：明度 + 彩度 + 加权色相差。 */
  function oklchDist(a, b) {
    const dL = a.L - b.L;
    const dC = a.C - b.C;
    const dh = (hueDelta(a.H, b.H) * Math.PI) / 180;
    const dH = 2 * Math.sqrt(Math.max(a.C, 0) * Math.max(b.C, 0)) * Math.sin(dh / 2);
    return dL * dL + dC * dC + dH * dH;
  }

  /** 簇中心：L/C 算术平均，色相按彩度加权走圆周平均。 */
  function centroidOf(points) {
    if (!points.length) return { L: 0.5, C: 0, H: 0 };
    let L = 0;
    let C = 0;
    let sin = 0;
    let cos = 0;
    for (const p of points) {
      const o = p.ok;
      L += o.L;
      C += o.C;
      const w = Math.max(o.C, 0.0001);
      sin += Math.sin((o.H * Math.PI) / 180) * w;
      cos += Math.cos((o.H * Math.PI) / 180) * w;
    }
    return {
      L: L / points.length,
      C: C / points.length,
      H: C > 1e-6 ? normHue((Math.atan2(sin, cos) * 180) / Math.PI) : 0,
    };
  }

  /** 4 个中心按明度排好后，沿折线均匀取 count 档。 */
  function rampFromCenters(centers, count = 5) {
    const cs = centers.slice().sort((a, b) => a.L - b.L);
    if (!cs.length) {
      return Array.from({ length: count }, (_, i) => ({ L: 0.2 + i * 0.17, C: 0.08, H: 0 }));
    }
    if (cs.length === 1) {
      const c = cs[0];
      return Array.from({ length: count }, (_, i) => {
        const t = i / (count - 1);
        return {
          L: clamp(c.L + (t - 0.5) * 0.34, 0.03, 0.97),
          C: c.C * (0.55 + 0.45 * Math.sin(Math.PI * t)),
          H: c.H,
        };
      });
    }
    const out = [];
    for (let i = 0; i < count; i++) {
      const t = i / (count - 1);
      const pos = t * (cs.length - 1);
      const seg = Math.min(cs.length - 2, Math.floor(pos));
      const f = pos - seg;
      const a = cs[seg];
      const b = cs[seg + 1];
      out.push({
        L: a.L + (b.L - a.L) * f,
        C: a.C + (b.C - a.C) * f,
        H: normHue(a.H + hueDelta(b.H, a.H) * f),
      });
    }
    return out;
  }

  const stopsFromRamp = (ramp) => ramp.map((c) => oklchToHex(c.L, c.C, c.H));

  /** 墨色跟明暗方案走：深场白字，亮场深字；对比不足再退到纯黑/纯白。 */
  function pickInk(stops) {
    const rgbStops = stops.map(hexToRgb);
    const fieldLum =
      (relLum(rgbStops[1]) + relLum(rgbStops[2]) + relLum(rgbStops[3])) / 3;
    const field = fieldLum < 0.30 ? 'dark' : 'light';
    let ink = field === 'dark' ? '#F7F7FA' : '#121216';
    const c = contrast(hexToRgb(ink), rgbStops[2]);
    if (c < 3.0) ink = field === 'dark' ? '#FFFFFF' : '#08080A';
    // 2026-11-08：额外带出 fieldLum，铺色面板要按实际亮度分档决定白字/深字
    return { ink, field, fieldLum };
  }

  /** 一组 RGB 色（兼容旧 rememberColors 调用）摊成完整色板。 */
  function paletteFromColors(colors) {
    const ok = colors.slice(0, 3).map(rgbToOklch);
    const stops = stopsFromRamp(rampFromCenters(ok, 5));
    const inkInfo = pickInk(stops);
    const rgbStops = stops.map(hexToRgb);
    return {
      stops,
      ink: inkInfo.ink,
      field: inkInfo.field,
      // 2026-11-08：透传 fieldLum 供铺色面板判断中亮底白字
      fieldLum: inkInfo.fieldLum,
      main: rgbToHex(colors[0] || [138, 138, 138]),
      mainPct: 100,
      accent: rgbToHex(colors[0] || [138, 138, 138]),
      colors: colors.slice(0, 3).map((c) => c.slice(0, 3)),
    };
  }

  /**
   * 像素 -> 完整色板。
   * 返回 { stops[5], ink, field, main, mainPct, accent, colors[3] }。
   * colors 取 5 档里的 [2]、[3]、[4]（中间到亮端）——
   * 深端两档在播放页背景上容易接近纯黑，三色接口只给能看见的层次。
   */
  function paletteFromData(data, side) {
    const pts = [];
    let ar = 0, ag = 0, ab = 0, an = 0;
    for (let i = 0; i < data.length; i += 4) {
      const r = data[i], g = data[i + 1], b = data[i + 2], a = data[i + 3];
      if (a < 200) continue;
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b);
      const l = (mx + mn) / 2;
      if (l > 246) continue;               // 纯白高光没有色彩信息
      ar += r; ag += g; ab += b; an++;
      pts.push({ r, g, b, ok: rgbToOklch([r, g, b]) });
    }

    // 全空（透明 / 纯白）也必须给出可用的 5 档，绝不能把 null 抛给大厅。
    const avg = an ? [ar / an, ag / an, ab / an] : [96, 116, 190];
    if (!pts.length) {
      const stops = stopsFromRamp(rampFromCenters([rgbToOklch(avg)], 5));
      const inkInfo = pickInk(stops);
      const rgbStops = stops.map(hexToRgb);
      return {
        stops,
        ink: inkInfo.ink,
        field: inkInfo.field,
        // 2026-11-08：透传 fieldLum 供铺色面板判断中亮底白字
        fieldLum: inkInfo.fieldLum,
        main: rgbToHex(avg),
        mainPct: 100,
        accent: rgbToHex(avg),
        colors: [rgbStops[2], rgbStops[3], rgbStops[4]],
        fallback: true,
      };
    }

    const k = 4;
    const sorted = pts.slice().sort((a, b) => a.ok.L - b.ok.L);
    const initial = [];
    for (let i = 0; i < k; i++) {
      const start = Math.floor((i * sorted.length) / k);
      const end = Math.floor(((i + 1) * sorted.length) / k);
      initial.push(centroidOf(sorted.slice(start, Math.max(start + 1, end))));
    }

    let centers = initial;
    let groups = [];
    let assigns = [];
    for (let iter = 0; iter < 10; iter++) {
      groups = Array.from({ length: k }, () => []);
      const nextAssign = new Array(pts.length);
      let changed = false;
      for (let i = 0; i < pts.length; i++) {
        let best = 0;
        let bestD = Infinity;
        for (let j = 0; j < k; j++) {
          const d = oklchDist(pts[i].ok, centers[j]);
          if (d < bestD) { bestD = d; best = j; }
        }
        nextAssign[i] = best;
        if (assigns[i] !== best) changed = true;
        groups[best].push(pts[i]);
      }
      assigns = nextAssign;
      centers = groups.map((g, j) => (g.length ? centroidOf(g) : centers[j]));
      if (!changed) break;
    }

    const clusters = centers.map((c, i) => ({
      ...c,
      n: groups[i].length,
      pct: (groups[i].length / an) * 100,
      score: groups[i].length * Math.max(c.C, 0.005),
    }));
    const main = clusters.slice().sort((a, b) => b.score - a.score)[0];
    const mainHex = main ? oklchToHex(main.L, main.C, main.H) : '#8a8a8a';
    const stops = stopsFromRamp(rampFromCenters(centers, 5));
    const inkInfo = pickInk(stops);
    const rgbStops = stops.map(hexToRgb);

    return {
      stops,
      ink: inkInfo.ink,
      field: inkInfo.field,
      // 2026-11-08：透传 fieldLum 供铺色面板判断中亮底白字
      fieldLum: inkInfo.fieldLum,
      main: mainHex,
      mainPct: main ? main.pct : 100,
      accent: mainHex,
      colors: [rgbStops[2], rgbStops[3], rgbStops[4]],
    };
  }

  function analyzeImage(img) {
    const n = COLOR_SIDE;
    const cv = document.createElement('canvas');
    cv.width = cv.height = n;
    const ctx = cv.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(img, 0, 0, n, n);
    return paletteFromData(ctx.getImageData(0, 0, n, n).data, n);
  }

  /** 已经加载好的图片直接取色（不再发一次请求）。返回 3 个 RGB 数组。 */
  function colorsFromImage(img) {
    try {
      return analyzeImage(img).colors;
    } catch {
      return null;   // 跨域或解码失败都不能影响列表
    }
  }

  const cachedPalette = (entry) => {
    if (!entry) return null;
    return Array.isArray(entry) ? paletteFromColors(entry) : entry;
  };

  /** 把完整色板（或旧的 3 色数组）塞进缓存，键就是图片 URL。
   *  同一个 URL 的 3 色接口和 5 档接口都从这里读，保证是一次聚类的结果。 */
  function rememberColors(url, palette) {
    if (!url || !palette) return;
    colorCache.set(url, Array.isArray(palette) ? paletteFromColors(palette) : palette);
  }

  function loadPalette(url) {
    if (pendingPalette.has(url)) return pendingPalette.get(url);
    const p = new Promise((resolve) => {
      const img = new Image();
      img.crossOrigin = 'anonymous';
      img.onload = () => {
        try {
          const pal = analyzeImage(img);
          colorCache.set(url, pal);
          resolve(pal);
        } catch {
          resolve(null);   // 取色失败就让 CSS 用默认色，不能影响播放
        }
      };
      img.onerror = () => resolve(null);
      img.src = url;
    }).finally(() => pendingPalette.delete(url));
    pendingPalette.set(url, p);
    return p;
  }

  /** 3 色兼容接口：返回 [RGB, RGB, RGB]，来自 stops[2]/[3]/[4]。 */
  function extractColors(url) {
    if (!url) return Promise.resolve(null);
    const cached = colorCache.get(url);
    if (cached) {
      const pal = cachedPalette(cached);
      return Promise.resolve(pal ? pal.colors : null);
    }
    return loadPalette(url).then((pal) => (pal ? pal.colors : null));
  }

  /**
   * 完整色板接口。
   *   paletteFromCover(URL)      -> Promise<{stops, ink, field, main, mainPct, ...}>
   *   paletteFromCover(已加载 img, 别名URL) -> 同步返回同一个对象（失败返回 null）
   * 大厅海报的图已经解码好，走同步分支；队列封面只有 URL，走异步分支。
   * 别名 URL 是同一张封面的另一档尺寸（例如播放页的 400px）：已经有缓存就直接用，
   * 保证大厅海报和播放页拿到的是**同一次聚类**，而不是 1200px/400px 各算一遍。
   */
  function paletteFromCover(input, aliasUrl) {
    if (typeof input === 'string') {
      const cached = colorCache.get(input);
      if (cached) return Promise.resolve(cachedPalette(cached));
      return loadPalette(input);
    }
    const img = input;
    const url = img && (img.currentSrc || img.src) || '';
    if (aliasUrl) {
      const aliasCached = colorCache.get(aliasUrl);
      if (aliasCached) return cachedPalette(aliasCached);
    }
    if (url) {
      const cached = colorCache.get(url);
      if (cached) return cachedPalette(cached);
    }
    try {
      const pal = analyzeImage(img);
      if (url) colorCache.set(url, pal);
      if (aliasUrl) colorCache.set(aliasUrl, pal);
      return pal;
    } catch {
      return null;
    }
  }

  /* ------------------------------------------------------------------ *
   * BPM：优先用网易云百科的元数据，拿不到再靠实时检测
   *
   * 网易云的常规歌曲接口**没有** BPM 字段（v3/song/detail 的全部键逐个看过），
   * 只有「歌曲百科」这个接口有：/song/play/about/block/page 的
   * SONG_PLAY_ABOUT_SONG_BASIC block 里 creativeType === 'bpm' 那条。
   * 匿名就能用，实测覆盖 9/9，而且没有实时检测的倍速歧义
   * （《自由的你》百科写 84，检测报 169 = 2×84）。
   *
   * 所以分工是：元数据给**速度**，实时检测给**相位** ——
   * 跟拍效果必须知道"第一拍落在哪"，光有速度不够。
   * 结果按歌曲 id 缓存进 localStorage，重播瞬间就有，不用再等检测收敛。
   * ------------------------------------------------------------------ */
  const BPM_CACHE_KEY = 'bpmCache';

  const readBpmCache = () => {
    try { return JSON.parse(localStorage.getItem(BPM_CACHE_KEY) || '{}'); } catch { return {}; }
  };
  function writeBpmCache(id, bpm) {
    try {
      const c = readBpmCache();
      c[id] = bpm;
      // 只留最近 300 首，别把 localStorage 撑爆
      const keys = Object.keys(c);
      if (keys.length > 300) for (const k of keys.slice(0, keys.length - 300)) delete c[k];
      localStorage.setItem(BPM_CACHE_KEY, JSON.stringify(c));
    } catch { /* 隐私模式下写不了，忽略 */ }
  }

  async function applyWikiBpm(track, token) {
    const cached = readBpmCache()[track.id];
    if (cached) {
      Beat.lockTempo(cached, 'metadata');
      emit('bpmsource', { bpm: cached, source: 'metadata', cached: true });
      return cached;
    }
    try {
      const w = await API.songWiki(track.id);
      if (token !== state.token) return null;      // 期间又切歌了，丢弃
      if (w.bpm) {
        writeBpmCache(track.id, w.bpm);
        Beat.lockTempo(w.bpm, 'metadata');
        emit('bpmsource', { bpm: w.bpm, source: 'metadata', language: w.language, tags: w.tags || [] });
        return w.bpm;
      }
    } catch { /* 拿不到就走检测 */ }
    emit('bpmsource', { bpm: null, source: 'detected' });
    return null;
  }

  /* ------------------------------------------------------------------ *
   * 歌词解析
   *
   * 两种格式：
   *   LRC —— 每行一个时间戳：[00:12.34]今天我 寒夜里看雪飘
   *   YRC —— 逐字，行首是 [整行起点,整行时长]，每个字后面跟 (字起点,字时长)：
   *            [12000,3000](12000,500,0)今(12500,500,0)天(13000,500,0)…
   *
   * 返回统一结构，每行：{ t, text, tr, chars? }
   *   chars 存在即表示这行有逐字时间，每项 { c, t, d }。
   * ------------------------------------------------------------------ */

  /** 解析 YRC 一行 → { t, dur, text, chars }（时间统一转成秒） */
  function parseYrcLine(line) {
    const head = line.match(/^\[(\d+),(\d+)\]/);
    if (!head) return null;
    const lineStart = +head[1];
    const lineDur = +head[2];
    const rest = line.slice(head[0].length);

    // 字与时间：(起点毫秒,时长毫秒,0)字
    const chars = [];
    const re = /\((\d+),(\d+),\d+\)([^()]*)/g;
    let m;
    while ((m = re.exec(rest))) {
      const text = m[3];
      // 全部换算成秒，和 LRC 的时间轴保持同一单位
      if (text) chars.push({ c: text, t: +m[1] / 1000, d: +m[2] / 1000 });
    }
    const text = chars.map((c) => c.c).join('').trim();
    if (!text) return null;
    return { t: lineStart / 1000, dur: lineDur / 1000, text, chars };
  }

  /** 解析普通 LRC（一行可能有多个时间戳） */
  function parseLrcLines(lrc, trMap) {
    const out = [];
    for (const line of lrc.split('\n')) {
      const stamps = [...line.matchAll(/\[(\d+):(\d+(?:[.:]\d+)?)\]/g)];
      if (!stamps.length) continue;
      const text = line.replace(/\[[^\]]*\]/g, '').trim();
      if (!text) continue;
      for (const m of stamps) {
        const key = `${+m[1]}:${parseFloat(m[2].replace(':', '.'))}`;
        out.push({ t: +m[1] * 60 + parseFloat(m[2].replace(':', '.')), text, tr: trMap.get(key) || '' });
      }
    }
    return out;
  }

  /** 翻译映射表：时间戳 → 译文 */
  function buildTrMap(tlyric) {
    const map = new Map();
    if (!tlyric) return map;
    for (const line of tlyric.split('\n')) {
      const m = line.match(/^\[(\d+):(\d+(?:[.:]\d+)?)\](.*)$/);
      if (m) map.set(`${+m[1]}:${parseFloat(m[2].replace(':', '.'))}`, m[3].trim());
    }
    return map;
  }

  /**
   * 统一入口：优先用 YRC（逐字），没有就退回 LRC。
   * @returns {{ lines: Array, format: 'yrc'|'lrc'|'none' }}
   */
  function parseLyrics({ lyric, yrc, tlyric, ytlrc }) {
    const trMap = buildTrMap(tlyric || ytlrc);

    if (yrc) {
      const lines = [];
      for (const raw of yrc.split('\n')) {
        const o = parseYrcLine(raw);
        if (!o) continue;
        // 逐字行的翻译：翻译表是按 [mm:ss.xx] 建的，用同一套 key 去找
        const total = Math.round(o.t * 100) / 100;
        const mm = Math.floor(total / 60);
        const ss = total - mm * 60;
        o.tr = trMap.get(`${mm}:${ss}`) || trMap.get(`${mm}:${ss.toFixed(2)}`) || '';
        lines.push(o);
      }
      if (lines.length) {
        lines.sort((a, b) => a.t - b.t);
        return { lines, format: 'yrc' };
      }
    }

    if (lyric) {
      const lines = parseLrcLines(lyric, trMap);
      if (lines.length) return { lines, format: 'lrc' };
    }
    return { lines: [], format: 'none' };
  }

  /** 兼容旧签名（只传 lrc 字符串） */
  function parseLRC(lrc, tlyric) {
    return parseLyrics({ lyric: lrc, tlyric }).lines;
  }

  /* ------------------------------------------------------------------ *
   * 解析播放地址
   *
   * 原 load() 里的取址逻辑原样搬出来：正常切歌和「预载下一首」都走这里，
   * 保证两条路径对 QQ / 边车 / 演示音轨的判断完全一致，不各写一套。
   * ------------------------------------------------------------------ */
  /* 音质（第 13 轮第 12 件，用户 2026-11-19 07:24/07:25/07:29 定）：
     用户选的档位是唯一事实来源（window.LIZI_QUALITY，EQ 引擎维护、
     localStorage 持久化，默认无损），不按账号会员卡档。qualityFor 把用户
     档位翻译成各平台上游的真实参数；平台没有该档时取该平台不高于请求档
     的最高档（天花板规则，与汽水/酷我/LX 既有的降级逻辑一致）。
     臻品三档是 QQ 的版本命名：2.0=Hi-Res、3.0=全景声、4.0=母带。
     DTS:X 六个平台 + LX 都没有对应的上游流，EQ 页不提供该档，这里也不映射。 */
  const QUALITY_MAP = {
    netease: { standard: 'standard', higher: 'higher', exhigh: 'exhigh', lossless: 'lossless', hires: 'hires', dolby: 'dolby', sky: 'sky', jymaster: 'jymaster' },
    qq: { standard: '128', higher: '128', exhigh: '320', lossless: 'flac', hires: 'hires', dolby: 'atmos51', sky: 'atmos20', jymaster: 'master' },
    kugou: { standard: '128', higher: '128', exhigh: '320', lossless: 'flac', hires: 'hires', dolby: 'flac', sky: 'flac', jymaster: 'flac' },
    kuwo: { standard: '128', higher: '128', exhigh: '320', lossless: 'flac', hires: 'hires', dolby: 'flac', sky: 'flac', jymaster: 'flac' },
    /* Apple Music（第 13 轮第 24 件）：公开 API 只有 30 秒试听（128k AAC），
       选什么档都只能拿到 standard；整首要原生 MusicKit 播放器，不在本轮。 */
    applemusic: { standard: 'standard', higher: 'standard', exhigh: 'standard', lossless: 'standard', hires: 'standard', dolby: 'standard', sky: 'standard', jymaster: 'standard' },
    qishui: { standard: 'standard', higher: 'standard', exhigh: 'high', lossless: 'lossless', hires: 'hires', dolby: 'hires', sky: 'hires', jymaster: 'hires' },
    bodian: { standard: 'standard', higher: 'standard', exhigh: 'high', lossless: 'lossless', hires: 'lossless', dolby: 'lossless', sky: 'lossless', jymaster: 'lossless' },
    lx: { standard: '128k', higher: '128k', exhigh: '320k', lossless: 'flac24bit', hires: 'hires', dolby: 'atmos', sky: 'atmos', jymaster: 'master' },
  };
  const userQuality = () => (typeof window !== 'undefined' && window.LIZI_QUALITY) || 'lossless';
  const qualityFor = (src) => {
    const map = QUALITY_MAP[src] || QUALITY_MAP.netease;
    return map[userQuality()] || map.lossless;
  };
  /* 各平台服务端回的实际档位值 → 统一档位 id（播放条与 EQ 页只显示这个，
     不显示请求档）。网易 level 本身就是档位 id；其余平台回平台自己的档位名。 */
  const QUALITY_LABEL = { standard: '标准', higher: '较高', exhigh: '极高', lossless: '无损', hires: '臻品音质 2.0', dolby: '杜比全景声', sky: '臻品全景声 3.0', jymaster: '臻品母带 4.0' };
  const canonQuality = (src, served, br) => {
    const map = {
      netease: { standard: 'standard', higher: 'higher', exhigh: 'exhigh', lossless: 'lossless', hires: 'hires', dolby: 'dolby', sky: 'sky', jymaster: 'jymaster' },
      qq: { master: 'jymaster', atmos51: 'dolby', atmos20: 'sky', hires: 'hires', flac: 'lossless', ape: 'lossless', '320': 'exhigh', '128': 'standard', m4a: 'standard' },
      kugou: { hires: 'hires', flac: 'lossless', '320': 'exhigh', '128': 'standard' },
      kuwo: { '4000': 'hires', '2000': 'lossless', '320': 'exhigh', '128': 'standard', web: 'standard' },
      qishui: { hires: 'hires', lossless: 'lossless', high: 'exhigh', standard: 'standard' },
      bodian: { lossless: 'lossless', high: 'exhigh', standard: 'standard' },
      lx: { master: 'jymaster', atmos: 'dolby', hires: 'hires', flac24bit: 'lossless', '320k': 'exhigh', '128k': 'standard' },
    }[src] || {};
    let tier = map[String(served || '')] || '';
    if (!tier && br) {
      tier = br >= 800000 ? 'lossless' : br >= 300000 ? 'exhigh' : br >= 180000 ? 'higher' : 'standard';
    }
    return tier;
  };
  const qualityLabelOf = (tier) => QUALITY_LABEL[tier] || tier || '';
  try { window.__liziQualityFor = qualityFor; } catch { /* ignore */ }   // 第 13 轮第 12 件：EQ 页重查路按取链同款参数拿档位

  async function fetchTrackUrl(track, opts = {}) {
    /* 非网易云的曲目（QQ / 酷狗 / 汽水 / 波点 / Spotify）：id 和直链都在各自边车上。
       这里只做分支，具体形状由 api.js 抹平（srcLyric / srcSongUrl / srcAudio）。 */
    const src = track.source || 'netease';
    const isQQ = src === 'qq';
    const isOther = !isQQ && src !== 'netease';
    let url = null;
    let proxyUrl = null;   // 第 12 轮：直链失败后的兜底地址（同一条升级后的地址走本机代理）
    let directUrl = null;  // 第 12 轮：实际交给 audio.src 的直链（已升 https）
    let demo = false;
    let reason = '';
    let preview = false;
    let lxQuality = '';
    let qualityTier = '';  // 第 13 轮第 12 件：上游实际回的档位（统一档位 id），播放条/EQ 页只显示它
    let qualityBr = 0;     // 实际码率（bps），有就显示
    let clipStartMs = 0;
    // via：这条地址从哪来（platform / cloud / lx / local / demo）。播放器拿它决定：
    // 地址进了播放器才失败时，按优先级往下一档重试一次；演示音不再兜圈。
    let via = '';

    /* 本地文件：地址就是本机 /api/local/file，不走 LX、不走平台接口。 */
    if (src === 'local') {
      return { url: API.localFile(track.id), demo: false, reason: '', preview: false, clipStartMs: 0, lxQuality: '', qualityTier: '', qualityLabel: '', qualityBr: 0, via: 'local' };
    }

    /* 第 14 轮诊断：取链开始记一步 —— 之前只有「播放开始」（play() resolve
       之后）和失败日志，崩在取链中途时最后一步对不上。预载下一首也走这里，
       记的是那首的 id；只记平台/id，不记地址/密钥。 */
    postDiagAudio(`取链开始：source=${src} id=${track.id ?? track.mid ?? track.hash ?? ''}`);

    /* 落雪取链（第 13 轮第 5 件抽出来的腿，主路/兜底两处共用同一份）：
       下面按会员态决定它排第几：没会员先跑它（拿整首），有会员后跑它
       （平台拿不到才兜底）。成功时保留平台那档失败的 reason（不清空）——
       万一 LX 地址进了播放器才死，兜底演示音的角标才能说清真正原因。 */
    const tryLX = async () => {
      if (opts.skipLX) return;
      if (src !== 'netease' && src !== 'qq' && src !== 'kugou' && src !== 'kuwo' && src !== 'qishui') return;
      try {
        const lx = await API.lxSongUrl(track, qualityFor('lx'));
        if (lx && lx.url) {
          directUrl = API.lxAudio(lx.url);
          url = directUrl;
          proxyUrl = API.proxyAudio('lx', lx.url);
          lxQuality = lx.quality || '';
          qualityTier = canonQuality('lx', lx.quality);
          preview = false;
          via = 'lx';
        } else if (lx && lx.code !== 0 && lx.code !== undefined) {
          postDiagAudio(`LX 取链失败：source=${src} id=${track.id ?? track.mid ?? track.hash ?? ''} code=${lx.code} ${lx.error || ''}`);
        }
      } catch (e) {
        postDiagAudio(`LX 取链异常：source=${src} id=${track.id ?? track.mid ?? track.hash ?? ''} ${String((e && e.message) || e)}`);
      }
    };

    /* 取链顺序（第 13 轮第 5 件，用户 06:43 定死的二选一）：
       有会员（已登录 AND 有 VIP 信号）→ 平台官方 → 云盘 → LX → 演示音
       （第 7 轮的顺序，原样不动）；
       没会员（没登录 / 登录了但没会员 / 状态取不到）→ LX 先 → 平台 → 云盘
       → 演示音。LX 先是为了拿整首：没会员时官方常只给 30 秒试听（preview），
       先走平台就把整首歌降级成试听了；LX 拿不到再回官方——但只接免费歌的
       整首地址，VIP 歌的试听地址直接拒掉（第 13 轮第 11 件：不放试听片段），
       再拿不到走原有兜底，绝不直接死掉。
       波点 / Spotify：LX 不支持它们，永远走老顺序；本地文件上面已直接返回。 */
    const lxFirst = !opts.skipLX
      && (src === 'netease' || src === 'qq' || src === 'kugou' || src === 'kuwo' || src === 'qishui')
      && !(await fetchMembership(src));
    if (lxFirst) await tryLX();
    if (lxFirst && url) postDiagAudio(`没会员走 LX 优先：source=${src} id=${track.id ?? track.mid ?? track.hash ?? ''} via=lx quality=${lxQuality || ''}`);

    /* 取链顺序（2026-11-18 第 7 轮第 8 件：平台官方 → 已登录账号的个人云盘 →
       落雪自定义源兜底 → 演示音；推翻 2026-11-17 的「落雪优先、平台备用」）：
       平台先试，拿不到才往下走；每一档只在上一档明确拿不到地址时才跑，
       这样平台有地址的歌绝不会被 LX / 云盘抢走，也不会多花一次请求。
       opts.skipPlatform / skipCloud / skipLX：播放中重试时用——已证实是死的
       那一档直接跳过，从下一档开始试。 */
    if (!url && !opts.skipPlatform) try {
      if (isQQ) {
        /* 第 12 轮：直接播。QQ 直链（aqqmusic / ws.stream）真文件回 ACAO:*，
           crossOrigin 直链走得通；代理只留作直链失败后的兜底。 */
        const d = await API.qqSongUrl(track.mid || track.id, qualityFor('qq'));
        if (d.url) {
          directUrl = API.qqAudio(d.url);
          url = directUrl;
          proxyUrl = API.proxyAudio('qq', d.url);
          preview = !!d.preview;
          qualityTier = canonQuality('qq', d.quality);
        } else {
          reason = d.reason === 'login' ? 'vip' : 'qq-unavailable';
        }
      } else if (isOther) {
        /* 第 12 轮：直接播（见上）。reason 原样从服务端来（login / region /
           drm / unavailable），界面据此说清楚「为什么没声音」，绝不用假音轨冒充。 */
        const d = await API.srcSongUrl(track, qualityFor(src));
        if (d && d.url) {
          directUrl = API.srcAudio(src, d.url);
          url = directUrl;
          proxyUrl = API.proxyAudio(src, d.url);
          preview = !!d.preview;
          clipStartMs = d.clipStartMs || 0;
          qualityTier = canonQuality(src, d.quality);
        } else {
          reason = (d && d.reason) || 'unavailable';
        }
      } else {
        const d = await API.songUrl(track.id, qualityFor('netease'));
        const item = (d.data || [])[0];
        // 第 13 轮第 11 件：没会员时官方给的常是试听地址（freeTrialInfo 非空，
        // 服务端 normalize("song/url") 已透传，见 NetEase.swift:537）。
        // 试听绝不能当整首放：lxFirst（没会员、LX 已先跑过且没拿到）时拒掉
        // 试听地址，往下走云盘/演示音；免费歌（freeTrialInfo 为空）照常放官方。
        // 有会员时官方本来就给整首，freeTrialInfo 不会出现。
        const isTrial = !!(item && item.freeTrialInfo);
        if (item?.url && !(lxFirst && isTrial)) {
          directUrl = API.neteaseAudio(item.url);
          url = directUrl;
          proxyUrl = API.proxyAudio('netease', item.url);
          preview = isTrial;
          qualityTier = canonQuality('netease', item.level, item.br);
          qualityBr = item.br || 0;
        }
        // code -110 = 未授权。绝大多数是 VIP 专属（fee=1），登录后就能播。
        // 把这个原因带出去，界面才能告诉用户"为什么放不了"，而不是默默放演示音。
        else if (item?.code === -110) reason = 'vip';
        else if (lxFirst && isTrial) {
          reason = 'vip';
          postDiagAudio(`网易试听已拒：id=${track.id}（没会员、LX 没拿到，试听片段不放，走云盘/演示音）`);
        }
        else reason = 'unavailable';
      }
      if (url) via = 'platform';
    } catch { reason = 'network'; }

    /* 个人云盘（只接网易「我的云盘」：QQ / 酷狗 / 酷我没有同等的个人云盘
       取链口，见 fetchCloudUrl 注释）：平台拿不到地址、且已登录时才试，
       按歌名 + 歌手在云盘里找这首歌，命中后用云盘 songId 再调一次
       /song/url 取可播地址。没登录直接跳过，不弹登录、不报错。 */
    if (!url && !opts.skipCloud && src === 'netease') {
      const cloud = await fetchCloudUrl(track);
      if (cloud && cloud.url) {
        url = cloud.url;
        directUrl = cloud.url;
        proxyUrl = cloud.proxyUrl || null;
        via = 'cloud';
        reason = '';
      }
    }

    /* 落雪兜底（有会员时才走到这里；没会员时上面已经先跑过 tryLX，失败了
       才轮到平台/云盘，这里不再重复跑）。波点没有 LX 解析，不接。 */
    if (!url && !lxFirst) await tryLX();

    if (!url) {
      demo = true;
      url = await makeDemoTrack(40, track.id);
      postDiagAudio(`取链均失败，走演示音：source=${src} id=${track.id ?? track.mid ?? track.hash ?? ''} reason=${reason || 'unavailable'} via=演示音`);
    }
    return { url, demo, reason, preview, clipStartMs, lxQuality, qualityTier, qualityLabel: qualityLabelOf(qualityTier), qualityBr, via: demo ? 'demo' : via, directUrl, proxyUrl };
  }

  /* ------------------------------------------------------------------ *
   * 个人云盘（网易「我的云盘」）
   *
   * 为什么只接网易：QQ 音乐没有个人云盘上传/取链功能；酷狗的云盘
   * （cloudlist.service.*）在代码库里只有歌单读写，没有「列出我上传
   * 的歌 + 取可播地址」的口；酷我 / 汽水 / 波点 / Spotify 同样没有。
   * 所以云盘这一档只对 src === 'netease' 生效，其它平台跳过。
   *
   * 匹配：云盘歌有独立 songId。先按 track.id 精确匹配（用户上传的
   * 就是这首歌时 id 一致）；再按「歌名 + 歌手」归一化匹配（上传的
   * 文件和曲库 id 不同是最常见的情况）。归一化去大小写 / 空白 /
   * 标点 / 括号后缀，歌手只比第一位。
   * 缓存：云盘列表按会话缓存 10 分钟（登录态 + 列表一起刷），平台
   * 失败的歌不会每首拉一次全量列表；翻页最多 5 页（1000 首）。
   * 超时：不新设——列表和取链都走 api.js 的 60 秒上限，不收短。
   * ------------------------------------------------------------------ */
  let cloudCache = { at: 0, loggedIn: false, songs: [] };
  const CLOUD_CACHE_TTL_MS = 10 * 60 * 1000;
  const CLOUD_MAX_PAGES = 5;
  const CLOUD_PAGE_SIZE = 200;
  const normCloudKey = (s) => String(s || '').toLowerCase()
    .replace(/[\s\-_·•()（）【】\[\]{}'"“”‘’.,，。、!！?？:：;；|/\\]+/g, '');
  function cloudArtistKey(track) {
    const a = track.artists;
    const first = Array.isArray(a) ? (a[0] && (a[0].name || a[0])) : String(a || '').split('/')[0];
    return normCloudKey(first);
  }
  function findCloudSong(track) {
    const tid = track.id;
    if (tid != null && tid !== '') {
      const byId = cloudCache.songs.find((c) => String(c.songId) === String(tid));
      if (byId) return byId;
    }
    const nameKey = normCloudKey(track.name);
    if (!nameKey) return null;
    const artistKey = cloudArtistKey(track);
    return cloudCache.songs.find((c) => {
      if (normCloudKey(c.name) !== nameKey) return false;
      if (!artistKey) return true;
      const ca = normCloudKey(c.artists);
      return !ca || ca.includes(artistKey) || artistKey.includes(ca);
    }) || null;
  }
  async function fetchCloudUrl(track) {
    const now = Date.now();
    if (now - cloudCache.at > CLOUD_CACHE_TTL_MS) {
      let loggedIn = false;
      try { const s = await API.session(); loggedIn = !!(s && s.loggedIn); } catch { loggedIn = false; }
      let songs = [];
      if (loggedIn) {
        // 未登录不拉列表；列表按页翻到底（最多 5 页），某一页失败就停，
        // 用已拿到的页继续匹配，别因为翻页失败把整档废掉。
        for (let page = 0; page < CLOUD_MAX_PAGES; page++) {
          let d = null;
          try { d = await API.neteaseCloud(CLOUD_PAGE_SIZE, page * CLOUD_PAGE_SIZE); } catch { break; }
          if (!d) break;
          const rows = Array.isArray(d.songs) ? d.songs
            : (Array.isArray(d.data) ? d.data.map((c) => ({
              songId: c.songId, name: c.songName || c.name,
              artists: c.artist || c.artists || '', album: c.album || c.albumName || '',
            })) : []);
          songs.push(...rows);
          if (!d.hasMore || rows.length < CLOUD_PAGE_SIZE) break;
        }
      }
      cloudCache = { at: now, loggedIn, songs };
    }
    if (!cloudCache.loggedIn) return null;   // 没登录：跳过这一档，不弹登录
    if (!cloudCache.songs.length) return null;
    const hit = findCloudSong(track);
    if (!hit) {
      postDiagAudio(`云盘无匹配，走落雪：source=netease id=${track.id ?? ''} name=${track.name || ''} via=云盘`);
      return null;
    }
    try {
      const d = await API.songUrl(hit.songId);
      const item = (d.data || [])[0];
      if (item && item.url) {
        postDiagAudio(`云盘取链成功：source=netease id=${track.id ?? ''} cloudSongId=${hit.songId} via=云盘`);
        return { url: API.neteaseAudio(item.url), proxyUrl: API.proxyAudio('netease', item.url), cloudSongId: hit.songId };
      }
      postDiagAudio(`云盘取链失败：source=netease id=${track.id ?? ''} cloudSongId=${hit.songId} code=${item ? item.code : ''} via=云盘`);
    } catch (e) {
      postDiagAudio(`云盘取链异常：source=netease id=${track.id ?? ''} cloudSongId=${hit.songId} ${String((e && e.message) || e)}`);
    }
    return null;
  }

  /* 取址后地址进了播放器才发现是死的（代理 502/403、解码失败）时，
     按优先级往下一档重试一次：fetchTrackUrl 只在取址前按「平台 → 云盘 →
     LX」降级，取址后失败原来是死路，只能显示「播放失败」。每首只重试一次，
     且只在用户还没切歌时才换源；手势拦截（NotAllowedError）不重试。
     skip 掉的档 = 取址时已经给过地址、播放失败的那一档（以及它之前
     明确拿不到地址的档）；LX 是最后一档，LX 地址死了没有下一档可试，
     第 11 轮第 8 件起改放演示音（fallbackToDemo），不再直接报 sourceerror
     卡住 —— 取链失败走演示音、播放失败也走演示音，兜底才算走通。 */
  async function retryWithFallback(track, token) {
    if (!track || token !== state.token || state.fallbackRetried) return false;
    const via = (state.lastFetch && state.lastFetch.via) || '';
    if (via !== 'platform' && via !== 'cloud') return false;   // lx/demo/local：没下一档可试
    state.fallbackRetried = true;
    const skips = via === 'platform'
      ? { skipPlatform: true }
      : { skipPlatform: true, skipCloud: true };
    let data;
    try {
      data = await fetchTrackUrl(track, skips);
    } catch { return false; }
    if (token !== state.token || !data || !data.url || data.demo) return false;
    revokeDeckBlob(audio);
    audio.preload = 'metadata';
    audio.src = data.url;
    state.lastFetch = { via: data.via, track, token, reason: data.reason, directUrl: data.directUrl, proxyUrl: data.proxyUrl };
    state.proxyTried = false;
    emit('source', { demo: data.demo, track, reason: data.reason, preview: data.preview, clipStartMs: data.clipStartMs, lxQuality: data.lxQuality, qualityTier: data.qualityTier || '', qualityLabel: data.qualityLabel || '', qualityBr: data.qualityBr || 0 });
    try {
      await audio.play();
      Beat.resume();
      Beat.start();
      state.playing = true;
      emit('playstate', true);
      return true;
    } catch {
      state.playing = false;
      emit('playstate', false);
      return false;
    }
  }

  /* 直链进了播放器才死时，先走同一条地址的代理兜底一次（第 12 轮）：
     直链失败可能是 CDN 临时抽风 / CORS 抖动，代理同源、无 CORS 问题，
     常能救回来；代理也死了再按原逻辑往下一档 / 演示音。每首只试一次
     （state.proxyTried，load / retry / commit 落点时清零），且只在用户
     还没切歌时才换源。via 不改：代理再失败时 error 事件按原 via 走
     下一档 / 演示音，不丢重试链。 */
  async function tryProxyFallback(track, token) {
    const lf = state.lastFetch;
    if (!track || token !== state.token || !lf || lf.token !== token) return false;
    if (!lf.proxyUrl || state.proxyTried) return false;
    if (lf.via !== 'platform' && lf.via !== 'cloud' && lf.via !== 'lx') return false;
    state.proxyTried = true;
    postDiagAudio(`直链播放失败，走代理兜底：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${lf.via}`);
    revokeDeckBlob(audio);
    audio.preload = 'metadata';
    audio.src = lf.proxyUrl;
    try {
      await audio.play();
      Beat.resume();
      Beat.start();
      state.playing = true;
      emit('playstate', true);
      return true;
    } catch {
      state.playing = false;
      emit('playstate', false);
      return false;
    }
  }

  /* LX 地址进了播放器才死时的最后一档：第 11 轮第 8 件。
     取链阶段 LX 失败会走演示音（fetchTrackUrl 末尾），但播放阶段
     （代理 502/403、解码失败）原来直接报 sourceerror 卡住 ——
     用户看到的就是「播不出、也不出声」。这里改放演示音：界面照常
     走完（歌词、进度、演示音轨角标），角标 reason 沿用平台那档失败的
     原因（vip/无版权等），用户才知道为什么不是真歌。
     同步占位 state.fallbackRetried：error 事件和 load() 里 play() 的
     catch 可能同时触发，只放一次演示音；演示音本身再报错不循环。 */
  async function fallbackToDemo(track, token, reason) {
    if (!track || token !== state.token || state.fallbackRetried) return false;
    state.fallbackRetried = true;
    try {
      const url = await makeDemoTrack(40, track.id);
      if (token !== state.token) { URL.revokeObjectURL(url); return false; }
      revokeDeckBlob(audio);
      deckBlobs.set(audio, url);
      state.objectUrl = url;
      audio.preload = 'metadata';
      audio.src = url;
      state.lastFetch = { via: 'demo', track, token, reason };
      emit('source', { demo: true, track, reason, preview: false, clipStartMs: 0, lxQuality: '', qualityTier: '', qualityLabel: '', qualityBr: 0 });
      await audio.play();
      Beat.resume();
      Beat.start();
      state.playing = true;
      emit('playstate', true);
      postDiagAudio(`落雪地址播放失败，已改放演示音：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} reason=${reason || 'unavailable'}`);
      return true;
    } catch {
      state.playing = false;
      emit('playstate', false);
      return false;
    }
  }

  /** 诊断上报（与 B 专员约定的接口）：POST /api/diag/log {category:"audio", message}。
   *  B 的路由还没好时服务端回 404，前端 fire-and-forget、静默吞掉，绝不能影响播放。
   *  message 只含 MediaError 码 / 上游 host / 状态机 / 原因码，不带直链 query（vkey 之类不进日志）。
   *  第 15 轮第 6 件：加一次重试 + sendBeacon 兜底 + 计数对账。
   *  旧版 fire-and-forget 无重试、无队列：服务端没收到时诊断直接丢，
   *  下次报告分不清“没发”还是“没收到”。计数挂 window.__liziDiagCounts，
   *  服务端 /api/diag/search 回 diagLogReceived，两边对账。 */
  const __diagCounts = { sent: 0, acked: 0, failed: 0 };
  window.__liziDiagCounts = () => ({ ...__diagCounts });
  function postDiagAudio(message) {
    const payload = JSON.stringify({ category: 'audio', message: String(message || '').slice(0, 500) });
    const sendOnce = () => {
      __diagCounts.sent += 1;
      return fetch('/api/diag/log', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: payload,
        keepalive: true,
      });
    };
    try {
      sendOnce().then((res) => {
        if (res && res.ok) { __diagCounts.acked += 1; return; }
        throw new Error('HTTP ' + (res && res.status));
      }).catch(() => {
        // 一次重试（300ms 后）；还失败就改 sendBeacon（页面卸载时也能发）。
        setTimeout(() => {
          sendOnce().then((res) => {
            if (res && res.ok) { __diagCounts.acked += 1; return; }
            throw new Error('retry HTTP ' + (res && res.status));
          }).catch(() => {
            __diagCounts.failed += 1;
            try {
              if (navigator.sendBeacon) {
                const blob = new Blob([payload], { type: 'application/json' });
                if (navigator.sendBeacon('/api/diag/log', blob)) __diagCounts.sent += 1;
              }
            } catch { /* 诊断不上报不能影响播放 */ }
          });
        }, 300);
      });
    } catch { /* 诊断不上报不能影响播放 */ }
  }

  /** 第 16 轮第 3 件：关键播放步骤直通原生面包屑（liziDiag 桥）。
   *  postDiagAudio 走 HTTP POST，内容进程在 POST 落地前死掉这一步就丢
   *  （19:16 五次 url=OK 后零 JS 日志）；postMessage 是直通 App 进程的
   *  IPC，原生收到立刻文件落盘，死也不丢。只用于播放启动链上的关键步骤
   *  （取链返回 / play() 调用 / 播放开始 / 超时 / 被拒 / 播放失败），
   *  不替代 postDiagAudio（诊断页的 logs 仍走 POST）。桥不在时静默跳过。 */
  function postNativeStep(step) {
    try {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.liziDiag;
      if (h) h.postMessage(String(step || '').slice(0, 200));
    } catch { /* 桥不在也不影响播放 */ }
  }

  /** 第 15 轮第 5 件：play() 8–10 秒超时——直链字符串 OK 不等于媒体字节能到，
   *  CDN stall 时 play() 既不 resolve 也不 reject；超时按播放失败走兜底链，
   *  不再静默等死。返回原 play() 的 promise，超时抛 {name:'PlayTimeoutError'}。 */
  function playWithTimeout(el, ms = 9000) {
    let timer = null;
    const timeoutP = new Promise((_, reject) => {
      timer = setTimeout(() => {
        const e = new Error('play() timeout after ' + ms + 'ms');
        e.name = 'PlayTimeoutError';
        reject(e);
      }, ms);
    });
    return Promise.race([el.play(), timeoutP]).then(
      (v) => { clearTimeout(timer); return v; },
      (e) => { clearTimeout(timer); throw e; },
    );
  }

  /** <audio> 报错时的真实原因（原来 sourceerror 只发 {}，界面除了「播放失败」
   *  什么都说不出来，诊断日志也看不到）：MediaError 码 + 上游 host +
   *  networkState/readyState。host 只取域名，不带 query（vkey 之类不进日志）。 */
  function audioErrorDetail(el) {
    let host = '';
    try { host = new URL(el.src).host; } catch { /* blob: 地址没有 host */ }
    const e = el.error;
    return {
      code: e ? e.code : 0,
      message: e ? (e.message || '') : '',
      host,
      networkState: el.networkState,
      readyState: el.readyState,
    };
  }

  /** 拉当前这首的歌词并推给订阅者（startTrackMeta 与 reloadLyrics 共用）。
   *  歌词先拉，别等音频（QQ 认 songmid，其它边车认自己的 id）。
   *  本地文件没有在线歌词：不发请求（否则会打到 /api/local/lyric 再被转走），歌词区保持空白。 */
  function fetchLyricsFor(track, token) {
    const src = track.source || 'netease';
    const isQQ = src === 'qq';
    const isOther = !isQQ && src !== 'netease';
    const lyricReq = src === 'local' ? null : (isQQ
      ? API.qqLyric(track.mid || track.id)
      : isOther
        ? API.srcLyric(track)
        : API.lyric(track.id));
    if (lyricReq) lyricReq
      .then((d) => {
        if (token !== state.token) return;
        const { lines, format } = parseLyrics(d);
        state.lyric = lines;
        state.lyricFormat = format;
        emit('lyric', { lines, active: -1, format });
      })
      .catch(() => {});
  }

  /** 换歌时统一的元数据入口：trackchange + 清空歌词 + 异步拉歌词 / BPM。
   *  正常切歌和交叉淡化落点（commitIncoming）共用，避免两边显示的歌词不同步。 */
  function startTrackMeta(track, index, token) {
    const src = track.source || 'netease';

    emit('trackchange', { track, index });
    // 第 15 轮第 2 件：切歌时把标题/歌手写进 MediaSession metadata，
    // 系统按它画 Now Playing（否则只有命令、没有曲目信息时也可能回落）。
    try {
      if ('mediaSession' in navigator && navigator.mediaSession && typeof MediaMetadata !== 'undefined') {
        navigator.mediaSession.metadata = new MediaMetadata({
          title: track.name || '',
          artist: Array.isArray(track.artists) ? track.artists.map((a) => a.name || a).join(' / ') : (track.artists || ''),
          album: track.album || '',
        });
      }
    } catch { /* metadata 写不上也不拦着播 */ }
    state.lyric = [];
    state.lyricIndex = -1;
    emit('lyric', { lines: [], active: -1 });

    fetchLyricsFor(track, token);

    // BPM 元数据也并行拉：比等实时检测收敛快得多，而且没有倍速歧义
    // （只有网易云有百科接口；实时检测照常工作）
    if (src === 'netease') applyWikiBpm(track, token);
  }

  /* ------------------------------------------------------------------ *
   * 加载并播放某一首
   * ------------------------------------------------------------------ */
  async function load(i, autoplay = true) {
    cancelGlide('load');                 // 手动切歌/重载：先把进行中的过渡收掉
    if (!state.queue.length) return;
    /* 第 13 轮第 1 件补：显式起播（点歌/切歌/自动下一首）就是“用户要听”，
       清掉 userPaused——否则之前亲手暂停过一次，切后台时 enterBackground
       会以为用户还停着而拒绝接管，VM 1g 就是这么失败的。 */
    if (autoplay) userPaused = false;
    prepareSeq++;                        // 让还在路上的预载作废
    const token = ++state.token;
    state.index = normalizeIndex(i);
    saveQueue();                         // 下一首 / 上一首 / 点队列行都会走到这里
    const track = state.queue[state.index];

    // 空闲 deck 上如果还预载着下一首，先停掉；活动元素才是这次要换的
    try { idleDeck.pause(); } catch { /* 还没开始播 */ }
    setDeckGain(idleDeck, 0);
    setDeckGain(audio, 1);

    // 节拍检测：换歌时把节拍时钟归零。
    // 必须先 reset 再 startTrackMeta —— 百科 BPM 命中缓存时会在同步阶段 lockTempo，
    // 反过来会把刚锁上的速度清掉。
    Beat.reset();
    Beat.attach(audio);
    if (Beat.setClock) Beat.setClock(audio);

    startTrackMeta(track, state.index, token);

    const data = await fetchTrackUrl(track);

    // 第 16 轮第 3 件：取链返回记一步（之前只有取链开始和 play() resolve
    // 后的「播放开始」——崩在「地址已回、play() 未调」这段时分不清；
    // 只记 via，不记地址）。
    if (data.url && !data.demo) {
      postDiagAudio(`取链返回：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
      postNativeStep(`取链返回 source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
    }

    if (token !== state.token) {         // 期间又切歌了
      if (data.demo) URL.revokeObjectURL(data.url);
      // 第 15 轮第 5 件：token 抢占丢弃点记一条轻量诊断——连点/切歌时
      // 在途 load() 在取链返回后静默丢弃，旧日志里看不到这次丢弃。
      postDiagAudio(`取链返回后 token 已变，丢弃本次 load：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''}`);
      return;
    }

    revokeDeckBlob(audio);
    if (data.demo) { deckBlobs.set(audio, data.url); state.objectUrl = data.url; }
    // 记下这首的地址来源：error 事件里靠它判断要不要往下一档重试。
    // reason 一起记：LX 地址播放失败改放演示音时，角标要说清真正原因。
    // directUrl/proxyUrl 一起记：直链失败时 error 事件先试代理兜底（第 12 轮）。
    state.lastFetch = { via: data.via, track, token, reason: data.reason, directUrl: data.directUrl, proxyUrl: data.proxyUrl };
    state.fallbackRetried = false;
    state.proxyTried = false;

    audio.preload = 'metadata';
    audio.src = data.url;
    /* 后台切歌（影子播完/锁屏切歌）：deck 只留着 src 供回前台接，声音走影子。
       前台播：影子也同步指到同一条地址预热缓冲（只缓冲不播），切后台时
       enterBackground 不用等冷启动、无缓冲就能直出续播，顿一下 + 往回跳
       就是冷启动那 0.5–2 秒等出来的。第 14 轮第 12 件。 */
    retargetBg(data.url);
    emit('source', { demo: data.demo, track, reason: data.reason, preview: data.preview, clipStartMs: data.clipStartMs, lxQuality: data.lxQuality, qualityTier: data.qualityTier || '', qualityLabel: data.qualityLabel || '', qualityBr: data.qualityBr || 0 });

    if (autoplay) {
      try {
        // 第 16 轮第 3 件：play() 调用前记一步——「播放开始」只在 resolve
        // 后记，崩在 play() 里时最后一步还是取链返回，分不清有没有调 play()。
        postDiagAudio(`play() 调用：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
        postNativeStep(`play() 调用 source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
        await playWithTimeout(sounding());
        // 第 10 轮诊断：audio.play() 已 resolve，记下这首走的是哪一档。
        // 真机崩溃后看 /api/diag/search，能确认崩的那首是 platform 还是 demo。
        postDiagAudio(`播放开始：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via} demo=${data.demo}`);
        postNativeStep(`播放开始 source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via} demo=${data.demo}`);
        // 音频上下文要等用户手势后才能跑，放歌时顺手续上；后台影子出声不走图，不碰它。
        if (!bgActive) { Beat.resume(); Beat.start(); }
        state.playing = true;
        emit('playstate', true);
      } catch (e) {
        // 第 15 轮第 5 件：play() 超时 / reject 但 audio.error 为空时也留痕。
        // 旧逻辑全要求 audio.error 为真：AbortError（连点时 src 被改写）和
        // NotAllowedError 之外的静默分支在诊断里一行都没有；play() 永远
        // pending（CDN stall）时更是连 catch 都进不去——现在 9 秒超时
        // 兜底，超时按播放失败走同一条兜底链（代理 → 下一档 → 演示音）。
        const timedOut = !!(e && e.name === 'PlayTimeoutError');
        const errName = (e && e.name) || '';
        if (timedOut) {
          postDiagAudio(`播放开始超时：source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}（play() 9 秒未回，走兜底链）`);
          postNativeStep(`播放开始超时 source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
        } else if (e && errName !== 'NotAllowedError' && !audio.error) {
          postDiagAudio(`play() 被拒但 audio.error 为空：name=${errName} source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via}`);
          postNativeStep(`play() 被拒 source=${track.source || 'netease'} id=${track.id ?? track.mid ?? track.hash ?? ''} via=${data.via} name=${errName}`);
        }
        const failed = timedOut || !!audio.error;
        // 手势拦截（NotAllowedError）不是地址问题，不重试；地址问题（error 已挂上
        // 或 play() 超时）且是平台/云盘/LX 地址时，先走同一条地址的代理兜底一次（第 12 轮），
        // 代理也死了再按原逻辑往下一档 / 演示音。
        if (e && errName !== 'NotAllowedError' && failed && (data.via === 'platform' || data.via === 'cloud' || data.via === 'lx') && token === state.token) {
          const okProxy = await tryProxyFallback(track, token);
          if (okProxy) return { demo: data.demo };
        }
        if (e && errName !== 'NotAllowedError' && failed && (data.via === 'platform' || data.via === 'cloud') && token === state.token) {
          const ok = await retryWithFallback(track, token);
          if (ok) return { demo: data.demo };
        }
        // LX 地址在 play() 这一步就失败：同样改放演示音（和 error 事件同一入口，
        // fallbackToDemo 里有同步占位，两边同时触发也只放一次）。
        if (e && errName !== 'NotAllowedError' && failed && data.via === 'lx' && token === state.token) {
          const ok = await fallbackToDemo(track, token, data.reason || 'unavailable');
          if (ok) return { demo: true };
        }
        state.playing = false;
        emit('playstate', false);
      }
    }
    return { demo: data.demo };
  }

  /* ------------------------------------------------------------------ *
   * 交叉淡化（由 audio/glide.js 驱动）
   *
   * 职责分界：Player 管队列、地址解析、活动元素切换；Glide 管触发时机与增益曲线。
   * 预载只动 idleDeck，不改 state.index / 歌词，所以预载失败或用户切歌都不会串台。
   * ------------------------------------------------------------------ */

  /** 自动播放时下一首的下标；没有下一首返回 null。
   *  auto=true 时要和 ended → next(true) 的规则完全一致：
   *   单曲循环不交叉；顺序播放到队尾不凭空接歌；列表循环回到第一首；随机随便挑。 */
  function peekNext(auto = true) {
    const n = state.queue.length;
    if (!n) return null;
    if (auto && state.mode === 'single') return null;
    if (state.mode === 'shuffle') return Math.floor(Math.random() * n);
    if (state.index >= n - 1) {
      if (auto && state.mode === 'order') return null;
      return 0;
    }
    return state.index + 1;
  }

  /** 把第 i 首解析好并预载到空闲 deck（不播放、不改当前曲目）。
   *  返回的对象交给 commitIncoming；期间用户切歌会让 token 失配，自动作废。 */
  async function prepareIncoming(i) {
    if (!state.queue.length) return null;
    if (typeof Beat === 'undefined' || typeof Beat.attach !== 'function' || typeof Beat.deckGain !== 'function') return null;
    const token = state.token;
    const seq = ++prepareSeq;
    const index = normalizeIndex(i);
    const track = state.queue[index];
    const incoming = idleDeck;

    try { incoming.pause(); } catch { /* 正常，本来就没在播 */ }
    const data = await fetchTrackUrl(track);

    if (seq !== prepareSeq || token !== state.token || state.queue[index] !== track) {
      if (data.demo) URL.revokeObjectURL(data.url);
      return null;
    }

    revokeDeckBlob(incoming);
    incoming.preload = 'auto';           // 预取：离曲尾 fade+3s 就把数据拉起来
    incoming.src = data.url;
    if (data.demo) deckBlobs.set(incoming, data.url);
    try { incoming.load(); } catch { /* 老浏览器没有 load() 也能自动加载 */ }

    const ok = Beat.attach(incoming);
    if (!ok) { try { incoming.pause(); } catch { /* ignore */ } return null; }
    setDeckGain(incoming, 0);            // 先静音，等 Glide 调度淡入
    incoming.muted = audio.muted;
    incoming.volume = audio.volume;

    return { ...data, index, track, token, element: incoming };
  }

  /** 过渡结束时把活动元素换到进场 deck。
   *  之后 audio 指向新歌 —— 进度、歌词、暂停/拖动、上一首/下一首都作用在它上面。 */
  function commitIncoming(prepared) {
    if (!prepared || prepared.token !== state.token) return false;
    if (prepared.element !== idleDeck) return false;
    if (state.queue[prepared.index] !== prepared.track) return false;

    prepareSeq++;                        // 落点之后不允许别的预载再改这条元素
    const incoming = prepared.element;
    const outgoing = audio;
    audio = incoming;
    idleDeck = outgoing;
    state.index = prepared.index;
    saveQueue();                         // 交叉淡化落点也要记住当前曲目

    // 先 reset 再 startTrackMeta（理由同 load：缓存 BPM 会同步 lockTempo）
    Beat.reset();
    Beat.attach(audio);
    if (Beat.setClock) Beat.setClock(audio);
    setDeckGain(incoming, 1);
    setDeckGain(outgoing, 0);
    try { outgoing.pause(); } catch { /* 可能已经自然结束 */ }
    incoming.preload = 'metadata';

    const token = ++state.token;
    startTrackMeta(prepared.track, prepared.index, token);
    // 过渡落点也要记地址来源，否则这首的 error 事件认不出是哪一档的地址、重试走不到。
    state.lastFetch = { via: prepared.via, track: prepared.track, token, reason: prepared.reason, directUrl: prepared.directUrl, proxyUrl: prepared.proxyUrl };
    state.fallbackRetried = false;
    state.proxyTried = false;

    state.objectUrl = deckBlobs.get(incoming) || null;
    emit('source', {
      demo: prepared.demo, track: prepared.track, reason: prepared.reason,
      preview: prepared.preview, clipStartMs: prepared.clipStartMs, lxQuality: prepared.lxQuality,
      qualityTier: prepared.qualityTier || '', qualityLabel: prepared.qualityLabel || '', qualityBr: prepared.qualityBr || 0,
    });
    /* 后台正好淡入落点（前台起的过渡、切后台后才落点）：deck 换了但它是静音的，
       影子还在放旧歌——把影子指到新 deck 的地址/进度上续播，不跳歌不断流；
       前台落点原样不动。 */
    if (bgActive) {
      retargetBg(audio.src, audio.currentTime || 0);
      bgAudio.play().catch(() => {});
      state.playing = !bgAudio.paused;
    } else {
      state.playing = !audio.paused;
      if (state.playing) { Beat.resume(); Beat.start(); }
    }
    emit('playstate', state.playing);
    emit('time', { cur: sounding().currentTime, total: sounding().duration || 0 });
    return true;
  }

  /* ------------------------------------------------------------------ *
   * audio 事件
   * ------------------------------------------------------------------ */
  /* 两条 deck 都绑同一套事件，但只有「活动元素」的事件才对外。
     过渡期间进场元素也在播，它的 play/timeupdate 不能冒充当前曲目。 */
  function bindDeck(el) {
    el.addEventListener('play', () => {
      if (el !== audio) return;
      state.playing = true;
      Beat.resume();
      Beat.start();
      emit('playstate', true);
    });
    el.addEventListener('pause', () => {
      if (el !== audio) return;
      state.playing = false;
      Beat.stop();
      emit('playstate', false);
    });
    el.addEventListener('timeupdate', () => {
      if (el !== audio) return;
      emit('time', { cur: el.currentTime, total: el.duration || 0 });
    });
    el.addEventListener('loadedmetadata', () => {
      if (el !== audio) return;
      emit('time', { cur: el.currentTime, total: el.duration || 0 });
    });
    /* 第 15 轮第 5 件：补 stalled/suspend/waiting 监听——直链字符串 OK
       不等于媒体字节能到，CDN stall 时 play() 既不 resolve 也不 reject、
       error 事件也不触发；这三个事件是 stall 唯一的可见信号，各记一条诊断。 */
    for (const ev of ['stalled', 'suspend', 'waiting']) {
      el.addEventListener(ev, () => {
        if (el !== audio) return;
        const d = audioErrorDetail(el);
        postDiagAudio(`音频${ev}：code=${d.code} host=${d.host} ns=${d.networkState} rs=${d.readyState} via=${(state.lastFetch && state.lastFetch.via) || ''}`);
      });
    }
    el.addEventListener('progress', () => {
      if (el !== audio) return;
      try {
        if (el.buffered.length) emit('buffer', el.buffered.end(el.buffered.length - 1));
      } catch { /* ignore */ }
    });
    el.addEventListener('ended', () => {
      if (el !== audio) return;
      /* 过渡中出场曲自然结束是正常现象，真正的切歌在 Glide 的 commit 里；
         这里再 next() 会跳过进场曲。 */
      if (window.Glide && window.Glide.isTransitioning && window.Glide.isTransitioning()) return;
      if (state.mode === 'single') { el.currentTime = 0; el.play(); }
      else next(true);
    });
    el.addEventListener('error', async () => {
      if (el !== audio) return;
      if (!el.src) return;
      const detail = audioErrorDetail(el);
      // 直链播放失败：先走同一条地址的代理兜底一次（第 12 轮）；代理也死了
      // 再往下走原逻辑（LX → 演示音，平台/云盘 → 下一档）。proxyTried 置位后
      // 不会再进这条分支，不循环。
      if (state.lastFetch && (state.lastFetch.via === 'platform' || state.lastFetch.via === 'cloud' || state.lastFetch.via === 'lx') && state.lastFetch.token === state.token && !state.proxyTried && state.lastFetch.proxyUrl) {
        const failedTrack = state.lastFetch.track;
        console.warn('[player] 直链播放失败，走代理兜底：', detail);
        postDiagAudio(`直链播放失败，走代理兜底：code=${detail.code} host=${detail.host} ns=${detail.networkState} rs=${detail.readyState} via=${state.lastFetch.via}`);
        const okProxy = await tryProxyFallback(failedTrack, state.lastFetch.token);
        if (okProxy) return;
        // 代理也死了：往下走原逻辑；error 事件不会为这次代理失败再触发
        // （tryProxyFallback 里 play() 的 catch 已接住），直接用本次 detail 走。
      }
      // LX 地址播放失败：第 11 轮第 8 件起改放演示音，不再直接报 sourceerror
      // 卡住（取链失败走演示音、播放失败也走演示音，兜底才算走通）。
      if (state.lastFetch && state.lastFetch.via === 'lx' && state.lastFetch.token === state.token) {
        const failedTrack = state.lastFetch.track;
        const failedReason = state.lastFetch.reason || 'unavailable';
        console.warn('[player] 落雪地址播放失败，改放演示音：', detail);
        postDiagAudio(`落雪地址播放失败，改放演示音：code=${detail.code} host=${detail.host} ns=${detail.networkState} rs=${detail.readyState}`);
        fallbackToDemo(failedTrack, state.lastFetch.token, failedReason).then((ok) => {
          if (!ok) emit('sourceerror', detail);
        });
        return;
      }
      // 刚才的地址是平台/云盘的：往下一档重试一次；重试本身失败时再报 sourceerror。
      // 旧行为只发 {}，界面和日志都看不到原因；现在把真实原因带出去。
      if (state.lastFetch && (state.lastFetch.via === 'platform' || state.lastFetch.via === 'cloud') && state.lastFetch.token === state.token) {
        const failedVia = state.lastFetch.via === 'platform' ? '平台' : '云盘';
        console.warn(`[player] ${failedVia}地址播放失败，往下一档重试：`, detail);
        postDiagAudio(`${failedVia}地址播放失败，往下一档重试：code=${detail.code} host=${detail.host} ns=${detail.networkState} rs=${detail.readyState}`);
        retryWithFallback(state.lastFetch.track, state.lastFetch.token).then((ok) => {
          if (!ok) {
            postDiagAudio(`下一档重试失败：code=${detail.code} host=${detail.host} ns=${detail.networkState} rs=${detail.readyState}`);
            emit('sourceerror', detail);
          }
        });
        return;
      }
      console.warn('[player] 播放失败：', detail);
      postDiagAudio(`播放失败：code=${detail.code} host=${detail.host} ns=${detail.networkState} rs=${detail.readyState} via=${(state.lastFetch && state.lastFetch.via) || ''}`);
      postNativeStep(`播放失败 source=${(state.lastFetch && state.lastFetch.track && state.lastFetch.track.source) || ''} code=${detail.code} host=${detail.host} via=${(state.lastFetch && state.lastFetch.via) || ''}`);
      emit('sourceerror', detail);
    });
  }
  bindDeck(deckA);
  bindDeck(deckB);

  /* 第 15 轮第 2 件：网页媒体会话——WKWebView 播起来后 WebKit 会按页面
     MediaSession 重建 Now Playing 与命令；原来页面根本没设 handler，
     系统只给 ±10 秒快退快进（原生侧一次注册拦不住这次重建）。
     上一首/下一首指向 App 自己的切歌，seekbackward/seekforward 显式
     设 null 摘掉，play/pause 直接动活动元素。七平台同步：这是播放器
     通用行为，不分平台。 */
  try {
    if ('mediaSession' in navigator && navigator.mediaSession) {
      navigator.mediaSession.setActionHandler('previoustrack', () => { try { prev(); } catch { /* ignore */ } });
      navigator.mediaSession.setActionHandler('nexttrack', () => { try { next(); } catch { /* ignore */ } });
      navigator.mediaSession.setActionHandler('play', () => { try { sounding().play().catch(() => {}); } catch { /* ignore */ } });
      navigator.mediaSession.setActionHandler('pause', () => { try { sounding().pause(); } catch { /* ignore */ } });
      navigator.mediaSession.setActionHandler('seekbackward', null);
      navigator.mediaSession.setActionHandler('seekforward', null);
    }
  } catch { /* 老 WebKit 没有 mediaSession 也不拦着播 */ }

  /* ------------------------------------------------------------------ *
   * 前后台切换与音频中断（第 13 轮第 1 件，替换第 12 轮“只回前台恢复”）
   *
   * 三条路，状态只用 wantResume / userPaused 两个旗标：
   *  (a) 切后台：visibilitychange → enterBackground()，影子接管续播（见上）。
   *      注意不能用 state.playing 做判断——系统暂停元素时会触发 pause 事件，
   *      state.playing 已经被置 false；所以隐藏瞬间由 enterBackground 自己
   *      按“元素是不是在播”记 wantResume。
   *  (b) 被别的音乐软件/电话/Siri 中断：原生侧 .began 调
   *      __liziAudioInterruptionBegan（只记 wantResume，不动元素——系统会
   *      自己暂停它）；.ended 调 __liziAudioInterruptionEnded：还在前台就
   *      地续播，还在后台只记着，等回前台再续（别在微信里突然出声）。
   *      中断时影子/deck 的 pause 事件会把 state.playing 置 false，那是
   *      系统行为，不是用户点的暂停，所以 wantResume 不受它影响。
   *  (c) 回前台：visibilitychange 可见 / 原生 didBecomeActive 都调
   *      __liziResumeWebAudio → exitBackground() 把进度接回 deck；没进过
   *      后台接管时按 wantResume 原地续播。位置不丢：全程只在元素间交接
   *      currentTime，从不 reload、不重播、不丢队列。
   * ------------------------------------------------------------------ */
  function resumeWebAudio() {
    try { Beat.resume(); } catch { /* Beat 不可用也不影响续播 */ }
    if (bgActive) { exitBackground(); return; }
    try {
      if (wantResume && !userPaused && audio.src && audio.paused) {
        audio.play().catch(() => {});
      }
    } catch { /* ignore */ }
    wantResume = false;
  }
  // 原生侧 didBecomeActive / 中断结束时调这个钩子；页面自己回前台也走同一条路。
  window.__liziResumeWebAudio = resumeWebAudio;
  // 原生侧 AVAudioSession 中断 .began / .ended 调这两个钩子（见 ContentView）。
  window.__liziAudioInterruptionBegan = () => {
    try { if (state.playing || !sounding().paused) wantResume = true; } catch { /* ignore */ }
  };
  window.__liziAudioInterruptionEnded = () => {
    try { if (!document.hidden) resumeWebAudio(); } catch { /* ignore */ }
  };
  // 原生侧 didEnterBackground 的备用触发（visibilitychange 是主路，这个是兜底；
  // enterBackground 自己是幂等的，两边都调也不会接管两次）。
  window.__liziEnterBackground = () => { enterBackground(); };
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      enterBackground();
      return;
    }
    resumeWebAudio();
  });

  /* ------------------------------------------------------------------ *
   * 喜欢（第 12 轮第 15 件补：锁屏全屏卡片上的星标按钮）。
   * 锁屏的喜欢按钮走 MPRemoteCommandCenter.likeCommand，原生侧收到后调
   * window.__liziLikeCurrent() 切换当前曲目的喜欢态，再用 __liziLiked()
   * 回读、写回 likeCommand.isActive（星标实心/空心）。
   * 存本地（localStorage lizi.liked，`source:id` 键，最多 500 条），不依赖
   * 各平台自己的「我喜欢的音乐」歌单接口——那个要登录且各家形状不一，
   * 这里只负责「这首现在喜不喜欢」这个开关本身。
   * 第 14 轮第 16 件：同时存一份曲目快照（lizi.likedTracks，见下），
   * 没有喜欢接口的平台拿它当「我的喜欢」的本地来源。
   * ------------------------------------------------------------------ */
  const LIKED_KEY = 'lizi.liked';
  /* 第 14 轮第 16 件：星标只存 `source:id` 键，画不出曲目。
     点星标时同时存一份曲目快照（lizi.likedTracks，同 cap 500、与 keys
     同步增删），供没有喜欢接口的平台（酷狗/酷我/Apple Music）的
     「我的喜欢」本地兜底——是用户自己点的真实收藏，不造假。 */
  const LIKED_TRACKS_KEY = 'lizi.likedTracks';
  function likedTracksSnapshot(t) {
    return { id: t.id, source: t.source || '', name: t.name || '', artists: t.artists || '', cover: t.cover || '', duration: t.duration || 0 };
  }
  function readLikedTracks() {
    try {
      const v = JSON.parse(localStorage.getItem(LIKED_TRACKS_KEY) || '[]');
      return Array.isArray(v) ? v.filter((x) => x && x.id != null) : [];
    } catch { return []; }
  }
  window.__liziLikedTracks = () => readLikedTracks();
  function likedKey(t) { return t ? ((t.source || '') + ':' + String(t.id)) : ''; }
  function readLiked() {
    try {
      const v = JSON.parse(localStorage.getItem(LIKED_KEY) || '[]');
      return Array.isArray(v) ? v.filter((x) => typeof x === 'string') : [];
    } catch { return []; }
  }
  function currentTrack() {
    const q = state.queue || [];
    return q[state.index] || null;
  }
  window.__liziLiked = () => {
    const cur = currentTrack();
    return !!cur && readLiked().includes(likedKey(cur));
  };
  window.__liziLikeCurrent = () => {
    const cur = currentTrack();
    if (!cur) return false;
    const key = likedKey(cur);
    let list = readLiked();
    const i = list.indexOf(key);
    const liked = i < 0;
    if (liked) list.unshift(key);
    else list.splice(i, 1);
    // 快照与 keys 同步增删（先按 key 去重，再喜欢就插到最前）。
    let snaps = readLikedTracks().filter((s) => likedKey(s) !== key);
    if (liked) snaps.unshift(likedTracksSnapshot(cur));
    try {
      localStorage.setItem(LIKED_KEY, JSON.stringify(list.slice(0, 500)));
      localStorage.setItem(LIKED_TRACKS_KEY, JSON.stringify(snaps.slice(0, 500)));
    } catch { /* 存不住也不拦着播 */ }
    return liked;
  };

  /* ------------------------------------------------------------------ *
   * 对外 API
   * ------------------------------------------------------------------ */
  function next(auto = false) {
    if (!state.queue.length) return;
    cancelGlide('next');
    if (state.mode === 'shuffle') return load(Math.floor(Math.random() * state.queue.length));
    // 顺序播放：到底了就停，不自动回到第一首（用户手点下一首才回）
    if (state.index >= state.queue.length - 1) {
      if (auto && state.mode === 'order') { state.playing = false; emit('playstate', false); return; }
      return load(0);                  // 列表循环：回到第一首
    }
    return load(state.index + 1);
  }

  // 第 13 轮第 10 件：上一首按钮必须真的切到上一首。
  // 旧逻辑“播过 3 秒先回到本曲开头”是唯一挂在按钮上的 seek 行
  // 为——用户按一下歌跳回开头，读到的就是“快退”，不是“上一首”；
  // 代码里三处按钮/远程命令/岛 Intent 本来就全是 prev/next，没有快进/快退
  // 控件可改，改的就是这条规则。回到开头用进度条拖动。
  function prev() {
    if (!state.queue.length) return;
    cancelGlide('prev');
    if (state.mode === 'shuffle') return load(Math.floor(Math.random() * state.queue.length));
    // 列表循环/顺序：第一首再往前 = 最后一首
    return load((state.index - 1 + state.queue.length) % state.queue.length);
  }

  /* 启动时把上次的队列装回来。只恢复状态，不碰 audio.src、不自动播放；
     用户点播放 / 下一首时才由 load() 按 id 重新解析播放地址。 */
  restoreQueue();

  return {
    state, on,
    /* 对外仍然只有一个 audio：始终指向当前活动元素。
       app.js 里读 Player.audio.currentTime / duration / paused / muted 的地方不用改。
       后台接管期间返回影子元素（进度/暂停态都是正在出声的那条，锁屏/岛/歌词
       读到的才是真进度）；回前台自动指回 deck。 */
    get audio() { return bgActive ? bgAudio : audio; },
    /* 后台接管态（验收/诊断用）：bgActive / 影子元素。 */
    get bgActive() { return bgActive; },
    get bgAudio() { return bgAudio; },
    /* 会员判定（第 13 轮第 5/7 件共用）：纯函数 + 异步查询 + 清缓存。
       app.js 的标识、accounts.js 的 normStatus 都调同一套。 */
    membershipFromStatus, hasMembership: fetchMembership, clearMembershipCache,
    parseLRC, parseLyrics, makeDemoTrack,
    extractColors, colorsFromImage, rememberColors, paletteFromCover,

    /** 设置整个队列并从第 i 首开始 */
    playQueue(tracks, i = 0, autoplay = true) {
      state.queue = tracks.slice();
      state.index = i;
      saveQueue();                       // 队列一换就落盘，刷新 / 重开还能按整张列表走
      return load(i, autoplay);
    },
    playAt: (i) => load(i),
    next, prev,

    /* 交叉淡化用的低层接口（audio/glide.js 调用）。
       decks：活动 / 空闲元素；peekNext / prepareIncoming / commitIncoming 见上。 */
    get decks() { return { active: audio, idle: idleDeck }; },
    peekNext, prepareIncoming, commitIncoming,

    toggle() {
      cancelGlide('toggle');
      const el = sounding();
      if (!el.src) { if (state.queue.length) load(Math.max(0, state.index)); return; }
      if (el.paused) {
        userPaused = false;                 // 用户亲手点播放：清除“别自动续”的标记
        if (!bgActive) Beat.resume();
        el.play();
      } else {
        userPaused = true;                  // 用户亲手点暂停：回来也不许自动续播
        wantResume = false;
        el.pause();
      }
    },

    seek(sec) {
      if (!isFinite(sec)) return;
      cancelGlide('seek');
      try { sounding().currentTime = Math.max(0, sec); } catch { /* ignore */ }
      /* 后台拖进度：deck 也同步一份，回前台接得准（影子是主，deck 是备）。 */
      if (bgActive) { try { audio.currentTime = Math.max(0, sec); } catch { /* ignore */ } }
      Beat.reset();          // 跳转后节拍相位要重新对齐
    },

    /* 第 13 轮第 19/20 件：不换歌、只重拉当前这首的歌词（LRCLIB 开关变了之后用）。
       先清空再拉，token 还是当前这首的，旧请求回来会被 token 挡掉；本地文件本来就没
       在线歌词，重拉也是空，歌词区保持「这首没有歌词」。 */
    reloadLyrics() {
      const track = state.queue[state.index];
      if (!track) return;
      state.lyric = [];
      state.lyricIndex = -1;
      emit('lyric', { lines: [], active: -1 });
      fetchLyricsFor(track, state.token);
    },
    setVolume(v) {
      const vol = Math.max(0, Math.min(1, v));
      audio.volume = vol;
      if (idleDeck) idleDeck.volume = vol;   // 过渡期间两条 deck 的音量保持一致
      try { bgAudio.volume = vol; } catch { /* ignore */ }   // 后台影子音量跟着走
    },
    get volume() { return audio.volume; },

    setMode(m) { cancelGlide('mode'); state.mode = m; saveQueue(); emit('mode', m); },
    cycleMode() {
      cancelGlide('mode');
      const order = ['order', 'loop', 'single', 'shuffle'];
      state.mode = order[(order.indexOf(state.mode) + 1) % order.length];
      saveQueue();
      emit('mode', state.mode);
      return state.mode;
    },

    /** 按当前播放时间找歌词行。返回 { index, charIndex } —— charIndex 是
     *  逐字格式下"当前唱到第几个字"，非逐字时为 -1。
     *  注意单位：t 是秒（audio.currentTime），YRC/LRC 里的时间戳统一按秒存，
     *  避免两套单位混用（混用会导致中文/日文歌永远停在第一行）。 */
    lyricAt(t) {
      const lines = state.lyric;
      let lo = 0, hi = lines.length - 1, found = -1;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (lines[mid].t <= t) { found = mid; lo = mid + 1; }
        else hi = mid - 1;
      }

      // 逐字高亮：在已定位到的行里二分找当前字
      let charIndex = -1;
      if (found >= 0 && lines[found].chars) {
        const chars = lines[found].chars;
        let a = 0, b = chars.length - 1, cf = -1;
        while (a <= b) {
          const mid = (a + b) >> 1;
          if (chars[mid].t <= t) { cf = mid; a = mid + 1; }
          else b = mid - 1;
        }
        charIndex = cf;
      }

      if (found !== state.lyricIndex || charIndex !== state.charIndex) {
        state.lyricIndex = found;
        state.charIndex = charIndex;
        emit('lyric', { lines, active: found, charIndex, format: state.lyricFormat });
      }
      return { index: found, charIndex };
    },
  };
})();
