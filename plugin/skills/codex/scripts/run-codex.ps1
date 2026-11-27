#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Windows PowerShell runner for the Google Antigravity x OpenAI Codex workflow.
.EXAMPLE
  pwsh -NoProfile -File run-codex.ps1 execute C:\path\to\workspace C:\path\to\implementation_plan.md C:\path\to\codex_last_message.md
  pwsh -NoProfile -File run-codex.ps1 resume  C:\path\to\workspace C:\path\to\codex_fix_instructions.md C:\path\to\codex_last_message.md
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet("execute", "resume")]
  [string]$Mode,

  [Parameter(Mandatory = $true, Position = 1)]
  [string]$WorkspaceDir,

  [Parameter(Mandatory = $true, Position = 2)]
  [string]$InputFile,

  [Parameter(Mandatory = $false, Position = 3)]
  [string]$OutputFile = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

if (-not (Test-Path -LiteralPath $WorkspaceDir -PathType Container)) {
  Write-Error "ERROR: Workspace directory does not exist: $WorkspaceDir"
  exit 2
}

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf) -or ((Get-Item -LiteralPath $InputFile).Length -eq 0)) {
  Write-Error "ERROR: Input plan/instructions file is missing or empty: $InputFile"
  exit 2
}

$outFlags = @()
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  $outDir = Split-Path -Parent $OutputFile
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $outFlags = @("-o", $OutputFile)
}

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

  # Auto-detect approval flag across codex-cli versions
  $helpText = (& codex exec --help 2>&1) -join "`n"
  if ($helpText -match "--approve-for-me") {
    $approvalFlags = @("--approve-for-me", "-s", "workspace-write")
  } else {
    $approvalFlags = @("--full-auto")
  }

  $stdinContent = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8

  if ($Mode -eq "execute") {
    $cwd = (Get-Location).Path
    $promptHeader = "You are the Principal Software Engineer in a Gemini (Product & Architecture) + Codex (Engineering) workflow. <stdin> contains the user-approved specification defining the goal, UX/business behavior, edge cases, scope boundaries, and acceptance criteria inside $cwd. You own the 'How': inspect the relevant code, design clean and idiomatic engineering implementations matching existing codebase conventions, and strictly respect scope boundaries. Before finishing, run the relevant build, typecheck, lint, and test commands yourself inside the workspace and fix any failures on the spot so you deliver working, verified code in one pass. End with a concise technical summary of files changed and verification commands executed."
    Write-Output "==> [Codex Engineer] Starting implementation & self-test in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Spec file: $InputFile"

    $argsList = @("exec") + $approvalFlags + @("--color", "never") + $gitFlags + $outFlags + @($promptHeader)
    $stdinContent | & codex @argsList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      [Console]::Error.WriteLine("")
      [Console]::Error.WriteLine("ERROR: 'codex exec' exited with code $exitCode.")
      [Console]::Error.WriteLine("Hint: If this is an authentication error, run 'codex login' in your terminal once to sign in.")
      exit $exitCode
    }
  } else {
    Write-Output "==> [Codex Engineer] Resuming latest Codex session in: $WorkspaceDir"
    Write-Output "==> [Codex Engineer] Follow-up review feedback: $InputFile"

    $argsList = @("exec") + $approvalFlags + @("--color", "never", "resume", "--last") + $gitFlags + $outFlags + @("-")
    $stdinContent | & codex @argsList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
      [Console]::Error.WriteLine("")
      [Console]::Error.WriteLine("ERROR: 'codex exec resume --last' exited with code $exitCode.")
      exit $exitCode
    }
  }
} finally {
  Pop-Location
}
