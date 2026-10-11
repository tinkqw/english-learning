#!/usr/bin/env python3
"""seed-cards.py — 一次性写入种子卡到 $ENGLISH_DATA_DIR/cards.db

下面的 SEEDS 是一组通用的职场英语示例表达，换成你自己常用、但说不顺的表达效果更好。
种子卡入库后先进候选区，「开始学习」时按每日额度展示、激活。

合规：模型只收语块 + 中性场景概括，不送原文。UNIQUE(chunk, source)，可重跑（跳过已有）。
变体句生成失败不影响入库，variant_scene 留空。
"""
import json
import sqlite3
import sys
from datetime import datetime

from fsrs import Card, FSRS

import english_lib as lib

SCHEMA = """
CREATE TABLE IF NOT EXISTS cards (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL DEFAULT 'production',   -- production | recognition
  chunk TEXT NOT NULL,
  zh_scene TEXT NOT NULL,
  en_sentence TEXT NOT NULL,
  cloze TEXT NOT NULL,
  variant_scene TEXT,
  source TEXT NOT NULL,                      -- seed-wordlist | slack-translate | meeting | reading-pick ...
  created_at TEXT NOT NULL,
  due TEXT NOT NULL,
  fsrs_json TEXT NOT NULL,
  phonetic TEXT,
  UNIQUE(chunk, source)
);
CREATE TABLE IF NOT EXISTS review_log (
  id INTEGER PRIMARY KEY,
  card_id INTEGER NOT NULL REFERENCES cards(id),
  rating INTEGER NOT NULL,                   -- 1 Again 2 Hard 3 Good 4 Easy
  review_time TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS review_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""

W = "seed-wordlist"

SEEDS = [
    # ---- 邮件 / 会议连接短语 ----
    dict(chunk="please find attached", hint="附件请查收", scene="发邮件附上文件",
         sentence="Please find attached the updated proposal.", surface="Please find attached", source=W),
    dict(chunk="thanks for the quick turnaround", hint="多谢这么快处理", scene="感谢对方快速处理",
         sentence="Thanks so much for the quick turnaround.", surface="for the quick turnaround", source=W),
    dict(chunk="please bear with us", hint="请再等等 / 多包涵", scene="请对方再等待",
         sentence="Please bear with us while we finish the review.", surface="Please bear with us", source=W),
    dict(chunk="get back to you shortly", hint="稍后回复你", scene="承诺稍后回复",
         sentence="I will look into this and get back to you shortly.", source=W),
    dict(chunk="keep you posted", hint="随时同步进展", scene="承诺持续同步进展",
         sentence="I'll keep you posted on the timeline.", source=W),
    dict(chunk="feel free to …", hint="尽管 / 随时", scene="邀请对方随时做某事",
         sentence="Feel free to reach out if anything is unclear.", surface="Feel free to", source=W),
    dict(chunk="touch base", hint="碰个头 / 对一下", scene="约时间碰头对齐",
         sentence="Let's touch base again next week.", source=W),
    dict(chunk="for your reference", hint="供你参考", scene="发材料供参考",
         sentence="I've attached last quarter's numbers for your reference.", source=W),
    dict(chunk="for visibility", hint="供（相关人）知悉", scene="拉人进邮件知悉",
         sentence="Adding the design team here for visibility.", source=W),
    dict(chunk="looping you in", hint="把你拉进来（知会）", scene="把同事拉进沟通",
         sentence="Looping you in since you own the release.", surface="Looping you in", source=W),
    dict(chunk="sorry for the late reply", hint="抱歉回复晚了", scene="回复晚了致歉",
         sentence="Sorry for the late reply, it's been a busy week.", surface="Sorry for the late reply", source=W),
    # ---- 推进 / 表态 ----
    dict(chunk="I am comfortable moving forward", hint="我认为可以推进", scene="表达可以推进",
         sentence="I am comfortable moving forward with this plan.", source=W),
    dict(chunk="the risk is manageable", hint="风险可控", scene="评估风险可控",
         sentence="The risk is manageable if we roll it out gradually.", surface="The risk is manageable", source=W),
    dict(chunk="hold off on …", hint="暂缓", scene="请对方暂缓某动作",
         sentence="Let's hold off on the announcement until Friday.", surface="hold off on", source=W),
    dict(chunk="flag", hint="提出 / 标记", scene="邀请对方提出问题或反馈",
         sentence="Please flag anything that looks off.", surface="flag", source=W),
    dict(chunk="close this out", hint="把这事收尾", scene="把事项收尾",
         sentence="Let's close this out by end of day.", source=W),
    dict(chunk="give the green light", hint="放行 / 批准", scene="拿到放行批准",
         sentence="Legal gave the green light this morning.", surface="gave the green light", source=W),
    dict(chunk="wrap up", hint="收尾 / 结束", scene="会议或项目收尾",
         sentence="We wrapped up the retro today.", surface="wrapped up", source=W),
    dict(chunk="pull together", hint="汇总 / 整理好", scene="承诺汇总材料发对方",
         sentence="I'll pull together a summary and share it tomorrow.", source=W),
    dict(chunk="haven't had the chance to …", hint="还没腾出手…", scene="说明还没来得及做某事",
         sentence="I haven't had the chance to review it yet.", surface="haven't had the chance to", source=W),
]


def build_cloze(seed):
    surface = seed.get("surface") or seed["chunk"]
    idx = seed["sentence"].casefold().find(surface.casefold())
    if idx < 0:
        raise ValueError(f"surface 不在句中: {surface!r} vs {seed['sentence']!r}")
    actual = seed["sentence"][idx:idx + len(surface)]
    return seed["sentence"].replace(
        actual, "{{c1::" + actual + "::" + seed["hint"] + "}}", 1)


VARIANT_PROMPT = ("只输出一行 JSON，不要任何其他文字：{{\"rows\": [{{\"i\": 编号, \"example\": \"...\"}}]}}。"
                  "对每个条目写一句换场景的英文职场例句（自然包含该语块或其变形，不要照抄输入场景）。"
                  "输入：{payload}")


def model_variants(pending):
    """pending: [(id, seed)] → {id: example_str}，失败返回部分结果。走 claude -p（english_lib.claude_json）。"""
    result = {}
    for i in range(0, len(pending), 10):
        batch = pending[i:i + 10]
        payload = [{"i": cid, "chunk": s["chunk"], "scene": s["scene"]} for cid, s in batch]
        out = lib.claude_json(VARIANT_PROMPT.format(payload=json.dumps(payload, ensure_ascii=False)))
        if not out:
            print(f"  [warn] 变体句批次失败（{batch[0][0]}..{batch[-1][0]}）", file=sys.stderr)
            continue
        for item in out.get("rows") or []:
            if "i" in item and item.get("example"):
                result[item["i"]] = item["example"]
    return result


def main():
    lib.DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(lib.DB_PATH)
    conn.executescript(SCHEMA)

    fsrs = FSRS(request_retention=0.9)
    now = datetime.now().isoformat(timespec="seconds")

    pending = []
    for seed in SEEDS:
        card = Card()
        d = card.to_dict()
        cur = conn.execute(
            "INSERT INTO cards (kind, chunk, zh_scene, en_sentence, cloze, source, created_at, due, fsrs_json) "
            "VALUES ('production',?,?,?,?,?,?,?,?) "
            "ON CONFLICT(chunk, source) DO NOTHING",
            (seed["chunk"], seed["scene"], seed["sentence"], build_cloze(seed),
             seed["source"], now, d["due"], json.dumps(d, ensure_ascii=False)))
        if cur.rowcount:
            pending.append((cur.lastrowid, seed))
    conn.commit()

    print(f"新入库 {len(pending)} 张（已存在跳过 {len(SEEDS) - len(pending)}）")
    if not pending:  # 重跑：补此前生成失败的变体句
        pending = [(r[0], {"chunk": r[1], "scene": r[2]}) for r in conn.execute(
            "SELECT id, chunk, zh_scene FROM cards WHERE variant_scene IS NULL")]
        if pending:
            print(f"回填模式：{len(pending)} 张缺变体句")
    if pending and "--no-variants" not in sys.argv:
        variants = model_variants(pending)
        for cid, example in variants.items():
            conn.execute("UPDATE cards SET variant_scene=? WHERE id=?", (example, cid))
        print(f"变体句 {len(variants)}/{len(pending)}")

    for row in conn.execute("select source, count(*) from cards group by source"):
        print(f"  {row[0]}: {row[1]}")
    total = conn.execute("select count(*) from cards").fetchone()[0]
    conn.commit()
    conn.close()
    print(f"cards.db 共 {total} 张")


if __name__ == "__main__":
    main()
