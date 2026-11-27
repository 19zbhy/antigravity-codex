#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Windows PowerShell runner for the Google Antigravity x OpenAI Codex workflow.
.DESCRIPTION
  Supports 'list-options', 'sync-options', 'execute' (workspace-write), 'review' (read-only),
  and 'resume'. Enables --ignore-user-config whitelist isolation by default (skipping heavy
  desktop plugins/MCPs while preserving model, effort, tier, and proxy settings) and runs in
  quiet log-summary mode.
.EXAMPLE
  pwsh -NoProfile -File run-codex.ps1 list-options
  pwsh -NoProfile -File run-codex.ps1 execute C:\path\to\workspace C:\path\to\implementation_plan.md C:\path\to\codex_last_message.md -Model gpt-6.2-sol -Effort high -Tier priority
  pwsh -NoProfile -File run-codex.ps1 review  C:\path\to\workspace C:\path\to\review_spec.md C:\path\to\codex_last_message.md
  pwsh -NoProfile -File run-codex.ps1 resume  C:\path\to\workspace C:\path\to\codex_fix_instructions.md C:\path\to\codex_last_message.md
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("list-options", "sync-options", "execute", "review", "resume")]
  [string]$Mode,

  [Parameter(Mandatory = $false, Position = 1)]
  [string]$WorkspaceDir = "",

  [Parameter(Mandatory = $false, Position = 2)]
  [string]$InputFile = "",

  [Parameter(Mandatory = $false, Position = 3)]
  [string]$OutputFile = "",

  [Parameter(Mandatory = $false)]
  [string]$Model = "",

  [Parameter(Mandatory = $false)]
  [string]$Effort = "",

  [Parameter(Mandatory = $false)]
  [ValidateSet("", "priority", "default", "flex", "fast")]
  [string]$Tier = "",

  [switch]$Worktree,
  [switch]$NoIsolate
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME ".codex" }
$configFile = Join-Path $codexDir "config.toml"
$cacheFile = Join-Path $codexDir "models_cache.json"

function Get-TomlStringValue([string]$Key, [string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  $pattern = "^\s*$([regex]::Escape($Key))\s*=\s*`"([^`"]*)`""
  foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
    if ($line -match $pattern) { return $Matches[1] }
  }
  return ""
}

function Get-CodexOptionsLines {
  $defaultModel = Get-TomlStringValue "model" $configFile
  $defaultEffort = Get-TomlStringValue "model_reasoning_effort" $configFile
  $defaultTier = Get-TomlStringValue "service_tier" $configFile

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
  $lines.Add("- service_tiers: priority (快速/Fast), default (标准), flex (弹性省流)")
  return $lines
}

function Sync-CodexOptionsIntoSkill {
  $scriptDir = Split-Path -Parent $PSCommandPath
  $skillPath = Join-Path (Split-Path -Parent $scriptDir) "SKILL.md"
  if (-not (Test-Path -LiteralPath $skillPath)) { return }
  $content = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
  if ($content -notmatch "<!-- CODEX_LIVE_OPTIONS_START -->" -or $content -notmatch "<!-- CODEX_LIVE_OPTIONS_END -->") { return }
  $block = (Get-CodexOptionsLines) -join "`n"
  $replacement = "<!-- CODEX_LIVE_OPTIONS_START -->`n$block`n<!-- CODEX_LIVE_OPTIONS_END -->"
  $updated = [regex]::Replace($content, "<!-- CODEX_LIVE_OPTIONS_START -->[\s\S]*?<!-- CODEX_LIVE_OPTIONS_END -->", [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
  [System.IO.File]::WriteAllText($skillPath, $updated, [System.Text.UTF8Encoding]::new($false))
}

if ($Mode -eq "list-options") {
  Get-CodexOptionsLines | ForEach-Object { Write-Output $_ }
  exit 0
}

if ($Mode -eq "sync-options") {
  Sync-CodexOptionsIntoSkill
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Model) -and $env:CODEX_MODEL) { $Model = $env:CODEX_MODEL }
if ([string]::IsNullOrWhiteSpace($Effort) -and $env:CODEX_EFFORT) { $Effort = $env:CODEX_EFFORT }
if ([string]::IsNullOrWhiteSpace($Tier) -and $env:CODEX_TIER) { $Tier = $env:CODEX_TIER }
if ($Tier -eq "fast") { $Tier = "priority" }

$isolate = (-not $NoIsolate) -and ($env:CODEX_ISOLATE -ne "0")
$verbose = ($env:CODEX_VERBOSE -eq "1")

# Ensure common global npm bin path is available in non-interactive shells
$npmGlobal = Join-Path $env:APPDATA "npm"
if ((Test-Path $npmGlobal) -and ($env:Path -notlike "*$npmGlobal*")) {
  $env:Path = "$npmGlobal;$env:Path"
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

if ([string]::IsNullOrWhiteSpace($InputFile) -or -not (Test-Path -LiteralPath $InputFile -PathType Leaf) -or ((Get-Item -LiteralPath $InputFile).Length -eq 0)) {
  Write-Error "ERROR: Input plan/instructions file is missing or empty: $InputFile"
  exit 2
}

$cleanupTmpOut = $false
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  $outDir = Split-Path -Parent $OutputFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $logFile = [System.IO.Path]::ChangeExtension($OutputFile, ".log")
} else {
  $tmpBase = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-last-message-" + [guid]::NewGuid().ToString("N"))
  $OutputFile = "$tmpBase.md"
  $logFile = "$tmpBase.log"
  $cleanupTmpOut = $true
}
$outFlags = @("-o", $OutputFile)

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
  if ($Mode -eq "review") {
    $approvalFlags = @("-s", "read-only")
  } elseif ($helpText -match "--approve-for-me") {
    $approvalFlags = @("--approve-for-me", "-s", "workspace-write")
  } else {
    $approvalFlags = @("--full-auto")
  }

  $worktreeFlags = @()
  if ($Worktree -and ($Mode -eq "execute")) {
    if ($helpText -match "--worktree") {
      $worktreeFlags = @("--worktree")
    } else {
      Write-Warning "Current codex CLI does not support --worktree; running in current workspace."
    }
  }

  $isolateFlags = @()
  $cfgProvider = Get-TomlStringValue "model_provider" $configFile
  if ($isolate -and ($helpText -match "--ignore-user-config")) {
    if ([string]::IsNullOrWhiteSpace($cfgProvider) -or ($cfgProvider -eq "openai")) {
      $isolateFlags = @("--ignore-user-config")
      if ([string]::IsNullOrWhiteSpace($Model))  { $Model  = Get-TomlStringValue "model" $configFile }
      if ([string]::IsNullOrWhiteSpace($Effort)) { $Effort = Get-TomlStringValue "model_reasoning_effort" $configFile }
      if ([string]::IsNullOrWhiteSpace($Tier))   { $Tier   = Get-TomlStringValue "service_tier" $configFile }
      if ((Test-Path -LiteralPath $configFile) -and ((Get-Content -LiteralPath $configFile -Raw -Encoding UTF8) -match '(?m)^\s*respect_system_proxy\s*=\s*true')) {
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

  if ($overrideDesc.Count -gt 0) {
    Write-Output "==> [Codex Engineer] Runtime config: $($overrideDesc -join ' ')"
  } else {
    Write-Output "==> [Codex Engineer] Runtime config: using ~/.codex/config.toml defaults"
  }

  $stdinContent = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8

  if ($Mode -eq "execute") {
    $cwd = (Get-Location).Path
    $promptHeader = "You are the Principal Software Engineer in a Google Antigravity + OpenAI Codex workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $cwd. You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Keep command outputs concise: never dump full large files or raw multi-hundred-line logs to stdout; prefer targeted line ranges or summarized checks. Do not run git commit or git push. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    Write-Output "==> [Codex Engineer] Starting implementation & self-test in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Spec file: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never") + $isolateFlags + $worktreeFlags + $overrideFlags + $gitFlags + $outFlags + @($promptHeader)
  } elseif ($Mode -eq "review") {
    $cwd = (Get-Location).Path
    $promptHeader = "You are a Principal Code Reviewer & Architecture Auditor in a Google Antigravity + OpenAI Codex workflow. You are running in strict read-only mode inside $cwd - do not attempt to modify any files. Read the audit scope in <stdin>, inspect the relevant source files or git diff concisely (never dump full large files to stdout), and report concrete findings grouped by severity (Critical / Warning / Suggestion) with exact file:line references and actionable recommendations."
    Write-Output "==> [Codex Reviewer] Starting read-only audit in: $WorkspaceDir"
    Write-Output "==> [Codex Reviewer] Audit spec: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never") + $isolateFlags + $overrideFlags + $gitFlags + $outFlags + @($promptHeader)
  } else {
    Write-Output "==> [Codex Engineer] Resuming latest Codex session in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Follow-up review feedback: $InputFile"
    $argsList = @("exec") + $approvalFlags + @("--color", "never", "resume", "--last") + $isolateFlags + $overrideFlags + $gitFlags + $outFlags + @("-")
  }

  if ($verbose) {
    $stdinContent | & codex @argsList
    $exitCode = $LASTEXITCODE
  } else {
    $stdinContent | & codex @argsList *> $logFile
    $exitCode = $LASTEXITCODE
  }

  # Silently refresh embedded live model catalog in SKILL.md for instant next-turn picker
  try { Sync-CodexOptionsIntoSkill } catch {}

  if ($exitCode -ne 0) {
    [Console]::Error.WriteLine("")
    [Console]::Error.WriteLine("ERROR: codex exited with code $exitCode.")
    if ((-not $verbose) -and (Test-Path -LiteralPath $logFile)) {
      [Console]::Error.WriteLine("Full process log: $logFile")
      [Console]::Error.WriteLine("--- Last 60 lines of log ---")
      Get-Content -LiteralPath $logFile -Tail 60 | ForEach-Object { [Console]::Error.WriteLine($_) }
      [Console]::Error.WriteLine("----------------------------")
    }
    [Console]::Error.WriteLine("Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in.")
    exit $exitCode
  }

  if (-not $verbose) {
    Write-Output "==> [Codex Engineer] Completed cleanly. Full process log: $logFile"
    if ((Test-Path -LiteralPath $OutputFile) -and ((Get-Item -LiteralPath $OutputFile).Length -gt 0)) {
      Write-Output ""
      Write-Output "=== Codex Final Summary ==="
      Get-Content -LiteralPath $OutputFile -Raw -Encoding UTF8 | Write-Output
    }
  }
} finally {
  if ($cleanupTmpOut -and (Test-Path -LiteralPath $OutputFile)) {
    Remove-Item -LiteralPath $OutputFile -Force -ErrorAction SilentlyContinue
  }
  Pop-Location
}
