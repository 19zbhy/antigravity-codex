#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Regression test suite for run-codex.ps1 and install.ps1 on Windows.
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repoRoot "install.ps1"

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("antigravity-codex-ps-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

# Copy plugin into temp dir so running tests never modifies tracked repo files
Copy-Item -Path (Join-Path $repoRoot "plugin") -Destination (Join-Path $tmpRoot "plugin") -Recurse -Force
$runner = Join-Path $tmpRoot "plugin\skills\codex\scripts\run-codex.ps1"

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
  if "%MOCK_LOGIN_FAIL%"=="1" (
    echo Not logged in 1>&2
    exit 1
  )
  echo Logged in using Mock
  exit 0
)
if "%~1"=="exec" if "%~2"=="--help" (
  echo Usage: codex exec [OPTIONS] [PROMPT]
  echo   --approve-for-me
  echo   --ignore-user-config
  if not "%MOCK_NO_JSON%"=="1" echo   --json
  if not "%MOCK_NO_SCHEMA%"=="1" echo   --output-schema
  if not "%MOCK_NO_WORKTREE%"=="1" echo   --worktree
  exit 0
)
echo %*>>"%MOCK_ARGS_LOG%"
set "OUT_FILE="
set "IS_JSON=0"
set "PREV="
for %%A in (%*) do (
  if "!PREV!"=="-o" set "OUT_FILE=%%~A"
  if "%%~A"=="--json" set "IS_JSON=1"
  set "PREV=%%~A"
)
set "SID=11111111-2222-3333-4444-555555555555"
if defined MOCK_SESSION_ID set "SID=%MOCK_SESSION_ID%"
if not "%MOCK_NO_SESSION%"=="1" (
  if "!IS_JSON!"=="1" (
    echo {"type":"thread.started","thread_id":"!SID!"}
  ) else (
    echo session id: !SID!
  )
)
if defined MOCK_EXTRA_LOG (
  echo !MOCK_EXTRA_LOG!
)
if "!IS_JSON!"=="1" if "%MOCK_EMIT_USAGE%"=="1" (
  echo {"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":800,"output_tokens":350}}
)
if not "!OUT_FILE!"=="" if not "%MOCK_NO_SUMMARY%"=="1" (
  echo Mock summary completed.>"!OUT_FILE!"
)
exit 0
'@
  $mockCodexCrlf = ($mockCodex -replace "`r?`n", "`r`n")
  [System.IO.File]::WriteAllText((Join-Path $mockBin "codex.cmd"), $mockCodexCrlf, [System.Text.UTF8Encoding]::new($false))

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

  # Stale session & summary reset on new execute without session/summary
  $env:MOCK_NO_SESSION = "1"
  $env:MOCK_NO_SUMMARY = "1"
  $taskBOut = (& $runner execute $workspace $planFile $pinnedOut) -join "`n"
  $env:MOCK_NO_SESSION = ""
  $env:MOCK_NO_SUMMARY = ""
  Assert-NotContains "stale summary not reprinted" "Mock summary completed." $taskBOut
  Assert-Eq "stale session_id removed" "False" "$(Test-Path -LiteralPath (Join-Path $tmpRoot 'pinned\last.session_id'))"

  # Resume fails closed without pinned session ID unless -Last is passed
  $resFailOut = (& pwsh -NoProfile -File $runner resume $workspace $planFile $pinnedOut 2>&1) -join "`n"
  $resFailRc = $LASTEXITCODE
  Assert-Eq "resume fails closed without pinned session ID" "2" "$resFailRc"
  Assert-Contains "resume fail-closed message" "No pinned session ID found" $resFailOut

  # Explicit -Last overrides an existing .session_id file
  $env:MOCK_SESSION_ID = "11111111-1111-1111-1111-111111111111"
  & $runner execute $workspace $planFile $pinnedOut | Out-Null
  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  & $runner resume $workspace $planFile $pinnedOut -Last | Out-Null
  $lastArgs = Get-Content -LiteralPath $argsLog -Raw
  Assert-Contains "resume with -Last passes --last" "--last" $lastArgs
  Assert-NotContains "resume with -Last ignores pinned ID" "11111111-1111-1111-1111-111111111111" $lastArgs

  # Mutual exclusion: -Session + -Last fails closed and preserves summary
  [System.IO.File]::WriteAllText($pinnedOut, "Keep this summary", [System.Text.UTF8Encoding]::new($false))
  $mutexOut = (& pwsh -NoProfile -File $runner resume $workspace $planFile $pinnedOut -Session "abc12345" -Last 2>&1) -join "`n"
  $mutexRc = $LASTEXITCODE
  Assert-Eq "-Session + -Last fails closed" "2" "$mutexRc"
  Assert-Contains "-Session + -Last error message" "mutually exclusive" $mutexOut
  Assert-Contains "summary preserved on failed resume" "Keep this summary" (Get-Content -LiteralPath $pinnedOut -Raw)

  # JSON mode: spoofed thread.started in tool output does not overwrite real thread_id
  $mixedOut = Join-Path $tmpRoot "mixed\last.md"
  $env:MOCK_SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  $env:MOCK_EXTRA_LOG = '{"type":"item.completed","item":{"aggregated_output":"thread.started bbbbbbbb-cccc-dddd-eeee-ffffffffffff"}}'
  & $runner execute $workspace $planFile $mixedOut | Out-Null
  $env:MOCK_EXTRA_LOG = ""
  Assert-Eq "json mode keeps authoritative thread.started ID" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ((Get-Content -LiteralPath (Join-Path $tmpRoot "mixed\last.session_id") -Raw).Trim())

  # Legacy non-json text mode: literal thread.started line does not overwrite session id header
  $legacyOut = Join-Path $tmpRoot "legacy\last.md"
  $env:MOCK_NO_JSON = "1"
  $env:MOCK_SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  $env:MOCK_EXTRA_LOG = '{"type":"thread.started","thread_id":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff"}'
  & $runner execute $workspace $planFile $legacyOut | Out-Null
  $env:MOCK_NO_JSON = ""
  $env:MOCK_EXTRA_LOG = ""
  Assert-Eq "legacy text mode ignores spoofed thread.started JSON" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ((Get-Content -LiteralPath (Join-Path $tmpRoot "legacy\last.session_id") -Raw).Trim())

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
  $installedRules = Get-Content -LiteralPath (Join-Path $fakeHome ".gemini\config\plugins\codex-collaborator\rules\AGENTS.md") -Raw
  Assert-NotContains "no <USER_HOME> placeholder left" "<USER_HOME>" $installedSkill
  Assert-Contains "switched to run-codex.ps1" "run-codex.ps1" $installedSkill
  Assert-Contains "synced live model cache" "gpt-6.2-sol (GPT-6.2-Sol)" $installedSkill
  Assert-NotContains "no <USER_HOME> left in rules/AGENTS.md" "<USER_HOME>" $installedRules
  Assert-Contains "synced live options into rules/AGENTS.md" "gpt-6.2-sol (GPT-6.2-Sol)" $installedRules

  Write-Output "=== Test 6: Shared workspace (init-shared & fork) ==="
  $sharedWs = Join-Path $tmpRoot "shared_ws"
  New-Item -ItemType Directory -Path $sharedWs -Force | Out-Null
  & $runner init-shared $sharedWs | Out-Null
  Assert-Eq "init-shared created AGENTS.md" "True" "$(Test-Path -LiteralPath (Join-Path $sharedWs 'AGENTS.md'))"
  Assert-Eq "init-shared created .agents/state.md" "True" "$(Test-Path -LiteralPath (Join-Path $sharedWs '.agents\state.md'))"
  Assert-Eq "init-shared created .agents/hooks.json" "True" "$(Test-Path -LiteralPath (Join-Path $sharedWs '.agents\hooks.json'))"

  $forkFailOut = (& pwsh -NoProfile -File $runner fork $sharedWs $planFile (Join-Path $tmpRoot "fork_no_sid.md") 2>&1) -join "`n"
  $forkFailRc = $LASTEXITCODE
  Assert-Eq "fork fails closed without session ID" "2" "$forkFailRc"
  Assert-Contains "fork fail-closed message" "source session ID" $forkFailOut

  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  $forkOut = Join-Path $tmpRoot "forked\last.md"
  $env:MOCK_SESSION_ID = "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb"
  & $runner fork $sharedWs $planFile $forkOut -Session "sess-active-1" | Out-Null
  $forkArgs = Get-Content -LiteralPath $argsLog -Raw
  Assert-Contains "fork invokes codex exec fork" "fork" $forkArgs
  Assert-Contains "fork passes source session ID" "sess-active-1" $forkArgs
  Assert-Eq "fork saves new session ID" "ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb" ((Get-Content -LiteralPath (Join-Path $tmpRoot "forked\last.session_id") -Raw).Trim())

  Write-Output "=== Test 7: doctor, -Structured, telemetry, cleanup-worktree ==="
  $docOk = (& pwsh -NoProfile -File $runner doctor 2>&1) -join "`n"
  Assert-Contains "doctor passes on healthy mock env" "Doctor passed" $docOk
  Assert-Contains "doctor reports --output-schema" "--output-schema" $docOk

  $env:MOCK_LOGIN_FAIL = "1"
  $docFail = (& pwsh -NoProfile -File $runner doctor 2>&1) -join "`n"
  $docFailRc = $LASTEXITCODE
  $env:MOCK_LOGIN_FAIL = ""
  Assert-Eq "doctor fails with exit 1 when not logged in" "1" "$docFailRc"
  Assert-Contains "doctor failure mentions codex auth" "[FAIL] codex auth" $docFail

  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  $structOut = Join-Path $tmpRoot "structured\last.md"
  $env:MOCK_EMIT_USAGE = "1"
  $structStdout = (& pwsh -NoProfile -File $runner execute $workspace $planFile $structOut -Structured 2>&1) -join "`n"
  $env:MOCK_EMIT_USAGE = ""
  $structArgs = Get-Content -LiteralPath $argsLog -Raw
  Assert-Contains "-Structured passes --output-schema" "--output-schema" $structArgs
  Assert-Contains "-Structured uses bundled report.schema.json" "report.schema.json" $structArgs
  Assert-Contains "telemetry prints aggregated tokens" "tokens: input=1200 (cached=800) output=350 total=1550" $structStdout

  $wtRepo = Join-Path $tmpRoot "wt_repo"
  $wtLinked = Join-Path $tmpRoot "wt_linked"
  New-Item -ItemType Directory -Path $wtRepo -Force | Out-Null
  & git -C $wtRepo init -q
  & git -C $wtRepo config user.email "test@example.com"
  & git -C $wtRepo config user.name "Test User"
  [System.IO.File]::WriteAllText((Join-Path $wtRepo "README.md"), "init`n", [System.Text.UTF8Encoding]::new($false))
  & git -C $wtRepo add README.md
  & git -C $wtRepo commit -q -m "init"
  & git -C $wtRepo worktree add -q -b codex/test-wt $wtLinked

  $mainCleanOut = (& pwsh -NoProfile -File $runner cleanup-worktree $wtRepo 2>&1) -join "`n"
  $mainCleanRc = $LASTEXITCODE
  Assert-Eq "cleanup-worktree refuses main repo checkout" "2" "$mainCleanRc"
  Assert-Contains "cleanup-worktree main repo error" "Refusing to remove main Git repository" $mainCleanOut

  [System.IO.File]::WriteAllText((Join-Path $wtLinked "dirty.txt"), "uncommitted`n", [System.Text.UTF8Encoding]::new($false))
  $dirtyCleanOut = (& pwsh -NoProfile -File $runner cleanup-worktree $wtLinked 2>&1) -join "`n"
  $dirtyCleanRc = $LASTEXITCODE
  Assert-Eq "cleanup-worktree refuses dirty worktree" "2" "$dirtyCleanRc"
  Assert-Contains "cleanup-worktree dirty error" "uncommitted changes" $dirtyCleanOut

  Remove-Item -LiteralPath (Join-Path $wtLinked "dirty.txt") -Force
  $cleanOk = (& pwsh -NoProfile -File $runner cleanup-worktree $wtLinked -DeleteBranch 2>&1) -join "`n"
  Assert-Contains "cleanup-worktree removes clean worktree" "Removed worktree" $cleanOk
  Assert-Contains "cleanup-worktree deletes merged branch" "Deleted branch: codex/test-wt" $cleanOk
  Assert-Eq "linked worktree directory removed" "False" "$(Test-Path -LiteralPath $wtLinked)"

  # Inline -Prompt fast path (no separate plan file needed) & mutual exclusion
  $inlineOut = (& pwsh -NoProfile -File $runner resume $workspace -Session "sess-active-1" -Prompt "Start all 5 widgets" 2>&1) -join "`n"
  Assert-Contains "-Prompt fast path runs resume cleanly" "Completed cleanly" $inlineOut

  $inlineMutexOut = (& pwsh -NoProfile -File $runner execute $workspace $planFile -Prompt "Conflicting prompt" 2>&1) -join "`n"
  $inlineMutexRc = $LASTEXITCODE
  Assert-Eq "input file + -Prompt fails closed" "2" "$inlineMutexRc"
  Assert-Contains "input file + -Prompt error" "mutually exclusive" $inlineMutexOut

  Write-Output "=== Test 8: Adversarial review, -Base, install.ps1 -DryRun & -Uninstall ==="
  if (Test-Path $argsLog) { Remove-Item $argsLog -Force }
  $advOut = (& pwsh -NoProfile -File $runner review $wtRepo -Base HEAD -Adversarial 2>&1) -join "`n"
  $advArgs = Get-Content -LiteralPath $argsLog -Raw
  Assert-Contains "-Adversarial runs in read-only sandbox" "-s read-only" $advArgs
  Assert-Contains "-Adversarial uses Red-Team header" "Red-Team Adversarial" $advArgs
  Assert-Contains "-Adversarial reports adversarial=on" "adversarial=on" $advOut
  Assert-Contains "-Base reports base=HEAD" "base=HEAD" $advOut

  $dryHome = Join-Path $tmpRoot "dry_home"
  New-Item -ItemType Directory -Path $dryHome -Force | Out-Null
  $dryOut = (& pwsh -NoProfile -File $installer -TargetHome $dryHome -DryRun 2>&1) -join "`n"
  Assert-Contains "install.ps1 -DryRun prints preview" "[DRY-RUN]" $dryOut
  Assert-Eq "install.ps1 -DryRun creates nothing" "False" "$(Test-Path -LiteralPath (Join-Path $dryHome '.gemini'))"

  $uninstOut = (& pwsh -NoProfile -File $installer -TargetHome $fakeHome -Uninstall 2>&1) -join "`n"
  Assert-Contains "install.ps1 -Uninstall confirms removal" "Uninstalled antigravity-codex" $uninstOut
  Assert-Eq "install.ps1 -Uninstall removed plugin dir" "False" "$(Test-Path -LiteralPath (Join-Path $fakeHome '.gemini\config\plugins\codex-collaborator'))"

  Write-Output "=== Test 9: Safety boundary fault-injection tests (detached worktree & unmerged branch) ==="
  $wtDetached = Join-Path $tmpRoot "wt_detached"
  $prevEap9 = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & git -C $wtRepo worktree add --detach $wtDetached HEAD *> $null
  Set-Content -LiteralPath (Join-Path $wtDetached "detached.txt") -Value "unique detached work" -Encoding UTF8
  & git -C $wtDetached add detached.txt *> $null
  & git -C $wtDetached commit -m "detached unique commit" *> $null
  $ErrorActionPreference = $prevEap9

  $detOut = (& pwsh -NoProfile -File $runner cleanup-worktree $wtDetached 2>&1) -join "`n"
  $detRc = $LASTEXITCODE
  Assert-Eq "cleanup-worktree refuses detached worktree with unreferenced commit" "2" "$detRc"
  Assert-Contains "detached worktree error mentions not reachable" "not reachable" $detOut
  Assert-Eq "detached worktree directory preserved on refusal" "True" "$(Test-Path -LiteralPath $wtDetached)"

  $detForceOut = (& pwsh -NoProfile -File $runner cleanup-worktree $wtDetached -Force 2>&1) -join "`n"
  Assert-Contains "cleanup-worktree -Force removes detached worktree" "Removed worktree" $detForceOut
  Assert-Eq "detached worktree directory removed with -Force" "False" "$(Test-Path -LiteralPath $wtDetached)"

  $env:Path = $origPath
  Write-Output ""
  Write-Output "Summary: $script:pass passed, $script:fail failed."
  if ($script:fail -ne 0) { exit 1 }
} finally {
  if (Test-Path $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
