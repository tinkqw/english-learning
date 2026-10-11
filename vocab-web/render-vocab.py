#!/usr/bin/env python3
"""多维表格生词本 + cards.db 在练卡 → 生词本网页的 data.json。

默认只渲染到 $ENGLISH_DATA_DIR/vocab-data.json；
--push 同时 rsync 到 $VOCAB_REMOTE（如 myserver:/var/www/vocab/data.json）。

数据边界：只读不写。多维表格是展示层，cards.db 是 FSRS 权威，页面不回写。
"""

from __future__ import annotations

import argparse
import os
import datetime
import json
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

DATA_DIR = Path(os.environ.get("ENGLISH_DATA_DIR") or Path.home() / "Data" / "english-learning")
STATE_PATH = DATA_DIR / "bitable-state.json"
UAT_PATH = Path(os.environ.get("FEISHU_UAT_FILE") or DATA_DIR / "uat_token.json")
CARDS_DB = DATA_DIR / "cards.db"
OUT_PATH = DATA_DIR / "vocab-data.json"
REMOTE = os.environ.get("VOCAB_REMOTE", "")

API = "https://open.feishu.cn/open-apis"


def user_token() -> str:
    token = json.loads(UAT_PATH.read_text(encoding="utf-8")).get("access_token", "")
    if not token:
        sys.exit("UAT 为空：先完成飞书 OAuth 授权，把 token 写进 FEISHU_UAT_FILE")
    return token


def call(path: str, token: str) -> dict:
    req = urllib.request.Request(
        API + path, method="GET",
        headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        sys.exit("HTTP %s %s: %s" % (exc.code, path,
                                     exc.read().decode("utf-8")[:300]))
    if body.get("code") != 0:
        sys.exit("飞书报错 %s: %s" % (body.get("code"), body.get("msg")))
    return body.get("data", {})


def text_of(value) -> str:
    """多维表格文本字段：可能是字符串，也可能是 text run 数组。"""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(seg.get("text", "") if isinstance(seg, dict) else str(seg)
                       for seg in value)
    return str(value)


def fetch_words(app_token: str, table_id: str, token: str) -> list[dict]:
    words, page_token = [], ""
    while True:
        path = ("/bitable/v1/apps/%s/tables/%s/records?page_size=100%s"
                % (app_token, table_id,
                   "&page_token=" + page_token if page_token else ""))
        data = call(path, token)
        for rec in data.get("items", []):
            f = rec.get("fields", {})
            ts = f.get("时间")
            words.append({
                "表达": text_of(f.get("表达")),
                "释义": text_of(f.get("释义")),
                "例句": text_of(f.get("例句")),
                "例句译文": text_of(f.get("例句译文")),
                "例句来源": text_of(f.get("例句来源")),
                "标签": text_of(f.get("标签")),
                "来源原文": text_of(f.get("来源原文")),
                "时间": (datetime.datetime.fromtimestamp(ts / 1000)
                        .strftime("%Y-%m-%d") if isinstance(ts, (int, float)) else ""),
                "状态": text_of(f.get("状态")) or "新收",
            })
        if not data.get("has_more"):
            return words
        page_token = data.get("page_token", "")


def fetch_active_cards() -> list[dict]:
    if not CARDS_DB.exists():
        return []
    conn = sqlite3.connect("file:%s?immutable=1" % CARDS_DB, uri=True)
    try:
        rows = conn.execute(
            "SELECT chunk, zh_scene, en_sentence, phonetic FROM cards"
            " WHERE status='active' ORDER BY priority, due").fetchall()
    finally:
        conn.close()
    return [{"chunk": r[0], "zh_scene": r[1], "en_sentence": r[2],
             "phonetic": r[3] or ""} for r in rows]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--push", action="store_true", help="渲染后 rsync 到服务器")
    args = ap.parse_args()

    state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    app_token, table_id = state["app_token"], state["table_id"]
    token = user_token()

    words = fetch_words(app_token, table_id, token)
    active = fetch_active_cards()

    payload = {
        "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "words": words,
        "fsrs_active": active,
        "counts": {
            "total": len(words),
            "新收": sum(1 for w in words if w["状态"] == "新收"),
            "想练": sum(1 for w in words if w["状态"] == "想练"),
            "已学会": sum(1 for w in words if w["状态"] == "已学会"),
            "fsrs_active": len(active),
        },
    }
    OUT_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=1),
                        encoding="utf-8")
    print("渲染 %s：%s" % (OUT_PATH, json.dumps(payload["counts"], ensure_ascii=False)))

    if args.push:
        if not REMOTE:
            sys.exit("未设置 VOCAB_REMOTE，无法推送")
        subprocess.run(["rsync", "-az", str(OUT_PATH), REMOTE], check=True)
        print("已推送 → %s" % REMOTE)


if __name__ == "__main__":
    main()
