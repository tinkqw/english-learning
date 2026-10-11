#!/bin/bash
# 每晚同步（示例 23:30 定时跑）：
#   1. words.jsonl 新增记录 → 模型抽表达 → 飞书多维表格生词本
#   2. 多维表格 + 在练卡 → data.json → 推到生词本网页服务器
#   3. 服务器上的口语练习记录 → 拉回本机
# 三步各自记退出码，任一步失败整体非 0 退出（接你自己的通知即可）。
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENGLISH_ENV_FILE:-${HERE}/.env}"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
export USER=${USER:-$(whoami)}   # claude -p 找登录态依赖 USER，部分定时器不设

DATA="${ENGLISH_DATA_DIR:-$HOME/Data/english-learning}"
LOG="${ENGLISH_LOG_DIR:-${DATA}/logs}/english-nightly.log"
mkdir -p "$(dirname "${LOG}")"
PY="${PYTHON:-python3}"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') 开始 ===" >> "${LOG}"
"${PY}" "${HERE}/sync-bitable.py" >> "${LOG}" 2>&1
c1=$?
"${PY}" "${HERE}/../vocab-web/render-vocab.py" --push >> "${LOG}" 2>&1
c2=$?
c3=0
if [ -n "${VOCAB_TRANSCRIPTS_REMOTE:-}" ]; then
  mkdir -p "${DATA}/oral-transcripts"
  rsync -az "${VOCAB_TRANSCRIPTS_REMOTE}" "${DATA}/oral-transcripts/" >> "${LOG}" 2>&1
  c3=$?
fi
echo "=== 退出码 sync-bitable=${c1} render-vocab=${c2} transcripts=${c3} ===" >> "${LOG}"

[ "${c1}" -eq 0 ] && [ "${c2}" -eq 0 ] && [ "${c3}" -eq 0 ]
