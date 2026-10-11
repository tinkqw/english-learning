#!/usr/bin/env python3
"""words.jsonl → 模型结构化 → 飞书多维表格（方案 §3.2③ 的承接层）。

一行一个表达（不是一行一次查询）：一条整句查询可抽出 0–N 个表达。
噪音不预筛，打「标签」让用户在表里自行筛选删除。

状态存 $ENGLISH_DATA_DIR/bitable-state.json：
  {app_token, table_id, url, pushed: {"<ts>|<表达>": record_id}}
其中 key 为 "<ts>|" 的空条目表示该记录已加工但没抽出表达，下次不重复送模型。

幂等：已推过的 (来源时间戳, 表达) 不重复写；重跑只补新的。

用法：
  python3 sync-bitable.py            # 增量跑
  python3 sync-bitable.py --dry      # 只打印将写入的行，不建表不写
  python3 sync-bitable.py --limit 10 # 只处理前 10 条未处理记录
"""

from __future__ import annotations

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DATA_DIR = Path(os.environ.get("ENGLISH_DATA_DIR") or Path.home() / "Data" / "english-learning")
WORDS_PATH = DATA_DIR / "words.jsonl"
STATE_PATH = DATA_DIR / "bitable-state.json"
# 飞书用户身份 token（user_access_token）：JSON 文件，含 access_token 字段，需自行定时刷新
UAT_PATH = Path(os.environ.get("FEISHU_UAT_FILE") or DATA_DIR / "uat_token.json")

API = "https://open.feishu.cn/open-apis"
APP_NAME = "英语表达 · 生词本"
TABLE_NAME = "表达"
BATCH = 8            # 每次送模型的原始记录数
MODEL_TIMEOUT = 300

TAGS = ["业务沟通", "技术术语", "日常"]
SENT_SOURCES = ["原句", "生成"]
# 学习状态是一条轴上的三个位置，不是几个独立开关（2026-09-20 由「想练」复选框改来）。
# 新行一律「新收」，「想练」「已学会」由用户在表里手动改；FSRS 毕业自动置位属二期回写。
STATUSES = ["新收", "想练", "已学会"]
STATUS_NEW = STATUSES[0]

FIELDS = [
    {"field_name": "表达", "type": 1},
    {"field_name": "释义", "type": 1},
    {"field_name": "例句", "type": 1},
    {"field_name": "例句译文", "type": 1},
    {"field_name": "例句来源", "type": 3,
     "property": {"options": [{"name": n} for n in SENT_SOURCES]}},
    {"field_name": "标签", "type": 3,
     "property": {"options": [{"name": n} for n in TAGS]}},
    {"field_name": "来源原文", "type": 1},
    {"field_name": "时间", "type": 5,
     "property": {"date_formatter": "yyyy/MM/dd HH:mm", "auto_fill": False}},
    {"field_name": "状态", "type": 3,
     "property": {"options": [{"name": n} for n in STATUSES]}},
]

# 首跑建的视图：按「状态」分流，默认视图只看待挑选的，已学会的不占视线。
# 筛选值必须是选项 id（不是选项名），2026-09-20 实测传名字报 1254001。
VIEWS = [("待挑选", "新收"), ("在练", "想练"), ("已学会", "已学会"), ("全部", None)]


# --- 状态 -----------------------------------------------------------------

def load_state() -> dict:
    if STATE_PATH.exists():
        state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
        state.setdefault("pushed", {})
        return state
    return {"app_token": "", "table_id": "", "url": "", "pushed": {}}


def save_state(state: dict) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, ensure_ascii=False, indent=2),
                          encoding="utf-8")


# --- 飞书 -----------------------------------------------------------------

def user_token() -> str:
    """用户身份走 UAT（飞书 user_access_token），文件路径见 FEISHU_UAT_FILE。"""
    token = json.loads(UAT_PATH.read_text(encoding="utf-8")).get("access_token", "")
    if not token:
        sys.exit("UAT 为空：先完成飞书 OAuth 授权，把 token 写进 FEISHU_UAT_FILE")
    return token


def call(path: str, token: str, method: str = "GET", payload=None) -> dict:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        sys.exit("HTTP %s %s: %s" % (exc.code, path,
                                     exc.read().decode("utf-8")[:300]))
    if body.get("code") != 0:
        sys.exit("飞书 %s code=%s msg=%s" % (path, body.get("code"), body.get("msg")))
    return body.get("data", {})


def ensure_table(state: dict, token: str) -> None:
    """首跑建 app + 表；已建则原样返回。"""
    if state.get("app_token") and state.get("table_id"):
        return
    app = call("/bitable/v1/apps", token, "POST", {"name": APP_NAME})["app"]
    app_token = app["app_token"]
    tbl = call("/bitable/v1/apps/%s/tables" % app_token, token, "POST",
               {"table": {"name": TABLE_NAME, "fields": FIELDS}})
    # 建 app 时自带一张空的默认表，删掉避免两张表并存
    existing = call("/bitable/v1/apps/%s/tables?page_size=100" % app_token, token)
    for t in existing.get("items", []):
        if t["table_id"] != tbl["table_id"]:
            call("/bitable/v1/apps/%s/tables/%s" % (app_token, t["table_id"]),
                 token, "DELETE")
    state["app_token"] = app_token
    state["table_id"] = tbl["table_id"]
    state["url"] = app.get("url") or ("https://feishu.cn/base/" + app_token)
    save_state(state)
    ensure_views(app_token, tbl["table_id"], token)
    print("已建表：" + state["url"])


def ensure_views(app_token: str, table_id: str, token: str) -> None:
    """按「状态」建四个视图。第一个复用建表自带的默认视图，避免多出一个空壳。"""
    base = "/bitable/v1/apps/%s/tables/%s" % (app_token, table_id)
    field = [f for f in call(base + "/fields?page_size=100", token)["items"]
             if f["field_name"] == "状态"][0]
    option_id = dict((o["name"], o["id"]) for o in field["property"]["options"])
    views = dict((v["view_name"], v["view_id"])
                 for v in call(base + "/views?page_size=100", token)["items"])
    default_vid = list(views.values())[0] if views else None

    for i, (name, status) in enumerate(VIEWS):
        if name in views:
            vid = views[name]
        elif i == 0 and default_vid:
            vid = default_vid
        else:
            vid = call(base + "/views", token, "POST",
                       {"view_name": name, "view_type": "grid"})["view"]["view_id"]
        if status is None:
            continue
        call(base + "/views/" + vid, token, "PATCH", {
            "view_name": name,
            "property": {"filter_info": {
                "conjunction": "and",
                "conditions": [{"field_id": field["field_id"], "operator": "is",
                                "value": json.dumps([option_id[status]])}],
            }},
        })


def push(rows: list, state: dict, token: str) -> int:
    """批量写记录，按 100 条一批。每批成功后立即落状态，中断不丢账。"""
    app_token, table_id = state["app_token"], state["table_id"]
    written = 0
    for i in range(0, len(rows), 100):
        chunk = rows[i:i + 100]
        data = call(
            "/bitable/v1/apps/%s/tables/%s/records/batch_create" % (app_token, table_id),
            token, "POST", {"records": [{"fields": r["fields"]} for r in chunk]})
        for row, rec in zip(chunk, data.get("records", [])):
            state["pushed"][row["key"]] = rec.get("record_id", "")
            written += 1
        save_state(state)
    return written


# --- 模型加工 --------------------------------------------------------------

PROMPT = """你在整理一个中文母语职场人士的英语生词本。
下面是他用划词翻译工具查过的记录，每条有编号、查询方向、原文、译文，部分带词典释义。

请从每条记录里抽出**值得学的英语表达**，一条记录可以抽 0 个、1 个或多个：
- 查的是单词或词组 → 抽这个词本身
- 查的是整句 → 抽句中有学习价值的语块（动词搭配、功能表达、业务说法），整句本身不作为表达
- 中→英翻译 → 抽英文译文里的关键表达
- 纯人名、纯代码、纯符号、纯数字、无意义片段 → 抽 0 个

每个表达输出这些字段：
- 表达：英文，保持原形（动词短语用原形）
- 释义：中文，一句话，不超过 25 字
- 例句：能体现这个表达用法的英文句子。**如果原记录本身就是完整英文句子且含这个表达，直接用原句**，此时「例句来源」填「原句」；否则自己造一句工作场景的，「例句来源」填「生成」。不得把自己造的句子说成原句。
- 例句译文：例句的中文
- 例句来源：原句 或 生成
- 标签：业务沟通 / 技术术语 / 日常。业务沟通=和同事客户沟通用得上的；技术术语=编程、调试、系统概念；日常=其余
- i：这条表达来自哪条记录的编号（整数）

记录：
{records}

只输出 JSON，不要任何解释文字，格式：
{{"rows":[{{"i":1,"表达":"...","释义":"...","例句":"...","例句译文":"...","例句来源":"原句","标签":"业务沟通"}}]}}"""


def ask(records: list) -> list | None:
    """返回 None = 调用失败（本批不标记，下次重试）；[] = 模型确认没抽出表达。"""
    lines = []
    for n, rec in enumerate(records, 1):
        line = "[%d] %s→%s\n原文：%s\n译文：%s" % (
            n, rec.get("sourceLanguage", ""), rec.get("targetLanguage", ""),
            rec.get("text", ""), (rec.get("translatedText") or "")[:300])
        parts = (rec.get("dictionaryEntry") or {}).get("parts") or []
        if parts:
            means = "；".join(
                "%s%s" % (p.get("part", ""), "/".join(p.get("means") or []))
                for p in parts[:3])
            line += "\n词典：" + means[:200]
        lines.append(line)
    prompt = PROMPT.format(records="\n\n".join(lines))

    binary = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    env = dict(os.environ)
    env.setdefault("USER", Path.home().name)  # launchd 下不设 USER
    try:
        proc = subprocess.run([binary, "-p", prompt], capture_output=True,
                              text=True, timeout=MODEL_TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        print("  ! 模型超时，跳过本批", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print("  ! 模型退出 %s: %s" % (proc.returncode, proc.stderr[:200]),
              file=sys.stderr)
        return None
    m = re.search(r"\{.*\}", proc.stdout, re.S)
    if not m:
        print("  ! 输出无 JSON：" + proc.stdout[:200], file=sys.stderr)
        return None
    try:
        return json.loads(m.group(0)).get("rows") or []
    except json.JSONDecodeError:
        print("  ! JSON 解析失败：" + m.group(0)[:200], file=sys.stderr)
        return None


# --- 主流程 ---------------------------------------------------------------

def read_words() -> list:
    out = []
    if not WORDS_PATH.exists():
        return out
    with WORDS_PATH.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("timestamp") and rec.get("text"):
                out.append(rec)
    return out


def to_fields(row: dict, rec: dict) -> dict:
    """模型输出 + 原记录 → 飞书字段。来源原文和时间本地填，不让模型回声。"""
    dt = datetime.datetime.fromisoformat(rec["timestamp"])
    source = row.get("例句来源")
    tag = row.get("标签")
    return {
        "表达": (row.get("表达") or "").strip(),
        "释义": (row.get("释义") or "").strip(),
        "例句": (row.get("例句") or "").strip(),
        "例句译文": (row.get("例句译文") or "").strip(),
        "例句来源": source if source in SENT_SOURCES else "生成",
        "标签": tag if tag in TAGS else "日常",
        "来源原文": rec.get("text", "")[:500],
        "时间": int(dt.timestamp() * 1000),  # 飞书日期字段要毫秒时间戳
        "状态": STATUS_NEW,
    }


def main() -> int:
    dry = "--dry" in sys.argv
    limit = 0
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    state = load_state()
    words = read_words()
    if not words:
        print("words.jsonl 无可用记录")
        return 0

    done_ts = set(k.split("|", 1)[0] for k in state["pushed"])
    todo = [r for r in words if r["timestamp"] not in done_ts]
    if limit:
        todo = todo[:limit]
    print("words.jsonl %d 条，待处理 %d 条" % (len(words), len(todo)))
    if not todo:
        print("无新增。表：" + (state.get("url") or "(未建)"))
        return 0

    token = user_token()
    if not dry:
        ensure_table(state, token)

    skipped = written = empty = failed = 0
    seen_keys = set()
    batches = (len(todo) - 1) // BATCH + 1
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        print("  批 %d/%d（%d 条）→ 模型" % (i // BATCH + 1, batches, len(batch)))
        rows = ask(batch)
        if rows is None:
            # 失败批不落「无表达」标记，否则这批记录永远不会再送模型
            failed += 1
            continue
        pending = []
        for row in rows:
            idx = row.get("i")
            if not isinstance(idx, int) or not (1 <= idx <= len(batch)):
                continue
            rec = batch[idx - 1]
            expr = (row.get("表达") or "").strip()
            if not expr:
                continue
            key = "%s|%s" % (rec["timestamp"], expr)
            if key in state["pushed"] or key in seen_keys:
                skipped += 1
                continue
            seen_keys.add(key)
            pending.append({"key": key, "fields": to_fields(row, rec)})

        if dry:
            for p in pending:
                f = p["fields"]
                print("  [dry] %-4s | %s — %s | 例句(%s): %s" % (
                    f["标签"], f["表达"], f["释义"], f["例句来源"], f["例句"][:60]))
            written += len(pending)
            continue

        # 每批跑完立刻写飞书并落状态：中途中断只丢当前这批的模型结果，
        # 不是整轮白跑
        if pending:
            written += push(pending, state, token)
        produced = set(p["key"].split("|", 1)[0] for p in pending)
        for rec in batch:
            if rec["timestamp"] not in produced:
                state["pushed"][rec["timestamp"] + "|"] = ""
                empty += 1
        save_state(state)

    if dry:
        print("[dry] 将写入 %d 行，去重跳过 %d" % (written, skipped))
        return 0

    print("写入 %d 行（去重跳过 %d），无表达记录 %d 条已标记" % (written, skipped, empty))
    print("表：" + state.get("url", ""))
    if failed:
        print("%d 批模型调用失败，未标记，下次重试" % failed, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
