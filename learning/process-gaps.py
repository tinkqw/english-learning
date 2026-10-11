#!/usr/bin/env python3
"""会后 / 写作缺口加工（方案 §3.2② / §3.3）：gaps.jsonl → 候选卡。

可定时跑（如每晚 23:00），也可手动跑。
- 行号游标（proc_state.gaps_cursor）：只加工上次成功位置之后的记录，
  停机期间积累和晚间新增在下次运行补齐（§3.3）
- 送模型的只有语块与场景概括（不送 Slack / 会议原文）——
  采集时已把 chunks+scene 写好，本脚本不重读原文
- 同 chunk 已存在（任何状态）不重复建卡（§3.3.1 按语块去重合并）
- 默认不发任何数量通知（§3.7）
"""

from __future__ import annotations

import json
import sys

import english_lib as lib

# 候选优先级（§3.2③）：必要纠错 / 会后缺口 1，翻译弱信号 2
PRIORITY_BY_MODE = {"polish": 1, "meeting": 1, "translate": 2}


def process(dry_run: bool = False) -> int:
    if not lib.GAPS_PATH.exists():
        print("gaps.jsonl 不存在，跳过")
        return 0
    conn = lib.connect()
    try:
        lib.ensure_schema(conn)
        cursor = int(lib.read_proc(conn, "gaps_cursor") or "0")
        made = failed = 0

        lines = lib.GAPS_PATH.read_text(encoding="utf-8").splitlines()
        for i, line in enumerate(lines[cursor:], start=cursor):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                failed += 1
                cursor = i + 1
                continue

            chunks = rec.get("chunks") or []
            mode = rec.get("mode") or "translate"
            source = rec.get("source") or "slack"
            scene = rec.get("scene") or "（采集时未附场景）"
            priority = PRIORITY_BY_MODE.get(mode, 2)
            src_tag = f"{source}-{mode}"

            for chunk in chunks:
                chunk = (chunk or "").strip()
                if not chunk:
                    continue
                if conn.execute("SELECT 1 FROM cards WHERE chunk = ?", (chunk,)).fetchone():
                    continue  # 已有同语块卡（任何状态）不重复建
                if dry_run:
                    print(f"[dry] {src_tag} {chunk} ← {scene}")
                    made += 1
                    continue
                fields = lib.make_card_fields(chunk, scene)
                if not fields:
                    print(f"造卡失败：{chunk}（下次运行重试）", file=sys.stderr)
                    continue  # 不推进游标里的这张？行级游标只能整行推进——失败块跳过，行继续
                lib.insert_candidate(conn, chunk, fields, source=src_tag, priority=priority)
                made += 1

            cursor = i + 1  # 该行处理完（单块造卡失败不阻塞整行，避免毒丸卡死游标）
            if not dry_run:
                lib.write_proc(conn, "gaps_cursor", str(cursor))

        total = conn.execute(
            "SELECT COUNT(*) FROM cards WHERE status = 'candidate'"
        ).fetchone()[0]
        print(f"加工新增候选 {made} 个（失败块 {failed}），游标 {cursor}/{len(lines)}，"
              f"候选区共 {total} 张")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(process(dry_run="--dry" in sys.argv))
