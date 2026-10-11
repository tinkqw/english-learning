#!/usr/bin/env python3
"""材料归档（方案 §3.2③ / §3.10 第 4 步）：words.jsonl → materials 表。

可定时跑（如每晚 21:00），也可手动跑。
- 按记录 ts 幂等去重（UNIQUE ts）：跨日补齐、失败重跑、重复运行都不重复建（§3.3.1）
- 读「上次成功处理位置之后」的记录，不按「当天」过滤；ts 是唯一键，全量扫描天然等价游标推进
- trigger=inline 的记录（点词）标 ★，只作展示信号，不自动激活（§3.6）
- 默认不推送任何通知（§3.7）
"""

from __future__ import annotations

import json
import sys

import english_lib as lib


def archive(dry_run: bool = False) -> int:
    if not lib.WORDS_PATH.exists():
        print("words.jsonl 不存在，跳过")
        return 0
    conn = lib.connect()
    try:
        lib.ensure_schema(conn)
        added = starred = skipped = 0
        with lib.WORDS_PATH.open(encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1
                    continue
                ts = rec.get("timestamp") or rec.get("ts")
                if not ts:
                    skipped += 1
                    continue
                exists = conn.execute(
                    "SELECT 1 FROM materials WHERE ts = ?", (ts,)
                ).fetchone()
                if exists:
                    continue
                starred_flag = 1 if rec.get("trigger") == "inline" else 0
                if dry_run:
                    print(f"[dry] {ts} {'★' if starred_flag else ' '} "
                          f"{(rec.get('text') or '')[:50]}")
                    added += 1
                    continue
                conn.execute(
                    "INSERT OR IGNORE INTO materials (ts, text, translated, starred, archived_at) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (ts, rec.get("text") or "", rec.get("translatedText") or "",
                     starred_flag, lib.now().isoformat()),
                )
                added += 1
                starred += starred_flag
        if not dry_run:
            conn.commit()
        print(f"归档新增 {added} 条（点词 ★ {starred}），坏行 {skipped}，"
              f"库内共 {conn.execute('SELECT COUNT(*) FROM materials').fetchone()[0]} 条")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(archive(dry_run="--dry" in sys.argv))
