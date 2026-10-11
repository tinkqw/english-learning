#!/usr/bin/env python3
"""英语表达统一入口（bot 转发协议不变，逻辑全在 session.py）。

用法（聊天机器人收到用户消息后转发给本脚本）：
    echo "<用户这条消息>" | python3 answer.py
    exit 0 = 有回复（stdout 即回复内容，纯文本）
    exit 2 = 当前没有会话，bot 按普通消息处理
    exit 3 = 有会话但这条不像答案 / 阶段不符，bot 按普通消息处理

新会话模型（方案 2026-09-20 版）：「开始学习」主动开启 → 集中学习展示 →
「学好了，开始练」激活 → 产出练习 + 自评 → 换场景检验毕业。
"""

from __future__ import annotations

import sys

import english_lib as lib
import session


def main() -> int:
    text = sys.stdin.read().strip()
    if not text or not lib.DB_PATH.exists():
        return 2

    conn = lib.connect()
    try:
        lib.ensure_schema(conn)
        reply, code = session.handle(text, conn)
        if code == 0 and reply:
            print(reply)
        return code
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
