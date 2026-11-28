---
name: codex
description: >-
  仅当用户输入 /codex 斜杠命令，或在对话中明确要求“交给 Codex / 开启协同”时激活（平时普通编码请求请勿自动激活，由 Antigravity 直接完成）。激活后由 Antigravity 负责发散思维探路、用人话对齐目标与边界并做独立终审；由 Codex CLI 负责自主工程实现与现场自测闭环。
---

# Antigravity × Codex 协同技能 (`/codex`)

> **触发与会话锁定边界**：仅在用户通过 `/codex` 显式召唤、或明确口头指定交给 Codex 时启用。一旦本对话通过 `/codex` 选定项目、会话与运行档位，**自动在本对话内锁定并沿用该配置**——后续普通消息无需再敲 `/codex`，直接沿用同一项目、会话与模型档位继续走协同闭环（除非用户明确说“退出 `/codex`”）；**仅当用户在同一对话里再次显式输入 `/codex`** 时，才重新弹出选择卡片切换项目或档位。协同期间请严格遵循 **「Antigravity 管 Why & What（产品发散、人话沟通、架构边界、终审把关），Codex 管 How（地道工程设计、极速编码、现场自测闭环）」** 的分工原则，切勿在未获用户允许时由 Antigravity 自己改业务源码。

---

## Phase 0：1 轮秒弹项目与 Codex 运行档位选择

1. **1 轮秒弹选择卡片（若已在第 1 轮通过 `rules/AGENTS.md` 预热弹出，直接承接用户选择，勿重复弹卡片）**：
   - 直接读取下方由安装脚本与 `run-codex.sh` 自动同步好的本机实时快照（**不要在弹卡片前额外跑终端或读 `config.toml`**；仅当下方快照为 `- (not synced yet)` 时，才先跑一次 `run-codex.sh sync-options`）。
   - **选项文案简洁无括号**：思考深度采用中英对照，响应速度使用自然中文，Phase 3 传参时再映射回路径与 CLI 参数（`--model <slug>`、`--effort <low|medium|high|xhigh|max|ultra>`、`--tier <priority|default>`）：
     - 思考深度映射（中英对照）：`low`→`低 · Low`、`medium`→`中 · Medium`、`high`→`高 · High`、`xhigh`→`超高 · XHigh`、`max`→`极高 · Max`、`ultra`→`极限 · Ultra`
     - 响应速度映射：`priority`→`极速模式`、`default`→`标准速度`
   - 若用户尚未选择且未在 `/codex` 消息中显式指定全部参数，立即调用 `ask_question` 一次性弹出以下 4 题单选：
     - **问题 1（进入哪个 Codex 项目）**（仅当下方快照存在 `- projects:` 时展示）：
       - `(Recommended) 使用当前工作区`
       - 快照中 `- projects:` 的全部项目名（只写项目名，不附路径括号；选中后再取对应路径）。
     - **问题 2（选择 Codex 模型）**：
       - `(Recommended) 默认 · <default_model 的展示名>`
       - 快照中 `- models:` 的前 6 个最新模型友好名称（如 `GPT-6.2-Sol`）。
     - **问题 3（选择思考深度）**：
       - `(Recommended) 默认 · <default_effort 对应的中英对照名>`
       - 按 `低 · Low → 中 · Medium → 高 · High → 超高 · XHigh → 极高 · Max → 极限 · Ultra` 顺序列出快照 `- efforts:` 中包含的档位。
     - **问题 4（选择响应速度）**：
       - `(Recommended) 默认 · <default_tier 对应的中文名>`
       - `极速模式`、`标准速度`。
2. **若用户选择了某个 Codex 项目（1 轮极速弹出对话选择 + 自动共享状态）**：
   - 将该项目路径作为本次任务的 `<workspace_dir>`。
   - **优先直接使用下方快照里的 `- project_sessions:` 预同步列表（零额外命令轮次，省去一次 `list-sessions` 往返！）**：
     - 若下方 `- project_sessions:` 中已有该项目的最近对话，**不要先跑 `list-sessions`**，直接在本轮并行读取 `<project_path>/.agents/state.md`（若存在）并调用 `ask_question` 弹出单选卡片（标题：`选择「<项目名>」中的对话`；选项简洁无重复前缀、无冗余括号）：
       - `(Recommended) 新建对话`
       - 逐条列出缓存的 `<对话名> · <时间>`（例如 `重构登录模块 · 11-27 21:38`，**不要**每条都重复写“继续老会话：”）
       - `刷新对话列表`（仅当用户点此项，或快照中无该项目缓存时，才运行 `run-codex.sh list-sessions "<project_path>" --limit 8` 实时查库并重新弹窗）
     - 若读取 `.agents/state.md` 发现不存在，顺手运行一次 `run-codex.sh init-shared "<project_path>" --exclude-state` 无感开启双端共享状态。
   - 当用户选中某条老会话时：
       1. **先让 Antigravity 真正承接上下文**：立刻运行 `run-codex.sh show-session <session_id> --turns 10` 只读提取该条 Codex 老对话最近 10 条纯净用户/助手对话（自动过滤系统提示与冗长工具日志），让 Antigravity 在 Phase 1 规划前完整了解之前聊过的内容；
       2. **Phase 3 默认使用 `resume --session <id>` 原位续聊**（切回 Codex App 可直接在该对话中看到新增回合；仅当用户明确要求“分叉 / 不要改原对话”时才使用 `fork --session <id>`）。
          - **若 `resume` 报 `already has an active writer`（`HINT_THREAD_LOCKED`）**：严禁未经告知直接关闭 Codex 桌面端！立刻调用 `ask_question` 告知用户并给出 2 个选项：
            1. `(Recommended) 关闭 Codex 桌面端并原位续聊` → 用户同意后，带上 `--quit-app-on-lock`（Windows 为 `-QuitAppOnLock`）重新运行 `resume`，自动优雅关闭 Codex 桌面端释放写锁后原位继续；
            2. `不关闭，分叉出新对话继续` → 用户不同意关闭时，改用 `fork --session <id>` 无损继承上下文继续执行（不关闭 Codex 桌面端）。
3. 记住用户的选择（选“沿用本机默认配置”的项在 Phase 3 中不传覆盖参数，直接沿用 `~/.codex/config.toml`）。每次 `run-codex.sh` 执行后会自动静默刷新下方快照。

<!-- CODEX_LIVE_OPTIONS_START -->
- (not synced yet)
<!-- CODEX_LIVE_OPTIONS_END -->

---

## Phase 1：任务分级、快速探路与“人话”任务书（Antigravity）

0. **任务分级：轻量操作直达快车道（Fast Path）vs 正式方案门禁（Full Plan Path）**：
   - **快车道（1 轮直达，免写任何任务文件、免等 `Proceed`）**：若用户需求是**目标单一明确、无不可逆破坏风险**的轻量操作或小改动——例如：启停/重启服务或进程、运行构建/测试/脚本、查询运行状态或日志、明确的一两行微调、或只读代码审查（`review`）——**禁止做多轮冗长摸排、也不要先 `write_file` 写临时文件**！直接用 `--prompt "<简洁任务指令>"`（Windows 为 `-Prompt`）在**本轮直接调用 `run-codex.sh`** 交给 Codex 执行（例如：`run-codex.sh resume "/path/to/ws" --session <id> --prompt "重启本地开发服务并确认端口健康"`）。
   - **正式门禁（走下方 Phase 1 → Phase 2）**：涉及跨文件功能开发、架构重构、多方案取舍、或存在删除/覆盖/配置修改等风险的任务，先并行只读摸排（**尽量合并在 1 轮内完成**），再出 `implementation_plan.md` 等待用户点击 **Proceed**。

1. **严禁越权改代码 + 优先感知跨端共享上下文**：
   - 只用只读工具（`read_file`、搜索工具、只读命令）快速摸清相关代码结构、现有约定与可复用模块。
   - **共享项目状态感知**：若工作区存在 `AGENTS.md` 或 `.agents/state.md`，优先读取以了解独立 Codex 或历史会话刚刚做过的改动、遗留问题与约定；若当前环境已配置 `basic-memory` 等共享记忆 MCP，按需检索该项目的长期架构决策并浓缩进任务书。
   - **老会话接力（按需）**：若用户明确希望从 Codex Desktop / CLI 的某条历史会话继续干活，可先调用 `run-codex.sh list-sessions /absolute/path/to/workspace` 只读列出该项目最近的 Codex 线程，并在 Phase 3 默认使用 `resume --session <id>` 原位续聊（若用户希望不改动原对话则改用 `fork --session <id>`）。
2. **发散思维前置与视觉分工（灵活判断）**：
   - **若需求开放、存在多种实现路径（如“快改轻量版 vs 高扩展重构版”）或发现潜在产品盲区**：先用通俗好懂的“人话”给出 2～3 个思路与利弊对比（必要时配合 `ask_question` 让用户一键选方向），帮用户打开思路、敲定大方向后再写方案卡片。
   - **若涉及前端视觉设计、配色布局或高清截图审阅**：优先由 Antigravity 直接与用户对齐视觉风格并完成审图，不要把大体积原图塞进 Codex 上下文；纯逻辑/工程模块再交由 Codex 实现。
   - **若需求目标已经非常明确**：直接生成方案卡片，同时主动补充你帮用户额外想到的边界防坑点。
3. **生成“抓大放小、人话可读”的任务书 `<Artifact Directory Path>/implementation_plan.md`**（可按任务类型参考同目录 `resources/implementation-task.md`、`bugfix-task.md` 或 `review-task.md`；将 `ArtifactMetadata` 设为 `UserFacing: true` 和 `RequestFeedback: true` 以渲染 **Proceed** 按钮）：
   - **只读审查特例**：若用户明确要求「只读审查 / Code Review / 源码审计」（不改任何代码），可在 Phase 0 选完档位后直接用 `review` 子命令（`read-only` 沙箱）移交 Codex 审计，无需等待 `Proceed` 写代码门禁。
   - 方案顶部必须保留执行标记与选定的 Codex 运行参数（确保下一轮收到用户确认信号时准确透传）：
     `> 执行方式：用户确认后通过 codex 技能调用 run-codex.sh 交由 OpenAI Codex CLI 自主工程实现与现场自测闭环`
     `> Codex 运行配置：model=<选择值或默认> | effort=<选择值或默认> | tier=<选择值或默认>`
   - **严禁事无巨细堆砌伪代码捆死 Codex**！方案聚焦以下 4 个模块（让用户用人话秒懂，同时给足 Codex 工程发挥空间）：
     1. **目标与体验逻辑（Goal & Behavior）**：用清晰的大白话描述要解决的问题、期望的交互/业务表现与输入输出规则。
     2. **发散防坑与边缘情况（Edge Cases & Guardrails）**：列明异常输入、空状态、并发/状态同步、向后兼容等需要兜底的边界场景。
     3. **架构切入点与作用域红线（Workspace Root & Scope Boundaries）**：指明工作区绝对路径、相关联的现有目录/模块、项目既有的技术栈约定，以及**严禁触碰的文件/目录红线**（具体函数怎么拆、代码怎么组织最优雅，完全交由 Codex 自主设计）。
     4. **现场自测与交付标准（Self-Test & Acceptance Criteria）**：明确要求 Codex 在修改完成后，必须在工作区内自行跑通哪些构建、类型检查、Lint 或测试命令才能交卷。

---

## Phase 2：强制人工确认门禁（正式方案任务适用）

> 轻量直达任务（Fast Path）与只读审查（`review`）跳过本阶段，直接进入 Phase 3。

1. 用简明“人话”总结方案的核心思路与取舍点，引导用户查看 `implementation_plan.md`，然后**立即停止工具调用，等待用户拍板**。
2. 若用户提出调整意见，先更新 `implementation_plan.md` 并再次请用户确认；在用户明确点头（点击 **Proceed** 或回复确认）前，**严禁调用 `run-codex.sh`**。

---

## Phase 3：放权移交 Codex 极速施工 + 现场自测闭环

用户确认后，使用字面量绝对路径直接调用辅助脚本（不要使用 `$VAR` 或 `$(...)` 展开，也不要用 `&&`、`;`、`|` 拼接其他命令，以确保 Antigravity 的 `Always Allow` 前缀自动放行永久生效）：

`<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh`

调用 `run_command` 执行命令（设置 `WaitMsBeforeAsync: 10000`、`NotificationTimeoutSeconds: 240`；按 Phase 0 选择按需附加 `--model` / `--effort` / `--tier`，沿用默认的项直接省略；若用户要求隔离分支可加 `--worktree`）：

```bash
# 写代码 / 重构 / 修 Bug（workspace-write 沙箱）
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh execute /absolute/path/to/workspace /absolute/path/to/implementation_plan.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md --model <model> --effort <effort> --tier <tier>

# 只读代码审查 / 架构审计（strict read-only 沙箱，严禁改文件；支持 --base <branch> 与 --adversarial 红队对抗式审查）
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh review /absolute/path/to/workspace /absolute/path/to/artifact_dir/scratch/review_spec.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md --model <model> --effort <effort> --tier <tier>

# 红队对抗式分支 Diff 审查（无需手写 spec 文件，自动比对 --base main...HEAD）
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh review /absolute/path/to/workspace --base main --adversarial
```

- **白名单轻量隔离（默认开启）**：脚本自动使用 `--ignore-user-config` 跳过桌面端 `~/.codex/config.toml` 里的重型插件与 MCP（仅白名单透传顶层 `model`、`model_reasoning_effort`、`service_tier` 与 `[features].respect_system_proxy`），以降低 Codex 启动与上下文开销（如需加载完整桌面配置可加 `--no-isolate`）。
- **严格隔离失败即中止与安全清理**：若传入 `--worktree` 但当前目录非 Git 仓库或 CLI 不支持，脚本会直接报错退出，绝不降级写主工作区；合并或验收完毕后可用 `run-codex.sh cleanup-worktree <worktree_path> [--delete-branch]` 安全清理临时 worktree（默认拒绝丢弃未提交改动或未合并分支）。
- **结构化交付与自动遥测摘要**：支持按需附加 `--structured`（使用内置 `resources/report.schema.json`）或 `--schema <file>` 约束 Codex 输出结构化验收 JSON；每次执行完毕后，脚本会自动从 `*.events.jsonl` 汇总耗时与 Token 用量，并附带 `git status --short` 与 `git diff --stat` 摘要。
- **环境一键体检**：若遇到 CLI 异常、未登录或配置不生效，可直接运行 `run-codex.sh doctor` 快速定位环境状态。
- **精确会话绑定**：`execute` 成功后会自动从日志提取本次 `session_id` 写入同目录的 `*.session_id`；后续 `resume` 只要传入同一个 `codex_last_message.md` 路径，即可精确续接该任务会话（亦支持 `--session <id>`），避免多任务并发时 `--last` 串会话。
- **静默摘要模式（默认开启）**：完整过程日志会落盘到同目录的 `*.log` 文件，终端仅回传最终摘要（`codex_last_message.md`），减少 Antigravity 侧的无效上下文消耗（如需实时查看完整过程日志，可在调试时设置 `CODEX_VERBOSE=1`）。
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

3. **单点回写共享状态（仅代码/里程碑改动时）+ 用“人话”向用户交付成果**：
   - **共享项目状态回写（Single-Writer）**：**仅当本次任务产生了实质代码/配置改动或里程碑推进**，且工作区存在 `.agents/state.md` 时，才由 Antigravity 作为唯一写回口精简更新（控制在 50 行内）；对于纯启停进程、查状态、跑测试等**未改动源码的轻量操作，跳过回写 `.agents/state.md` 和多余的 `git status` 检查**，直接 1 轮向用户汇报结果。若配置了 `basic-memory` MCP 且产生了值得长期保留的架构决策或踩坑记录，按需沉淀写入。
   - 摒弃生硬晦涩的终端日志堆砌，用通俗清晰的语言告诉用户：
     - **做好了什么**：实际实现的效果与使用方式；
     - **动了哪里**：新增/修改的核心文件列表（附可点击的 `file://` 链接）及各自作用；
     - **稳不稳**：构建与测试验收情况，以及值得留意的后续建议（如有）。
