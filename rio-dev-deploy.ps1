<#
.SYNOPSIS
    rio-dev-deploy.ps1 - set up rio for daily use on Windows 11.

.DESCRIPTION
    The Windows counterpart to rio-dev-deploy.sh. That script apt/apk-installs the
    Tcl/Tk toolchain; Windows has no such package manager for it, so this script does
    what CAN be automated here and is honest about the one step that can't:

      1. VERIFY the toolchain by actually loading it in tclsh (Tk + json required;
         tls optional - only the Claude agent needs it). This is the real source of
         truth, same as the shell script. If tclsh isn't found, it explains how to
         install Tcl/Tk and stops.
      2. PERSISTENCE - set the XDG_CONFIG_HOME / XDG_DATA_HOME user environment
         variables (and create the folders) so rio remembers your preferences and
         reopens your last session between launches. Without these, rio runs fine but
         forgets everything on exit.
      3. Optionally (-Shortcut) drop a Desktop shortcut that launches rio via wish.

    If tclsh isn't found and winget is available, the script OFFERS to install
    Magicsplat Tcl/Tk (winget id Magicsplat.TclTk) - one package that bundles Tk +
    tcllib, exactly rio's dependency set. It always ASKS first (answer y), or pass -Yes
    to auto-confirm, or -NoInstall to only be told how to install it by hand. Absent
    winget, get Magicsplat directly: https://www.magicsplat.com/tcl-installer/
    (ActiveTcl works too; add tcllib via `teacup install tcllib`).

    Safe to re-run: every step is idempotent.

.PARAMETER VerifyOnly
    Only verify the toolchain loads; change nothing.

.PARAMETER NoPersist
    Skip the persistence env-var setup (it runs by default otherwise).

.PARAMETER Shortcut
    Also create a "rio" shortcut on the Desktop that launches the GUI.

.PARAMETER Yes
    Auto-confirm the winget install prompt (non-interactive). Without it the script
    asks before installing anything.

.PARAMETER NoInstall
    Never offer to install via winget; just print manual instructions if Tcl is absent.

.PARAMETER DryRun
    Print what would happen without changing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\rio-dev-deploy.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\rio-dev-deploy.ps1 -Shortcut

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\rio-dev-deploy.ps1 -VerifyOnly

.NOTES
    Keep this file ASCII-only. Windows PowerShell 5.1 reads a BOM-less .ps1 as the
    system ANSI codepage (e.g. Windows-1252), NOT UTF-8, so a non-ASCII character
    (em dash, ellipsis, curly quote) is mis-decoded into bytes that break parsing.
    Use '-' and '...' rather than the typographic forms.
#>

[CmdletBinding()]
param(
    [switch]$VerifyOnly,
    [switch]$NoPersist,
    [switch]$Shortcut,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$DryRun,
    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Help) { Get-Help -Detailed $PSCommandPath; exit 0 }

# --- helpers ----------------------------------------------------------------

function Log  ($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn ($m) { Write-Host "warn: $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "error: $m" -ForegroundColor Red; exit 1 }
function Step ($m) { if ($DryRun) { Write-Host "  [dry-run] $m" } }

# Locate a Tcl program (tclsh / wish), tolerating versioned names Magicsplat and
# ActiveTcl ship (tclsh.exe, tclsh86t.exe, tclsh90.exe, ...). Returns the full path or $null.
function Find-Tcl ($stem) {
    $cmd = Get-Command "$stem" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in Get-Command "$stem*" -CommandType Application -ErrorAction SilentlyContinue) {
        if ($c.Name -match "^$stem\d*t?\.exe$") { return $c.Source }
    }
    return $null
}

# Ask a yes/no question; -Yes answers it affirmatively without prompting. Default No.
function Confirm-Yes ($question) {
    if ($Yes) { return $true }
    $ans = Read-Host "$question [y/N]"
    return ($ans -match '^(y|yes)$')
}

# Pull PATH changes a fresh installer made into THIS session, so a just-installed
# tclsh becomes findable without opening a new terminal.
function Update-PathFromRegistry {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH = @($machine, $user | Where-Object { $_ }) -join ';'
}

# Offer to install the toolchain via winget (Magicsplat.TclTk bundles Tk + tcllib -
# rio's whole dependency set). Always asks first unless -Yes. Returns the tclsh path
# on success, else $null (caller falls back to manual guidance).
$WingetId = "Magicsplat.TclTk"
function Install-Toolchain {
    if ($NoInstall) { return $null }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Warn "winget not available - cannot offer an automatic install"
        return $null
    }
    if ($DryRun) {
        Step "prompt, then: winget install --exact --id $WingetId --source winget"
        return $null
    }
    Write-Host ""
    Write-Host "  winget can install Magicsplat Tcl/Tk ($WingetId) - Tk + tcllib, rio's"
    Write-Host "  full dependency set, in one package."
    if (-not (Confirm-Yes "  Install it now via winget?")) {
        Log "skipping winget install (declined)"
        return $null
    }
    Log "installing $WingetId via winget..."
    & winget install --exact --id $WingetId --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Warn "winget install exited $LASTEXITCODE - install Magicsplat by hand and re-run"
        return $null
    }
    Update-PathFromRegistry
    return (Find-Tcl "tclsh")
}

# --- verification -----------------------------------------------------------
#
# The real test: does the toolchain load? Probe with tclsh itself (same logic as
# rio-dev-deploy.sh). Tk needs no display on Windows, but withdraw its window so it
# doesn't flash. tls is OPTIONAL here - only the agent's HTTPS needs it.

# The Tcl probe, as an ARRAY of single-line strings - NOT a multi-line string literal.
# Windows PowerShell 5.1 mis-parses multi-line string literals (here-strings AND quoted)
# in a file with LF line endings, reading their interior as PowerShell; single-line
# single-quoted elements sidestep that entirely. Set-Content writes one per line. Each
# element is single-quoted (so $name/$ver etc. stay literal Tcl) and apostrophe-free
# (so the closing quote is unambiguous - hence {*can*find*} not {*can't find*}).
$Probe = @(
    'set fail 0'
    'proc check {name {require 1}} {'
    '    global fail'
    '    if {[catch {package require $name} ver]} {'
    '        if {[string match {*find package*} $ver] || [string match {*can*find*} $ver]} {'
    '            puts [format "  %-8s MISSING (%s)" $name $ver]'
    '            if {$require} {incr fail}'
    '        } else {'
    '            puts [format "  %-8s ok (installed; load note: %s)" $name $ver]'
    '        }'
    '    } else {'
    '        if {$name eq "Tk"} {catch {wm withdraw .}}'
    '        puts [format "  %-8s ok %s" $name $ver]'
    '    }'
    '}'
    'check Tk 1'
    'check tls 0'
    'check json 1'
    'puts [format "  %-8s %s" tclsh [info patchlevel]]'
    'if {$fail} { puts stderr "verify: $fail required package(s) missing"; exit 1 }'
    'exit 0'
)

function Invoke-Verify ($tclsh) {
    if ($DryRun) { Log "verify: skipped (dry run)"; return }
    Log "verifying Tcl toolchain"
    $probePath = Join-Path $env:TEMP "rio-probe.tcl"
    Set-Content -Path $probePath -Value $Probe -Encoding ascii
    try {
        & $tclsh $probePath
        $code = $LASTEXITCODE
    } finally {
        Remove-Item $probePath -ErrorAction SilentlyContinue
    }
    if ($code -ne 0) {
        Die "toolchain verify failed - Tk and/or json (tcllib) not loadable. Install/repair Tcl/Tk (see -Help), then re-run."
    }
    Log "toolchain OK"
}

# --- persistence: XDG env vars ----------------------------------------------

function Set-Persistence {
    $cfg = Join-Path $env:USERPROFILE "rio\config"
    $dat = Join-Path $env:USERPROFILE "rio\data"

    foreach ($pair in @(@('XDG_CONFIG_HOME', $cfg), @('XDG_DATA_HOME', $dat))) {
        $name = $pair[0]; $val = $pair[1]
        $existing = [Environment]::GetEnvironmentVariable($name, 'User')
        if ($existing) {
            Log "$name already set ($existing) - leaving it"
            $val = $existing
        } elseif ($DryRun) {
            Step "setx $name `"$val`"  (User scope)"
        } else {
            [Environment]::SetEnvironmentVariable($name, $val, 'User')
            Set-Item -Path "Env:$name" -Value $val   # also this session, for the dir create below
            Log "$name = $val"
        }
        if (-not $DryRun -and -not (Test-Path $val)) {
            New-Item -ItemType Directory -Force -Path $val | Out-Null
            Log "created $val"
        } elseif ($DryRun) {
            Step "mkdir $val"
        }
    }
    Warn "open a NEW terminal (or re-login) for the env vars to reach future launches"
}

# --- optional: Desktop shortcut ---------------------------------------------

function New-RioShortcut ($wish, $rioGui) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "rio.lnk"
    if ($DryRun) { Step "create shortcut $lnkPath -> $wish `"$rioGui`""; return }
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $wish
    $lnk.Arguments        = "`"$rioGui`""
    $lnk.WorkingDirectory = Split-Path $rioGui
    $lnk.Description       = "rio editor"
    $lnk.Save()
    Log "shortcut: $lnkPath"
}

# --- main -------------------------------------------------------------------

$rioGui = Join-Path $PSScriptRoot "rio-gui\rio-gui.tcl"

$tclsh = Find-Tcl "tclsh"
if (-not $tclsh) {
    Warn "tclsh not found on PATH."
    $tclsh = Install-Toolchain
}
if (-not $tclsh) {
    Write-Host ""
    Write-Host "  Install Tcl/Tk with tcllib, then re-run this script:"
    Write-Host "    - winget install --exact --id $WingetId --source winget"
    Write-Host "    - Magicsplat Tcl/Tk (direct): https://www.magicsplat.com/tcl-installer/"
    Write-Host "    - or ActiveTcl, then: teacup install tcllib"
    Write-Host ""
    if (-not $DryRun) { Die "no Tcl toolchain" }
    exit 0
}
Log "tclsh: $tclsh"

Invoke-Verify $tclsh

if ($VerifyOnly) { Log "verify-only: done."; exit 0 }

if (-not $NoPersist) { Set-Persistence }

if ($Shortcut) {
    $wish = Find-Tcl "wish"
    if (-not $wish) { Warn "wish not found - skipping shortcut (Tk GUI stub missing?)" }
    elseif (-not (Test-Path $rioGui)) { Warn "rio-gui.tcl not found at $rioGui - skipping shortcut" }
    else { New-RioShortcut $wish $rioGui }
}

Write-Host ""
Log "done. Launch rio with:"
$wishHint = (Find-Tcl "wish"); if (-not $wishHint) { $wishHint = "wish" }
Write-Host "    $wishHint `"$rioGui`""
if ($DryRun) { Warn "dry run - nothing was changed" }
