/* 生词本 PWA：列表翻看 + 勾 1–3 个按住说话 */
'use strict';

const $ = (id) => document.getElementById(id);
const STATUSES = ['全部', '新收', '想练', '已学会'];
const TAGS = ['全部', '业务沟通', '技术术语', '日常'];

let WORDS = [];
let fStatus = '全部', fTag = '全部', fQuery = '';
const picked = new Map(); // 表达 -> word

/* ---------- 列表 ---------- */

function chipRow(el, items, current, onPick) {
  el.innerHTML = '';
  for (const it of items) {
    const b = document.createElement('button');
    b.className = 'chip';
    b.textContent = it;
    b.setAttribute('aria-pressed', it === current ? 'true' : 'false');
    b.onclick = () => onPick(it);
    el.appendChild(b);
  }
}

function renderChips() {
  chipRow($('statusChips'), STATUSES, fStatus, (v) => { fStatus = v; renderChips(); renderList(); });
  chipRow($('tagChips'), TAGS, fTag, (v) => { fTag = v; renderChips(); renderList(); });
}

function matches(w) {
  if (fStatus !== '全部' && w['状态'] !== fStatus) return false;
  if (fTag !== '全部' && w['标签'] !== fTag) return false;
  if (fQuery) {
    const hay = (w['表达'] + w['释义'] + w['例句'] + w['例句译文']).toLowerCase();
    if (!hay.includes(fQuery)) return false;
  }
  return true;
}

function renderList() {
  const list = $('list');
  list.innerHTML = '';
  const rows = WORDS.filter(matches);
  $('empty').hidden = rows.length > 0;
  for (const w of rows) {
    const card = document.createElement('div');
    card.className = 'card' + (picked.has(w['表达']) ? ' picked' : '');

    const head = document.createElement('button');
    head.className = 'card-head';

    const pick = document.createElement('span');
    pick.className = 'pick';
    pick.textContent = '✓';
    pick.onclick = (e) => { e.stopPropagation(); togglePick(w, card); };

    const main = document.createElement('span');
    main.className = 'head-main';
    const expr = document.createElement('div');
    expr.className = 'expr';
    expr.textContent = w['表达'];
    const gloss = document.createElement('div');
    gloss.className = 'gloss';
    gloss.textContent = w['释义'];
    main.append(expr, gloss);

    const badge = document.createElement('span');
    badge.className = 'badge' + (w['状态'] === '想练' ? ' want' : '');
    badge.textContent = w['状态'];

    head.append(pick, main, badge);
    head.onclick = () => card.classList.toggle('open');

    const detail = document.createElement('div');
    detail.className = 'detail';
    const dl = document.createElement('div');
    dl.className = 'dl';
    for (const [label, key] of [['例句', '例句'], ['译文', '例句译文'], ['标签', '标签'],
                                ['来源', '来源原文'], ['时间', '时间']]) {
      if (!w[key]) continue;
      const p = document.createElement('p');
      const b = document.createElement('b');
      b.textContent = label + '　';
      p.append(b, document.createTextNode(w[key]));
      dl.appendChild(p);
    }
    detail.appendChild(dl);

    card.append(head, detail);
    list.appendChild(card);
  }
}

function togglePick(w, card) {
  const k = w['表达'];
  if (picked.has(k)) picked.delete(k);
  else {
    if (picked.size >= 3) return; // 勾 1–3 个
    picked.set(k, w);
  }
  card.classList.toggle('picked', picked.has(k));
  renderBar();
}

function renderBar() {
  const n = picked.size;
  $('practiceBar').classList.toggle('show', n > 0);
  $('pickCnt').textContent = n ? `已勾 ${n} 个表达（最多 3 个）` : '';
}

/* ---------- 练习 ---------- */

let ws = null, capCtx = null, playCtx = null, mediaStream = null, workletNode = null;
let playTime = 0, ended = false;
let capturing = false, wsReady = false, capReady = false, framesThisPress = 0;

const WORKLET_SRC = `
class PCM16 extends AudioWorkletProcessor {
  constructor() { super(); this.buf = []; this.ratio = sampleRate / 16000; this.acc = 0; }
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch) return true;
    for (let i = 0; i < ch.length; i++) {
      this.acc += this.ratio;
      if (this.acc >= 1) { this.acc -= 1; this.buf.push(ch[i]); }
    }
    while (this.buf.length >= 320) { // 20ms @16k
      const frame = new Int16Array(320);
      for (let i = 0; i < 320; i++) {
        const s = Math.max(-1, Math.min(1, this.buf[i]));
        frame[i] = s < 0 ? s * 32768 : s * 32767;
      }
      this.buf.splice(0, 320);
      this.port.postMessage(frame.buffer, [frame.buffer]);
    }
    return true;
  }
}
registerProcessor('pcm16', PCM16);
`;

function setStatus(t, isErr) {
  const s = $('status');
  s.textContent = t;
  s.classList.toggle('err', !!isErr);
}

const lineEls = new Map();   // key -> .txt 元素；key = reply_id / question_id
const chatBufs = new Map();  // reply_id -> 已累加文本

function setLine(who, key, text) {
  if (!text) return;
  let el = lineEls.get(key);
  if (!el) {
    const div = document.createElement('div');
    div.className = 'line ' + (who === '教练' ? 'coach' : 'me');
    const w = document.createElement('span');
    w.className = 'who';
    w.textContent = who;
    el = document.createElement('span');
    el.className = 'txt';
    div.append(w, el);
    $('subs').appendChild(div);
    lineEls.set(key, el);
  }
  el.textContent = text;
  $('subs').scrollTop = $('subs').scrollHeight;
}

function playPCM(buf) {
  if (!playCtx) playCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 });
  const i16 = new Int16Array(buf);
  const f32 = new Float32Array(i16.length);
  for (let i = 0; i < i16.length; i++) f32[i] = i16[i] / 32768;
  const ab = playCtx.createBuffer(1, f32.length, 24000);
  ab.getChannelData(0).set(f32);
  const src = playCtx.createBufferSource();
  src.buffer = ab;
  src.connect(playCtx.destination);
  playTime = Math.max(playTime, playCtx.currentTime) + ab.duration;
  src.start(playTime - ab.duration);
}

function cue(freq, dur = 0.09) {
  try {
    if (!playCtx) playCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 24000 });
    const o = playCtx.createOscillator(), g = playCtx.createGain();
    o.type = 'sine'; o.frequency.value = freq;
    g.gain.setValueAtTime(0.12, playCtx.currentTime);
    g.gain.exponentialRampToValueAtTime(0.001, playCtx.currentTime + dur);
    o.connect(g).connect(playCtx.destination);
    o.start(); o.stop(playCtx.currentTime + dur);
  } catch {}
}

// 练习开始时预建麦克风管线；按下只切换 capturing 开关，不再临时建 AudioContext
async function prepareCapture() {
  capCtx = new (window.AudioContext || window.webkitAudioContext)();
  await capCtx.resume();
  const blob = new Blob([WORKLET_SRC], { type: 'application/javascript' });
  await capCtx.audioWorklet.addModule(URL.createObjectURL(blob));
  mediaStream = await navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
  });
  const src = capCtx.createMediaStreamSource(mediaStream);
  workletNode = new AudioWorkletNode(capCtx, 'pcm16');
  workletNode.port.onmessage = (e) => {
    framesThisPress++;
    if (capturing && ws && ws.readyState === 1) ws.send(e.data);
  };
  src.connect(workletNode);
}

function stopCapture() {
  capturing = false; capReady = false;
  if (workletNode) { workletNode.disconnect(); workletNode = null; }
  if (mediaStream) { mediaStream.getTracks().forEach((t) => t.stop()); mediaStream = null; }
  if (capCtx) { capCtx.close(); capCtx = null; }
}

function maybeEnableTalk() {
  if (wsReady && capReady && !ended) {
    $('talk').disabled = false;
    setStatus('就绪。按住说话，松开听回答。');
  }
}

function openPractice() {
  ended = false;
  capturing = false; wsReady = false; capReady = false;
  setStatus('请求麦克风权限…');
  prepareCapture()
    .then(() => {
      capReady = true;
      if (!wsReady && ws && ws.readyState === 1) setStatus('连接已建立，准备练习…');
      maybeEnableTalk();
    })
    .catch((err) => setStatus('麦克风不可用：' + err.message, true));
  $('ovChunks').innerHTML = '';
  for (const w of picked.values()) {
    const s = document.createElement('span');
    s.className = 'ov-chunk';
    s.textContent = w['表达'];
    $('ovChunks').appendChild(s);
  }
  $('subs').innerHTML = '';
  lineEls.clear();
  chatBufs.clear();
  $('overlay').classList.add('show');
  document.body.style.overflow = 'hidden';

  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const base = location.pathname.replace(/[^/]*$/, ''); // 兼容长随机路径与本地
  ws = new WebSocket(`${proto}://${location.host}${base}ws`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    setStatus(capReady ? '连接已建立，准备练习…' : '连接已建立，等待麦克风授权…');
    ws.send(JSON.stringify({ type: 'start', chunks: [...picked.keys()] }));
  };
  ws.onmessage = (ev) => {
    if (typeof ev.data !== 'string') { playPCM(ev.data); return; }
    const m = JSON.parse(ev.data);
    if (m.type === 'ready') {
      wsReady = true;
      maybeEnableTalk();
    } else if (m.type === 'event') {
      const p = m.payload || {};
      if (m.event === 'ASRResponse') {
        const text = (p.results || []).map((r) => r.text || '').join('');
        if (text) setLine('你', 'me' + chatBufs.size, text); // 教练每开口一次，下一段「你」换行
      }
      if (m.event === 'ChatResponse' && p.content) {
        const acc = (chatBufs.get(p.reply_id) || '') + p.content;
        chatBufs.set(p.reply_id, acc);
        setLine('教练', p.reply_id, acc);
      }
    } else if (m.type === 'saved') {
      setStatus('练习已保存。');
    } else if (m.type === 'timeout') {
      setStatus('本轮已达 10 分钟上限，自动结束并保存。', true);
      finishLocal();
    } else if (m.type === 'error') {
      setStatus('出错：' + m.message, true);
    }
  };
  ws.onerror = () => setStatus('连接出错', true);
  ws.onclose = () => { if (!ended) setStatus('连接已断开', true); };
}

function endPractice() {
  if (ended) return;
  ended = true;
  if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'end' }));
  setStatus('保存中…');
  setTimeout(finishLocal, 1500);
}

function finishLocal() {
  stopCapture();
  if (ws) { try { ws.close(); } catch {} ws = null; }
  if (playCtx) { playCtx.close(); playCtx = null; playTime = 0; }
  $('overlay').classList.remove('show');
  document.body.style.overflow = '';
  $('talk').disabled = true;
  $('talk').classList.remove('listening');
}

/* ---------- 启动 ---------- */

$('search').oninput = (e) => { fQuery = e.target.value.trim().toLowerCase(); renderList(); };
$('startBtn').onclick = openPractice;
$('endBtn').onclick = endPractice;

const talk = $('talk');
talk.addEventListener('pointerdown', async (e) => {
  e.preventDefault();
  if (talk.disabled || capturing) return;
  // iOS 上预建的 capture context 可能被 TTS 播放挂起；按下是可信手势，强制 resume/重建
  try {
    if (!capReady) { await prepareCapture(); capReady = true; }
    if (capCtx.state !== 'running') await capCtx.resume();
    if (capCtx.state !== 'running') throw new Error('音频被系统挂起（' + capCtx.state + '），请再按一次');
  } catch (err) { setStatus('麦克风不可用：' + err.message, true); return; }
  framesThisPress = 0;
  capturing = true;
  talk.classList.add('listening');
  cue(880);
  setStatus('正在听…');
  setTimeout(() => {
    if (capturing && framesThisPress === 0) setStatus('没收到麦克风声音，请检查 Safari 麦克风权限', true);
  }, 1200);
});
for (const ev of ['pointerup', 'pointercancel', 'pointerleave']) {
  talk.addEventListener(ev, () => {
    if (!capturing) return;
    capturing = false;
    talk.classList.remove('listening');
    cue(520);
    if (!ended && wsReady) setStatus('松开，听教练回答。');
  });
}

fetch('data.json')
  .then((r) => r.json())
  .then((d) => {
    WORDS = d.words || [];
    const c = d.counts || {};
    $('meta').textContent = `${c.total ?? WORDS.length} 条 · 更新于 ${(d.generated_at || '').slice(0, 10)}`;
    renderChips();
    renderList();
  })
  .catch(() => { $('meta').textContent = 'data.json 加载失败'; });

if ('serviceWorker' in navigator) {
  // 占位：本期不引入离线缓存，避免 data.json 陈旧
}
