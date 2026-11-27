<p align="center">
  <img src="./assets/logo.svg" width="84" height="84" alt="antigravity-codex logo" />
</p>

<h1 align="center">antigravity-codex</h1>

<p align="center">
  <strong>Google Antigravity × OpenAI Codex — 按需触发协同工作流（<code>/codex</code>）</strong>
</p>

<p align="center">
  <a href="./README.md">English</a> | 简体中文
</p>

<p align="center">
  <img src="./assets/workflow-preview.png" alt="Antigravity x Codex 工作流示意图" width="100%" />
</p>

---

## 为什么选择 `antigravity-codex`？

一套为 **Google Antigravity** 打造的轻量、零依赖原生插件，将 **Antigravity** 与 **Codex CLI** 的各自长板结合起来——并且**只在你输入 `/codex` 时按需触发**：

- **平时零侵入**：刻意不写全局 `rules/AGENTS.md`，仅通过 `skills/codex` 按需加载。日常问答和小改动依然由 Antigravity 原生完成，不污染上下文。
- **深度原生 UI 门禁**：调用 Antigravity 原生 `implementation_plan.md` 方案卡片（`RequestFeedback: true`），渲染可点击的 **Proceed** 按钮并支持划词批注微调，未拍板前严禁修改一行代码。
- **清晰的职责分工（`Why & What` vs. `How`）**：
  - **Antigravity（需求分析 + 终审把关）**：负责发散思维探路、输出抓大放小的“人话”任务书、划定边缘防坑清单与红线边界、独立复核 `git diff` 并用人话汇报。
  - **Codex CLI（工程实现 + 现场自测）**：拿到清晰目标后自主决定最地道的工程实现，并在工作区现场跑通构建、Lint 与单测闭环，一次交出能跑通的代码。
- **零第三方桥接 · 100% 官方正门**：不装 MCP Server、不用逆向反代、不依赖 tmux，直接通过官方 `codex exec` / `codex exec resume --last` 命令行协作，合规稳定。
- **静默日志摘要 · 大幅省额度**：把多文件编码与编译试错卸载到单次脚本调用中；默认开启静默摘要模式，将冗长的过程日志落盘到 `.log` 文件、终端仅回传最终结果摘要（调试时可设 `CODEX_VERBOSE=1`），并配合精简输出纪律与前端视觉优先对齐策略。
- **全平台支持**：原生提供 **macOS / Linux (`run-codex.sh`)** 与 **Windows (`run-codex.ps1`)** 双端支持。

---

## 工作流时序图

```mermaid
sequenceDiagram
    actor User as 用户
    participant Antigravity as Antigravity (管 Why & What)
    participant Codex as Codex CLI (管 How & 现场自测)

    Note over User,Antigravity: 平时普通消息：Antigravity 自己直接执行（无需任何开关）
    User->>Antigravity: 输入 "/codex + 开发/重构/修Bug需求"
    opt 需求开放或有多种解法时
        Antigravity-->>User: 用“人话”发散提供 2~3 个思路选项与防坑建议
        User->>Antigravity: 敲定大方向
    end
    Antigravity->>Antigravity: 只读调研代码库，生成抓大放小的 implementation_plan.md
    Antigravity-->>User: 展示带 [Proceed] 按钮的“人话”方案卡片并暂停等待
    User->>Antigravity: 划词批注微调或点击 [Proceed] 拍板确认
    Antigravity->>Codex: 调用 run-codex.sh / run-codex.ps1 execute 放权移交
    Codex->>Codex: 自主工程设计 + 修改代码 + 现场跑通编译/Lint/单测闭环
    Codex-->>Antigravity: 一次性交付验证通过的代码与技术摘要
    Antigravity->>Antigravity: 独立复核 git diff 对齐产品本意与边界红线
    alt 存在需求遗漏或边界偏差
        Antigravity->>Codex: 调用 run-codex resume --last 精准打回微调（最多 3 轮）
        Codex-->>Antigravity: 极速返修完成
    end
    Antigravity-->>User: 用“人话”汇总实现效果、可点击文件链接与验收情况
```

---

## 环境要求

1. 已安装 **Google Antigravity**。
2. 已安装并登录 **OpenAI Codex CLI**（支持 `npm install -g @openai/codex`、`brew install codex`，也自动兼容 macOS ChatGPT 桌面端自带的 `codex`）：
   ```bash
   codex --version
   codex login status
   ```
   若尚未登录，在终端执行一次 `codex login` 完成授权即可。

---

## 安装方式（任选其一）

### 方式一：命令行一键安装（推荐）

**macOS / Linux：**
```bash
git clone https://github.com/19zbhy/antigravity-codex.git
cd antigravity-codex
./install.sh
```

**Windows (PowerShell)：**
```powershell
git clone https://github.com/19zbhy/antigravity-codex.git
cd antigravity-codex
.\install.ps1
```

安装脚本会自动完成：
- 将插件复制到 `~/.gemini/config/plugins/codex-collaborator`
- 自动将模板中的 `<USER_HOME>` 替换为你的真实绝对路径（确保 Antigravity `Always Allow` 命令前缀放行生效）
- 赋予脚本可执行权限、检查语法并核验本机 `codex` CLI 登录状态

### 方式二：把安装文档直接拖给 Antigravity 自动安装（Agent-Native）

不想敲终端命令？直接将 [docs/INSTALL_WITH_ANTIGRAVITY.md](./docs/INSTALL_WITH_ANTIGRAVITY.md) 拖进 Antigravity 对话框，发送一句：

> **「请严格按照这份文档，帮我在本机自动部署并验证这套 `/codex` 双脑协同插件」**

Gemini 就会自动帮你检测环境、替换本机路径、写入全局插件并验证热加载生效。

---

## 使用指南

1. **日常问答 / 小修小补**：直接发消息，由 Gemini 独立完成。
2. **复杂新功能 / 跨文件重构 / 疑难排障**：在输入框敲 **`/codex 你的需求`** 即可召唤双脑协同。
3. **审阅拍板**：查看 `implementation_plan.md` 方案卡片，满意后点击 **Proceed**。
4. **首次放行**：首次执行 `run-codex.sh`（或 `run-codex.ps1`）弹出命令确认框时，勾选 **Always Allow（始终允许）**，后续即可全程无感自动跑完。

---

## 仓库目录结构

```text
antigravity-codex/
├── README.md                              # 英文主文档
├── README.zh-CN.md                        # 中文文档
├── LICENSE                                # MIT 开源协议
├── install.sh                             # macOS / Linux 一键安装脚本
├── install.ps1                            # Windows PowerShell 一键安装脚本
├── assets/
│   ├── logo.svg                           # 插件图标
│   └── workflow-preview.png               # 四步闭环视觉演示图
├── docs/
│   └── INSTALL_WITH_ANTIGRAVITY.md        # 拖入 Antigravity 自动部署 SOP
└── plugin/                                # 干净的插件模板（无硬编码个人路径）
    ├── plugin.json
    ├── README.md
    ├── assets/logo.svg
    └── skills/codex/
        ├── SKILL.md                       # /codex 协同技能定义
        └── scripts/
            ├── run-codex.sh               # macOS / Linux 执行器（兼容 Bash 3.2）
            └── run-codex.ps1              # Windows PowerShell 执行器
```

---

## 致谢与灵感来源

- 本项目的静默日志摘要输出、精简输出纪律与前端视觉分工思路受到 [xinqinnain/antigravity-codex-commander](https://github.com/xinqinnain/antigravity-codex-commander) 的启发，在此致谢。

---

## 开源协议

[MIT](./LICENSE)
