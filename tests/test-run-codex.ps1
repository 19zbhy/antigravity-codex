#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Regression test suite for run-codex.ps1 and install.ps1 on Windows.
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot "plugin\skills\codex\scripts\run-codex.ps1"
$installer = Join-Path $repoRoot "install.ps1"

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("antigravity-codex-ps-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$script:pass = 0
$script:fail = 0

function Assert-Eq([string]$Name, [string]$Expected, [string]$Actual) {
  if ($Expected -eq $Actual) {
    Write-Output "  [PASS] $Name"
    $script:pass++
  } else {
    Write-Error "  [FAIL] $Name : expected='$Expected' actual='$Actual'" -ErrorAction Continue
    $script:fail++
  }
}

function Assert-Contains([string]$Name, [string]$Needle, [string]$Haystack) {
  if ($Haystack -and $Haystack.Contains($Needle)) {
    Write-Output "  [PASS] $Name"
    $script:pass++
  } else {
    Write-Error "  [FAIL] $Name : expected '$Needle' in '$Haystack'" -ErrorAction Continue
    $script:fail++
  }
}

function Assert-NotContains([string]$Name, [string]$Needle, [string]$Haystack) {
  if (-not ($Haystack -and $Haystack.Contains($Needle))) {
    Write-Output "  [PASS] $Name"
    $script:pass++
  } else {
    Write-Error "  [FAIL] $Name : did NOT expect '$Needle' in '$Haystack'" -ErrorAction Continue
    $script:fail++
  }
}

try {
  $mockBin = Join-Path $tmpRoot "bin"
  New-Item -ItemType Directory -Path $mockBin -Force | Out-Null
  $argsLog = Join-Path $tmpRoot "mock_args.log"

  $mockCodex = @'
@echo off
setlocal enabledelayedexpansion
if "%~1"=="--version" (
  echo codex-cli 0.171.0-mock
  exit /b 0
)
if "%~1"=="login" if "%~2"=="status" (
  echo Logged in using Mock
  exit /b 0
)
if "%~1"=="exec" if "%~2"=="--help" (
  echo Usage: codex exec [OPTIONS] [PROMPT]
  echo   --approve-for-me
  echo   --ignore-user-config
  if not "%MOCK_NO_WORKTREE%"=="1" echo   --worktree
  exit /b 0
)
echo %*>>"%MOCK_ARGS_LOG%"
set "OUT_FILE="
set "PREV="
for %%A in (%*) do (
  if "!PREV!"=="-o" set "OUT_FILE=%%~A"
  set "PREV=%%~A"
)
if not "%MOCK_SESSION_ID%"=="" (
  echo session id: %MOCK_SESSION_ID%
) else (
  echo session id: 11111111-2222-3333-4444-555555555555
)
if not "!OUT_FILE!"=="" (
  echo Mock summary completed.>"!OUT_FILE!"
)
exit /b 0
'@
  [System.IO.File]::WriteAllText((Join-Path $mockBin "codex.cmd"), $mockCodex, [System.Text.UTF8Encoding]::new($false))

  $origPath = $env:Path
  $env:Path = "$mockBin;$env:Path"
  $env:MOCK_ARGS_LOG = $argsLog

  $workspace = Join-Path $tmpRoot "workspace"
  New-Item -ItemType Directory -Path $workspace -Force | Out-Null
  $planFile = Join-Path $tmpRoot "plan.md"
  [System.IO.File]::WriteAllText($planFile, "# Test Plan`n", [System.Text.UTF8Encoding]::new($false))

  Write-Output "=== Test 1: TOML top-level vs [profiles.*] scoping ==="
  $codexHome1 = Join-Path $tmpRoot "codex_home_1"
  New-Item -ItemType Directory -Path $codexHome1 -Force | Out-Null
  $toml1 = @"
service_tier = "priority"

[profiles.dev]
model = "profile-only-model"

[other_table]
respect_system_proxy = true
"@
  [System.IO.File]::WriteAllText((Join-Path $codexHome1 "config.toml"), $toml1, [System.Text.UTF8Encoding]::new($false))
  $cache1 = '{"models":[{"slug":"gpt-6.2-sol","display_name":"GPT-6.2-Sol","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}]}]}'
  [System.IO.File]::WriteAllText((Join-Path $codexHome1 "models_cache.json"), $cache1, [System.Text.UTF8Encoding]::new($false))

  $env:CODEX_HOME = $codexHome1
  $optsOut = (& $runner list-options) -join "`n"
  Assert-Contains "top-level default_model is default" "- default_model: default" $optsOut
  Assert-NotContains "profile model does not leak" "profile-only-model" $optsOut
  Assert-Contains "visible model listed" "gpt-6.2-sol (GPT-6.2-Sol)" $optsOut

  Write-Output "=== Test 2: Fail-closed -Worktree ==="
  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  $env:MOCK_NO_WORKTREE = "1"
  $wtOut = (& pwsh -NoProfile -File $runner execute $workspace $planFile -Worktree 2>&1) -join "`n"
  $wtRc = $LASTEXITCODE
  $env:MOCK_NO_WORKTREE = ""
  Assert-Eq "-Worktree fails on non-git dir" "2" "$wtRc"
  Assert-Contains "-Worktree error message" "requires a Git repository" $wtOut

  Write-Output "=== Test 3: Session ID capture & pinned resume ==="
  $pinnedOut = Join-Path $tmpRoot "pinned\last.md"
  $env:MOCK_SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  & $runner execute $workspace $planFile $pinnedOut | Out-Null
  $savedSid = (Get-Content -LiteralPath (Join-Path $tmpRoot "pinned\last.session_id") -Raw).Trim()
  Assert-Eq "session ID saved" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" $savedSid

  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  & $runner resume $workspace $planFile $pinnedOut | Out-Null
  $resArgs = (Get-Content -LiteralPath $argsLog -Raw)
  Assert-Contains "resume uses pinned session ID" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" $resArgs
  Assert-NotContains "resume omits --last when pinned" "--last" $resArgs

  Write-Output "=== Test 4: Strict read-only review ==="
  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  & $runner review $workspace $planFile | Out-Null
  $revArgs = (Get-Content -LiteralPath $argsLog -Raw)
  Assert-Contains "review uses -s read-only" "-s read-only" $revArgs
  Assert-NotContains "review omits workspace-write" "workspace-write" $revArgs

  Write-Output "=== Test 5: End-to-end install.ps1 ==="
  $fakeHome = Join-Path $tmpRoot "fake_home"
  New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
  & $installer -TargetHome $fakeHome | Out-Null
  $installedSkill = Get-Content -LiteralPath (Join-Path $fakeHome ".gemini\config\plugins\codex-collaborator\skills\codex\SKILL.md") -Raw
  Assert-NotContains "no <USER_HOME> placeholder left" "<USER_HOME>" $installedSkill
  Assert-Contains "switched to run-codex.ps1" "run-codex.ps1" $installedSkill
  Assert-Contains "synced live model cache" "gpt-6.2-sol (GPT-6.2-Sol)" $installedSkill

  $env:Path = $origPath
  Write-Output ""
  Write-Output "Summary: $script:pass passed, $script:fail failed."
  if ($script:fail -ne 0) { exit 1 }
} finally {
  if (Test-Path $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
