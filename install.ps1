#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-command installer for antigravity-codex on Windows (PowerShell).
.DESCRIPTION
  Installs the codex-collaborator plugin into $HOME\.gemini\config\plugins\codex-collaborator,
  replaces <USER_HOME> with the literal absolute home directory, and configures SKILL.md
  to invoke run-codex.ps1 natively on Windows.
#>

[CmdletBinding()]
param(
  [string]$TargetHome = $HOME
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcPluginDir = Join-Path $scriptDir "plugin"
$destPluginDir = Join-Path $TargetHome ".gemini\config\plugins\codex-collaborator"

if (-not (Test-Path -LiteralPath $srcPluginDir -PathType Container)) {
  Write-Error "Plugin template directory not found at: $srcPluginDir"
  exit 1
}

Write-Output "==> Installing antigravity-codex (codex-collaborator)..."
Write-Output "    Target directory: $destPluginDir"

New-Item -ItemType Directory -Path $destPluginDir -Force | Out-Null

# Clean up legacy rules or old skill directories if upgrading
foreach ($legacy in @("rules", "skills\codex-executor")) {
  $legacyPath = Join-Path $destPluginDir $legacy
  if (Test-Path -LiteralPath $legacyPath) {
    Remove-Item -LiteralPath $legacyPath -Recurse -Force
  }
}

# Copy plugin bundle files
Copy-Item -Path (Join-Path $srcPluginDir "*") -Destination $destPluginDir -Recurse -Force

# Determine PowerShell executable name (prefer pwsh if installed, fallback to powershell)
$psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$runnerPath = Join-Path $destPluginDir "skills\codex\scripts\run-codex.ps1"

# Patch SKILL.md for Windows literal paths and PowerShell runner
$skillFile = Join-Path $destPluginDir "skills\codex\SKILL.md"
$skillContent = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8

$unixPlaceholderRunner = "<USER_HOME>/.gemini/config/plugins/codex-collaborator/skills/codex/scripts/run-codex.sh"
$winRunnerCmd = "$psExe -NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`""

$skillContent = $skillContent.Replace($unixPlaceholderRunner, $winRunnerCmd)
$skillContent = $skillContent.Replace("<USER_HOME>", $TargetHome)
$skillContent = $skillContent.Replace("run-codex.sh", "run-codex.ps1")
$skillContent = $skillContent.Replace("--model <model> --effort <effort> --tier <tier>", "-Model <model> -Effort <effort> -Tier <tier>")
$skillContent = $skillContent.Replace("``--model`` / ``--effort`` / ``--tier``", "``-Model`` / ``-Effort`` / ``-Tier``")

[System.IO.File]::WriteAllText($skillFile, $skillContent, [System.Text.UTF8Encoding]::new($false))

Write-Output "==> Plugin files installed successfully!"
Write-Output ""

# Check OpenAI Codex CLI status
$npmGlobal = Join-Path $env:APPDATA "npm"
if ((Test-Path $npmGlobal) -and ($env:Path -notlike "*$npmGlobal*")) {
  $env:Path = "$npmGlobal;$env:Path"
}

$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($codexCmd) {
  $ver = (& codex --version 2>$null) -join ""
  Write-Output "==> Detected Codex CLI: $ver ($($codexCmd.Source))"
  $loginStatus = (& codex login status 2>&1) -join " "
  if ($LASTEXITCODE -eq 0) {
    Write-Output "==> Codex auth status: $loginStatus"
  } else {
    Write-Warning "Codex CLI is not logged in yet. Run 'codex login' once in your terminal."
  }
} else {
  Write-Warning "'codex' CLI was not found in PATH."
  Write-Output "    Install it via: npm install -g @openai/codex"
  Write-Output "    Then run:       codex login"
}

Write-Output ""
Write-Output "Done! Next steps:"
Write-Output "  1. In Antigravity, normal messages still run directly with Gemini."
Write-Output "  2. Type '/codex <your request>' whenever you want to invoke the Gemini x Codex workflow."
Write-Output "  3. On the first run of run-codex.ps1, click 'Always Allow' for seamless future runs."
