<#
.SYNOPSIS
    install-windows.ps1 - install rio on Windows 11.

.DESCRIPTION
    rio is a small IDE written in Tcl/Tk. There is nothing to compile: it runs from
    this folder. So "installing" it is three things, and this script does all three -
    the Windows counterpart to install-unix.sh:

      1. INSTALL THE TOOLCHAIN if you don't have it. Windows has no apt/apk, so this
         offers winget instead, then VERIFIES by actually loading it in tclsh (Tk +
         json required; tls only matters for HTTPS - a hosted agent provider, or an
         https extension repository). Loading it, not a successful install, is the
         real answer - same as the shell script.
      2. PERSISTENCE - relocate rio's settings and session state to a tidy place by
         setting the XDG_CONFIG_HOME / XDG_DATA_HOME user environment variables (and
         creating the folders). rio remembers things either way; this only decides
         where. Skip with -NoPersist.
      3. SHORTCUTS so you can start rio like any other application: a Start Menu
         entry and one on the Desktop, both launching rio through wish. Skip with
         -NoShortcut.

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

.PARAMETER NoShortcut
    Skip the Start Menu and Desktop shortcuts (they are created by default).

.PARAMETER Yes
    Auto-confirm the winget install prompt (non-interactive). Without it the script
    asks before installing anything.

.PARAMETER NoInstall
    Never offer to install via winget; just print manual instructions if Tcl is absent.

.PARAMETER DryRun
    Print what would happen without changing anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-windows.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -NoShortcut

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-windows.ps1 -VerifyOnly

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
    [switch]$NoShortcut,
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
    # Not on PATH: search the well-known Windows Tcl install dirs (Magicsplat installs
    # to %LOCALAPPDATA%\Apps\Tcl86|Tcl90\bin; ActiveTcl to C:\Tcl\bin), so a toolchain
    # just installed by winget is found even before PATH refreshes in this session.
    $dirs = @(
        (Join-Path $env:LOCALAPPDATA 'Apps\Tcl86\bin')
        (Join-Path $env:LOCALAPPDATA 'Apps\Tcl90\bin')
        'C:\Tcl\bin'
    )
    foreach ($d in $dirs) {
        if ($d -and (Test-Path $d)) {
            $hit = Get-ChildItem -Path $d -Filter "$stem*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
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
    # Pipe winget's console output to Out-Host, NOT the pipeline: an uncaptured native
    # command's stdout would otherwise become part of this function's return value, so
    # the caller's $tclsh would be the winget banner text instead of the path.
    & winget install --exact --id $WingetId --source winget --accept-package-agreements --accept-source-agreements | Out-Host
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
# install-unix.sh). Tk needs no display on Windows, but withdraw its window so it
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

# One shortcut in $dir. The target is wish.exe with rio's script as its argument -
# NOT a shortcut to the .tcl file, which would obey whatever Windows currently
# associates with .tcl and can silently become "open in Notepad".
function New-RioShortcut ($dir, $wish, $rioGui, $icon) {
    $lnkPath = Join-Path $dir "rio.lnk"
    if ($DryRun) { Step "create shortcut $lnkPath -> $wish `"$rioGui`""; return }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $wish
    $lnk.Arguments        = "`"$rioGui`""
    $lnk.WorkingDirectory = Split-Path $rioGui
    $lnk.Description      = "rio - a small IDE with git and AI-agent integration"
    # Without this the shortcut wears wish.exe's icon (Tk's feather), which is not
    # rio. rio ships a real multi-size .ico for exactly this; the icon on the WINDOW
    # itself is set by rio at startup and is a separate thing.
    if ($icon -and (Test-Path $icon)) { $lnk.IconLocation = $icon }
    $lnk.Save()
    Log "shortcut: $lnkPath"
}

# Both places Windows expects an installed application to be: the Start Menu app
# list, and the Desktop.
function Install-Shortcuts ($wish, $rioGui) {
    $icon = Join-Path $PSScriptRoot "rio-gui\icons\rio.ico"
    New-RioShortcut ([Environment]::GetFolderPath('Programs')) $wish $rioGui $icon
    New-RioShortcut ([Environment]::GetFolderPath('Desktop'))  $wish $rioGui $icon
}

# --- main -------------------------------------------------------------------

$rioGui = Join-Path $PSScriptRoot "rio-gui\rio-gui.tcl"

$tclsh = Find-Tcl "tclsh"
if (-not $tclsh -and -not $VerifyOnly) {
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

if (-not $NoShortcut) {
    $wish = Find-Tcl "wish"
    if (-not $wish) { Warn "wish not found - skipping shortcuts (Tk GUI stub missing?)" }
    elseif (-not (Test-Path $rioGui)) { Warn "rio-gui.tcl not found at $rioGui - skipping shortcuts" }
    else { Install-Shortcuts $wish $rioGui }
}

Write-Host ""
if (-not $NoShortcut -and -not $DryRun) {
    Log "done. Start rio from the Start Menu or the Desktop shortcut, or:"
} else {
    Log "done. Launch rio with:"
}
$wishHint = (Find-Tcl "wish"); if (-not $wishHint) { $wishHint = "wish" }
Write-Host "    $wishHint `"$rioGui`" [file-or-folder ...]"
if ($DryRun) { Warn "dry run - nothing was changed" }
