#Requires -Version 5.1
<#
.SYNOPSIS
    Replace the system notepad.exe with the MSIX build of Notepad++ (VBS-based redirector).

.DESCRIPTION
    Installs npp-notepad-redirect.vbs to a stable folder outside the package and registers it as
    the Image File Execution Options "Debugger" of notepad.exe:

        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe
            Debugger = "C:\Windows\System32\wscript.exe" //nologo "C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs"

    wscript.exe is a GUI subsystem host, so no console window appears (nothing flashes).
    The VBS drops the notepad.exe path that IFEO appends and forwards the remaining arguments to
    the packaged application through its app execution alias (npp.exe).

    Undo with restore-notepad.ps1.

.PARAMETER Verify
    After applying, launch notepad.exe with a temp file and check that Notepad++ opened it
    (and that no cmd/conhost was created, i.e. no console flash).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\replace-notepad.ps1
    powershell -ExecutionPolicy Bypass -File .\replace-notepad.ps1 -Verify

.NOTES
    Requires elevation (writes HKLM). The script re-launches itself with UAC.
    Keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).

    Why the .vbs lives in %ProgramData% and not inside the package:
      * C:\Program Files\WindowsApps\<pkg> is versioned (...._8.3.3.0_x64__<hash>), so any IFEO
        value pointing there dies on the next update;
      * that folder is read-only for administrators (TrustedInstaller owns it), so the redirect
        cannot be dropped in after the fact;
      * the VBS already resolves the package through the stable alias %LOCALAPPDATA%
        \Microsoft\WindowsApps\npp.exe, so it survives upgrades without being rewritten.
#>
[CmdletBinding()]
param(
    [switch] $Verify,
    [string] $InstallDir = (Join-Path $env:ProgramData 'NppMsixRedirect')
)

$ErrorActionPreference = 'Stop'

$ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
$pkgName = 'NotepadPlusPlus.MSIX'
$vbsName = 'npp-notepad-redirect.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

function Step([string] $text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- elevation
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are required - asking for elevation (UAC)...' -ForegroundColor Yellow
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($Verify) { $arguments += '-Verify' }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $arguments
    return
}

# ---------------------------------------------------------------- preconditions
Step 'Checking the package'
$pkg = Get-AppxPackage -Name $pkgName
if (-not $pkg) {
    throw "Package $pkgName is not installed. Install the .msixbundle first (PowerEditor\visual.net\Packaging\build-msix.ps1 -Sign -Install)."
}
Write-Host "Package : $($pkg.PackageFullName)"

$alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\npp.exe'
if (-not (Test-Path $alias)) {
    throw "App execution alias not found: $alias`nEnable it in Settings > Apps > App execution aliases, then retry."
}
Write-Host "Alias   : $alias"

if (-not (Test-Path $wscript)) {
    throw "wscript.exe not found ($wscript). VBScript may be removed on this OS - there is no fallback any more, see README section 14."
}

# ---------------------------------------------------------------- install the vbs
Step 'Installing the redirector script'
$source = Join-Path $PSScriptRoot $vbsName
if (-not (Test-Path $source)) { throw "Redirector script not found: $source" }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$target = Join-Path $InstallDir $vbsName
Copy-Item -Path $source -Destination $target -Force
Write-Host "Script  : $target"

# ---------------------------------------------------------------- register IFEO
Step 'Registering the IFEO Debugger value'
$debuggerValue = '"' + $wscript + '" //nologo "' + $target + '"'
New-Item -Path $ifeoKey -Force | Out-Null
Set-ItemProperty -Path $ifeoKey -Name Debugger -Value $debuggerValue -Type String
Write-Host "Debugger: $debuggerValue"

Step 'Done'
Write-Host 'notepad.exe now opens Notepad++ (no console flash).'
Write-Host 'Undo with: powershell -ExecutionPolicy Bypass -File .\restore-notepad.ps1'

# ---------------------------------------------------------------- verify
if ($Verify) {
    Step 'Verifying'
    $probe = Join-Path $env:TEMP ('npp-redirect-probe-{0}.txt' -f (Get-Date -Format 'HHmmss'))
    Set-Content -Path $probe -Value 'redirect probe' -Encoding UTF8
    Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $cmdBase = @(Get-Process -Name 'cmd' -ErrorAction SilentlyContinue).Count
    $conBase = @(Get-Process -Name 'conhost' -ErrorAction SilentlyContinue).Count

    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList "`"$probe`""

    $cmdPeak = $cmdBase
    $conPeak = $conBase
    for ($i = 0; $i -lt 30; $i++) {
        $c = @(Get-Process -Name 'cmd' -ErrorAction SilentlyContinue).Count
        $h = @(Get-Process -Name 'conhost' -ErrorAction SilentlyContinue).Count
        if ($c -gt $cmdPeak) { $cmdPeak = $c }
        if ($h -gt $conPeak) { $conPeak = $h }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Seconds 3

    $npp = Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue
    if ($npp) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($probe)
        $ok = $npp | Where-Object { $_.MainWindowTitle -like "*$leaf*" }
        if ($ok) { Write-Host "PASS: Notepad++ opened the file - $($ok[0].MainWindowTitle)" -ForegroundColor Green }
        else { Write-Host "WARN: Notepad++ started but the file argument did not arrive: '$($npp[0].MainWindowTitle)'" -ForegroundColor Yellow }
        $npp | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    }
    else {
        Write-Host 'FAIL: no Notepad++ process. Check the package and the npp.exe alias.' -ForegroundColor Red
    }

    if (($cmdPeak -le $cmdBase) -and ($conPeak -le $conBase)) {
        Write-Host 'PASS: no cmd.exe / conhost.exe was created -> no console flash.' -ForegroundColor Green
    }
    else {
        Write-Host ("WARN: cmd/conhost appeared (peak {0}/{1}) -> something still spawns a console." -f $cmdPeak, $conPeak) -ForegroundColor Yellow
    }
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
}
