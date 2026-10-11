# english-learning

一套给职场人用的英语学习工具：在日常阅读和写作里**顺手收集**不会的表达，再用间隔复习和语音陪练把它们**练成自己说得出口的话**。

## 学习流程

```
阅读英文 ──划词翻译（Easydict）──→ words.jsonl ──┐
写英文   ──让 AI 翻译 / 润色（skill）─→ gaps.jsonl ─┤
                                                 ▼
                       每晚加工：抽表达 → 飞书多维表格生词本 / 候选卡
                                                 ▼
          ┌──────────────────────────────────────┴───────────────────────┐
   聊天里练（飞书机器人）                                    手机上练（生词本网页）
   「开始学习」→ 集中学习 → 中文场景写英文 → AI 判分        翻看生词 → 勾 1–3 个表达
   → 自评 → FSRS 安排下次复习 → 换场景检验毕业             → 按住说话，和语音 AI 情境对话
```

## 目录

| 目录 | 是什么 |
|---|---|
| `easydict/` | 改过的 Easydict（macOS 划词翻译），加了生词本、点词查词卡、新查询弹窗等，见 `NOTICE.md` |
| `easydict-config/` | 构建脚本、配套提示词与设置方法 |
| `learning/` | 复习系统：卡片库、会话引擎、判分、FSRS 调度、学习提醒、夜间加工 |
| `vocab-web/` | 生词本网页（PWA）+ 火山引擎实时语音中继，手机上翻生词、开口练 |
| `skills/english-collect/` | Claude Code skill：翻译 / 润色时顺手把表达缺口记进 `gaps.jsonl` |

## 依赖

- macOS + Xcode（构建 Easydict）
- Python 3.9+，`pip install -r learning/requirements.txt`
- [Claude Code](https://claude.com/claude-code) CLI：判分、造卡、抽表达都走 `claude -p`
- 飞书自建应用：学习提醒、多维表格生词本（不用飞书的话，`learning/answer.py` 是纯 stdin/stdout 接口，可接到任何聊天机器人）
- 生词本网页：一台有域名和 HTTPS 的 Linux 服务器（Node 18+、nginx），火山引擎「豆包端到端实时语音大模型」账号

## 快速开始

1. **数据目录**：`cp learning/env.example learning/.env`，填 `ENGLISH_DATA_DIR` 等配置。
2. **Easydict**：按 `easydict-config/README.md` 构建安装，生词本目录指向 `ENGLISH_DATA_DIR`。
3. **种子卡**：`cd learning && python3 seed-cards.py`（先把 `SEEDS` 换成你自己想练的表达）。
4. **接聊天机器人**：机器人收到消息后执行 `echo "<消息>" | python3 learning/answer.py`。退出码 0 = 把 stdout 作为回复发回；2 = 当前没有学习会话；3 = 有会话但这条不像答案。2 和 3 都按普通消息处理。
5. **定时任务**（任选 launchd / cron）：
   - `learning/remind.py`：每天一两次学习提醒，没东西可学就不发
   - `learning/scripts/run-evening.sh`：归档查询材料、把缺口加工成候选卡
   - `learning/scripts/run-nightly.sh`：同步多维表格生词本、推送网页数据、拉回口语练习记录
6. **生词本网页**：按 `vocab-web/README.md` 部署。

本地测试会话流程（不调模型、用临时库）：`cd learning && python3 test-session-flow.py`

## 聊天命令

| 命令 | 作用 |
|---|---|
| 开始学习 | 开一轮：先展示新表达，再练到期的卡 |
| 学好了，开始练 | 结束展示，进入练习 |
| 暂停学习 / 继续学习 / 结束学习 | 控制当前一轮 |
| 生词本 [关键词 / 日期 / p2] | 查归档的查询材料 |
| 想练 \<英文表达\> | 现场造一张候选卡 |
| 记表达：\<一句中文\> | 记下一句说不出来的话，夜间补英文 |
| 不练 / 恢复 \<表达\> | 移除候选 / 把已毕业的卡找回复习 |

## 隐私

学习数据（生词、卡片库、练习记录）只存在本机和你自己的服务器上，不在本仓库里。送给模型的只有英文语块和一句中性场景描述，不含聊天或邮件原文。

## 许可证

GPL-3.0，见 `LICENSE`。`easydict/` 部分的版权归 Easydict 原作者，见 `NOTICE.md`。
