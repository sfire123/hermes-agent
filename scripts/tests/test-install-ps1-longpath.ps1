# Tests for install.ps1's 8.3 short-path normalization.
#
# Run from a PowerShell prompt:
#
#   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/tests/test-install-ps1-longpath.ps1
#
# Background: when the Windows profile folder's name contains a space
# ("First Last"), a dot ("Stone.ZEN8"), or an accented character, Windows can
# expose %TEMP%, %LOCALAPPDATA% and friends as an 8.3 alias
# (C:\Users\FIRST~1.LAS\...). PowerShell's FileSystem provider chokes on the
# aliased component once it reaches a provider cmdlet (Tee-Object -FilePath),
# aborting the Node/Electron stages and the desktop post-build probe.
# install.ps1 expands those paths up front; this asserts that contract.
#
# HOW THIS RUNS THE CODE: by executing install.ps1 as a real subprocess with a
# crafted environment and reading what it reports back. `-ProtocolVersion` is a
# side-effect-free early exit that sits BELOW the normalization block, so the
# whole block -- including the script-level Add-Type the kernel32 resolver
# needs -- executes exactly as it does during an install. Nothing here parses
# install.ps1's source (AGENTS.md bans source-reading tests: they pass on
# broken code and fail on correct refactors).
#
# HERMETIC ENVIRONMENT: every case sets all five profile variables explicitly.
# GitHub's own Windows runners hand down a genuinely 8.3-aliased TEMP/TMP
# (C:\Users\RUNNER~1\AppData\Local\Temp), so an inherited variable is a live
# instance of the very bug under test and would contaminate any case that
# didn't override it.
#
# Portability: resolver 3 (profile-root substitution) is pure path arithmetic,
# so the substitution assertions run everywhere, including non-Windows CI. The
# kernel32 and COM resolvers only have anything to expand on a real Windows
# volume; on other hosts they no-op and fall through, which is itself the
# graceful-degradation contract asserted below.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
$installScript = Join-Path $repoRoot "scripts/install.ps1"

if (-not (Test-Path $installScript)) {
    throw "Could not locate install.ps1 at $installScript"
}

$failures = 0
$script:lastStderr = ''

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Label)
    if ($Expected -ne $Actual) {
        Write-Host "FAIL: $Label" -ForegroundColor Red
        Write-Host "  expected: $Expected"
        Write-Host "  actual:   $Actual"
        if ($script:lastStderr) {
            # The installer's own account of what it did. Without this a
            # failure on a host you can't reach is pure guesswork.
            Write-Host "  installer stderr:"
            foreach ($line in ($script:lastStderr -split "`r?`n")) {
                if ($line.Trim()) { Write-Host "    $line" }
            }
        }
        $script:failures++
    } else {
        Write-Host "OK: $Label" -ForegroundColor Green
    }
}

# --- Harness ---------------------------------------------------------------
# The real profile root the installer will substitute in, derived the same way
# install.ps1 derives it so these assertions hold on any host and any account.
$profileDir = [Environment]::GetFolderPath('UserProfile')
$usersDir = Split-Path -Parent $profileDir
$sep = [System.IO.Path]::DirectorySeparatorChar

# A profile alias that cannot resolve: no such folder exists, so kernel32 and
# COM both fail and only the profile-root substitution can handle it.
$shortProfile = Join-Path $usersDir 'FIRST~1.LAS'

function Join-Parts {
    # Join path segments with the platform separator. Literal forward slashes
    # inside a path would make Split-Path's behavior host-dependent, which is
    # noise this suite doesn't need.
    param([string[]]$Parts)
    return ($Parts -join $sep)
}

# Run install.ps1 -ProtocolVersion with a fully-specified environment, and
# return what the normalization block reported on stderr.
function Invoke-Normalization {
    param(
        [hashtable]$Environment = @{},
        [string[]]$ExtraArgs = @()
    )

    # Start from a long, self-consistent profile so nothing is inherited;
    # callers override only the variables their case is about.
    $env0 = @{
        TEMP         = (Join-Parts @($profileDir, 'AppData', 'Local', 'Temp'))
        TMP          = (Join-Parts @($profileDir, 'AppData', 'Local', 'Temp'))
        LOCALAPPDATA = (Join-Parts @($profileDir, 'AppData', 'Local'))
        APPDATA      = (Join-Parts @($profileDir, 'AppData', 'Roaming'))
        USERPROFILE  = $profileDir
        HERMES_HOME  = ''
    }
    foreach ($key in $Environment.Keys) { $env0[$key] = $Environment[$key] }

    $psExe = (Get-Process -Id $PID).Path
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    foreach ($arg in (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installScript) + $ExtraArgs + @('-ProtocolVersion'))) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    foreach ($key in $env0.Keys) { $psi.Environment[$key] = $env0[$key] }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $script:lastStderr = $stderr

    # One line per rewritten variable: "expanded 8.3 short path in %NAME%: old -> new"
    $rewrites = @{}
    foreach ($line in ($stderr -split "`r?`n")) {
        if ($line -match 'expanded 8\.3 short path in %(?<name>[^%]+)%: (?<from>.+) -> (?<to>.+)$') {
            $rewrites[$Matches['name']] = $Matches['to'].Trim()
        }
    }
    $installDir = $null
    if ($stderr -match 'resolved install paths: HermesHome=(?<home>.+?) InstallDir=(?<dir>.+?)\s*$') {
        $installDir = $Matches['dir'].Trim()
    }

    return @{
        ExitCode   = $proc.ExitCode
        Stdout     = $stdout.Trim()
        Rewrites   = $rewrites
        InstallDir = $installDir
    }
}

function Get-Rewrite {
    # '' rather than $null for an untouched variable, so a failure prints
    # something legible instead of a blank.
    param($Result, [string]$Name)
    if ($Result.Rewrites.ContainsKey($Name)) { return $Result.Rewrites[$Name] }
    return '<not rewritten>'
}

Write-Host ""
Write-Host "-- normalization is a no-op for ordinary paths --"

# A profile name with a space is NOT itself a short path; nothing to expand.
$result = Invoke-Normalization
Assert-Equal -Expected 0 -Actual $result.ExitCode -Label "long paths: install.ps1 still reaches its early exit"
Assert-Equal -Expected "1" -Actual $result.Stdout -Label "long paths: protocol version still on stdout"
Assert-Equal -Expected 0 -Actual $result.Rewrites.Count -Label "long paths: nothing rewritten"
Assert-Equal -Expected $null -Actual $result.InstallDir -Label "long paths: no path report emitted"

Write-Host ""
Write-Host "-- an unresolvable profile alias is rebuilt on the long profile root --"

# The reported failure: TEMP under an 8.3 profile alias that no resolver can
# expand (8dot3 disabled, or a stale alias). GH #52842, GH #57526.
$shortTemp = Join-Parts @($shortProfile, 'AppData', 'Local', 'Temp')
$expectedTemp = Join-Parts @($profileDir, 'AppData', 'Local', 'Temp')

$result = Invoke-Normalization @{ TEMP = $shortTemp; TMP = $shortTemp }
Assert-Equal -Expected 0 -Actual $result.ExitCode -Label "short TEMP: install.ps1 still reaches its early exit"
Assert-Equal -Expected $expectedTemp -Actual (Get-Rewrite $result 'TEMP') -Label "short TEMP is rebuilt on the long profile root"
Assert-Equal -Expected $expectedTemp -Actual (Get-Rewrite $result 'TMP')  -Label "short TMP is rebuilt on the long profile root"
Assert-Equal -Expected 2 -Actual $result.Rewrites.Count -Label "short TEMP: only the aliased variables are touched"

# The profile root itself, with no tail to reattach. USERPROFILE is also where
# the installer looks first for a long root, so this exercises the fallback to
# HOMEDRIVE/HOMEPATH and %USERNAME%.
$result = Invoke-Normalization @{ USERPROFILE = $shortProfile }
Assert-Equal -Expected $profileDir -Actual (Get-Rewrite $result 'USERPROFILE') -Label "bare short profile root expands to the long root"

Write-Host ""
Write-Host "-- every profile-rooted variable is covered, not just TEMP --"

# The desktop stage derives InstallDir from %LOCALAPPDATA%; a short root there
# fails the post-build probe after the build already succeeded (GH #52842).
$result = Invoke-Normalization @{
    TEMP         = $shortTemp
    TMP          = $shortTemp
    LOCALAPPDATA = (Join-Parts @($shortProfile, 'AppData', 'Local'))
    APPDATA      = (Join-Parts @($shortProfile, 'AppData', 'Roaming'))
    USERPROFILE  = $shortProfile
}
foreach ($name in @('TEMP', 'TMP', 'LOCALAPPDATA', 'APPDATA', 'USERPROFILE')) {
    Assert-Equal -Expected $false -Actual ((Get-Rewrite $result $name) -match '~\d') -Label "$name is normalized and carries no 8.3 alias"
}

# ...and the install paths derived from them are re-derived, not left short.
# This is the difference between "the build works" and "the installer stops
# claiming a successful build failed". Built with a literal backslash because
# that is how install.ps1 itself composes the default (it is a Windows path).
$expectedInstallDir = (Join-Parts @($profileDir, 'AppData', 'Local')) + '\hermes\hermes-agent'
Assert-Equal -Expected $expectedInstallDir -Actual $result.InstallDir -Label "InstallDir is re-derived from the long LOCALAPPDATA"

Write-Host ""
Write-Host "-- substitution is scoped to the profile folder --"

# We can only prove the long spelling of the profile root itself. A short
# component anywhere else must be left exactly as the caller set it.
$belowProfile = Join-Parts @($profileDir, 'DEEPLY~1', 'Temp')
$result = Invoke-Normalization @{ TEMP = $belowProfile; TMP = $belowProfile }
Assert-Equal -Expected '<not rewritten>' -Actual (Get-Rewrite $result 'TEMP') -Label "a short component below the profile root is left alone"

# A custom TEMP on another volume has no profile root to substitute.
$otherVolume = Join-Parts @("D:", 'SHORT~1', 'Temp')
$result = Invoke-Normalization @{ TEMP = $otherVolume; TMP = $otherVolume }
Assert-Equal -Expected '<not rewritten>' -Actual (Get-Rewrite $result 'TEMP') -Label "short TEMP outside the profile is left alone"

Write-Host ""
Write-Host "-- an explicit -InstallDir is normalized, never replaced --"

$result = Invoke-Normalization -Environment @{ TEMP = $shortTemp; TMP = $shortTemp } `
    -ExtraArgs @('-InstallDir', (Join-Path $shortProfile 'custom-hermes'))
Assert-Equal -Expected (Join-Path $profileDir 'custom-hermes') -Actual $result.InstallDir -Label "explicit -InstallDir keeps the caller's directory, on the long root"

# --- Summary ---------------------------------------------------------------
Write-Host ""
if ($failures -gt 0) {
    Write-Host "FAILED: $failures assertion(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All 8.3 short-path normalization tests passed." -ForegroundColor Green
    exit 0
}
