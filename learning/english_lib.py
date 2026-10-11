#!/usr/bin/env python3
"""英语表达共用库：DB / schema 自检 / 判分 / FSRS / 造卡（方案 2026-09-20 版）。

被 session.py（会话引擎）、daily-digest.py、process-gaps.py、remind.py 共用。
兼容 Python 3.9：不用 3.10+ 语法（match、X | Y 运行时类型）。
"""

from __future__ import annotations

import json
import logging
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

# 数据目录：环境变量 ENGLISH_DATA_DIR，默认 ~/Data/english-learning。
# Easydict 设置里的「生词本目录」要指向同一个目录（words.jsonl 写在这里）。
DATA_DIR = Path(os.environ.get("ENGLISH_DATA_DIR") or Path.home() / "Data" / "english-learning")
DB_PATH = DATA_DIR / "cards.db"
GAPS_PATH = DATA_DIR / "gaps.jsonl"
WORDS_PATH = DATA_DIR / "words.jsonl"
LOG_DIR = Path(os.environ.get("ENGLISH_LOG_DIR") or DATA_DIR / "logs")
LOG_PATH = LOG_DIR / "english-review.log"

CST = timezone(timedelta(hours=8))  # 北京时间（方案：额度与归档按北京日）

# 方案 §3.3.5：三来源合计每天新激活 ≤2；§3.4 口语 ≤3 条；§3.2③ 日报每页 ≤8 段
DAILY_ACTIVATION_CAP = 2
ORAL_PROMPT_CAP = 3
PAGE_SEGMENTS = 8
# §3.3.5「旧卡占满本轮预算则不加新」的操作判据：到期旧卡达到该数即本轮不激活新卡
DUE_HEAVY_THRESHOLD = 5

CLAUDE_TIMEOUT = 120

LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler(LOG_PATH, encoding="utf-8")],
)
log = logging.getLogger("english-lib")

CLOZE_RE = re.compile(r"\{\{c\d+::(.+?)::(.+?)\}\}")


def load_env(path=None) -> None:
    """读 KEY=VALUE 格式的配置文件进环境变量（不覆盖已有值）。

    默认读 ENGLISH_ENV_FILE，没设就读本目录的 .env；文件不存在则什么都不做。
    """
    env_path = Path(path or os.environ.get("ENGLISH_ENV_FILE")
                    or Path(__file__).resolve().parent / ".env")
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def now() -> datetime:
    return datetime.now(timezone.utc)


def today_cst() -> str:
    return datetime.now(CST).strftime("%Y-%m-%d")


def connect(db_path=None) -> sqlite3.Connection:
    path = Path(db_path) if db_path else DB_PATH
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


# --- schema 自检（幂等，answer.py 每次启动跑一遍，免独立迁移步骤） --------

def ensure_schema(conn: sqlite3.Connection) -> None:
    # 基础表（真实库已存在，IF NOT EXISTS 兜底新装机 / 测试库）
    conn.execute(
        "CREATE TABLE IF NOT EXISTS cards ("
        "id INTEGER PRIMARY KEY, kind TEXT NOT NULL DEFAULT 'production', "
        "chunk TEXT NOT NULL, zh_scene TEXT NOT NULL, en_sentence TEXT NOT NULL, "
        "cloze TEXT NOT NULL, variant_scene TEXT, source TEXT NOT NULL, "
        "created_at TEXT NOT NULL, due TEXT NOT NULL, fsrs_json TEXT NOT NULL, "
        "phonetic TEXT, UNIQUE(chunk, source))"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS review_log ("
        "id INTEGER PRIMARY KEY, card_id INTEGER NOT NULL REFERENCES cards(id), "
        "rating INTEGER NOT NULL, review_time TEXT NOT NULL)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS review_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    )
    cols = {r["name"] for r in conn.execute("PRAGMA table_info(cards)")}
    if "status" not in cols:
        # candidate = 候选（不进到期队列）；active = 在复习；suspended = 已毕业；dropped = 用户删除的候选
        conn.execute("ALTER TABLE cards ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
    if "grad_state" not in cols:
        # NULL = 未达毕业条件；eligible = 三次不同日达标，待隔日换场景检验；verified = 检验通过（确认后转 suspended）
        conn.execute("ALTER TABLE cards ADD COLUMN grad_state TEXT")
    if "priority" not in cols:
        # 候选优先级（方案 §3.2③）：0 用户点「想练」/ 1 必要纠错与会后缺口 / 2 翻译弱信号 / 3 种子卡。小者优先
        conn.execute("ALTER TABLE cards ADD COLUMN priority INTEGER NOT NULL DEFAULT 3")
    log_cols = {r["name"] for r in conn.execute("PRAGMA table_info(review_log)")}
    if "usable" not in log_cols:
        # 判分「能用」轴（毕业判据之一）；历史行无此值为 NULL，不参与毕业计数
        conn.execute("ALTER TABLE review_log ADD COLUMN usable INTEGER")
    conn.execute(
        "CREATE TABLE IF NOT EXISTS activation_log ("
        "card_id INTEGER NOT NULL, activated_on TEXT NOT NULL, "
        "PRIMARY KEY (card_id, activated_on))"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS materials ("
        "id INTEGER PRIMARY KEY, ts TEXT NOT NULL UNIQUE, "
        "text TEXT NOT NULL, translated TEXT, starred INTEGER DEFAULT 0, "
        "archived_at TEXT)"
    )
    conn.execute(
        "CREATE TABLE IF NOT EXISTS proc_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    )
    # 种子卡迁移（方案 §3.3 / §3.10.3）：从未作答也从未激活的卡 → 候选区（priority=3 存量，
    # 排在「想练」/ 必要纠错 / 会后缺口之后）。幂等：激活过（activation_log）或作答过的卡不动。
    conn.execute(
        "UPDATE cards SET status = 'candidate', priority = 3 "
        "WHERE status = 'active' AND kind = 'production' "
        "AND id NOT IN (SELECT DISTINCT card_id FROM review_log) "
        "AND id NOT IN (SELECT DISTINCT card_id FROM activation_log)"
    )
    conn.commit()


# --- review_state 读写（新键统一 session: / proc: 前缀，与旧 review.py 的键隔离） ---

def read_state(conn: sqlite3.Connection, prefix: str = "session:") -> dict:
    out = {}
    for k, v in conn.execute("SELECT key, value FROM review_state"):
        if k.startswith(prefix):
            out[k[len(prefix):]] = v
    return out


def write_state(conn: sqlite3.Connection, items: dict, prefix: str = "session:") -> None:
    for key, value in items.items():
        conn.execute(
            "INSERT INTO review_state (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (prefix + key, str(value)),
        )
    conn.commit()


def read_proc(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM proc_state WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def write_proc(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO proc_state (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )
    conn.commit()


# --- claude -p -----------------------------------------------------------

def claude_json(prompt: str) -> dict | None:
    """调 claude -p 拿一行 JSON。失败返回 None，调用方降级。"""
    binary = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    if not Path(binary).exists():
        log.error("找不到 claude CLI：%s", binary)
        return None

    env = dict(os.environ)
    env.setdefault("USER", Path.home().name)  # launchd / pm2 下不设 USER

    try:
        proc = subprocess.run(
            [binary, "-p", prompt],
            capture_output=True, text=True, timeout=CLAUDE_TIMEOUT, env=env,
        )
    except subprocess.TimeoutExpired:
        log.error("claude -p 超时")
        return None
    if proc.returncode != 0:
        log.error("claude -p 退出 %s: %s", proc.returncode, proc.stderr[:200])
        return None

    raw = proc.stdout.strip()
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        log.error("claude 输出无 JSON：%s", raw[:200])
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        log.error("JSON 解析失败：%s", m.group(0)[:200])
        return None


# --- 判分（方案 §3.4） ----------------------------------------------------

SCORE_PROMPT = """你是英语表达教练，学习者在练「中文场景 → 说出英文」。

场景：{zh_scene}
目标表达：{chunk}
参考句：{en_sentence}
学习者写的：{answer}

只输出一行 JSON，不要任何其他内容、不要代码围栏：
{{"usable": true/false, "native": true/false, "fix": "", "why": ""}}

判据：
- usable：语义对、语法对，放进那个场景能用；语义语法语境都成立的替代表达也算 true
- native：母语者在职场里真的会这么说（语法对但生硬 → false）
- fix：一行最小修正，只改必要处，不超过 30 字；已经很好就留空字符串
- why：一句话说明为什么这么改，不超过 25 字；无修正就留空字符串"""


def score_answer(card: sqlite3.Row, answer: str) -> dict | None:
    return claude_json(SCORE_PROMPT.format(
        zh_scene=card["zh_scene"], chunk=card["chunk"],
        en_sentence=card["en_sentence"], answer=answer,
    ))


VERIFY_PROMPT = """你是英语表达教练。学习者刚在一轮复习里练过这个表达，现在换一个新工作场景，不看任何提示，检验能否独立用出来。

目标表达：{chunk}
练习时的场景：{zh_scene}
这次的新场景：{new_scene}
学习者写的：{answer}

只输出一行 JSON，不要任何其他内容、不要代码围栏：
{{"usable": true/false, "used_target": true/false, "fix": "", "why": ""}}

判据：
- usable：语义对、语法对，放进新场景能用
- used_target：用上了目标表达（chunk 本身或它的自然变形，时态/人称变化算用上）
- fix / why：最小修正与一句原因，都限 30/25 字内，无修正留空"""


def score_verify(card: sqlite3.Row, new_scene: str, answer: str) -> dict | None:
    return claude_json(VERIFY_PROMPT.format(
        chunk=card["chunk"], zh_scene=card["zh_scene"],
        new_scene=new_scene, answer=answer,
    ))


SCENE_PROMPT = """给一个英语学习者出「换场景检验」题。TA 练过的表达和场景如下：

表达：{chunk}
原场景：{zh_scene}

请换一个明显不同的日常工作场景（开会 / Slack 沟通 / 邮件 / 跨团队协作等），
写 1-2 句中文场景描述，要求学习者在这个场景里把上面的英文表达用出来。
场景描述里不能出现该英文表达本身，也不给任何英文提示。

只输出场景描述本身，不要任何前后缀。"""


def make_new_scene(card: sqlite3.Row) -> str | None:
    """毕业检验用的新工作场景（方案 §3.4：不提供句框与目标语块）。"""
    out = claude_json_text(SCENE_PROMPT.format(chunk=card["chunk"], zh_scene=card["zh_scene"]))
    return out.strip() if out else None


def claude_json_text(prompt: str) -> str | None:
    """和 claude_json 同管道，但要的是纯文本不是 JSON。"""
    binary = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    if not Path(binary).exists():
        return None
    env = dict(os.environ)
    env.setdefault("USER", Path.home().name)
    try:
        proc = subprocess.run(
            [binary, "-p", prompt],
            capture_output=True, text=True, timeout=CLAUDE_TIMEOUT, env=env,
        )
    except subprocess.TimeoutExpired:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


# --- 造卡（候选加工，方案 §3.3：生成 {chunk, zh_scene, en_sentence, cloze, variant_scene}） ---

MAKE_CARD_PROMPT = """你在为一个英语学习者做复习卡。学习者想练这个英文表达：

表达：{chunk}
TA 记下的场景（中性描述，不含人名）：{scene}

只输出一行 JSON，不要任何其他内容、不要代码围栏：
{{"zh_scene": "", "en_sentence": "", "cloze": "", "variant_scene": ""}}

要求：
- zh_scene：一句中文场景（什么情况下说这句话），10 字左右
- en_sentence：含该表达的自然英文例句（通用职场语气，不写具体公司/人名）
- cloze：把 en_sentence 里该表达挖空，格式 {{c1::英文表达::中文提示}}，其余原样保留
- variant_scene：另一个日常工作场景里的完整英文句，同样含该表达"""


def make_card_fields(chunk: str, scene: str) -> dict | None:
    out = claude_json(MAKE_CARD_PROMPT.format(chunk=chunk, scene=scene))
    if not out:
        return None
    need = ("zh_scene", "en_sentence", "cloze", "variant_scene")
    if not all(out.get(k) for k in need):
        log.error("造卡字段不全：%s", out)
        return None
    return {k: out[k] for k in need}


def insert_candidate(conn: sqlite3.Connection, chunk: str, fields: dict,
                     source: str, priority: int) -> int | None:
    """入候选区（status='candidate'）。同 chunk 已存在（任何状态）则跳过，返回 None。"""
    exists = conn.execute("SELECT id FROM cards WHERE chunk = ?", (chunk,)).fetchone()
    if exists:
        return None
    cur = conn.execute(
        "INSERT INTO cards (kind, chunk, zh_scene, en_sentence, cloze, variant_scene, "
        "source, created_at, due, fsrs_json, status, priority) "
        "VALUES (?,?,?,?,?,?,?,?,?,?, 'candidate', ?)",
        ("production", chunk, fields["zh_scene"], fields["en_sentence"], fields["cloze"],
         fields.get("variant_scene"), source, now().isoformat(), now().isoformat(),
         json.dumps({"state": 0}), priority),
    )
    conn.commit()
    return cur.lastrowid


# --- FSRS（方案 §3.4：due 是建议时间，不夹 09:00） ------------------------

def apply_rating(conn: sqlite3.Connection, card: sqlite3.Row, rating: int,
                 usable: int | None) -> str:
    """按自评更新 FSRS 与 due，写 review_log（含判分 usable），返回下次复习描述。"""
    from fsrs import FSRS, Card, Rating, State

    scheduler = FSRS(request_retention=0.9)
    fsrs_card = Card()
    stored = json.loads(card["fsrs_json"])
    for key, value in stored.items():
        if hasattr(fsrs_card, key):
            setattr(fsrs_card, key, value)
    fsrs_card.due = datetime.fromisoformat(stored["due"]) if stored.get("due") else now()
    fsrs_card.state = State(stored.get("state", 0))
    # last_review 是可选属性（全新 Card() 实例上 hasattr 为 False，上面的循环恢复不了它），
    # 不恢复的话 Review 态卡进 repeat() 会 AttributeError
    if stored.get("last_review"):
        fsrs_card.last_review = datetime.fromisoformat(stored["last_review"])

    updated = scheduler.repeat(fsrs_card, now())[Rating(rating)].card
    payload = updated.to_dict()

    conn.execute(
        "UPDATE cards SET due = ?, fsrs_json = ? WHERE id = ?",
        (payload["due"], json.dumps(payload, ensure_ascii=False), card["id"]),
    )
    conn.execute(
        "INSERT INTO review_log (card_id, rating, review_time, usable) VALUES (?, ?, ?, ?)",
        (card["id"], rating, now().isoformat(), usable),
    )
    conn.commit()

    due_local = datetime.fromisoformat(payload["due"]).astimezone(CST)
    delta = due_local - datetime.now(CST)
    if delta < timedelta(0):
        return "已到期，下次开始学习时会再出现"
    minutes = delta.total_seconds() / 60
    if minutes < 60:
        return f"{int(minutes)} 分钟后到期"
    if delta < timedelta(days=1):
        return f"约 {delta.seconds // 3600} 小时后到期"
    return f"{delta.days + 1} 天后（{due_local.strftime('%m-%d')}）"


# --- 毕业判定（方案 §3.4：三个不同日期独立答对且顺畅 → eligible） ----------

def check_graduation(conn: sqlite3.Connection, card_id: int) -> bool:
    """激活日之后（不含激活当天），usable=1 且 rating=3 的不同日期 ≥3 → eligible。

    激活当天是「刚看完答案的初学练习」，不算独立证据（方案 §3.4）。
    """
    row = conn.execute(
        "SELECT activated_on FROM activation_log WHERE card_id = ? ORDER BY activated_on LIMIT 1",
        (card_id,),
    ).fetchone()
    if not row:
        return False
    first_day = row["activated_on"]
    dates = [
        r["d"] for r in conn.execute(
            "SELECT DISTINCT substr(review_time, 1, 10) AS d FROM review_log "
            "WHERE card_id = ? AND usable = 1 AND rating = 3 AND review_time >= ?",
            (card_id, first_day + "T16:00"),  # activated_on 是北京日，review_time 是 UTC（北京日 D 的 UTC 下界是 D-1 16:00）
        )
    ]
    eligible = len(dates) >= 3
    if eligible:
        conn.execute("UPDATE cards SET grad_state = 'eligible' WHERE id = ?", (card_id,))
        conn.commit()
    return eligible


def render_question(cloze: str) -> str:
    return CLOZE_RE.sub(lambda m: f"____（{m.group(2)}）", cloze)


def question_text(card: sqlite3.Row, index: int, total: int) -> str:
    return (f"{index}/{total}　场景：{card['zh_scene']}\n"
            f"{render_question(card['cloze'])}\n直接回英文；打不出回 skip")


# --- 口语 prompt（方案 §3.5：≤3 条，不足不凑数） ---------------------------

def oral_prompts(cards: list) -> list:
    prompts = []
    for card in cards[:ORAL_PROMPT_CAP]:
        prompts.append(
            f"You're my English-speaking colleague. Let's talk about: {card['zh_scene']}. "
            f"Get me to use \"{card['chunk']}\" naturally. Correct me only at the end."
        )
    return prompts
