---
name: codex
description: >-
  仅当用户输入 /codex 斜杠命令，或在对话中明确要求“交给 Codex / 开启协同”时激活（平时普通编码请求请勿自动激活，由 Antigravity 直接完成）。激活后由 Antigravity 负责发散思维探路、用人话对齐目标与边界并做独立终审；由 Codex CLI 负责自主工程实现与现场自测闭环。
---

# Antigravity × Codex 协同技能 (`/codex`)

> **触发边界**：仅在用户通过 `/codex` 显式召唤、或明确口头指定交给 Codex 时启用。一旦启用，请严格遵循 **「Antigravity 管 Why & What（产品发散、人话沟通、架构边界、终审把关），Codex 管 How（地道工程设计、极速编码、现场自测闭环）」** 的分工原则，切勿在未获用户允许时由 Antigravity 自己改业务源码。

---

## Phase 0：极速弹出 Codex 运行档位选择（模型 / 推理强度 / 服务档位）

1. **检查用户是否已在 `/codex` 消息中显式指定配置**（例如“用 high 推理、快速模式”或 `--model ... --effort ... --tier ...`）：
   - 若用户已明确指定，直接采用并跳过弹窗。
2. **零额外工具轮次、秒弹选择卡片**：
   - 直接读取下方由安装脚本与 `run-codex.sh` 自动同步好的本机实时选项快照（**不要在弹卡片前额外跑终端或读 `config.toml`**，避免拖慢弹窗速度；仅当下方快照显示 `(not synced yet)` 时，才先跑一次 `run-codex.sh sync-options`）。
   - **立即调用 `ask_question`** 一次性弹出 3 个单选问题（每题第一项均为 `(Recommended) 沿用本机默认配置`）：
     - **问题 1（Codex 模型）**：`(Recommended) 沿用本机默认配置（当前：<default_model>）` + 下方快照中列出的全部可用模型（用户也可在卡片自带的 Other 手填任意模型名）。
     - **问题 2（推理强度 `model_reasoning_effort`）**：`(Recommended) 沿用本机默认配置（当前：<default_effort>）` + 下方快照中的全部 `efforts`。
     - **问题 3（服务档位 `service_tier`）**：`(Recommended) 沿用本机默认配置（当前：<default_tier>）` + `priority（快速模式 / Fast）`、`default（标准模式）`、`flex（弹性省流模式）`。
3. 记住用户的选择（选“沿用本机默认配置”的项在 Phase 3 中不传覆盖参数，直接沿用 `~/.codex/config.toml`）。每次 `run-codex.sh` 执行后会自动静默刷新下方快照，随 Codex 更新保持同步。

<!-- CODEX_LIVE_OPTIONS_START -->
- (not synced yet)
<!-- CODEX_LIVE_OPTIONS_END -->

---

## Phase 1：发散探路与“人话”任务书（Antigravity）

1. **严禁越权改代码**：只用只读工具（`read_file`、搜索工具、只读命令）快速摸清相关代码结构、现有约定与可复用模块。
2. **发散思维前置与视觉分工（灵活判断）**：
   - **若需求开放、存在多种实现路径（如“快改轻量版 vs 高扩展重构版”）或发现潜在产品盲区**：先用通俗好懂的“人话”给出 2～3 个思路与利弊对比（必要时配合 `ask_question` 让用户一键选方向），帮用户打开思路、敲定大方向后再写方案卡片。
   - **若涉及前端视觉设计、配色布局或高清截图审阅**：优先由 Antigravity 直接与用户对齐视觉风格并完成审图，不要把大体积原图塞进 Codex 上下文；纯逻辑/工程模块再交由 Codex 实现。
   - **若需求目标已经非常明确**：直接生成方案卡片，同时主动补充你帮用户额外想到的边界防坑点。
3. **生成“抓大放小、人话可读”的任务书 `<Artifact Directory Path>/implementation_plan.md`**（设置 `ArtifactMetadata` 为 `UserFacing: true` 和 `RequestFeedback: true` 以渲染 **Proceed** 按钮）：
   - 方案顶部必须保留执行标记与选定的 Codex 运行参数（确保下一轮收到用户确认信号时准确透传）：
     `> 执行方式：用户确认后通过 codex 技能调用 run-codex.sh 交由 OpenAI Codex CLI 自主工程实现与现场自测闭环`
     `> Codex 运行配置：model=<选择值或默认> | effort=<选择值或默认> | tier=<选择值或默认>`
   - **严禁事无巨细堆砌伪代码捆死 Codex**！方案聚焦以下 4 个模块（让用户用人话秒懂，同时给足 Codex 工程发挥空间）：
     1. **目标与体验逻辑（Goal & Behavior）**：用清晰的大白话描述要解决的问题、期望的交互/业务表现与输入输出规则。
     2. **发散防坑与边缘情况（Edge Cases & Guardrails）**：列明异常输入、空状态、并发/状态同步、向后兼容等需要兜底的边界场景。
     3. **架构切入点与作用域红线（Workspace Root & Scope Boundaries）**：指明工作区绝对路径、相关联的现有目录/模块、项目既有的技术栈约定，以及**严禁触碰的文件/目录红线**（具体函数怎么拆、代码怎么组织最优雅，完全交由 Codex 自主设计）。
     4. **现场自测与交付标准（Self-Test & Acceptance Criteria）**：明确要求 Codex 在修改完成后，必须在工作区内自行跑通哪些构建、类型检查、Lint 或测试命令才能交卷。

---

## Phase 2：强制人工确认门禁（Mandatory Approval Gate）

1. 用简明“人话”总结方案的核心思路与取舍点，引导用户查看 `implementation_plan.md`，然后**立即停止工具调用，等待用户拍板**。
2. 若用户提出调整意见，先更新 `implementation_plan.md` 并再次请用户确认；在用户明确点头（点击 **Proceed** 或回复确认）前，**严禁调用 `run-codex.sh`**。

---

## Phase 3：放权移交 Codex 极速施工 + 现场自测闭环

用户确认后，使用字面量绝对路径直接调用辅助脚本（不要使用 `$VAR` 或 `$(...)` 展开，也不要用 `&&`、`;`、`|` 拼接其他命令，以确保 Antigravity 的 `Always Allow` 前缀自动放行永久生效）：

`<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh`

调用 `run_command` 执行命令（设置 `WaitMsBeforeAsync: 10000`、`NotificationTimeoutSeconds: 240`；按 Phase 0 选择按需附加 `--model` / `--effort` / `--tier`，沿用默认的项直接省略）：

```bash
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh execute /absolute/path/to/workspace /absolute/path/to/implementation_plan.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md --model <model> --effort <effort> --tier <tier>
```

- 脚本默认开启**静默摘要模式**：完整过程日志会落盘到同目录的 `*.log` 文件，终端仅回传最终摘要（`codex_last_message.md`），大幅减少 Antigravity 侧的无效上下文消耗（如需实时查看完整过程日志，可在调试时设置 `CODEX_VERBOSE=1`）。
- 要求 Codex 遵守**精简输出纪律**：不要向 stdout 倾倒整份大文件或数百行原始日志，优先按行号定向查看或汇总验证结果。
- 若脚本提示尚未登录（`codex login`），暂停并请用户在终端运行一次 `codex login` 授权后再继续。

---

## Phase 4：Antigravity 独立终审与“说人话”汇报

`run-codex.sh` 执行完毕后，由 Antigravity 进行独立把关：

1. **对齐初心与边界复核**：
   - 读取 `scratch/codex_last_message.md`（若有），并检查 `git status --short` 与 `git diff`（非 Git 目录则用 `read_file` 查看改动文件）。
   - 重点站在**产品体验与架构全局观**核查：用户的真实意图满足了吗？列出的边缘情况兜住了吗？有没有越界误改无关文件？
2. **核验测试结果与精准打回**：
   - 若 Codex 在现场已跑通全部构建/测试且 Diff 干净，可做轻量抽检确认即可，避免重复跑耗时全量测试拖慢节奏；若 Codex 未跑某项关键验证，由 Antigravity 补跑确认。
   - 若发现需求遗漏、逻辑偏差或测试报错，**不要由 Antigravity 自己上手改业务源码**（除非用户主动要求你接手）：将简明问题清单与报错信息写入 `<Artifact Directory Path>/scratch/codex_fix_instructions.md`，通过 `resume` 唤醒同一个 Codex 会话极速返修（透传与 Phase 3 一致的 `--model` / `--effort` / `--tier` 参数，设置 `WaitMsBeforeAsync: 10000`、`NotificationTimeoutSeconds: 240`，最多 3 轮）：

```bash
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh resume /absolute/path/to/workspace /absolute/path/to/artifact_dir/scratch/codex_fix_instructions.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md
```

3. **用“人话”向用户交付成果**：
   - 摒弃生硬晦涩的终端日志堆砌，用通俗清晰的语言告诉用户：
     - **做好了什么**：实际实现的效果与使用方式；
     - **动了哪里**：新增/修改的核心文件列表（附可点击的 `file://` 链接）及各自作用；
     - **稳不稳**：构建与测试验收情况，以及值得留意的后续建议（如有）。
