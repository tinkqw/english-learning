# 生词本网页

手机上用的 PWA：翻看生词本，勾 1–3 个想练的表达，按住说话，和火山引擎豆包实时语音模型（美式英语音色）围绕工作场景对话，结束时集中给反馈。

```
浏览器（page/）──wss /ws──→ nginx ──→ relay-server.js ──wss──→ 火山实时语音
                                      └─ 练习结束：双方文本落 transcripts/{时间}.jsonl
本机 render-vocab.py ──rsync──→ 服务器 data.json（页面数据，只读）
```

- 凭证只在服务器 `.env`，浏览器端零凭证；页面登录用表单 + 90 天 Cookie（密码只存加盐哈希）。
- 页面不回写任何学习状态。「想练」「已学会」在多维表格里手动标。
- 每轮硬上限 10 分钟。

## 部署

1. 服务器装 Node 18+、nginx，域名解析好，`certbot --nginx -d <域名>` 申请证书。
2. 参照 `nginx.example.conf` 配站点，换成你的域名。
3. 建目录：`/var/www/vocab`、`/opt/vocab-relay`、`/var/lib/vocab/transcripts`（属主为运行中继的用户）。
4. 把 `relay/env.example` 填好，存成服务器上的 `/opt/vocab-relay/.env`，`chmod 600`。
5. 本机执行 `VOCAB_HOST=<ssh 主机> bash deploy.sh`。
6. 本机执行 `python3 render-vocab.py --push` 推第一份数据（需设 `VOCAB_REMOTE`）。

`page/data.json` 是虚构的示例数据，本地预览用；部署时不会覆盖服务器上的真实数据。

## 已知坑

- iOS：先建的录音 AudioContext 会被播放挂起，所以每次按下说话都在手势里 `resume()`，失败就重建。
- iOS Safari 不支持振动 API，反馈只能靠视觉和提示音。
- 登录墙后的站点，`<link rel="manifest">` 要加 `crossorigin="use-credentials"`，否则拿到的是登录页。
- 火山鉴权头 `X-Api-Access-Key` 要填控制台「服务接口认证信息」里的 Access Token。
