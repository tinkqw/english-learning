#!/usr/bin/env node
/**
 * vocab-relay：浏览器 ↔ 火山端到端实时语音大模型（O2.0）WebSocket 中继
 *
 * 浏览器侧（nginx /ws 反代进来）：
 *   文本帧 {"type":"start","chunks":[...]} → 建火山会话
 *   二进制帧 = 麦克风 PCM16 16k → TaskRequest
 *   文本帧 {"type":"end"} → FinishSession，落 transcript
 * 火山侧（wss://openspeech.bytedance.com/api/v3/realtime/dialogue，二进制协议）：
 *   TTSResponse 音频 → 原样转二进制帧给浏览器
 *   ASR/Chat 文本事件 → {"type":"event","event":名,"payload":...} + 写 transcript 缓冲
 *
 * 凭证只在服务器：.env 的 VOLC_API_KEY / VOLC_APP_ID。
 * 每轮硬上限 10 分钟（事前截断）。
 */
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const { WebSocketServer, WebSocket } = require('ws');

const LISTEN_HOST = '127.0.0.1';
const LISTEN_PORT = Number(process.env.LISTEN_PORT || 8787);
const VOLC_URL = 'wss://openspeech.bytedance.com/api/v3/realtime/dialogue';
const TRANSCRIPT_DIR = process.env.TRANSCRIPT_DIR || '/var/lib/vocab/transcripts';
const SESSION_CAP_MS = 10 * 60 * 1000;

const API_KEY = process.env.VOLC_API_KEY || '';
const APP_ID = process.env.VOLC_APP_ID || '';

/* ---------- 火山二进制协议 ---------- */

const MT = { FULL_REQ: 0b0001, AUDIO_REQ: 0b0010, FULL_RESP: 0b1001, AUDIO_RESP: 0b1011, ERROR: 0b1111 };
const EV = {
  StartConnection: 1, FinishConnection: 2,
  StartSession: 100, FinishSession: 102,
  TaskRequest: 200,
  ConnectionStarted: 50, ConnectionFailed: 51,
  SessionStarted: 150, SessionFinished: 152, SessionFailed: 153, UsageResponse: 154,
  TTSSentenceStart: 350, TTSResponse: 352, TTSEnded: 359,
  ASRInfo: 450, ASRResponse: 451, ASREnded: 459,
  ChatResponse: 550, ChatEnded: 559,
};
const EV_NAME = Object.fromEntries(Object.entries(EV).map(([k, v]) => [v, k]));
const CONNECT_EVENTS = new Set([1, 2, 50, 51]);

function u32(n) { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; }

function frame(msgType, { event, sessionId, payload } = {}) {
  const flags = event != null ? 0b0100 : 0;
  const serial = msgType === MT.FULL_REQ || msgType === MT.FULL_RESP ? 0b0001 : 0; // JSON
  const parts = [Buffer.from([0x11, (msgType << 4) | flags, (serial << 4) | 0, 0])];
  if (event != null) parts.push(u32(event));
  if (sessionId) parts.push(u32(Buffer.byteLength(sessionId)), Buffer.from(sessionId));
  const body = payload || Buffer.alloc(0);
  parts.push(u32(body.length), body);
  return Buffer.concat(parts);
}

function jsonFrame(msgType, opts, obj) {
  return frame(msgType, { ...opts, payload: Buffer.from(JSON.stringify(obj)) });
}

function parseFrame(buf) {
  if (buf.length < 8) return null;
  const msgType = (buf[1] >> 4) & 0xf;
  const flags = buf[1] & 0xf;
  const compress = buf[2] & 0xf;
  let off = 4;
  const out = { msgType, event: null, payload: null, code: null };
  if (msgType === MT.ERROR) { out.code = buf.readUInt32BE(off); off += 4; }
  if (flags & 0b0011) off += 4; // sequence，不用
  if (flags & 0b0100) {
    out.event = buf.readUInt32BE(off); off += 4;
    const idLen = buf.readUInt32BE(off); off += 4;
    off += idLen; // connect/session id，不用
  }
  if (off + 4 > buf.length) return out;
  const pLen = buf.readUInt32BE(off); off += 4;
  let payload = buf.subarray(off, off + pLen);
  if (compress === 1 && payload.length) payload = zlib.gunzipSync(payload);
  out.payload = payload;
  return out;
}

/* ---------- 教练 system_role ---------- */

function buildSystemRole(chunks) {
  const list = chunks.map((c, i) => `${i + 1}. ${c}`).join('\n');
  return `You are a friendly coworker helping the learner practise spoken English through a short, realistic work scenario.

Target expressions — help the learner use each one naturally, one at a time:
${list}

How to run the conversation:
1. Stay in English the whole time, including setup, help and the final feedback. If the learner struggles, simplify your English instead of switching languages.
2. If the learner answers in Chinese or mixes languages, say back what you think they mean in plain English and check it once. After that single check, carry on.
3. Ask open questions only. Do not give the learner options to pick from, and do not suggest an answer inside your question.
4. The learner speaks first. Offer a short phrase only when they ask for help or clearly get stuck, then hand the turn back.
5. Keep your turns brief: about 10 to 20 words, one idea, no more than one new word.
6. Save corrections for the end. Keep track of repeated mistakes and give focused feedback once the learner says they are finished.
Begin with a one-sentence scenario and a single open question.`;
}

/* ---------- 登录态（表单 + Cookie；不用 auth_basic，iOS 不把 basic auth 凭证带给 WebSocket） ---------- */

const PASS_SALT = process.env.VOLC_PAGE_PASS_SALT || '';
const PASS_HASH = process.env.VOLC_PAGE_PASS_HASH || '';
const COOKIE_NAME = 'vocab_auth';
const COOKIE_MAX_AGE = 90 * 86400; // 90 天

function sha256(s) { return crypto.createHash('sha256').update(s).digest('hex'); }
function checkPass(pw) {
  return !!PASS_HASH && sha256(PASS_SALT + String(pw ?? '')) === PASS_HASH;
}
function authToken() {
  return crypto.createHmac('sha256', PASS_HASH).update('vocab-auth-v1').digest('hex');
}
function validCookie(header) {
  if (!PASS_HASH || !header) return false;
  const m = header.match(new RegExp('(?:^|;\\s*)' + COOKIE_NAME + '=([0-9a-f]{64})'));
  return !!m && m[1] === authToken();
}

const httpServer = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  if (url === '/_auth') { // nginx auth_request 子请求，只判 Cookie
    res.writeHead(validCookie(req.headers.cookie) ? 200 : 401);
    res.end();
    return;
  }
  if (url === '/login' && req.method === 'POST') {
    let body = '';
    req.on('data', (c) => { body += c; if (body.length > 4096) req.destroy(); });
    req.on('end', () => {
      let pw = null;
      try { pw = JSON.parse(body).password; } catch {}
      if (checkPass(pw)) {
        res.writeHead(200, {
          'Content-Type': 'application/json',
          'Set-Cookie': `${COOKIE_NAME}=${authToken()}; Max-Age=${COOKIE_MAX_AGE}; Path=/; HttpOnly; SameSite=Lax; Secure`,
        });
        res.end('{"ok":true}');
      } else {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        res.end('{"ok":false}');
      }
    });
    return;
  }
  res.writeHead(404);
  res.end();
});

/* ---------- 会话 ---------- */

const wss = new WebSocketServer({ server: httpServer });
httpServer.listen(LISTEN_PORT, LISTEN_HOST);
console.log(`vocab-relay listening on ${LISTEN_HOST}:${LISTEN_PORT}`);

wss.on('connection', (client) => {
  let volc = null;
  let sessionId = null;
  let transcript = [];
  let startedAt = null;
  let capTimer = null;
  let ended = false;

  const sendClient = (obj) => { if (client.readyState === 1) client.send(JSON.stringify(obj)); };
  const ts = () => new Date().toISOString();

  function cleanupVolc() {
    if (capTimer) { clearTimeout(capTimer); capTimer = null; }
    if (volc) { try { volc.close(); } catch {} volc = null; }
  }

  function saveTranscript() {
    if (!transcript.length) return null;
    fs.mkdirSync(TRANSCRIPT_DIR, { recursive: true });
    const file = path.join(TRANSCRIPT_DIR, `${ts().replace(/[:.]/g, '-')}.jsonl`);
    fs.writeFileSync(file, transcript.map((l) => JSON.stringify(l)).join('\n') + '\n');
    return file;
  }

  function endSession(reason) {
    if (ended) return;
    ended = true;
    if (volc && volc.readyState === 1 && sessionId) {
      try { volc.send(jsonFrame(MT.FULL_REQ, { event: EV.FinishSession, sessionId }, {})); } catch {}
    }
    setTimeout(() => {
      const file = saveTranscript();
      if (reason === 'timeout') sendClient({ type: 'timeout' });
      sendClient({ type: 'saved', file: file ? path.basename(file) : null });
      cleanupVolc();
    }, 1200);
  }

  function connectVolc(chunks) {
    if (!API_KEY || !APP_ID) {
      sendClient({ type: 'error', message: '服务器未配置 VOLC_API_KEY / VOLC_APP_ID' });
      return;
    }
    sessionId = crypto.randomUUID();
    volc = new WebSocket(VOLC_URL, {
      headers: {
        'X-Api-App-ID': APP_ID,
        'X-Api-Access-Key': API_KEY,
        'X-Api-Resource-Id': 'volc.speech.dialog',
        'X-Api-App-Key': 'PlgvMymc7f3tQnJ6',
        'X-Api-Connect-Id': crypto.randomUUID(),
      },
    });
    volc.binaryType = 'nodebuffer';

    volc.on('open', () => {
      volc.send(jsonFrame(MT.FULL_REQ, { event: EV.StartConnection }, {}));
    });

    volc.on('message', (data) => {
      let m;
      try { m = parseFrame(data); } catch { return; }
      if (!m) return;

      if (m.msgType === MT.ERROR) {
        let detail = '';
        try { detail = JSON.parse(m.payload.toString()).message || ''; } catch {}
        transcript.push({ t: ts(), ev: 'Error', code: m.code, detail });
        sendClient({ type: 'error', message: `火山错误 ${m.code} ${detail}`.trim() });
        return;
      }

      if (m.msgType === MT.AUDIO_RESP) {
        if (client.readyState === 1 && m.payload) client.send(m.payload);
        return;
      }
      if (m.msgType !== MT.FULL_RESP || m.event == null) return;

      const name = EV_NAME[m.event] || `ev${m.event}`;
      let json = null;
      try { json = m.payload && m.payload.length ? JSON.parse(m.payload.toString()) : null; } catch {}

      if (m.event === EV.ConnectionStarted) {
        volc.send(jsonFrame(MT.FULL_REQ, { event: EV.StartSession, sessionId }, {
          asr: { extra: { end_smooth_window_ms: 1500 } },
          tts: {
            speaker: 'en_male_tim_uranus_bigtts',
            audio_config: { channel: 1, format: 'pcm_s16le', sample_rate: 24000 },
            extra: {},
          },
          dialog: {
            bot_name: 'Tim',
            system_role: buildSystemRole(chunks),
            speaking_style: 'Friendly, patient American colleague. Short natural turns.',
            extra: { model: '1.2.1.1', input_mod: 'keep_alive' },
          },
        }));
        return;
      }
      if (m.event === EV.SessionStarted) {
        startedAt = Date.now();
        capTimer = setTimeout(() => endSession('timeout'), SESSION_CAP_MS);
        sendClient({ type: 'ready' });
        return;
      }
      if (m.event === EV.SessionFinished || m.event === EV.SessionFailed) return;

      // ASR / Chat / TTS 文本事件：落 transcript + 转给浏览器做字幕
      if ([EV.ASRInfo, EV.ASRResponse, EV.ASREnded, EV.ChatResponse, EV.ChatEnded,
           EV.TTSSentenceStart, EV.TTSEnded].includes(m.event)) {
        transcript.push({ t: ts(), ev: name, payload: json });
        if (m.event === EV.ASRResponse || m.event === EV.ChatResponse) {
          sendClient({ type: 'event', event: name, payload: json });
        }
      }
    });

    volc.on('error', (err) => sendClient({ type: 'error', message: '火山连接出错：' + err.message }));
    volc.on('close', () => { if (!ended) sendClient({ type: 'error', message: '火山连接已断开' }); });
  }

  client.on('message', (data, isBinary) => {
    if (isBinary) {
      if (volc && volc.readyState === 1 && sessionId && !ended) {
        volc.send(frame(MT.AUDIO_REQ, { event: EV.TaskRequest, sessionId, payload: data }));
      }
      return;
    }
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === 'start' && Array.isArray(msg.chunks) && msg.chunks.length) {
      connectVolc(msg.chunks.slice(0, 3));
    } else if (msg.type === 'end') {
      endSession('user');
    }
  });

  client.on('close', () => { endSession('user'); setTimeout(cleanupVolc, 1500); });
});
