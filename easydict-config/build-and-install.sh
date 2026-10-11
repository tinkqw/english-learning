#!/bin/bash
# 构建 easydict/ → 签名 → 装到 /Applications → 启动。
# 用法：bash easydict-config/build-and-install.sh
#   SIGN_IDENTITY  登录钥匙串里的代码签名证书名（自签即可，见 README），默认 "Easydict Local Signing"
#   XCODE_DIR      Xcode 路径，默认 /Applications/Xcode.app
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/easydict"
IDENTITY="${SIGN_IDENTITY:-Easydict Local Signing}"
XCODE_DIR="${XCODE_DIR:-/Applications/Xcode.app}"
APP="${SRC}/DerivedData.noindex/Build/Products/Release/Easydict.app"
LOG="${SRC}/DerivedData.noindex/build.log"

mkdir -p "$(dirname "${LOG}")"

echo "==> 构建（日志 ${LOG}）"
cd "${SRC}"
# EASYDICT_RELEASE_PACKAGING=YES 跳过 SwiftFormat 构建阶段（该阶段可能无限挂起）
DEVELOPER_DIR="${XCODE_DIR}/Contents/Developer" \
EASYDICT_RELEASE_PACKAGING=YES \
xcodebuild -workspace Easydict.xcworkspace -scheme Easydict \
  -configuration Release -derivedDataPath ./DerivedData.noindex \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build > "${LOG}" 2>&1

grep -q '^\*\* BUILD SUCCEEDED \*\*' "${LOG}" || { echo "构建失败，见 ${LOG}"; grep -m 10 'error:' "${LOG}" || true; exit 1; }

echo "==> 签名（${IDENTITY}）"
# 用固定证书而不是 adhoc（-s -）：adhoc 每次重编签名都变，辅助功能 / 屏幕录制授权会静默失效
codesign --force --deep -s "${IDENTITY}" "${APP}"

echo "==> 安装到 /Applications"
osascript -e 'quit app "Easydict"' 2>/dev/null || true
sleep 2
if [ -d /Applications/Easydict.app ]; then
  mv /Applications/Easydict.app "$HOME/.Trash/Easydict-$(date +%Y%m%d-%H%M%S).app"
fi
cp -R "${APP}" /Applications/

echo "==> 启动"
open -a /Applications/Easydict.app
