# 第三方代码声明

## Easydict

`easydict/` 目录基于 [Easydict](https://github.com/tisfeng/Easydict)（作者 tisfeng 及贡献者）修改而来，以 GNU General Public License v3.0 发布，原版权与许可证见 `easydict/LICENSE`。基础版本为 Easydict 2.22.0（上游 `dev` 分支提交 `e09fa75`，2026-09-15）。

生词本导出功能（把每次查询追加写入本地 `words.jsonl`）来自 crossoverJie 提交给上游的 [PR #1319](https://github.com/tisfeng/Easydict/pull/1319)。

本项目在此基础上做的修改：

- 点击翻译结果里的单词，在单词附近弹出词典卡，不替换当前查询；点词查询也写入生词本，标 `trigger=inline`
- 点词时直接朗读该词
- 菜单栏增加「生词本」入口，打开本机设置的在线生词表链接
- 重做查询弹窗：服务选择栏、卡片式布局、顶部操作按钮
- 主窗口改为对照布局（单词上下紧凑，句子与段落左右对照），可把弹窗里的结果直接带到主窗口
- 修复长译文末行被裁切，收紧原文与译文的段落空白

## 口语陪练的教练规则

`vocab-web/relay/relay-server.js` 里给语音模型的教练规则（全程英文、不给选项、学习者先开口、结束时集中纠错等）参考了 [english-speaking-coach](https://github.com/yomage-ai/english-speaking-coach) 的练习设计思路，规则文字为本项目自行编写，未包含该项目的代码或文本。

## 其他依赖

- [py-fsrs](https://github.com/open-spaced-repetition/py-fsrs)（MIT）：间隔复习调度
- [ws](https://github.com/websockets/ws)（MIT）：语音中继的 WebSocket 库
