# Google Antigravity × OpenAI Codex 协同工作流：一键部署指南（`/codex` 按需触发）

> [!TIP]
> **给使用者的最简用法（Agent-Native 一键安装）**：直接将本文档拖入（或全选复制粘贴到）你的 **Antigravity** 对话框中，发送一句：**「请严格按照这份文档，帮我在本机自动部署并验证这套 `/codex` 协同插件」**，Antigravity 就会自动完成环境检查、安装依赖、写入全局插件与校验全流程。

---

## 一、 设计理念与职责分工

本方案基于 Antigravity 原生插件与斜杠技能机制（**`/codex` 按需触发 + 终端异步脚本**），无需去菜单翻找开关，也不依赖任何第三方桥接库，核心是**让两个模型各自只做最擅长的事**：

- **平时默认状态**：什么都不用管，直接发消息就是 **Gemini 自己独立问答与编码**；
- **输入 `/codex` 召唤双脑协同时**：
  - **Antigravity / Gemini（产品军师 + 架构翻译官 + 终审质检）—— 管 `Why & What`**：
    1. **发散思维探路**：面对开放需求或潜在盲区，先用大白话给你提供 2～3 套可选思路与利弊对比；
    2. **抓大放小写“人话”任务书**：生成的方案卡片（`implementation_plan.md`）只讲清**业务目标、边缘防坑清单、架构切入点与红线边界**，让你几秒看懂并点击 **Proceed** 拍板——**绝不堆砌冗长伪代码去捆死 Codex 的手脚**；
    3. **独立终审与人话汇报**：复核 `git diff` 是否贴合你的本意，最后把硬核技术改动翻译成清晰的人话汇报给你。
  - **OpenAI Codex CLI（王牌总工程师 + 极速施工队）—— 管 `How`**：
    1. **自主地道工程实现**：拿到清晰的目标与边界后，自主决定最优雅的函数拆解、类型设计与代码组织；
    2. **施工现场自测闭环**：在工作区内边改边跑构建、Lint 与单测，遇到编译报错当场花几秒钟顺手修掉，一次性交出能跑通的成品，大幅减少来回折返耗时。

---

## 二、 给 Antigravity 的自动部署执行指令

> [!IMPORTANT]
> **以下章节为写给执行部署的 Antigravity Agent 的标准作业程序（SOP）**。当你收到用户发来的本文档时，请直接由你本人按以下 5 个步骤在本机完成安装与配置（macOS / Linux 使用 `run-codex.sh`；若检测到 Windows 环境，请将路径与脚本等价适配为仓库中的 PowerShell 版本 `run-codex.ps1`）。

### Step 1：本机环境检测与获取真实家目录

1. 执行只读检测命令，确认以下信息：
   - 当前用户的**真实家目录绝对路径**（记为 `<USER_HOME>`，例如 `/Users/alice` 或 `/home/alice`——后续写入配置文件时**必须替换为字面量绝对路径**，切勿保留 `$HOME` 或 `~`，否则会影响 Antigravity 命令前缀自动授权匹配）；
   - 检查本机是否已安装 `codex`（含 macOS ChatGPT.app 内置路径 `/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS`）、`node`、`npm`、`brew`、`jq`。
2. 读取内置的 `plugin` 技能说明（若可用），通过 Language Server 的 `GetAllPlugins` 接口检查现有全局插件列表，确认 `codex-collaborator` 名称无冲突（若此前存在旧版含 `rules/` 或 `skills/codex-executor/` 的目录，请一并清理以确保干净升级）。

---

### Step 2：安装并核验 OpenAI Codex CLI

1. **若未安装 `codex`**：
   - 优先使用 `npm install -g @openai/codex`（macOS 也可用 `brew install codex`）进行全局安装。
2. **核验 CLI 版本与登录状态**：
   - 运行 `codex --version`、`codex exec --help` 与 `codex login status`。
   - 如果 `codex login status` 显示已登录（如 `Logged in using ChatGPT` 或 API Key），直接继续；如果显示未登录，先继续把下面的所有插件配置文件部署完毕，最后提醒用户在终端执行一次 `codex login` 即可。

---

### Step 3：创建全局插件目录与基础元数据

在 `<USER_HOME>/.gemini/config/plugins/codex-collaborator/` 下创建以下文件（**注意：不要创建 `rules/` 目录**，以保证平时默认不拦截普通对话）：

#### 1. `<USER_HOME>/.gemini/config/plugins/codex-collaborator/plugin.json`

```json
{
  "name": "codex-collaborator",
  "displayName": "Antigravity × Codex 协同 (/codex)",
  "description": "按需触发的 Antigravity × Codex 协同工作流：平时默认由 Antigravity 独立工作；输入 /codex 时，由 Antigravity 负责发散探路、用人话对齐需求边界与终审把关，由 Codex CLI 负责自主工程实现与现场自测闭环。",
  "version": "1.0.0",
  "logo": "assets/logo.svg",
  "suggestedPrompts": [
    "/codex 我想做一个新功能，先帮我发散几个思路，拍板后交给 Codex 落地",
    "/codex 帮我理清这个模块的重构边界，我确认后让 Codex 负责工程实现与自测",
    "/codex 排查这个问题的根因并用人话讲清方案，确认后交给 Codex 极速修复"
  ]
}
```

#### 2. `<USER_HOME>/.gemini/config/plugins/codex-collaborator/assets/logo.svg`

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128" fill="none">
  <defs>
    <linearGradient id="geminiGrad" x1="16" y1="16" x2="76" y2="76" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#4F8BFF"/>
      <stop offset="100%" stop-color="#9B72CB"/>
    </linearGradient>
    <linearGradient id="codexGrad" x1="52" y1="52" x2="112" y2="112" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#10A37F"/>
      <stop offset="100%" stop-color="#34D399"/>
    </linearGradient>
  </defs>
  <path d="M46 16 C46 34, 34 46, 16 46 C34 46, 46 58, 46 76 C46 58, 58 46, 76 46 C58 46, 46 34, 46 16 Z" fill="url(#geminiGrad)"/>
  <rect x="52" y="54" width="60" height="56" rx="14" fill="url(#codexGrad)"/>
  <path d="M68 73 L79 82 L68 91" stroke="#FFFFFF" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>
  <line x1="84" y1="91" x2="98" y2="91" stroke="#FFFFFF" stroke-width="6" stroke-linecap="round"/>
</svg>
```

#### 3. `<USER_HOME>/.gemini/config/plugins/codex-collaborator/README.md`

```markdown
# Antigravity × Codex 协同插件 (`/codex` 按需触发)

- **平时默认状态**：无需任何开关，默认由 **Antigravity** 自己直接完成问答与编码。
- **按需协同**：输入 **`/codex 你的需求`** 发送，启动 **Antigravity（管 Why & What + 终审把关）× Codex CLI（管 How + 现场自测）** 的完整闭环。
```

---

### Step 4：写入 `/codex` 斜杠技能与执行脚本

#### 1. 斜杠技能定义：`<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/SKILL.md`

> [!WARNING]
> 写入此文件时，**必须把下方文本中所有的 `<USER_HOME>` 替换为你本机检测到的真实绝对路径**（例如 `/Users/zhangsan`），不要保留占位符或环境变量！

````markdown
---
name: codex
description: >-
  仅当用户输入 /codex 斜杠命令，或在对话中明确要求“交给 Codex / 开启协同”时激活（平时普通编码请求请勿自动激活，由 Antigravity 直接完成）。激活后由 Antigravity 负责发散思维探路、用人话对齐目标与边界并做独立终审；由 Codex CLI 负责自主工程实现与现场自测闭环。
---

# Antigravity × Codex 协同技能 (`/codex`)

> **触发边界**：仅在用户通过 `/codex` 显式召唤、或明确口头指定交给 Codex 时启用。一旦启用，请严格遵循 **「Gemini 管 Why & What（产品发散、人话沟通、架构边界、终审把关），Codex 管 How（地道工程设计、极速编码、现场自测闭环）」** 的分工原则，切勿在未获用户允许时由 Gemini 自己改业务源码。

---

## Phase 1：发散探路与“人话”任务书（Gemini）

1. **严禁越权改代码**：只用只读工具（`read_file`、搜索工具、只读命令）快速摸清相关代码结构、现有约定与可复用模块。
2. **发散思维前置与视觉分工（灵活判断）**：
   - **若需求开放、存在多种实现路径（如“快改轻量版 vs 高扩展重构版”）或发现潜在产品盲区**：先用通俗好懂的“人话”给出 2～3 个思路与利弊对比（必要时配合 `ask_question` 让用户一键选方向），帮用户打开思路、敲定大方向后再写方案卡片。
   - **若涉及前端视觉设计、配色布局或高清截图审阅**：优先由 Antigravity 直接与用户对齐视觉风格并完成审图，不要把大体积原图塞进 Codex 上下文；纯逻辑/工程模块再交由 Codex 实现。
   - **若需求目标已经非常明确**：直接生成方案卡片，同时主动补充你帮用户额外想到的边界防坑点。
3. **生成“抓大放小、人话可读”的任务书 `<Artifact Directory Path>/implementation_plan.md`**（设置 `ArtifactMetadata` 为 `UserFacing: true` 和 `RequestFeedback: true` 以渲染 **Proceed** 按钮）：
   - 方案顶部必须保留执行标记：`> 执行方式：用户确认后通过 codex 技能调用 run-codex.sh 交由 OpenAI Codex CLI 自主工程实现与现场自测闭环`
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

调用 `run_command` 执行命令（设置 `WaitMsBeforeAsync: 10000`、`NotificationTimeoutSeconds: 240`）：

```bash
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh execute /absolute/path/to/workspace /absolute/path/to/implementation_plan.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md
```

- 脚本默认开启**静默摘要模式**：完整过程日志落盘到同目录的 `*.log`，终端只回传最终摘要，大幅节省 Antigravity 上下文（调试时可设 `CODEX_VERBOSE=1`）。
- 若脚本提示尚未登录（`codex login`），暂停并请用户在终端运行一次 `codex login` 授权后再继续。

---

## Phase 4：Gemini 独立终审与“说人话”汇报

`run-codex.sh` 执行完毕后，由 Gemini 进行独立把关：

1. **对齐初心与边界复核**：
   - 读取 `scratch/codex_last_message.md`（若有），并检查 `git status --short` 与 `git diff`（非 Git 目录则用 `read_file` 查看改动文件）。
   - 重点站在**产品体验与架构全局观**核查：用户的真实意图满足了吗？列出的边缘情况兜住了吗？有没有越界误改无关文件？
2. **核验测试结果与精准打回**：
   - 若 Codex 在现场已跑通全部构建/测试且 Diff 干净，可做轻量抽检确认即可，避免重复跑耗时全量测试拖慢节奏；若 Codex 未跑某项关键验证，由 Gemini 补跑确认。
   - 若发现需求遗漏、逻辑偏差或测试报错，**不要由 Gemini 自己上手改业务源码**（除非用户主动要求你接手）：将简明问题清单与报错信息写入 `<Artifact Directory Path>/scratch/codex_fix_instructions.md`，通过 `resume` 唤醒同一个 Codex 会话极速返修（设置 `WaitMsBeforeAsync: 10000`、`NotificationTimeoutSeconds: 240`，最多 3 轮）：

```bash
<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh resume /absolute/path/to/workspace /absolute/path/to/artifact_dir/scratch/codex_fix_instructions.md /absolute/path/to/artifact_dir/scratch/codex_last_message.md
```

3. **用“人话”向用户交付成果**：
   - 摒弃生硬晦涩的终端日志堆砌，用通俗清晰的语言告诉用户：
     - **做好了什么**：实际实现的效果与使用方式；
     - **动了哪里**：新增/修改的核心文件列表（附可点击的 `file://` 链接）及各自作用；
     - **稳不稳**：构建与测试验收情况，以及值得留意的后续建议（如有）。
````

#### 2. 执行脚本：`<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew, npm global bin, and ChatGPT desktop codex-cli paths are available in GUI shells
export PATH="/opt/homebrew/bin:/usr/local/bin:${HOME}/.npm-global/bin:/Applications/ChatGPT.app/Contents/Resources/codex-cli/codex-path:/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS:${PATH}"

usage() {
  cat <<'EOF' >&2
Usage:
  run-codex.sh execute <workspace_dir> <plan_file> [output_last_message_file]
  run-codex.sh resume  <workspace_dir> <fix_file>  [output_last_message_file]

Environment variables:
  CODEX_VERBOSE=1   Stream full codex process output to stdout instead of quiet log-summary mode.
EOF
  exit 2
}

if [[ $# -lt 3 ]]; then
  usage
fi

MODE="$1"
WORKSPACE_DIR="$2"
INPUT_FILE="$3"
OUTPUT_FILE="${4:-}"
VERBOSE="${CODEX_VERBOSE:-0}"

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: 'codex' CLI not found in PATH. Install it via: npm install -g @openai/codex" >&2
  exit 127
fi

if [[ ! -d "$WORKSPACE_DIR" ]]; then
  echo "ERROR: Workspace directory does not exist: $WORKSPACE_DIR" >&2
  exit 2
fi

if [[ ! -f "$INPUT_FILE" ]] || [[ ! -s "$INPUT_FILE" ]]; then
  echo "ERROR: Input plan/instructions file is missing or empty: $INPUT_FILE" >&2
  exit 2
fi

CLEANUP_TMP_OUT=0
if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  LOG_FILE="${OUTPUT_FILE%.*}.log"
else
  OUTPUT_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-last-message.XXXXXX.md")"
  LOG_FILE="${OUTPUT_FILE%.md}.log"
  CLEANUP_TMP_OUT=1
fi
OUT_FLAGS=(-o "$OUTPUT_FILE")

cleanup() {
  if [[ "$CLEANUP_TMP_OUT" -eq 1 ]]; then
    rm -f "$OUTPUT_FILE"
  fi
}
trap cleanup EXIT

cd "$WORKSPACE_DIR"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_FLAGS=()
else
  GIT_FLAGS=(--skip-git-repo-check)
fi

# Auto-detect approval flag across codex-cli versions
if codex exec --help 2>&1 | grep -q -- '--approve-for-me'; then
  APPROVAL_FLAGS=(--approve-for-me -s workspace-write)
else
  APPROVAL_FLAGS=(--full-auto)
fi

run_codex_cmd() {
  local exit_code=0
  if [[ "$VERBOSE" == "1" ]]; then
    "$@" || exit_code=$?
  else
    "$@" >"$LOG_FILE" 2>&1 || exit_code=$?
  fi

  if [[ "$exit_code" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: codex exited with code $exit_code." >&2
    if [[ "$VERBOSE" != "1" ]] && [[ -f "$LOG_FILE" ]]; then
      echo "Full process log: $LOG_FILE" >&2
      echo "--- Last 60 lines of log ---" >&2
      tail -n 60 "$LOG_FILE" >&2 || true
      echo "----------------------------" >&2
    fi
    echo "Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in." >&2
    exit "$exit_code"
  fi

  if [[ "$VERBOSE" != "1" ]]; then
    echo "==> [Codex Engineer] Completed cleanly. Full process log: $LOG_FILE"
    if [[ -s "$OUTPUT_FILE" ]]; then
      echo ""
      echo "=== Codex Final Summary ==="
      cat "$OUTPUT_FILE"
    fi
  fi
}

case "$MODE" in
  execute)
    PROMPT_HEADER="You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $(pwd). You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    echo "==> [Codex Engineer] Starting implementation & self-test in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Spec file: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      "$PROMPT_HEADER" < "$INPUT_FILE"
    ;;

  resume)
    echo "==> [Codex Engineer] Resuming latest Codex session in: $WORKSPACE_DIR"
    echo "==> [Codex Engineer] Follow-up review feedback: $INPUT_FILE"
    run_codex_cmd codex exec \
      "${APPROVAL_FLAGS[@]}" \
      --color never \
      resume \
      --last \
      ${GIT_FLAGS[@]+"${GIT_FLAGS[@]}"} \
      ${OUT_FLAGS[@]+"${OUT_FLAGS[@]}"} \
      - < "$INPUT_FILE"
    ;;

  *)
    echo "ERROR: Unknown subcommand '$MODE' (expected 'execute' or 'resume')." >&2
    usage
    ;;
esac
```

---

### Step 5：赋权、插件校验与交付汇报

1. **赋予可执行权限**：运行 `chmod +x <USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh`（并使用 `bash -n` 校验脚本语法无误）。
2. **重新拉取插件清单验证**：再次调用 Language Server 的 `GetAllPlugins` 接口，确认返回结果中包含 `name: "codex-collaborator"`、`disabled: false`、`skills: ["codex"]` 且 `rules: []`（无全局常驻拦截）。
3. **向用户交付结果**：
   - 告知用户平时正常聊天由 Gemini 自己干活；需要双脑协同时只需在输入框敲 **`/codex 需求描述`** 即可召唤；
   - 如果 Step 2 中检测到 `codex login status` 尚未登录，提醒用户在终端执行一次 `codex login` 完成登录授权；
   - 提醒用户首次触发 `run-codex.sh` 命令弹窗时勾选 **Always Allow（始终允许）**，后续即可全程无感自动执行。
