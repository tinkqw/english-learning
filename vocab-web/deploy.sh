#!/bin/bash
# 把生词本网页（静态页 + 语音中继）部署到一台 Ubuntu 服务器。
# 用法：VOCAB_HOST=myserver bash deploy.sh
#   VOCAB_HOST    ssh 主机名（~/.ssh/config 里的别名或 user@ip）
#   VOCAB_WEBROOT 静态页目录，默认 /var/www/vocab
#   VOCAB_RELAY   中继代码目录，默认 /opt/vocab-relay
# 前提：服务器已装 Node 18+、nginx、证书；中继凭证写在 $VOCAB_RELAY/.env（见 relay/env.example）。
set -euo pipefail
cd "$(dirname "$0")"

HOST="${VOCAB_HOST:?设置 VOCAB_HOST}"
WEBROOT="${VOCAB_WEBROOT:-/var/www/vocab}"
RELAY="${VOCAB_RELAY:-/opt/vocab-relay}"

echo "== 1/3 页面 → ${WEBROOT}（不覆盖服务器上的 data.json）"
rsync -az --exclude data.json page/ "${HOST}:${WEBROOT}/"

echo "== 2/3 中继 → ${RELAY}"
rsync -az --exclude env.example relay/ "${HOST}:${RELAY}/"
ssh "${HOST}" "cd ${RELAY} && npm install --omit=dev --silent"

echo "== 3/3 systemd unit"
ssh "${HOST}" "sudo RELAY=${RELAY} bash -s" <<'EOF'
cat > /etc/systemd/system/vocab-relay.service <<UNIT
[Unit]
Description=vocab-relay (browser <-> volc realtime voice)
After=network.target

[Service]
User=$(stat -c %U "${RELAY}")
WorkingDirectory=${RELAY}
EnvironmentFile=${RELAY}/.env
ExecStart=/usr/bin/env node ${RELAY}/relay-server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now vocab-relay
systemctl restart vocab-relay
systemctl is-active vocab-relay
EOF
echo "done"
