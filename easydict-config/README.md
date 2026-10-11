# Easydict 配置

`easydict/` 是改过的 Easydict 源码（来源与改动见根目录 `NOTICE.md`）。这里放构建脚本和配合本项目用的设置。

## 构建安装

需要 Xcode。首次先在「钥匙串访问」里建一张自签代码签名证书（证书助理 → 创建证书 → 类型选「代码签名」），名字默认用 `Easydict Local Signing`。

```bash
bash easydict-config/build-and-install.sh
```

用固定证书签名，重新编译后辅助功能、屏幕录制授权不会失效。若用 Homebrew 装过官方版，先移除它的 cask 登记，否则 `brew upgrade` 会把自编版覆盖回去。

## 设置

1. **生词本**：设置 → 高级 → 生词本，打开开关，「存储目录」选 `ENGLISH_DATA_DIR`（默认 `~/Data/english-learning`）。每次查询会追加一行到 `words.jsonl`，点结果里的词查词时标 `trigger=inline`。
2. **自定义提示词**：`custom-prompt.txt` 是给 DeepSeek（或其他兼容 OpenAI 的服务）用的提示词，按输入类型分三种输出：中文出一行英文；单词出释义、搭配、拆词；句子出直译和重点词汇（重点词汇里的词可直接点开查）。写入方法：

   ```bash
   defaults write com.izual.Easydict EZDeepSeekUserPromptKey -string "$(cat easydict-config/custom-prompt.txt)"
   ```

3. **菜单栏「生词本」入口**（可选）：打开你的在线生词表。链接不写进代码，在本机设置：

   ```bash
   defaults write com.izual.Easydict EZVocabularyNotebookURL -string "https://..."
   ```

   键为空时菜单项不显示。

4. **关闭自动更新**（建议）：自动更新会装回官方版，覆盖本地改动。

   ```bash
   defaults write com.izual.Easydict SUEnableAutomaticChecks -bool false
   ```
