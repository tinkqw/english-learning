#!/bin/bash
# 每晚加工（示例 21:00 / 23:00 定时跑）：
#   daily-digest.py  words.jsonl → materials 表（飞书里「生词本」命令查的就是它）
#   process-gaps.py  gaps.jsonl  → 候选卡（翻译 / 润色 / 记表达 采集到的缺口）
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENGLISH_ENV_FILE:-${HERE}/.env}"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi
export USER=${USER:-$(whoami)}
PY="${PYTHON:-python3}"

cd "${HERE}"
"${PY}" daily-digest.py
c1=$?
"${PY}" process-gaps.py
c2=$?
[ "${c1}" -eq 0 ] && [ "${c2}" -eq 0 ]
