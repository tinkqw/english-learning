#!/usr/bin/env python3
"""集中学习会话引擎（方案 §3.4 / 2026-09-20 版）。

answer.py 是唯一入口（bot 的转发协议不变：exit 0=接管 / 2=无会话 / 3=不像答案），
本模块承载全部逻辑：开始 / 学习展示 / 练习 / 自评 / 暂停 / 结束 / 毕业检验 / 生词本查询。

会话状态存 review_state 表（session: 前缀，与旧 review.py 的裸键隔离，旧任务不冲突）：
    status: idle | learning | answering | paused
    phase（answering 内）: answer | rating
    queue / cursor / learn_ids / new_ids / practiced_ids / done / verify_queue / verify / grad_pending
"""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime

import english_lib as lib

RATING_MAP = {"1": 1, "2": 2, "3": 3, "打不出": 1, "卡壳": 2, "顺畅": 3}
RATING_HINT = "自评：1 打不出 / 2 打出但卡壳 / 3 顺畅"
CONTROL_WORDS = {"skip", "跳过"}

ACTIVATION_QUOTA_HINT = "（三来源每天最多 2 张新激活）"


# --- 小工具 --------------------------------------------------------------

def card_by_id(conn, card_id):
    return conn.execute("SELECT * FROM cards WHERE id = ?", (card_id,)).fetchone()


def card_by_chunk(conn, chunk):
    return conn.execute("SELECT * FROM cards WHERE chunk = ?", (chunk,)).fetchone()


def sget(state, key, default=None):
    return state.get(key, default)


def activated_today(conn) -> int:
    return conn.execute(
        "SELECT COUNT(DISTINCT card_id) FROM activation_log WHERE activated_on = ?",
        (lib.today_cst(),),
    ).fetchone()[0]


def due_cards(conn):
    return conn.execute(
        "SELECT * FROM cards WHERE status = 'active' AND kind = 'production' "
        "AND due <= ? ORDER BY due ASC",
        (lib.now().isoformat(),),
    ).fetchall()


def pending_candidates(conn, limit):
    return conn.execute(
        "SELECT * FROM cards WHERE status = 'candidate' "
        "ORDER BY priority ASC, id ASC LIMIT ?",
        (limit,),
    ).fetchall()


def looks_like_answer(text: str, phase: str) -> bool:
    """活动会话里只吞像答案的消息，中文提问 / 链接放回正常对话（协议 exit 3）。"""
    stripped = text.strip()
    if phase == "rating":
        return stripped in RATING_MAP
    if stripped.lower() in CONTROL_WORDS:
        return True
    meaningful = [c for c in stripped if not c.isspace()]
    if not meaningful:
        return False
    latin = sum(1 for c in meaningful if c.isascii() and (c.isalpha() or c in "'-,.!?"))
    return latin / len(meaningful) >= 0.6


# --- 学习展示（方案 §3.4 集中学习：表达 + 释义 + 例句） --------------------

def learn_text(cards) -> str:
    lines = [f"📖 集中学习　本轮 {len(cards)} 张新表达", ""]
    for i, card in enumerate(cards, 1):
        lines.append(f"**{i}. {card['chunk']}**")
        lines.append(f"场景：{card['zh_scene']}")
        lines.append(f"例句：{card['en_sentence']}")
        if card["variant_scene"]:
            lines.append(f"变体：{card['variant_scene']}")
        lines.append("")
    lines.append(f"记住了回「学好了，开始练」；想换掉某张回「不学这张 <表达>」。{ACTIVATION_QUOTA_HINT}")
    return "\n".join(lines)


# --- 组队列（§3.3.5：到期旧卡优先；旧卡多则本轮不加新） --------------------

def verify_queue_build(conn) -> list:
    """eligible 且隔日、且今天没检验过的卡（方案 §3.4 掌握与毕业）。"""
    today = lib.today_cst()
    out = []
    for card in conn.execute(
        "SELECT * FROM cards WHERE grad_state = 'eligible' AND status = 'active' ORDER BY id"
    ).fetchall():
        last = conn.execute(
            "SELECT MAX(substr(review_time, 1, 10)) FROM review_log WHERE card_id = ?",
            (card["id"],),
        ).fetchone()[0]
        # review_time 是 UTC；北京日 D 的上界是 UTC D 16:00，粗略用 D+1 也覆盖偏移
        if last and last >= today:
            continue  # 最后一次作答就在今天 → 没隔日
        last_verify = lib.read_proc(conn, f"last_verify_{card['id']}")
        if last_verify == today:
            continue  # 今天检验过（失败），明天再来
        out.append(card)
    return out


def start_session(conn, state) -> str:
    quota_left = lib.DAILY_ACTIVATION_CAP - activated_today(conn)
    due = due_cards(conn)
    verify = verify_queue_build(conn)

    new_cards = []
    if quota_left > 0 and len(due) < lib.DUE_HEAVY_THRESHOLD:
        new_cards = pending_candidates(conn, quota_left)

    if not due and not new_cards and not verify:
        cand = conn.execute("SELECT COUNT(*) FROM cards WHERE status = 'candidate'").fetchone()[0]
        return (
            f"没有到期的卡。候选区还有 {cand} 张，"
            + ("今天的新卡额度已用完，明天的学习再加新。" if quota_left <= 0 else
               "但到期旧卡已较多，本轮先不加新。" if len(due) >= lib.DUE_HEAVY_THRESHOLD else
               "发「生词本」看材料，看到想练的回「想练 <表达>」。")
        )

    lib.write_state(conn, {
        "started_at": lib.now().isoformat(),
        "paused_total": "0",
        "done": "0",
        "practiced_ids": "[]",
        "new_ids": "[]",
        "learn_ids": "[]",
        "verify_queue": json.dumps([c["id"] for c in verify]),
        "verify": "",
        "grad_pending": "",
    })

    if new_cards:
        lib.write_state(conn, {
            "status": "learning",
            "learn_ids": json.dumps([c["id"] for c in new_cards]),
        })
        return learn_text(new_cards)

    lib.write_state(conn, {"status": "answering", "cursor": "0", "phase": "answer"})
    queue = [c["id"] for c in due_cards(conn)]
    lib.write_state(conn, {"queue": json.dumps(queue)})
    return next_step(conn, lib.read_state(conn))


def activate_and_practice(conn, state) -> str:
    """「学好了，开始练」：激活 learn_ids（§3.3.4 学习展示后才进 FSRS），进入练习。"""
    learn_ids = json.loads(sget(state, "learn_ids", "[]"))
    today = lib.today_cst()
    for card_id in learn_ids:
        conn.execute(
            "INSERT OR IGNORE INTO activation_log (card_id, activated_on) VALUES (?, ?)",
            (card_id, today),
        )
        conn.execute(
            "UPDATE cards SET status = 'active', due = ? WHERE id = ?",
            (lib.now().isoformat(), card_id),
        )
    conn.commit()
    lib.write_state(conn, {
        "status": "answering", "phase": "answer",
        "new_ids": json.dumps(learn_ids),
        "learn_ids": "[]",
    })
    # 队列 = verify 检验 + 到期卡（含刚激活的，due=now）
    queue = [c["id"] for c in due_cards(conn)]
    lib.write_state(conn, {"queue": json.dumps(queue), "cursor": "0"})
    return next_step(conn, lib.read_state(conn))


# --- 出题 / 推进 ----------------------------------------------------------

def next_step(conn, state) -> str:
    """下一条内容：rating 恢复提示 → 毕业检验 → 练习题 → 自动结算。"""
    # 暂停后继续：上一题已判分只差自评，重出题干会让回答被 looks_like_answer 拒掉
    if (sget(state, "status") == "answering" and sget(state, "phase") == "rating"
            and not sget(state, "verify") and not sget(state, "grad_pending")):
        queue = json.loads(sget(state, "queue", "[]"))
        cursor = int(sget(state, "cursor", "0"))
        if cursor < len(queue):
            return f"（继续）上一题已判分，还差自评：\n{RATING_HINT}"

    verify_q = json.loads(sget(state, "verify_queue", "[]"))
    if verify_q and not sget(state, "verify"):
        card = card_by_id(conn, verify_q[0])
        scene = lib.make_new_scene(card)
        if not scene:
            # 生成失败不卡会话：这张今天不检了，继续练题
            lib.write_proc(conn, f"last_verify_{card['id']}", lib.today_cst())
            lib.write_state(conn, {"verify_queue": json.dumps(verify_q[1:])})
            return next_step(conn, lib.read_state(conn))
        lib.write_state(conn, {"verify": json.dumps({"card_id": card["id"], "scene": scene})})
        return (
            f"🎓 换场景检验（练过的表达，隔日无提示用出来）\n\n"
            f"新场景：{scene}\n\n"
            f"用一句英文回应这个场景，自由发挥，不给提示。"
        )

    queue = json.loads(sget(state, "queue", "[]"))
    cursor = int(sget(state, "cursor", "0"))
    if cursor >= len(queue):
        return settle(conn, state)
    card = card_by_id(conn, queue[cursor])
    return lib.question_text(card, cursor + 1, len(queue))


def settle(conn, state) -> str:
    """队列走完或用户主动结束的结算（§3.4 完成与容错：无催促文案）。"""
    done = int(sget(state, "done", "0"))
    practiced = json.loads(sget(state, "practiced_ids", "[]"))
    new_ids = json.loads(sget(state, "new_ids", "[]"))

    started = sget(state, "started_at")
    mins = ""
    if started:
        try:
            start = datetime.fromisoformat(started)
            paused = int(float(sget(state, "paused_total", "0")))
            span = (lib.now() - start).total_seconds() - paused
            mins = f"，净用时约 {int(span / 60)} 分钟"
        except ValueError:
            pass

    lines = [f"本轮完成 {done} 张{mins}。"]
    cards = [card_by_id(conn, i) for i in (new_ids + [p for p in practiced if p not in new_ids])]
    cards = [c for c in cards if c]
    prompts = lib.oral_prompts(cards)
    if prompts:
        lines.append("")
        lines.append("豆包口语 prompt（粘进智能体角色设定，练完让它集中反馈）：")
        for p in prompts:
            lines.append(f"- {p}")
    lines.append("")
    lines.append("想再来一轮发「开始学习」，想看材料发「生词本」。")
    lib.write_state(conn, {"status": "idle", "queue": "[]", "cursor": "0", "verify": "",
                           "verify_queue": "[]", "grad_pending": ""})
    return "\n".join(lines)


def advance(conn, state, extra="") -> str:
    """自评落账后前进一格（§3.4：不截断正在写的回答，自然收尾）。"""
    cursor = int(sget(state, "cursor", "0"))
    lib.write_state(conn, {"cursor": cursor + 1, "phase": "answer"})
    state = lib.read_state(conn)
    tail = next_step(conn, state)
    return f"{extra}\n\n{tail}" if extra else tail


# --- 毕业检验作答（§3.4：通过后由用户确认才 suspended） --------------------

def handle_verify(conn, state, text) -> tuple:
    verify = json.loads(sget(state, "verify"))
    card = card_by_id(conn, verify["card_id"])
    lib.write_proc(conn, f"last_verify_{card['id']}", lib.today_cst())

    verdict = lib.score_verify(card, verify["scene"], text)
    if verdict is None:
        # 判分失败保留题目，重试不重复记账
        return (
            f"判分没跑通，稍等重发这句就行（题目还在）：\n新场景：{verify['scene']}",
            0,
        )

    passed = verdict.get("usable") and verdict.get("used_target")
    if passed:
        lib.write_state(conn, {"verify": "", "grad_pending": card["id"]})
        fix = (verdict.get("fix") or "").strip()
        return (
            f"✅ 检验通过（独立用出来了）" + (f"，最小修正：{fix}" if fix else "") +
            f"\n\n算掌握了吗？回「掌握」就毕业（不再推这张），回「再练练」留在复习。",
            0,
        )

    why = (verdict.get("fix") or verdict.get("why") or "这次没用上或不可用").strip()
    verify_q = json.loads(sget(state, "verify_queue", "[]"))
    lib.write_state(conn, {"verify": "", "verify_queue": json.dumps(verify_q[1:])})
    tail = next_step(conn, lib.read_state(conn))
    return (
        f"❌ {why}\n不急，这张继续按间隔复习，检验过两天再来。\n\n{tail}",
        0,
    )


def handle_grad_confirm(conn, state, text) -> tuple:
    card_id = int(sget(state, "grad_pending"))
    if text.strip() == "掌握":
        conn.execute(
            "UPDATE cards SET status = 'suspended', grad_state = 'verified' WHERE id = ?",
            (card_id,),
        )
        conn.commit()
        lib.write_state(conn, {"grad_pending": ""})
        tail = next_step(conn, lib.read_state(conn))
        return (f"🎓 已毕业。这张不再推；想找回发「恢复 <表达>」。\n\n{tail}", 0)
    lib.write_state(conn, {"grad_pending": ""})
    tail = next_step(conn, lib.read_state(conn))
    return (f"好，留在复习里继续练。\n\n{tail}", 0)


# --- 练习作答 ------------------------------------------------------------

def handle_answer(conn, state, text) -> str:
    queue = json.loads(sget(state, "queue", "[]"))
    cursor = int(sget(state, "cursor", "0"))
    card = card_by_id(conn, queue[cursor])
    phase = sget(state, "phase", "answer")

    if phase == "rating":
        rating = RATING_MAP[text.strip()]
        usable = sget(state, "last_usable")
        usable = int(usable) if usable not in (None, "") else None
        nxt_due = lib.apply_rating(conn, card, rating, usable)
        practiced = json.loads(sget(state, "practiced_ids", "[]"))
        practiced.append(card["id"])
        lib.write_state(conn, {
            "practiced_ids": json.dumps(practiced),
            "done": int(sget(state, "done", "0")) + 1,
            "last_usable": "",
        })
        extra = f"记下了，下次 {nxt_due}。"
        if rating == 3 and usable == 1 and lib.check_graduation(conn, card["id"]):
            extra += "\n🎓 这张三次不同日独立答对，下次开始学习时会做换场景检验。"
        return advance(conn, lib.read_state(conn), extra)

    if text.lower() in {"skip", "跳过"}:
        lib.apply_rating(conn, card, 1, None)  # 打不出 = Again，不再问自评
        practiced = json.loads(sget(state, "practiced_ids", "[]"))
        practiced.append(card["id"])
        lib.write_state(conn, {"practiced_ids": json.dumps(practiced),
                               "done": int(sget(state, "done", "0")) + 1})
        return advance(conn, lib.read_state(conn),
                       f"参考：{card['en_sentence']}\n打不出记 Again，下次再见。")

    verdict = lib.score_answer(card, text)
    if verdict is None:
        # 判分失败：保留题目与进度，重试不重复记作答（§3.8.7）
        return (f"判分没跑通，稍等重发你的回答就行，题目还在。\n"
                f"{lib.question_text(card, cursor + 1, len(queue))}")

    usable = "✅ 能用" if verdict.get("usable") else "❌ 不能用"
    native = "✅ 地道" if verdict.get("native") else "⚠️ 不够地道"
    lines = [f"{usable}　{native}"]
    fix = (verdict.get("fix") or "").strip()
    if fix:
        why = (verdict.get("why") or "").strip()
        lines.append(f"改：{fix}" + (f"（{why}）" if why else ""))
    lines.append(f"参考：{card['en_sentence']}")
    lib.write_state(conn, {"phase": "rating", "last_usable":
                           "1" if verdict.get("usable") else "0"})
    return "\n".join(lines) + f"\n\n{RATING_HINT}"


# --- 生词本查询（§3.6：摘要有上限，全量可查可翻页） ------------------------

def handle_vocabulary(conn, arg: str) -> str:
    arg = (arg or "").strip()
    page = 1
    where, params = "1=1", []
    if arg[:1] in {"p", "P"} and arg[1:].isdigit():
        page = max(1, int(arg[1:]))
    elif arg and len(arg) == 10 and arg[4] == "-" and arg[:4].isdigit():
        where, params = "substr(ts, 1, 10) = ?", [arg]
    elif arg:
        where, params = "(text LIKE ? OR translated LIKE ?)", [f"%{arg}%", f"%{arg}%"]

    total = conn.execute(f"SELECT COUNT(*) FROM materials WHERE {where}", params).fetchone()[0]
    rows = conn.execute(
        f"SELECT * FROM materials WHERE {where} ORDER BY ts DESC LIMIT ? OFFSET ?",
        params + [lib.PAGE_SEGMENTS, (page - 1) * lib.PAGE_SEGMENTS],
    ).fetchall()

    if not rows:
        return "这个条件下没有归档材料。21:00 会把当天的查询归档进来；发「生词本」看最新的。"
    lines = [f"📚 生词本　第 {page} 页（共 {(total + lib.PAGE_SEGMENTS - 1) // lib.PAGE_SEGMENTS} 页，{total} 条）", ""]
    for r in rows:
        star = "★ " if r["starred"] else ""
        text = (r["text"] or "").replace("\n", " ")[:60]
        lines.append(f"{star}{r['ts'][:16]}　{text}")
        if r["translated"]:
            lines.append(f"　↳ {(r['translated'] or '')[:60]}")
        lines.append("")
    lines.append("翻页发「生词本 p2」；查关键词发「生词本 <词>」；想练哪个表达发「想练 <英文表达>」。")
    return "\n".join(lines)


# --- 命令 ----------------------------------------------------------------

def handle(text: str, conn: sqlite3.Connection) -> tuple:
    """返回 (回复, exit_code)。code 2 = 无会话不接管；3 = 不像答案不接管。"""
    state = lib.read_state(conn)
    status = sget(state, "status", "idle")
    stripped = text.strip()

    # --- 全局命令（任何状态都响应） ---
    if stripped in {"开始学习", "学英语", "开始学"}:
        if status in {"learning", "answering", "paused"}:
            return ("上一轮还没结束：回「继续学习」接着来，或「结束学习」结算后重开。", 0)
        return start_session(conn, state), 0

    if stripped in {"暂停学习", "暂停"}:
        if status not in {"learning", "answering"}:
            return ("现在没有在进行的会话。", 0)
        lib.write_state(conn, {"status": "paused", "resume_status": status,
                               "pause_started": lib.now().isoformat()})
        return "已暂停，进度保留。回「继续学习」恢复，或「结束学习」结算。", 0

    if stripped in {"继续学习", "继续"}:
        if status != "paused":
            return ("没有暂停中的会话。要开始发「开始学习」。", 0)
        items = {"status": sget(state, "resume_status", "answering")}
        pause_started = sget(state, "pause_started")
        if pause_started:
            span = (lib.now() - datetime.fromisoformat(pause_started)).total_seconds()
            items["paused_total"] = int(float(sget(state, "paused_total", "0"))) + int(span)
        lib.write_state(conn, items)
        state = lib.read_state(conn)
        if sget(state, "status") == "learning":
            learn_ids = json.loads(sget(state, "learn_ids", "[]"))
            cards = [card_by_id(conn, i) for i in learn_ids]
            return learn_text([c for c in cards if c]), 0
        return next_step(conn, state), 0

    if stripped in {"结束学习", "结束"}:
        if status == "idle":
            return ("没有进行中的会话。", 0)
        return settle(conn, state), 0

    if stripped.startswith("生词本"):
        return handle_vocabulary(conn, stripped[3:]), 0

    if stripped.startswith("想练"):
        chunk = stripped[2:].strip()
        if not chunk:
            return "用法：想练 <英文表达>（会当场做成候选卡，学习时展示后激活）。", 0
        if card_by_chunk(conn, chunk):
            return f"「{chunk}」已经在卡库里了。", 0
        fields = lib.make_card_fields(chunk, "用户从阅读材料里点选的表达，未附场景")
        if not fields:
            return "造卡没跑通，稍后再发一次。", 0
        lib.insert_candidate(conn, chunk, fields, source="reading-pick", priority=0)
        return (f"✅ 已加入候选：{chunk}\n下次「开始学习」会先展示再练（每天最多激活 2 张）。", 0)

    if stripped.startswith("不学这张"):
        chunk = stripped[5:].strip()
        if status != "learning" or not chunk:
            return ("「不学这张 <表达>」只在集中学习展示阶段用。", 0)
        learn_ids = json.loads(sget(state, "learn_ids", "[]"))
        card = card_by_chunk(conn, chunk)
        if not card or card["id"] not in learn_ids:
            return f"本轮展示里没有「{chunk}」。", 0
        learn_ids.remove(card["id"])
        conn.execute("UPDATE cards SET status = 'dropped' WHERE id = ?", (card["id"],))
        conn.commit()
        if not learn_ids:
            lib.write_state(conn, {"learn_ids": "[]", "status": "answering",
                                   "queue": "[]", "cursor": "0", "phase": "answer"})
            queue = [c["id"] for c in due_cards(conn)]
            lib.write_state(conn, {"queue": json.dumps(queue), "cursor": "0"})
            return next_step(conn, lib.read_state(conn)), 0
        lib.write_state(conn, {"learn_ids": json.dumps(learn_ids)})
        cards = [card_by_id(conn, i) for i in learn_ids]
        return learn_text([c for c in cards if c]), 0

    if stripped.startswith("不练"):
        chunk = stripped[3:].strip()
        card = card_by_chunk(conn, chunk)
        if not card or card["status"] != "candidate":
            return f"候选区没有「{chunk or '…'}」。", 0
        conn.execute("UPDATE cards SET status = 'dropped' WHERE id = ?", (card["id"],))
        conn.commit()
        return f"已从候选移除「{chunk}」（材料归档仍保留）。", 0

    if stripped.startswith("恢复"):
        chunk = stripped[2:].strip()
        card = card_by_chunk(conn, chunk)
        if not card or card["status"] != "suspended":
            return f"没有已毕业的「{chunk or '…'}」。", 0
        conn.execute("UPDATE cards SET status = 'active', grad_state = NULL WHERE id = ?",
                     (card["id"],))
        conn.commit()
        return f"已恢复「{chunk}」进复习。", 0

    if stripped.startswith("记表达"):
        content = stripped.split("：", 1)[-1].split(":", 1)[-1].strip()
        if not content or content == stripped:
            return "用法：记表达：<一句中文>（会后想到说不出的话，记下来夜间补英文）。", 0
        rec = {"ts": lib.now().isoformat(), "source": "meeting", "mode": "meeting",
               "zh": content, "en_draft": "", "en": "", "chunks": [], "scene": ""}
        with lib.GAPS_PATH.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return f"已记下，今晚后台补英文成候选，学习时展示。", 0

    # --- 会话内交互 ---
    if sget(state, "grad_pending"):
        if stripped in {"掌握", "再练练"}:
            return handle_grad_confirm(conn, state, stripped)
        return ("先确认上一张：回「掌握」毕业，或「再练练」留在复习。", 0)

    if status == "learning":
        if stripped in {"学好了，开始练", "学好了", "开始练"}:
            return activate_and_practice(conn, state), 0
        return ("集中学习展示中：回「学好了，开始练」进入练习，或「不学这张 <表达>」换卡。", 3)

    if status == "answering":
        if sget(state, "verify"):
            if looks_like_answer(stripped, "answer"):
                return handle_verify(conn, state, stripped)
            return "换场景检验进行中，回一句英文（不想现在检就发「结束学习」）。", 3
        phase = sget(state, "phase", "answer")
        if looks_like_answer(stripped, phase):
            return handle_answer(conn, state, stripped), 0
        return "", 3

    if status == "paused":
        return "", 3  # 暂停期间普通英文消息不接管（§3.4 入口与控制）

    return "", 2  # 无会话：bot 按普通消息处理
