# `/codex` Instant Picker Preload

> **严格触发边界**：本规则**仅**在用户输入 `/codex` 或明确要求“交给 Codex”时生效。日常普通消息请完全忽略本文件，由 Antigravity 直接处理。

当用户输入 `/codex` 时，**在第 1 轮直接并行调用 `read_file` 读取 `<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/SKILL.md` 与 `ask_question`**（不要先单独读文件再弹卡片，直接 1 轮出卡片），基于下方快照弹出精简 2 题单选：

1. **进入哪个 Codex 项目？**（仅当下方存在 `- projects:` 时展示）：
   - `(Recommended) 不进入 Codex 项目（使用当前工作区）`
   - 快照中 `- projects:` 的全部项目（格式：`项目名（路径）`）
2. **Codex 模型与档位（默认沿用本机配置；如需改推理强度/档位可点「其他」或直接在消息中说明）**：
   - `(Recommended) 沿用本机默认（<default_model> · <default_effort> · <default_tier>）`
   - 快照中 `- models:` 的前 5 个最新模型

<!-- CODEX_LIVE_OPTIONS_START -->
- (not synced yet)
<!-- CODEX_LIVE_OPTIONS_END -->
