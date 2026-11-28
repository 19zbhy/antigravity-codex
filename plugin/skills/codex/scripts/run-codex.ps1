#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Windows PowerShell runner for the Google Antigravity x OpenAI Codex workflow.
.DESCRIPTION
  Supports 'list-options', 'sync-options', 'execute' (workspace-write), 'review' (read-only),
  and 'resume' (pinned session ID with --last fallback). Enables --ignore-user-config whitelist
  isolation by default and fails closed when --worktree is requested but unsupported.
.EXAMPLE
  pwsh -NoProfile -File run-codex.ps1 list-options
  pwsh -NoProfile -File run-codex.ps1 execute C:\path\to\workspace C:\path\to\implementation_plan.md C:\path\to\codex_last_message.md -Model gpt-6.2-sol -Effort high -Tier priority
  pwsh -NoProfile -File run-codex.ps1 review  C:\path\to\workspace C:\path\to\review_spec.md C:\path\to\codex_last_message.md
  pwsh -NoProfile -File run-codex.ps1 resume  C:\path\to\workspace C:\path\to\codex_fix_instructions.md C:\path\to\codex_last_message.md
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("doctor", "list-options", "sync-options", "list-projects", "init-shared", "list-sessions", "show-session", "cleanup-worktree", "execute", "review", "resume", "fork")]
  [string]$Mode,

  [Parameter(Mandatory = $false, Position = 1)]
  [string]$WorkspaceDir = "",

  [Parameter(Mandatory = $false, Position = 2)]
  [string]$InputFile = "",

  [Parameter(Mandatory = $false, Position = 3)]
  [string]$OutputFile = "",

  [Parameter(Mandatory = $false)]
  [string]$Session = "",

  [Parameter(Mandatory = $false)]
  [string]$Model = "",

  [Parameter(Mandatory = $false)]
  [string]$Effort = "",

  [Parameter(Mandatory = $false)]
  [ValidateSet("", "priority", "default", "flex", "fast")]
  [string]$Tier = "",

  [Parameter(Mandatory = $false)]
  [int]$Limit = 10,

  [Parameter(Mandatory = $false)]
  [int]$Turns = 10,

  [Parameter(Mandatory = $false)]
  [string]$Schema = "",

  [Parameter(Mandatory = $false)]
  [string]$Prompt = "",

  [Parameter(Mandatory = $false)]
  [string]$Base = "",

  [switch]$ExcludeState,
  [switch]$Worktree,
  [switch]$Structured,
  [switch]$Adversarial,
  [switch]$DeleteBranch,
  [switch]$Force,
  [switch]$QuitAppOnLock,
  [switch]$NoIsolate,
  [switch]$Last,
  [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$configFile = Join-Path $codexDir "config.toml"
$cacheFile = Join-Path $codexDir "models_cache.json"

# Read ONLY top-level string keys (stops at the first [section] header)
function Get-TomlTopLevelString([string]$Key, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  $dqPattern = "^\s*$([regex]::Escape($Key))\s*=\s*`"([^`"]*)`""
  $sqPattern = "^\s*$([regex]::Escape($Key))\s*=\s*'([^']*)'"
  foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
    if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
    if ($line -match '^\s*\[') { break }
    if ($line -match $dqPattern) { return $Matches[1] }
    if ($line -match $sqPattern) { return $Matches[1] }
  }
  return ""
}

# Check boolean key strictly inside the [features] section
function Test-TomlFeatureTrue([string]$Key, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $inFeatures = $false
  $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*true(\s*(#.*)?)?$"
  foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
    if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
    if ($line -match '^\s*\[features\]\s*(#.*)?$') { $inFeatures = $true; continue }
    if ($line -match '^\s*\[') { $inFeatures = $false; continue }
    if ($inFeatures -and ($line -match $pattern)) { return $true }
  }
  return $false
}

function Get-SessionIdFromJsonl([string]$EventsPath) {
  if (-not (Test-Path -LiteralPath $EventsPath)) { return "" }
  foreach ($raw in (Get-Content -LiteralPath $EventsPath -Encoding UTF8)) {
    $line = $raw.Trim()
    if (-not $line.StartsWith("{")) { continue }
    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if ($obj -and ($obj.type -eq "thread.started") -and ($obj.thread_id -is [string]) -and ($obj.thread_id.Length -ge 8)) {
        return $obj.thread_id
      }
    } catch {}
  }
  return ""
}

function Get-SessionIdFromText([string]$LogPath) {
  if (-not (Test-Path -LiteralPath $LogPath)) { return "" }
  foreach ($line in (Get-Content -LiteralPath $LogPath -Encoding UTF8)) {
    if ($line -match '(?i)^\s*session id:\s*([0-9a-f-]{8,})\s*$') {
      return $Matches[1]
    }
  }
  return ""
}

function Get-UsageFromJsonl([string]$EventsPath) {
  if (-not (Test-Path -LiteralPath $EventsPath)) { return "" }
  $inp = 0; $cached = 0; $out = 0; $turns = 0
  foreach ($raw in (Get-Content -LiteralPath $EventsPath -Encoding UTF8)) {
    $line = $raw.Trim()
    if (-not $line.StartsWith("{")) { continue }
    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if ($obj -and ($obj.type -eq "turn.completed") -and $obj.usage) {
        $turns++
        if ($null -ne $obj.usage.input_tokens) { $inp += [int]$obj.usage.input_tokens }
        if ($null -ne $obj.usage.cached_input_tokens) { $cached += [int]$obj.usage.cached_input_tokens }
        if ($null -ne $obj.usage.output_tokens) { $out += [int]$obj.usage.output_tokens }
      }
    } catch {}
  }
  if ($turns -gt 0) {
    $total = $inp + $out
    return "tokens: input=$inp (cached=$cached) output=$out total=$total"
  }
  return ""
}

function Get-CodexProjectLines {
  $stateDb = Join-Path $codexDir "state_5.sqlite"
  if (-not (Test-Path -LiteralPath $stateDb)) { return @() }
  $pyCmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $pyCmd) { $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $pyCmd) { return @() }
  $pyCode = @'
import sqlite3, sys
try:
    try:
        conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
    except sqlite3.OperationalError:
        conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
    cur = conn.cursor()
    cur.execute("""
    SELECT p.name, pr.path
    FROM projects p
    JOIN project_roots pr ON p.id = pr.project_id
    WHERE pr.position = (SELECT MIN(pr2.position) FROM project_roots pr2 WHERE pr2.project_id = p.id)
    ORDER BY p.position ASC
    """)
    for name, path in cur.fetchall():
        if name and path:
            print(f"  - {name} | {path}")
    conn.close()
except Exception:
    pass
'@
  return @(& $pyCmd.Source -c $pyCode $stateDb 2>$null)
}

function Get-CodexProjectSessionLines {
  $stateDb = Join-Path $codexDir "state_5.sqlite"
  if (-not (Test-Path -LiteralPath $stateDb)) { return @() }
  $pyCmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $pyCmd) { $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $pyCmd) { return @() }
  $pyCode = @'
import datetime, os, sqlite3, sys
try:
    try:
        conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
    except sqlite3.OperationalError:
        conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
    cur = conn.cursor()
    cols = {r[1] for r in cur.execute("PRAGMA table_info(threads)").fetchall()}
    title_expr = "COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview, '')" if "name" in cols else "COALESCE(NULLIF(title, ''), preview, '')"
    ts_expr = "COALESCE(NULLIF(recency_at, 0), updated_at)" if "recency_at" in cols else "updated_at"
    projs = cur.execute("""
    SELECT p.name, pr.path
    FROM projects p
    JOIN project_roots pr ON p.id = pr.project_id
    WHERE pr.position = (SELECT MIN(pr2.position) FROM project_roots pr2 WHERE pr2.project_id = p.id)
    ORDER BY p.position ASC
    """).fetchall()
    for pname, ppath in projs:
        if not pname or not ppath: continue
        norm = os.path.realpath(ppath).rstrip("\\/")
        rows = cur.execute(
            f"SELECT id, {ts_expr}, {title_expr} FROM threads WHERE archived = 0 AND COALESCE(model, '') != 'codex-auto-review' AND (rtrim(rtrim(cwd, '/'), '\\') = ? OR rtrim(rtrim(cwd, '/'), '\\') = ?) ORDER BY {ts_expr} DESC LIMIT 6",
            (ppath.rstrip("\\/"), norm),
        ).fetchall()
        if rows:
            print(f"  - {pname}:")
            for sid, ts, title in rows:
                dt = datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M") if isinstance(ts, (int, float)) and ts > 0 else str(ts)
                print(f"    - {sid} | {dt} | {' '.join(str(title).split())[:60]}")
    conn.close()
except Exception:
    pass
'@
  return @(& $pyCmd.Source -c $pyCode $stateDb 2>$null)
}

function Get-CodexOptionsLines([bool]$IncludeSessions = $false) {
  $defaultModel = Get-TomlTopLevelString "model" $configFile
  $defaultEffort = Get-TomlTopLevelString "model_reasoning_effort" $configFile
  $defaultTier = Get-TomlTopLevelString "service_tier" $configFile

  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("- default_model: $(if ($defaultModel) { $defaultModel } else { 'default' })")
  $lines.Add("- default_effort: $(if ($defaultEffort) { $defaultEffort } else { 'default' })")
  $lines.Add("- default_tier: $(if ($defaultTier) { $defaultTier } else { 'default' })")

  $allEfforts = [System.Collections.Generic.List[string]]::new()
  if (Test-Path -LiteralPath $cacheFile) {
    $cacheData = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $lines.Add("- models:")
    foreach ($m in ($cacheData.models | Where-Object { $_.visibility -eq "list" })) {
      $lvls = @($m.supported_reasoning_levels | ForEach-Object { $_.effort } | Where-Object { $_ })
      foreach ($e in $lvls) {
        if (-not $allEfforts.Contains($e)) { $allEfforts.Add($e) }
      }
      $disp = if ($m.display_name) { $m.display_name } else { $m.slug }
      $lines.Add("  - $($m.slug) ($disp)")
    }
    $lines.Add("- efforts: $($allEfforts -join ', ')")
  } else {
    $lines.Add("- models: (run codex once to populate ~/.codex/models_cache.json)")
    $lines.Add("- efforts: low, medium, high, xhigh")
  }
  $lines.Add("- service_tiers: priority (快速/Fast), default (标准)")
  $projLines = Get-CodexProjectLines
  if ($projLines.Count -gt 0) {
    $lines.Add("- projects:")
    foreach ($pl in $projLines) { $lines.Add($pl) }
  }
  if ($IncludeSessions) {
    $sessLines = Get-CodexProjectSessionLines
    if ($sessLines.Count -gt 0) {
      $lines.Add("- project_sessions:")
      foreach ($sl in $sessLines) { $lines.Add($sl) }
    }
  }
  return $lines
}

function Sync-CodexOptionsIntoSkill {
  $scriptDir = Split-Path -Parent $PSCommandPath
  $skillDir = Split-Path -Parent $scriptDir
  $pluginRoot = Split-Path -Parent (Split-Path -Parent $skillDir)
  $targets = @(
    @{ Path = (Join-Path $skillDir "SKILL.md"); IncludeSessions = $true },
    @{ Path = (Join-Path $pluginRoot "rules\AGENTS.md"); IncludeSessions = $false }
  )
  foreach ($entry in $targets) {
    $targetPath = $entry.Path
    if (-not (Test-Path -LiteralPath $targetPath)) { continue }
    $content = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8
    if ($content -notmatch "<!-- CODEX_LIVE_OPTIONS_START -->" -or $content -notmatch "<!-- CODEX_LIVE_OPTIONS_END -->") { continue }
    $block = (Get-CodexOptionsLines -IncludeSessions $entry.IncludeSessions) -join "`n"
    $replacement = "<!-- CODEX_LIVE_OPTIONS_START -->`n$block`n<!-- CODEX_LIVE_OPTIONS_END -->"
    $updated = [regex]::Replace($content, "<!-- CODEX_LIVE_OPTIONS_START -->[\s\S]*?<!-- CODEX_LIVE_OPTIONS_END -->", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
    [System.IO.File]::WriteAllText($targetPath, $updated, [System.Text.UTF8Encoding]::new($false))
  }
}

if ($Mode -eq "doctor") {
  $failures = 0
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    Write-Output "=== antigravity-codex doctor ==="
    $codexBin = Get-Command codex -ErrorAction SilentlyContinue
    if ($codexBin) {
      $verLines = @(& codex --version 2>&1)
      $ver = if ($verLines.Count -gt 0) { "$($verLines[0])" } else { "found" }
      Write-Output "  [OK]   codex CLI: $ver ($($codexBin.Source))"
      $loginLines = @(& codex login status 2>&1)
      $loginExit = $LASTEXITCODE
      $loginOut = if ($loginLines.Count -gt 0) { "$($loginLines[0])" } else { "authenticated" }
      if ($loginExit -eq 0) {
        Write-Output "  [OK]   codex auth: $loginOut"
      } else {
        Write-Output "  [FAIL] codex auth: not signed in (run 'codex login' in terminal)"
        $failures++
      }
      $docHelp = (@(& codex exec --help 2>&1) | ForEach-Object { "$_" }) -join "`n"
      $caps = @()
      if ($docHelp -match "--json") { $caps += "--json" }
      if ($docHelp -match "--output-schema") { $caps += "--output-schema" }
      if ($docHelp -match "--worktree") { $caps += "--worktree" }
      if ($docHelp -match "--ignore-user-config") { $caps += "--ignore-user-config" }
      if ($docHelp -match "--approve-for-me") { $caps += "--approve-for-me" }
      Write-Output "  [OK]   codex exec flags: $(if ($caps.Count -gt 0) { $caps -join ' ' } else { 'basic' })"
    } else {
      Write-Output "  [FAIL] codex CLI: not found in PATH"
      $failures++
    }

    if (Test-Path -LiteralPath $configFile) {
      $dm = Get-TomlTopLevelString "model" $configFile
      $de = Get-TomlTopLevelString "model_reasoning_effort" $configFile
      $dt = Get-TomlTopLevelString "service_tier" $configFile
      $dp = Get-TomlTopLevelString "model_provider" $configFile
      Write-Output "  [OK]   config.toml: model=$(if ($dm) {$dm} else {'default'}) effort=$(if ($de) {$de} else {'default'}) tier=$(if ($dt) {$dt} else {'default'}) provider=$(if ($dp) {$dp} else {'openai'})"
    } else {
      Write-Output "  [WARN] config.toml: not found at $configFile"
    }

    if (Test-Path -LiteralPath $cacheFile) {
      Write-Output "  [OK]   models_cache.json: found ($cacheFile)"
    } else {
      Write-Output "  [WARN] models_cache.json: not found (run codex once to populate)"
    }

    $stateDb = Join-Path $codexDir "state_5.sqlite"
    if (Test-Path -LiteralPath $stateDb) {
      $projCount = (Get-CodexProjectLines).Count
      Write-Output "  [OK]   state_5.sqlite: found ($projCount Codex projects)"
    } else {
      Write-Output "  [WARN] state_5.sqlite: not found (Codex Desktop project/session lookup unavailable)"
    }

    $gitBin = Get-Command git -ErrorAction SilentlyContinue
    if ($gitBin) {
      $gitLines = @(& git --version 2>&1)
      $gitVer = if ($gitLines.Count -gt 0) { "$($gitLines[0])" } else { "found" }
      Write-Output "  [OK]   git: $gitVer"
    } else {
      Write-Output "  [WARN] git: not found (-Worktree and git diff summaries unavailable)"
    }

    $scriptDir = Split-Path -Parent $PSCommandPath
    $skillPath = Join-Path (Split-Path -Parent $scriptDir) "SKILL.md"
    if (Test-Path -LiteralPath $skillPath) {
      $skillText = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
      if ($skillText -match "<USER_HOME>") {
        Write-Output "  [WARN] SKILL.md: still contains <USER_HOME> placeholder (run install.ps1)"
      } elseif ($skillText -match "(?m)^- \(not synced yet\)\r?$") {
        Write-Output "  [WARN] SKILL.md: live options not synced yet (run sync-options)"
      } else {
        Write-Output "  [OK]   SKILL.md: installed and live options synced ($skillPath)"
      }
    } else {
      Write-Output "  [WARN] SKILL.md: not found at $skillPath"
    }
  } finally {
    $ErrorActionPreference = $prevEap
  }

  if ($failures -gt 0) {
    Write-Output "==> Doctor finished with $failures failure(s)."
    exit 1
  }
  Write-Output "==> Doctor passed: environment is ready."
  exit 0
}

if ($Mode -eq "cleanup-worktree") {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("ERROR: 'git' is required for cleanup-worktree.")
    exit 127
  }
  if ([string]::IsNullOrWhiteSpace($WorkspaceDir) -or -not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) {
    [Console]::Error.WriteLine("ERROR: Worktree directory does not exist: $WorkspaceDir")
    exit 2
  }
  $wtReal = (Resolve-Path -LiteralPath $WorkspaceDir).Path
  $gitMarker = Join-Path $wtReal ".git"
  if (Test-Path -LiteralPath $gitMarker -PathType Container) {
    [Console]::Error.WriteLine("ERROR: Refusing to remove main Git repository checkout: $wtReal")
    exit 2
  }
  if (-not (Test-Path -LiteralPath $gitMarker -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: Directory is not a linked Git worktree: $wtReal")
    exit 2
  }
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $commonGitDir = (@(& git -C $wtReal rev-parse --git-common-dir 2>$null)) -join ""
    $commonGitRc = $LASTEXITCODE
    if ($commonGitRc -ne 0 -or [string]::IsNullOrWhiteSpace($commonGitDir)) {
      [Console]::Error.WriteLine("ERROR: Unable to resolve parent Git repository for worktree: $wtReal")
      exit 2
    }
    $commonGitFull = if ([System.IO.Path]::IsPathRooted($commonGitDir)) { $commonGitDir } else { Join-Path $wtReal $commonGitDir }
    $mainRepo = Split-Path -Parent ((Resolve-Path -LiteralPath $commonGitFull).Path)
    $wtBranch = (@(& git -C $wtReal symbolic-ref --short HEAD 2>$null)) -join ""
    if ($LASTEXITCODE -ne 0) { $wtBranch = "" }
    $wtHead = (@(& git -C $wtReal rev-parse --verify HEAD 2>$null)) -join ""
    if ($LASTEXITCODE -ne 0) { $wtHead = "" }

    if (-not $Force) {
      $dirty = (@(& git -C $wtReal status --porcelain 2>$null)) -join ""
      if (-not [string]::IsNullOrWhiteSpace($dirty)) {
        [Console]::Error.WriteLine("ERROR: Worktree has uncommitted changes. Commit/stash them first or pass -Force: $wtReal")
        exit 2
      }
      if (-not [string]::IsNullOrWhiteSpace($wtHead)) {
        if ([string]::IsNullOrWhiteSpace($wtBranch)) {
          $reachableRefs = @(& git -C $mainRepo for-each-ref --contains $wtHead --format="%(refname)" refs/heads refs/tags 2>$null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
          if ($reachableRefs.Count -eq 0) {
            $shortHead = (@(& git -C $wtReal rev-parse --short HEAD 2>$null)) -join ""
            if ([string]::IsNullOrWhiteSpace($shortHead)) { $shortHead = $wtHead }
            [Console]::Error.WriteLine("ERROR: Detached worktree HEAD ($shortHead) has commits not reachable from any branch or tag. Create a branch to preserve them or pass -Force: $wtReal")
            exit 2
          }
        } elseif ($DeleteBranch) {
          $otherRefs = @(& git -C $mainRepo for-each-ref --contains $wtHead --format="%(refname)" refs/heads refs/tags 2>$null) | Where-Object { (-not [string]::IsNullOrWhiteSpace($_)) -and ($_ -ne "refs/heads/$wtBranch") }
          if ($otherRefs.Count -eq 0) {
            [Console]::Error.WriteLine("ERROR: Branch '$wtBranch' has commits not reachable from any other branch or tag. Merge it first or pass -Force: $wtReal")
            exit 2
          }
        }
      }
    }

    if ($Force) {
      & git -C $mainRepo worktree remove --force $wtReal
    } else {
      & git -C $mainRepo worktree remove $wtReal
    }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Output "==> [Codex Engineer] Removed worktree: $wtReal"

    if ($DeleteBranch -and -not [string]::IsNullOrWhiteSpace($wtBranch)) {
      if ($Force) {
        & git -C $mainRepo branch -D $wtBranch
      } else {
        & git -C $mainRepo branch -d $wtBranch
      }
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
      Write-Output "==> [Codex Engineer] Deleted branch: $wtBranch"
    }
  } finally {
    $ErrorActionPreference = $prevEap
  }
  exit 0
}

if ($Mode -eq "list-options") {
  Get-CodexOptionsLines | ForEach-Object { Write-Output $_ }
  exit 0
}

if ($Mode -eq "sync-options") {
  Sync-CodexOptionsIntoSkill
  exit 0
}

if ($Mode -eq "list-projects") {
  $projLines = Get-CodexProjectLines
  if ($projLines.Count -gt 0) {
    $projLines | ForEach-Object { Write-Output $_ }
  } else {
    Write-Output "No Codex projects found in $(Join-Path $codexDir 'state_5.sqlite')"
  }
  exit 0
}

if ($Mode -eq "init-shared") {
  if ([string]::IsNullOrWhiteSpace($WorkspaceDir) -or -not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) {
    Write-Error "ERROR: Workspace directory does not exist: $WorkspaceDir"
    exit 2
  }
  $targetWs = (Resolve-Path -LiteralPath $WorkspaceDir).Path
  New-Item -ItemType Directory -Path (Join-Path $targetWs ".agents\skills") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $targetWs ".agents\hooks") -Force | Out-Null

  $agentsMd = Join-Path $targetWs "AGENTS.md"
  if (-not (Test-Path -LiteralPath $agentsMd)) {
    $agentsBody = @"
# Project Agent Conventions (Shared by Codex & Antigravity)

- **Hot State Handoff**: Read `.agents/state.md` at the start of a session to see recent work from other agents, and update it concisely (< 50 lines) after meaningful code changes.
- **Long-Term Memory**: If a shared Memory MCP (such as `basic-memory`) is available, record lasting architecture decisions, environment caveats, and design trade-offs there.
- **Shared Project Skills**: Place project-specific skills under `.agents/skills/<name>/SKILL.md` so both Codex and Antigravity discover them natively.
"@
    [System.IO.File]::WriteAllText($agentsMd, "$agentsBody`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "  [CREATED] $agentsMd"
  } else {
    Write-Output "  [KEPT]    $agentsMd (already exists)"
  }

  $stateMd = Join-Path $targetWs ".agents\state.md"
  if (-not (Test-Path -LiteralPath $stateMd)) {
    $stateBody = @"
# Shared Workspace State

- **Current Goal**: (describe active milestone or task)
- **Last Updated By**: (Codex / Antigravity / /codex)
- **Recent Changes**:
  - None recorded yet.
- **Known Issues / Guardrails**:
  - None recorded yet.
- **Next Steps**:
  - None recorded yet.
"@
    [System.IO.File]::WriteAllText($stateMd, "$stateBody`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "  [CREATED] $stateMd"
  } else {
    Write-Output "  [KEPT]    $stateMd (already exists)"
  }

  $hookPs1 = Join-Path $targetWs ".agents\hooks\session-context.ps1"
  if (-not (Test-Path -LiteralPath $hookPs1)) {
    $hookBody = @'
$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Push-Location -LiteralPath $root
try {
  Write-Output "=== Shared Workspace Context ==="
  if (Get-Command git -ErrorAction SilentlyContinue) {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
      Write-Output "-- git status --short --"
      & git status --short
      Write-Output "-- recent commits --"
      & git log -n 5 --oneline
    }
  }
  $statePath = Join-Path $root ".agents\state.md"
  if (Test-Path -LiteralPath $statePath) {
    Write-Output "-- .agents/state.md --"
    Get-Content -LiteralPath $statePath -TotalCount 60 -Encoding UTF8
  }
} finally {
  Pop-Location
}
'@
    [System.IO.File]::WriteAllText($hookPs1, "$hookBody`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "  [CREATED] $hookPs1"
  } else {
    Write-Output "  [KEPT]    $hookPs1 (already exists)"
  }

  $hooksJson = Join-Path $targetWs ".agents\hooks.json"
  if (-not (Test-Path -LiteralPath $hooksJson)) {
    $hooksBody = @'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File .agents/hooks/session-context.ps1"
          }
        ]
      }
    ]
  }
}
'@
    [System.IO.File]::WriteAllText($hooksJson, "$hooksBody`n", [System.Text.UTF8Encoding]::new($false))
    Write-Output "  [CREATED] $hooksJson"
  } else {
    Write-Output "  [KEPT]    $hooksJson (already exists)"
  }

  if ($ExcludeState) {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
      $gitDirRaw = (& git -C $targetWs rev-parse --git-dir 2>$null) -join ""
      if ($LASTEXITCODE -eq 0 -and $gitDirRaw) {
        $gitDirFull = if ([System.IO.Path]::IsPathRooted($gitDirRaw)) { $gitDirRaw } else { Join-Path $targetWs $gitDirRaw }
        $excludeFile = Join-Path $gitDirFull "info\exclude"
        $excludeDir = Split-Path -Parent $excludeFile
        if (-not (Test-Path -LiteralPath $excludeDir)) { New-Item -ItemType Directory -Path $excludeDir -Force | Out-Null }
        $existingLines = if (Test-Path -LiteralPath $excludeFile) { Get-Content -LiteralPath $excludeFile -Encoding UTF8 } else { @() }
        if ($existingLines -notcontains ".agents/state.md") {
          Add-Content -LiteralPath $excludeFile -Value "`n.agents/state.md" -Encoding UTF8
          Write-Output "  [UPDATED] Added .agents/state.md to $excludeFile"
        } else {
          Write-Output "  [KEPT]    .agents/state.md already in $excludeFile"
        }
      }
    }
  }
  Write-Output "==> Shared workspace initialized: $targetWs"
  exit 0
}

if ($Mode -eq "list-sessions") {
  if ($Limit -lt 1) {
    Write-Error "ERROR: -Limit must be a positive integer."
    exit 2
  }
  if ([string]::IsNullOrWhiteSpace($WorkspaceDir) -or -not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) {
    Write-Error "ERROR: Workspace directory does not exist: $WorkspaceDir"
    exit 2
  }
  $targetWs = (Resolve-Path -LiteralPath $WorkspaceDir).Path.TrimEnd('\', '/')
  $stateDb = Join-Path $codexDir "state_5.sqlite"
  if (-not (Test-Path -LiteralPath $stateDb)) {
    Write-Output "No Codex session database found at: $stateDb"
    exit 0
  }
  $pyCmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $pyCmd) { $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue }
  if ($pyCmd) {
    $pyCode = @'
import datetime, os, sqlite3, sys
db_path, cwd_target, limit = sys.argv[1], os.path.realpath(sys.argv[2]).rstrip("\\/"), int(sys.argv[3])
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
cur = conn.cursor()
cols = {row[1] for row in cur.execute("PRAGMA table_info(threads)").fetchall()}
title_expr = "COALESCE(NULLIF(name, ''), NULLIF(title, ''), preview, '')" if "name" in cols else "COALESCE(NULLIF(title, ''), preview, '')"
ts_expr = "COALESCE(NULLIF(recency_at, 0), updated_at)" if "recency_at" in cols else "updated_at"
cur.execute(
    f"SELECT id, {ts_expr}, COALESCE(model, ''), {title_expr} FROM threads WHERE archived = 0 AND COALESCE(model, '') != 'codex-auto-review' AND rtrim(rtrim(cwd, '/'), '\\') = ? ORDER BY {ts_expr} DESC LIMIT ?",
    (cwd_target, limit),
)
rows = cur.fetchall()
conn.close()
if not rows:
    print(f"No active Codex sessions found for workspace: {cwd_target}")
else:
    for sid, ts, model, title in rows:
        dt = datetime.datetime.fromtimestamp(ts).strftime("%m-%d %H:%M") if isinstance(ts, (int, float)) and ts > 0 else str(ts)
        print(f"{sid} | {dt} | {model or 'default'} | {' '.join(str(title).split())[:80]}")
'@
    & $pyCmd.Source -c $pyCode $stateDb $targetWs $Limit
  } else {
    Write-Error "ERROR: python/python3 is required to query $stateDb on Windows."
    exit 127
  }
  exit 0
}

if ($Mode -eq "show-session") {
  $targetSid = if (-not [string]::IsNullOrWhiteSpace($Session)) { $Session } else { $WorkspaceDir }
  if ([string]::IsNullOrWhiteSpace($targetSid)) {
    Write-Error "ERROR: show-session requires a session ID."
    exit 2
  }
  if ($Turns -lt 1) {
    Write-Error "ERROR: -Turns must be a positive integer."
    exit 2
  }
  $stateDb = Join-Path $codexDir "state_5.sqlite"
  if (-not (Test-Path -LiteralPath $stateDb)) {
    Write-Error "ERROR: Codex session database not found at: $stateDb"
    exit 2
  }
  $pyCmd = Get-Command python -ErrorAction SilentlyContinue
  if (-not $pyCmd) { $pyCmd = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $pyCmd) {
    Write-Error "ERROR: python/python3 is required for show-session."
    exit 127
  }
  $pyCode = @'
import json, os, sqlite3, sys
db_path, sid, max_turns = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
except sqlite3.OperationalError:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro&immutable=1", uri=True)
cols = {r[1] for r in conn.execute("PRAGMA table_info(threads)").fetchall()}
title_expr = "COALESCE(NULLIF(name, ''), title, '')" if "name" in cols else "COALESCE(title, '')"
row = conn.execute(f"SELECT rollout_path, cwd, {title_expr}, COALESCE(model, '') FROM threads WHERE id = ?", (sid,)).fetchone()
conn.close()
if not row:
    sys.stderr.write(f"ERROR: Session ID not found in state_5.sqlite: {sid}\n")
    sys.exit(2)
rollout_path, cwd, title, model = row
print(f"=== Codex Session Context: {sid} ===")
print(f"Workspace: {cwd}")
if title: print(f"Title: {title}")
if model: print(f"Model: {model}")
if not rollout_path or not os.path.isfile(rollout_path):
    print("(Rollout transcript file not found on disk)")
    sys.exit(0)
SKIP = ("# AGENTS.md instructions for ", "<environment_context>", "<INSTRUCTIONS>", "<permissions instructions>", "<app-context>", "<collaboration_mode>")
msgs = []
with open(rollout_path, "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
        line = raw.strip()
        if not line.startswith("{"): continue
        try: obj = json.loads(line)
        except Exception: continue
        if obj.get("type") != "response_item": continue
        p = obj.get("payload") or {}
        if p.get("type") != "message": continue
        role = p.get("role")
        if role not in ("user", "assistant"): continue
        parts = [item.get("text", "").strip() for item in (p.get("content") or []) if isinstance(item, dict) and item.get("type") in ("input_text", "output_text", "text") and item.get("text", "").strip()]
        text = "\n".join(parts).strip()
        if not text or (role == "user" and any(text.startswith(sp) for sp in SKIP)): continue
        if len(text) > 1200: text = text[:1200] + "... [truncated]"
        msgs.append((role, text))
selected = msgs[-max_turns:]
print(f"Showing last {len(selected)} of {len(msgs)} message(s):\n")
for role, text in selected:
    print(f"[{role.upper()}] {text}\n---")
'@
  & $pyCmd.Source -c $pyCode $stateDb $targetSid $Turns
  exit $LASTEXITCODE
}

if ([string]::IsNullOrWhiteSpace($Model) -and $env:CODEX_MODEL) { $Model = $env:CODEX_MODEL }
if ([string]::IsNullOrWhiteSpace($Effort) -and $env:CODEX_EFFORT) { $Effort = $env:CODEX_EFFORT }
if ([string]::IsNullOrWhiteSpace($Tier) -and $env:CODEX_TIER) { $Tier = $env:CODEX_TIER }
if ($Tier -eq "fast") { $Tier = "priority" }

$isolate = (-not $NoIsolate) -and ($env:CODEX_ISOLATE -ne "0")
$verbose = $VerboseOutput -or ($env:CODEX_VERBOSE -eq "1")

# Append common global npm bin path as fallback in non-interactive shells
if ($env:APPDATA) {
  $npmGlobal = Join-Path $env:APPDATA "npm"
  if ((Test-Path $npmGlobal) -and ($env:Path -notlike "*$npmGlobal*")) {
    $env:Path = "$env:Path;$npmGlobal"
  }
}

$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexCmd) {
  Write-Error "ERROR: 'codex' CLI not found in PATH. Install it via: npm install -g @openai/codex"
  exit 127
}

if ([string]::IsNullOrWhiteSpace($WorkspaceDir) -or -not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) {
  Write-Error "ERROR: Workspace directory does not exist: $WorkspaceDir"
  exit 2
}

if ($Adversarial -or (-not [string]::IsNullOrWhiteSpace($Base))) {
  if ($Mode -ne "review") {
    [Console]::Error.WriteLine("ERROR: -Adversarial and -Base are only supported with 'review'.")
    exit 2
  }
}

if (($Mode -eq "review") -and [string]::IsNullOrWhiteSpace($InputFile) -and [string]::IsNullOrWhiteSpace($Prompt) -and (-not [string]::IsNullOrWhiteSpace($Base))) {
  $Prompt = "Review all changes in git diff ${Base}...HEAD (and any uncommitted changes in the working tree)."
}

$tmpPromptFile = ""
if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
  if ((-not [string]::IsNullOrWhiteSpace($InputFile)) -and ($InputFile -ne "-")) {
    [Console]::Error.WriteLine("ERROR: Input file and -Prompt are mutually exclusive.")
    exit 2
  }
  $tmpPromptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-prompt-" + [guid]::NewGuid().ToString("N") + ".txt")
  [System.IO.File]::WriteAllText($tmpPromptFile, "$Prompt`n", [System.Text.UTF8Encoding]::new($false))
  $InputFile = $tmpPromptFile
}

if ([string]::IsNullOrWhiteSpace($InputFile) -or -not (Test-Path -LiteralPath $InputFile -PathType Leaf) -or ((Get-Item -LiteralPath $InputFile).Length -eq 0)) {
  Write-Error "ERROR: Input plan/instructions file is missing or empty (or pass -Prompt <text>): $InputFile"
  exit 2
}

$tmpRunDir = ""
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  $outDir = Split-Path -Parent $OutputFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $logFile = [System.IO.Path]::ChangeExtension($OutputFile, ".log")
  $eventsFile = [System.IO.Path]::ChangeExtension($OutputFile, ".events.jsonl")
  $sessionFile = [System.IO.Path]::ChangeExtension($OutputFile, ".session_id")
} else {
  $tmpRunDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-run-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmpRunDir -Force | Out-Null
  $OutputFile = Join-Path $tmpRunDir "last_message.md"
  $logFile = Join-Path $tmpRunDir "last_message.log"
  $eventsFile = Join-Path $tmpRunDir "last_message.events.jsonl"
  $sessionFile = Join-Path $tmpRunDir "last_message.session_id"
}
$outFlags = @("-o", $OutputFile)
$runFailed = $false

Push-Location -LiteralPath $WorkspaceDir
try {
  $gitFlags = @()
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  $isGitRepo = $false
  if ($gitCmd) {
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -eq 0) {
      $isGitRepo = $true
    }
  }
  if (-not $isGitRepo) {
    $gitFlags = @("--skip-git-repo-check")
  }

  $helpText = (& codex exec --help 2>&1) -join "`n"
  $useJsonEvents = ($helpText -match "--json")
  $jsonFlags = if ($useJsonEvents) { @("--json") } else { @() }

  if ($Mode -eq "review") {
    $approvalFlags = @("-s", "read-only")
  } elseif ($helpText -match "--approve-for-me") {
    # --approve-for-me already implies workspace-write and conflicts with -s
    $approvalFlags = @("--approve-for-me")
  } else {
    $approvalFlags = @("--full-auto")
  }

  # Fail-closed --worktree check: never silently fall back to main workspace
  $worktreeFlags = @()
  if ($Worktree) {
    if ($Mode -ne "execute") {
      [Console]::Error.WriteLine("ERROR: -Worktree is only supported with 'execute'.")
      exit 2
    }
    if (-not $isGitRepo) {
      [Console]::Error.WriteLine("ERROR: -Worktree requires a Git repository, but '$WorkspaceDir' is not inside a Git work tree.")
      exit 2
    }
    if ($helpText -notmatch "--worktree") {
      [Console]::Error.WriteLine("ERROR: -Worktree was requested, but the installed codex CLI does not support --worktree. Refusing to fall back to the main workspace.")
      exit 2
    }
    $worktreeFlags = @("--worktree")
  }

  $schemaFlags = @()
  if ($Structured -or (-not [string]::IsNullOrWhiteSpace($Schema))) {
    if (($Mode -ne "execute") -and ($Mode -ne "review")) {
      [Console]::Error.WriteLine("ERROR: -Structured / -Schema is only supported with 'execute' or 'review'.")
      exit 2
    }
    $schemaPath = if (-not [string]::IsNullOrWhiteSpace($Schema)) { $Schema } else { Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) "resources\report.schema.json" }
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
      [Console]::Error.WriteLine("ERROR: Output schema file does not exist: $schemaPath")
      exit 2
    }
    if ($helpText -notmatch "--output-schema") {
      [Console]::Error.WriteLine("ERROR: -Structured / -Schema was requested, but the installed codex CLI does not support --output-schema.")
      exit 2
    }
    $schemaFlags = @("--output-schema", $schemaPath)
  }

  $baseDiffContext = ""
  if (-not [string]::IsNullOrWhiteSpace($Base)) {
    if (-not $isGitRepo) {
      [Console]::Error.WriteLine("ERROR: -Base requires a Git repository, but '$WorkspaceDir' is not inside a Git work tree.")
      exit 2
    }
    $prevEapBase = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      & git rev-parse --verify "${Base}^{commit}" *> $null
      if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("ERROR: -Base ref '$Base' does not exist in this Git repository.")
        exit 2
      }
      $baseDiffStat = (@(& git diff --stat "${Base}...HEAD" 2>$null | Select-Object -First 40)) -join "`n"
    } finally {
      $ErrorActionPreference = $prevEapBase
    }
    $statNote = if (-not [string]::IsNullOrWhiteSpace($baseDiffStat)) { $baseDiffStat } else { "no committed diff vs $Base" }
    $baseDiffContext = " Focus specifically on changes relative to base ref '$Base' (inspect 'git diff ${Base}...HEAD' and any uncommitted changes). Diff stat summary: $statNote."
  }

  $isolateFlags = @()
  $cfgProvider = Get-TomlTopLevelString "model_provider" $configFile
  if ($isolate -and ($helpText -match "--ignore-user-config")) {
    if ([string]::IsNullOrWhiteSpace($cfgProvider) -or ($cfgProvider -eq "openai")) {
      $isolateFlags = @("--ignore-user-config")
      if ([string]::IsNullOrWhiteSpace($Model))  { $Model  = Get-TomlTopLevelString "model" $configFile }
      if ([string]::IsNullOrWhiteSpace($Effort)) { $Effort = Get-TomlTopLevelString "model_reasoning_effort" $configFile }
      if ([string]::IsNullOrWhiteSpace($Tier))   { $Tier   = Get-TomlTopLevelString "service_tier" $configFile }
      if (Test-TomlFeatureTrue "respect_system_proxy" $configFile) {
        $isolateFlags += @("-c", "features.respect_system_proxy=true")
      }
    } else {
      Write-Output "==> [Codex Engineer] Custom model_provider='$cfgProvider' detected; loading full ~/.codex/config.toml"
    }
  }

  $overrideFlags = @()
  $overrideDesc = @()
  if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $overrideFlags += @("-m", $Model)
    $overrideDesc += "model=$Model"
  }
  if (-not [string]::IsNullOrWhiteSpace($Effort)) {
    $overrideFlags += @("-c", "model_reasoning_effort=`"$Effort`"")
    $overrideDesc += "effort=$Effort"
  }
  if (-not [string]::IsNullOrWhiteSpace($Tier)) {
    $overrideFlags += @("-c", "service_tier=`"$Tier`"")
    $overrideDesc += "tier=$Tier"
  }
  if ($isolateFlags.Count -gt 0) { $overrideDesc += "isolated=on" }
  if ($worktreeFlags.Count -gt 0) { $overrideDesc += "worktree=on" }
  if ($schemaFlags.Count -gt 0) { $overrideDesc += "schema=on" }
  if ($Adversarial) { $overrideDesc += "adversarial=on" }
  if (-not [string]::IsNullOrWhiteSpace($Base)) { $overrideDesc += "base=$Base" }

  if ($overrideDesc.Count -gt 0) {
    Write-Output "==> [Codex Engineer] Runtime config: $($overrideDesc -join ' ')"
  } else {
    Write-Output "==> [Codex Engineer] Runtime config: using ~/.codex/config.toml defaults"
  }

  $stdinContent = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8

  if ($Mode -eq "execute") {
    # Reset stale artifacts so a new task can never inherit an older run's summary or session ID
    foreach ($f in @($OutputFile, $sessionFile, $eventsFile)) {
      if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $cwd = (Get-Location).Path
    $promptHeader = "You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $cwd. You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Do not run git commit or git push. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    Write-Output "==> [Codex Engineer] Starting implementation & self-test in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Spec file: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never") + $jsonFlags + $isolateFlags + $worktreeFlags + $schemaFlags + $overrideFlags + $gitFlags + $outFlags + @($promptHeader)
  } elseif ($Mode -eq "review") {
    foreach ($f in @($OutputFile, $sessionFile, $eventsFile)) {
      if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    $cwd = (Get-Location).Path
    if ($Adversarial) {
      $promptHeader = "You are a Red-Team Adversarial Code & Design Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $cwd - do not modify any files. Do NOT praise the code; actively try to break it. Hunt for flawed assumptions, edge-case crashes, race conditions, locking/state bugs, security/permission boundary gaps, and silent failure modes.$baseDiffContext Inspect files or diffs concisely (never dump full large files to stdout) and report concrete findings grouped by severity (P0 Critical / P1 High / P2 Medium / P3 Low) with exact file:line references, minimal reproduction paths, and direct fixes."
      Write-Output "==> [Codex Reviewer] Starting adversarial read-only audit in: $WorkspaceDir"
    } else {
      $promptHeader = "You are a Principal Code Reviewer & Architecture Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $cwd - do not attempt to modify any files.$baseDiffContext Read the audit scope in <stdin>, inspect the relevant source files or git diff concisely (never dump full large files to stdout), and report concrete findings grouped by severity (Critical / Warning / Suggestion) with exact file:line references and actionable recommendations."
      Write-Output "==> [Codex Reviewer] Starting read-only audit in: $WorkspaceDir"
    }
    Write-Output "==> [Codex Reviewer] Audit spec: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never") + $jsonFlags + $isolateFlags + $schemaFlags + $overrideFlags + $gitFlags + $outFlags + @($promptHeader)
  } elseif ($Mode -eq "fork") {
    if ([string]::IsNullOrWhiteSpace($Session) -and (Test-Path -LiteralPath $sessionFile)) {
      $Session = ((Get-Content -LiteralPath $sessionFile -TotalCount 1 -Encoding UTF8) -join "").Trim()
    }
    if ([string]::IsNullOrWhiteSpace($Session)) {
      [Console]::Error.WriteLine("ERROR: fork requires a source session ID (pass -Session <id> or provide an output path with an existing .session_id file).")
      exit 2
    }
    $forkSourceSessionId = $Session
    foreach ($f in @($OutputFile, $eventsFile, $sessionFile)) {
      if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    Write-Output "==> [Codex Engineer] Forking Codex session '$forkSourceSessionId' in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Fork prompt file: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never", "fork") + $jsonFlags + $isolateFlags + $overrideFlags + $gitFlags + $outFlags + @($forkSourceSessionId, "-")
  } else {
    if ((-not [string]::IsNullOrWhiteSpace($Session)) -and $Last) {
      [Console]::Error.WriteLine("ERROR: -Session and -Last are mutually exclusive.")
      exit 2
    }

    $resumeMode = ""
    if (-not [string]::IsNullOrWhiteSpace($Session)) {
      $resumeMode = "pinned"
    } elseif ($Last) {
      $resumeMode = "last"
    } elseif (Test-Path -LiteralPath $sessionFile) {
      $Session = ((Get-Content -LiteralPath $sessionFile -TotalCount 1 -Encoding UTF8) -join "").Trim()
      if (-not [string]::IsNullOrWhiteSpace($Session)) {
        $resumeMode = "pinned"
      }
    }

    if ([string]::IsNullOrWhiteSpace($resumeMode)) {
      [Console]::Error.WriteLine("ERROR: No pinned session ID found for resume (checked -Session and $sessionFile). Pass -Session <id> or -Last explicitly.")
      exit 2
    }

    # Only reset stale summary/events AFTER resume target is validated
    foreach ($f in @($OutputFile, $eventsFile)) {
      if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
    Write-Output "==> [Codex Engineer] Follow-up review feedback: $InputFile"
    if ($resumeMode -eq "pinned") {
      Write-Output "==> [Codex Engineer] Resuming pinned Codex session '$Session' in: $WorkspaceDir"
      $argsList = @("exec") + $approvalFlags + @("--color", "never", "resume") + $jsonFlags + $isolateFlags + $overrideFlags + $gitFlags + $outFlags + @($Session, "-")
    } else {
      Write-Output "==> [Codex Engineer] Explicitly resuming latest Codex session (--last) in: $WorkspaceDir"
      $argsList = @("exec") + $approvalFlags + @("--color", "never", "resume", "--last") + $jsonFlags + $isolateFlags + $overrideFlags + $gitFlags + $outFlags + @("-")
    }
  }

  function Release-CodexAppLock {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_RELEASE_LOCK_CMD)) {
      Invoke-Expression $env:CODEX_RELEASE_LOCK_CMD
      return
    }
    $hasCodexApp = $false
    $hasChatGptApp = $false
    $appServers = @()
    try {
      $appServers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.CommandLine -match '(^|[\\/\"])codex(\.exe)?[\"\s].*app-server') -or
        (($_.ExecutablePath -match '[\\/]codex(\.exe)?$') -and ($_.CommandLine -match 'app-server'))
      })
      foreach ($p in $appServers) {
        $probe = if (-not [string]::IsNullOrWhiteSpace($p.ExecutablePath)) { $p.ExecutablePath } else { $p.CommandLine }
        if ($probe -match '[\\/]ChatGPT[\\/]') { $hasChatGptApp = $true }
        elseif ($probe -match '[\\/]Codex[\\/]') { $hasCodexApp = $true }
      }
    } catch {}

    if ($appServers.Count -eq 0) {
      [Console]::Error.WriteLine("==> [Codex Engineer] No active codex app-server process detected; skipping app quit.")
      return
    }
    if ($hasCodexApp -and $hasChatGptApp) {
      [Console]::Error.WriteLine("==> [Codex Engineer] Both Codex and ChatGPT app-server processes are running; refusing to guess which holds the lock. Please close the active app manually or use 'fork'.")
      return
    }
    $targetProc = $null
    if ($hasCodexApp) { $targetProc = "Codex" }
    elseif ($hasChatGptApp) { $targetProc = "ChatGPT" }
    else {
      [Console]::Error.WriteLine("==> [Codex Engineer] Active codex app-server could not be uniquely attributed to Codex or ChatGPT; refusing to close desktop apps automatically. Please release the lock manually or use 'fork'.")
      return
    }

    [Console]::Error.WriteLine("==> [Codex Engineer] Closing identified lock holder app: $targetProc")
    Get-Process -Name $targetProc -ErrorAction SilentlyContinue | ForEach-Object {
      try { $_.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds 2
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $allowQuit = $QuitAppOnLock -or ($env:CODEX_QUIT_APP_ON_LOCK -eq "1")
  if (($Mode -eq "resume") -and $allowQuit) {
    [Console]::Error.WriteLine("==> [Codex Engineer] Closing Codex Desktop App gracefully before resuming...")
    Release-CodexAppLock
  }
  $attempt = 1
  while ($true) {
    if ($useJsonEvents) {
      if ($verbose) {
        $stdinContent | & codex @argsList 2>$logFile | Tee-Object -FilePath $eventsFile
        $exitCode = $LASTEXITCODE
        if ((Test-Path -LiteralPath $logFile) -and ((Get-Item -LiteralPath $logFile).Length -gt 0)) {
          Get-Content -LiteralPath $logFile -Encoding UTF8 | ForEach-Object { [Console]::Error.WriteLine($_) }
        }
      } else {
        $stdinContent | & codex @argsList 1>$eventsFile 2>$logFile
        $exitCode = $LASTEXITCODE
      }
      $capturedSid = Get-SessionIdFromJsonl $eventsFile
    } else {
      if ($verbose) {
        $stdinContent | & codex @argsList 2>&1 | Tee-Object -FilePath $logFile
        $exitCode = $LASTEXITCODE
      } else {
        $stdinContent | & codex @argsList *> $logFile
        $exitCode = $LASTEXITCODE
      }
      $capturedSid = Get-SessionIdFromText $logFile
    }

    if (($exitCode -ne 0) -and ($Mode -eq "resume") -and ($attempt -eq 1)) {
      $lockHit = $false
      foreach ($lf in @($logFile, $eventsFile)) {
        if ((Test-Path -LiteralPath $lf) -and ((Get-Content -LiteralPath $lf -Raw -Encoding UTF8 -ErrorAction SilentlyContinue) -match "already has an active writer")) {
          $lockHit = $true
          break
        }
      }
      if ($lockHit) {
        $allowQuit = $QuitAppOnLock -or ($env:CODEX_QUIT_APP_ON_LOCK -eq "1")
        if ($allowQuit) {
          [Console]::Error.WriteLine("==> [Codex Engineer] Thread is locked by Codex Desktop App ('already has an active writer'). Closing Codex App gracefully and retrying resume...")
          Release-CodexAppLock
          $attempt = 2
          continue
        } else {
          [Console]::Error.WriteLine("HINT_THREAD_LOCKED: Thread is locked by Codex Desktop App ('already has an active writer'). Ask the user to confirm quitting Codex App (-QuitAppOnLock) or fall back to 'fork'.")
        }
      }
    }
    break
  }
  $sw.Stop()
  $elapsedS = [int][Math]::Floor($sw.Elapsed.TotalSeconds)

  if ($Mode -eq "fork") {
    if ((-not [string]::IsNullOrWhiteSpace($capturedSid)) -and ($capturedSid -ne $forkSourceSessionId)) {
      [System.IO.File]::WriteAllText($sessionFile, "$capturedSid`n", [System.Text.UTF8Encoding]::new($false))
    } else {
      if (Test-Path -LiteralPath $sessionFile) { Remove-Item -LiteralPath $sessionFile -Force -ErrorAction SilentlyContinue }
    }
  } elseif (-not [string]::IsNullOrWhiteSpace($capturedSid)) {
    [System.IO.File]::WriteAllText($sessionFile, "$capturedSid`n", [System.Text.UTF8Encoding]::new($false))
  }

  # Silently refresh embedded live model catalog in SKILL.md for instant next-turn picker
  try { Sync-CodexOptionsIntoSkill } catch {}

  if ($exitCode -ne 0) {
    $runFailed = $true
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("ERROR: codex exited with code $exitCode (after ${elapsedS}s).")
    if ((-not $verbose) -and (Test-Path -LiteralPath $logFile)) {
      [Console]::Error.WriteLine("Full process log: $logFile")
      [Console]::Error.WriteLine("--- Last 60 lines of log ---")
      Get-Content -LiteralPath $logFile -Tail 60 | ForEach-Object { [Console]::Error.WriteLine($_) }
      [Console]::Error.WriteLine("----------------------------")
    }
    [Console]::Error.WriteLine("Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in.")
    exit $exitCode
  }

  if (($Mode -eq "fork") -and ([string]::IsNullOrWhiteSpace($capturedSid) -or ($capturedSid -eq $forkSourceSessionId))) {
    $runFailed = $true
    [Console]::Error.WriteLine("ERROR: fork completed without a distinct new session ID (source: '$forkSourceSessionId'). Cleared stale session file to prevent accidentally resuming the source thread.")
    exit 1
  }

  if (-not [string]::IsNullOrWhiteSpace($capturedSid)) {
    Write-Output "==> [Codex Engineer] Session ID: $capturedSid (saved to $sessionFile)"
  }

  $usageSummary = if ($useJsonEvents) { Get-UsageFromJsonl $eventsFile } else { "" }
  if (-not [string]::IsNullOrWhiteSpace($usageSummary)) {
    Write-Output "==> [Codex Engineer] Telemetry: duration=${elapsedS}s | $usageSummary"
  } else {
    Write-Output "==> [Codex Engineer] Telemetry: duration=${elapsedS}s"
  }

  if (-not $verbose) {
    Write-Output "==> [Codex Engineer] Completed cleanly. Full process log: $logFile"
    if ((Test-Path -LiteralPath $OutputFile) -and ((Get-Item -LiteralPath $OutputFile).Length -gt 0)) {
      Write-Output ""
      Write-Output "=== Codex Final Summary ==="
      Get-Content -LiteralPath $OutputFile -Raw -Encoding UTF8 | Write-Output
    }
    if ($isGitRepo -and ($Mode -ne "review")) {
      if ($Worktree) {
        Write-Output "==> [Codex Engineer] Note: -Worktree was enabled; verify changes inside the created worktree (Git summary below reflects the original workspace checkout)."
      }
      $gitStatusLines = @(& git status --short 2>$null | Select-Object -First 40)
      if ($gitStatusLines.Count -gt 0) {
        Write-Output ""
        Write-Output "=== Git Workspace Changes ==="
        $gitStatusLines | ForEach-Object { Write-Output $_ }
        $gitDiffLines = @(& git diff --stat 2>$null | Select-Object -First 40)
        if ($gitDiffLines.Count -gt 0) {
          Write-Output "--- git diff --stat ---"
          $gitDiffLines | ForEach-Object { Write-Output $_ }
        }
      }
    }
  }
} finally {
  if (-not [string]::IsNullOrWhiteSpace($tmpPromptFile) -and (Test-Path -LiteralPath $tmpPromptFile)) {
    Remove-Item -LiteralPath $tmpPromptFile -Force -ErrorAction SilentlyContinue
  }
  Pop-Location
}
