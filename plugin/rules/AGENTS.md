# `/codex` Instant Picker Preload

> **严格触发边界**：本规则**仅**在用户输入 `/codex` 或明确要求“交给 Codex”时生效。日常普通消息请完全忽略本文件，由 Antigravity 直接处理。

当用户输入 `/codex` 时，**在第 1 轮直接并行调用 `read_file` 读取 `<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/SKILL.md` 与 `ask_question`**（不要先单独读文件再弹卡片，直接 1 轮出卡片）。

**文案本地化与极简要求**：卡片选项简洁无括号（Phase 3 调用脚本时再映射回对应路径与 CLI 参数）：
- 思考深度映射（中英对照）：`low`→`低 · Low`、`medium`→`中 · Medium`、`high`→`高 · High`、`xhigh`→`超高 · XHigh`、`max`→`极高 · Max`、`ultra`→`极限 · Ultra`
- 响应速度映射：`priority`→`极速模式`、`default`→`标准速度`

基于下方快照一次性弹出 4 题单选（均为第 1 项 `(Recommended)`，选项简洁无括号）：
1. **进入哪个 Codex 项目？**（仅当下方存在 `- projects:` 时展示）：
   - `(Recommended) 使用当前工作区`
   - 快照中 `- projects:` 的全部项目名（只写项目名，不附路径括号；选中后再取对应路径）
2. **选择 Codex 模型**：
   - `(Recommended) 默认 · <default_model 的展示名>`
   - 快照中 `- models:` 的前 6 个最新模型友好名称（如 `GPT-6.2-Sol`）
3. **选择思考深度**：
   - `(Recommended) 默认 · <default_effort 对应的中英对照名>`
   - 按 `低 · Low → 中 · Medium → 高 · High → 超高 · XHigh → 极高 · Max → 极限 · Ultra` 顺序列出快照 `- efforts:` 中包含的档位
4. **选择响应速度**：
   - `(Recommended) 默认 · <default_tier 对应的中文名>`
   - `极速模式`、`标准速度`

<!-- CODEX_LIVE_OPTIONS_START -->
- (not synced yet)
<!-- CODEX_LIVE_OPTIONS_END -->
