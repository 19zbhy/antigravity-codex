# `/codex` Instant Picker Preload

> **严格触发边界**：本规则**仅**在用户输入 `/codex` 或明确要求“交给 Codex”时生效。日常普通消息请完全忽略本文件，由 Antigravity 直接处理。

当用户输入 `/codex` 时，**在第 1 轮直接并行调用 `read_file` 读取 `<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/SKILL.md` 与 `ask_question`**（不要先单独读文件再弹卡片，直接 1 轮出卡片）。

**文案本地化要求**：卡片选项必须与用户当前语言一致（用户说中文时**禁止出现** `medium`、`xhigh`、`priority`、`flex` 等内部英文枚举名，全部翻译为下方自然中文；Phase 3 调用脚本时再映射回对应 CLI 参数值）：
- 思考深度映射：`low`→`低（轻量快答）`、`medium`→`中（日常均衡）`、`high`→`高（深度推理）`、`xhigh`→`超高（复杂难题）`、`max`→`极高（最大思考）`、`ultra`→`极限（深度攻坚）`
- 响应速度映射：`priority`→`极速模式（⚡ 优先响应，更耗额度）`、`default`→`标准速度（常规均衡）`、`flex`→`省流模式（弹性排队，更省额度）`

基于下方快照一次性弹出 4 题单选（均为第 1 项 `(Recommended)`）：
1. **进入哪个 Codex 项目？**（仅当下方存在 `- projects:` 时展示）：
   - `(Recommended) 不进入 Codex 项目（使用当前工作区）`
   - 快照中 `- projects:` 的全部项目（格式：`项目名（路径）`）
2. **选择 Codex 模型**：
   - `(Recommended) 沿用本机默认（当前：<default_model 的展示名>）`
   - 快照中 `- models:` 的前 6 个最新模型（直接展示友好名称如 `GPT-6.2-Sol`，勿重复括号拼接 slug）
3. **选择思考深度**：
   - `(Recommended) 沿用本机默认（当前：<default_effort 对应的中文名>）`
   - 按 `低 → 中 → 高 → 超高 → 极高 → 极限` 顺序列出快照 `- efforts:` 中包含的档位
4. **选择响应速度**：
   - `(Recommended) 沿用本机默认（当前：<default_tier 对应的中文名>）`
   - `极速模式（⚡ 优先响应，更耗额度）`、`标准速度（常规均衡）`、`省流模式（弹性排队，更省额度）`

<!-- CODEX_LIVE_OPTIONS_START -->
- (not synced yet)
<!-- CODEX_LIVE_OPTIONS_END -->
