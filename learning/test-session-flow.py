#!/usr/bin/env python3
"""集中学习会话流程测试（方案 2026-09-20 版）。

不调真 claude -p（判分 / 造卡 / 场景生成全 mock），用临时库跑完整状态机。
跑法：python3 test-session-flow.py   （全过输出 PASS 清单，失败 exit 1）
"""

from __future__ import annotations

import json
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

import english_lib as lib
import session

PASS = []
FAIL = []


def check(name: str, cond: bool, detail: str = ""):
    (PASS if cond else FAIL).append(name)
    print(("✅ " if cond else "❌ ") + name + (f"　{detail}" if detail and not cond else ""))


# --- 测试环境 -----------------------------------------------------------

tmpdir = tempfile.TemporaryDirectory()
DB = Path(tmpdir.name) / "test-cards.db"
GAPS = Path(tmpdir.name) / "gaps.jsonl"

lib.DB_PATH = DB
lib.GAPS_PATH = GAPS

SCORE_VERDICT = {"usable": True, "native": True, "fix": "", "why": ""}
VERIFY_VERDICT = {"usable": True, "used_target": True, "fix": "", "why": ""}
CARD_FIELDS = {
    "zh_scene": "会议中表示可以推进",
    "en_sentence": "I am comfortable moving forward.",
    "cloze": "{{c1::I am comfortable moving forward::我认为可以推进}}.",
    "variant_scene": "Given the rollback plan, I'm comfortable moving forward this weekend.",
}
SCORE_FAIL = {"on": False}


def score_answer_mock(card, answer):
    return None if SCORE_FAIL["on"] else dict(SCORE_VERDICT)


lib.score_answer = score_answer_mock
lib.score_verify = lambda card, scene, answer: dict(VERIFY_VERDICT)
lib.make_new_scene = lambda card: "周会上被点名：这个方案你敢不敢直接拍板？"
lib.make_card_fields = lambda chunk, scene: dict(CARD_FIELDS)

conn = lib.connect()
lib.ensure_schema(conn)


def say(text):
    reply, code = session.handle(text, conn)
    return reply


def state():
    return lib.read_state(conn)


def card_row(cid):
    return conn.execute("SELECT * FROM cards WHERE id = ?", (cid,)).fetchone()


def seed_card(cid, chunk):
    due = lib.now().isoformat()
    conn.execute(
        "INSERT INTO cards (id, kind, chunk, zh_scene, en_sentence, cloze, variant_scene, "
        "source, created_at, due, fsrs_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (cid, "production", chunk, "场景" + chunk, f"Use {chunk} here.",
         f"{{{{c1::{chunk}::{chunk}提示}}}}", f"Another day, {chunk} again.",
         "seed-wordlist", "2026-09-16T00:00:00+00:00", due,
         json.dumps({"state": 0, "due": due, "step": 0})),
    )
    conn.commit()


def practice_answer():
    """当前题：判分 → 自评 3，完整走一格，返回最后一拍的回复。"""
    say("an acceptable english answer")
    return say("3")


# --- 1. schema 与种子迁移 -------------------------------------------------

cols = {r["name"] for r in conn.execute("PRAGMA table_info(cards)")}
check("schema 新列就位（status / grad_state / priority）",
      {"status", "grad_state", "priority"} <= cols)

seed_card(101, "get back to you shortly")
seed_card(102, "keep you posted")
seed_card(103, "feel free to ask")
conn.execute("INSERT INTO review_log (card_id, rating, review_time) VALUES (101, 3, ?)",
             ((lib.now() - timedelta(days=1)).isoformat(),))
conn.commit()
lib.ensure_schema(conn)  # 再跑触发「未学种子卡转候选」
check("作答过的卡保持 active", card_row(101)["status"] == "active")
# 101 作答过、due 推到未来：不干扰第 4 段「激活新卡后第一题」的题序断言
conn.execute("UPDATE cards SET due = ? WHERE id = 101",
             ((lib.now() + timedelta(days=2)).isoformat(),))
conn.commit()
check("未学种子卡转候选（priority=3）",
      card_row(102)["status"] == "candidate" and card_row(102)["priority"] == 3)

# --- 2. 无会话 / 退出码协议 ------------------------------------------------

_, code = session.handle("I want to practice English now", conn)
check("无会话英文消息 → exit 2", code == 2)

# --- 3. 开始学习：集中学习展示 ---------------------------------------------

reply = say("开始学习")
check("开始学习进入 learning 展示", "集中学习" in reply and "学好了" in reply)
learn_ids = json.loads(state()["learn_ids"])
check("候选按额度只展示 2 张", len(learn_ids) == 2)
_, code = session.handle("这轮先不练，有别的事", conn)
check("learning 阶段中文 → exit 3 不接管", code == 3)

# --- 4. 学好了，开始练：激活 → 出题 → 判分 → 自评 --------------------------

reply = say("学好了，开始练")
check("激活后出第一题（挖空）", "____" in reply)
activated = conn.execute(
    "SELECT COUNT(*) FROM activation_log WHERE activated_on = ?", (lib.today_cst(),)
).fetchone()[0]
check("activation_log 记 2 张（当日额度）", activated == 2)

reply = say("I am comfortable moving forward")
check("判分返回两轴 + 自评提示", "能用" in reply and "自评" in reply)
check("判分后 phase=rating", state()["phase"] == "rating")

reply = say("3")
check("自评落账并出下一题", "记下了" in reply)
row = conn.execute(
    "SELECT rating, usable FROM review_log WHERE card_id = ? ORDER BY id DESC LIMIT 1",
    (learn_ids[0],),
).fetchone()
check("review_log 写入 usable=1", row and row["rating"] == 3 and row["usable"] == 1)

# --- 5. 判分失败：保留题目，重试不重复记账 ---------------------------------

before = conn.execute("SELECT COUNT(*) FROM review_log").fetchone()[0]
SCORE_FAIL["on"] = True
reply = say("tried again but grading is down")
check("判分失败提示重发", "没跑通" in reply)
SCORE_FAIL["on"] = False
after = conn.execute("SELECT COUNT(*) FROM review_log").fetchone()[0]
check("判分失败不写 review_log", before == after)
final_reply = practice_answer()
check("重试判分成功并走完自动结算", state()["status"] == "idle" and "豆包" in final_reply)

# --- 6. 队列走完自动结算；同日再开无新卡 ------------------------------------

conn.execute("UPDATE cards SET due = ? WHERE id IN (101, 102, 103)",
             ((lib.now() - timedelta(hours=1)).isoformat(),))
conn.commit()
reply = say("开始学习")
check("同日额度用完 → 到期卡直接进练习、不出新卡",
      state()["status"] == "answering" and "集中学习" not in reply)
practice_answer()                     # 练完第 1 张，队列还剩 → 不自动结算
reply = say("结束学习")
check("手动结算含口语 prompt", "豆包" in reply)

# --- 7. 暂停 / 继续（rating 中断恢复） --------------------------------------

say("开始学习")                          # 101 到期 → answering 出题
say("an answer that gets scored")      # → rating
check("判分后暂停前 phase=rating", state()["phase"] == "rating")
say("暂停学习")
_, code = session.handle("english while paused", conn)
check("暂停期间英文 → exit 3", code == 3)
reply = say("继续学习")
check("rating 阶段恢复只重发自评提示（不重出题干）", "自评" in reply and "____" not in reply)
say("3")
say("结束学习")

# --- 8. 毕业：三次不同日 → eligible → 换场景检验 → 掌握 ---------------------

conn.execute("INSERT OR IGNORE INTO activation_log VALUES (101, '2026-09-10')")
for day in (12, 13, 14):
    conn.execute(
        "INSERT INTO review_log (card_id, rating, review_time, usable) VALUES (101, 3, ?, 1)",
        (datetime(2026, 9, day, 2, 0, 0, tzinfo=timezone.utc).isoformat(),),
    )
conn.execute("UPDATE cards SET status='active', due=? WHERE id=101",
             ((lib.now() - timedelta(hours=1)).isoformat(),))
conn.commit()
lib.check_graduation(conn, 101)
check("三次不同日达标 → eligible", card_row(101)["grad_state"] == "eligible")

reply = say("开始学习")
check("隔日会话先出换场景检验（无英文提示）", "换场景检验" in reply and "____" not in reply)
check("verify 状态已置", bool(state().get("verify")))
reply = say("Let us move ahead with the launch plan next week")
check("检验通过 → 待用户确认", "掌握" in reply)
reply = say("掌握")
check("确认后 suspended + verified",
      card_row(101)["status"] == "suspended" and card_row(101)["grad_state"] == "verified")
say("结束学习")

# --- 9. 记表达 / 想练 / 生词本 ----------------------------------------------

say("记表达：这个数据怎么看")
check("记表达落 gaps.jsonl", GAPS.exists() and "这个数据怎么看" in GAPS.read_text(encoding="utf-8"))

conn.execute(
    "INSERT INTO materials (ts, text, translated, starred) VALUES (?, ?, ?, 1)",
    ("2026-09-20T10:00:00+08:00", "top of funnel", "漏斗顶部"),
)
conn.execute(
    "INSERT INTO materials (ts, text, translated) VALUES (?, ?, ?)",
    ("2026-09-19T10:00:00+08:00", "rollout", "推广"),
)
conn.commit()
reply = say("生词本")
check("生词本首页含 ★ 点词", "★" in reply and "top of funnel" in reply)
reply = say("生词本 rollout")
check("关键词查询命中且只出匹配行", "rollout" in reply and "top of funnel" not in reply)

say("想练 dig into the numbers")
row = conn.execute(
    "SELECT status, priority, source FROM cards WHERE chunk='dig into the numbers'"
).fetchone()
check("想练造卡入候选（priority=0, reading-pick）",
      row and row["status"] == "candidate" and row["priority"] == 0
      and row["source"] == "reading-pick")

# --- 收尾 -------------------------------------------------------------------

print()
print(f"通过 {len(PASS)} / 失败 {len(FAIL)}")
if FAIL:
    print("失败项：", "、".join(FAIL))
    sys.exit(1)
print("全部通过")
tmpdir.cleanup()
