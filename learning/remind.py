#!/usr/bin/env python3
"""学习提醒（方案 §3.11「用户选择开启的学习提醒；提醒不自动启动考试」）。

2026-09-20 取代旧的 09:00 推题任务。两者的根本区别：
  - 旧任务：选卡 → 建队列 → 推第一题 → 落状态。推出去的题在新会话引擎下无人接收
    （answer.py 在 status=idle 时返回「不接管」），等于死信。
  - 本脚本：只数数、只发一句话，不碰 cards.db 的任何状态，不建队列、不激活。
    真正的学习一律由用户发「开始学习」经 session.py 开启。

每天两个时段各跑一次（示例配置 22:30 / 09:30）。两次都是学习时段，
不是「提醒 + 补发」——所以不做「一天只发一条」的去重。

**没东西可做就不发**：到期 0 张且今天可学 0 个时静默退出，空推送最伤信任。

数据：$ENGLISH_DATA_DIR/cards.db（只读）
日志：$ENGLISH_LOG_DIR/english-remind.log
"""

from __future__ import annotations

import json
import logging
import os
import sqlite3
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import english_lib as lib  # noqa: E402

LOG_PATH = lib.LOG_DIR / "english-remind.log"
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

# 不用 logging.basicConfig：english_lib 在 import 时已经配过根 logger（指向
# english-review.log），basicConfig 第二次调用是空操作，本脚本的日志会全部
# 落到别的任务的文件里。所以挂独立 handler 并断开冒泡。
log = logging.getLogger("english-remind")
log.setLevel(logging.INFO)
log.propagate = False
if not log.handlers:
    _handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
    _handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    log.addHandler(_handler)


# --- 飞书 -----------------------------------------------------------------

def tenant_access_token() -> str:
    app_id = os.environ.get("FEISHU_APP_ID", "")
    app_secret = os.environ.get("FEISHU_APP_SECRET", "")
    if not app_id or not app_secret:
        log.error("缺 FEISHU_APP_ID / FEISHU_APP_SECRET")
        return ""
    req = urllib.request.Request(
        "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read().decode())
        if body.get("code") == 0:
            return body["tenant_access_token"]
        log.error("取 token 失败: %s", body.get("msg"))
    except (urllib.error.URLError, OSError) as exc:
        log.error("取 token 请求失败: %s", exc)
    return ""


def send_text(text: str) -> bool:
    token = tenant_access_token()
    # 收件人：FEISHU_USER_OPEN_ID（别名 FEISHU_RECIPIENT_ID）
    recipient = (os.environ.get("FEISHU_RECIPIENT_ID")
                 or os.environ.get("FEISHU_USER_OPEN_ID", ""))
    if not recipient:
        log.error("收件人未设置：需要 FEISHU_USER_OPEN_ID")
        return False
    if not token:
        return False

    payload = {
        "receive_id": recipient,
        "msg_type": "text",
        "content": json.dumps({"text": text}, ensure_ascii=False),
    }
    req = urllib.request.Request(
        "https://open.feishu.cn/open-apis/im/v1/messages?receive_id_type=open_id",
        data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read().decode())
        if body.get("code") == 0:
            log.info("推送成功 message_id=%s",
                     body.get("data", {}).get("message_id"))
            return True
        log.error("推送失败 code=%s msg=%s", body.get("code"), body.get("msg"))
    except (urllib.error.URLError, OSError) as exc:
        log.error("推送请求失败: %s", exc)
    return False


# --- 数数（只读，不改任何状态） ---------------------------------------------

def count_due(conn: sqlite3.Connection) -> int:
    """到期的在练卡。due 存 UTC ISO，直接与当前 UTC 比。"""
    row = conn.execute(
        "SELECT COUNT(*) FROM cards WHERE status = 'active' AND due <= ?",
        (lib.now().isoformat(),),
    ).fetchone()
    return row[0] if row else 0


def count_learnable(conn: sqlite3.Connection) -> int:
    """今天还能学几个新表达 = min(候选数, 今日剩余激活额度)。

    额度按北京日算、多轮不重置（方案 §3.3.5），所以两个时段共用同一份额度：
    早上用掉 2 张，晚上这里就会算出 0，提醒里不会再喊「可学新表达」。
    """
    used = conn.execute(
        "SELECT COUNT(*) FROM activation_log WHERE activated_on = ?",
        (lib.today_cst(),),
    ).fetchone()[0]
    left = max(0, lib.DAILY_ACTIVATION_CAP - used)
    if left == 0:
        return 0
    candidates = conn.execute(
        "SELECT COUNT(*) FROM cards WHERE status = 'candidate'"
    ).fetchone()[0]
    return min(left, candidates)


def compose(due: int, learnable: int, unfinished: bool) -> str:
    if unfinished:
        return ("📖 上一轮学习还没结束。\n"
                "发「继续学习」接着来，或「结束学习」结算后重开。")
    parts = []
    if due:
        parts.append("到期复习 %d 张" % due)
    if learnable:
        parts.append("可学新表达 %d 个" % learnable)
    return "📖 " + " · ".join(parts) + "\n发「开始学习」开始。"


def main() -> int:
    if not lib.DB_PATH.exists():
        log.info("cards.db 不存在，跳过")
        return 0

    lib.load_env()
    conn = lib.connect()
    try:
        lib.ensure_schema(conn)
        status = lib.read_state(conn).get("status", "idle")
        unfinished = status in {"learning", "answering", "paused"}
        due = count_due(conn)
        learnable = count_learnable(conn)

        # 会话没结束时照发（提醒你回去收尾）；否则没料就不出声
        if not unfinished and due == 0 and learnable == 0:
            log.info("到期 0 张、可学 0 个，静默不发")
            return 0

        text = compose(due, learnable, unfinished)
        log.info("到期 %d 张，可学 %d 个，未完成会话=%s", due, learnable, unfinished)
        if "--dry" in sys.argv:
            print(text)
            return 0
        return 0 if send_text(text) else 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
