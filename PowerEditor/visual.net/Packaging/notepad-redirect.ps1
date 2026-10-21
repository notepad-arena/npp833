#Requires -Version 5.1
<#
.SYNOPSIS
    Redirect notepad.exe to the MSIX build of Notepad++ with a script (no compiled exe).

.DESCRIPTION
    Copies a redirector script to a folder outside the package and points the Image File
    Execution Options "Debugger" value of notepad.exe at it:

      -Mode vbs (default, no console flash)
          HKLM\...\Image File Execution Options\notepad.exe
              Debugger = "C:\Windows\System32\wscript.exe" //nologo "C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.vbs"

      -Mode cmd (fallback, works everywhere VBScript is unavailable; a console flashes briefly)
          HKLM\...\Image File Execution Options\notepad.exe
              Debugger = "C:\Windows\System32\cmd.exe" /c C:\ProgramData\NppMsixRedirect\npp-notepad-redirect.cmd

    Both scripts drop the notepad.exe path that IFEO appends and forward the remaining
    arguments to the packaged application through its app execution alias (npp.exe).

    Why not point Debugger straight at the packaged exe?
      * C:\Program Files\WindowsApps\... denies direct execution ("Access is denied");
        packaged binaries can only be started through package activation.
      * that path embeds version + architecture + publisher hash, so it changes on every update.
      * IFEO appends the notepad.exe path as an argument, which Notepad++ would open as a file.

.PARAMETER Mode
    vbs = wscript.exe host, no console window at all (default)
    cmd = cmd.exe /c host, tiny console flash, but no VBScript dependency

.PARAMETER Verify
    After installing, launch notepad.exe with a temp file and check that Notepad++ opened it.
    Also samples cmd.exe / conhost.exe while launching to confirm there is no console window.

.PARAMETER Uninstall
    Remove the IFEO value and the script folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\notepad-redirect.ps1 -Verify
    powershell -ExecutionPolicy Bypass -File .\notepad-redirect.ps1 -Mode cmd -Verify
    powershell -ExecutionPolicy Bypass -File .\notepad-redirect.ps1 -Uninstall

.NOTES
    Keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).

    VBScript became a Feature-on-Demand starting with Windows 11 24H2; it is still enabled by
    default there, but if a machine has it removed (or wscript is blocked by policy) use
    -Mode cmd instead. The cmd route always creates a console window, hence the brief flash.

    Do not add "-notepadStyleCmdline": on Notepad++ 8.3.3 that makes the app restore the
    previous session instead of opening the file passed by notepad.exe.
#>
[CmdletBinding()]
param(
    [ValidateSet('vbs', 'cmd')] [string] $Mode = 'vbs',
    [switch] $Verify,
    [switch] $Uninstall,
    [string] $InstallDir = (Join-Path $env:ProgramData 'NppMsixRedirect'),
    [string] $SourceFile
)

$ErrorActionPreference = 'Stop'

$ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
$pkgName = 'NotepadPlusPlus.MSIX'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$cmdExe  = Join-Path $env:SystemRoot 'System32\cmd.exe'

function Write-Step([string] $text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

function Get-ModeSpec {
    param([string] $which)
    switch ($which) {
        'vbs' {
            if (-not (Test-Path $wscript)) {
                throw "wscript.exe not found ($wscript). VBScript may be removed on this OS; use -Mode cmd."
            }
            [pscustomobject]@{ FileName = 'npp-notepad-redirect.vbs'; Host = $wscript; HostArgs = '//nologo' }
        }
        'cmd' {
            [pscustomobject]@{ FileName = 'npp-notepad-redirect.cmd'; Host = $cmdExe; HostArgs = '/c' }
        }
    }
}

function Assert-NotepadPackage {
    $pkg = Get-AppxPackage -Name $pkgName
    if (-not $pkg) {
        Write-Warning "Package $pkgName is not installed; install the .msixbundle first."
        return $null
    }
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\npp.exe'
    if (-not (Test-Path $alias)) {
        Write-Warning "App execution alias not found: $alias  (check Settings > Apps > App execution aliases)."
    }
    $pkg
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Step 'Removing IFEO redirect'
    if (Test-Path $ifeoKey) {
        $props = Get-ItemProperty -Path $ifeoKey
        if ($null -ne $props.Debugger) {
            Remove-ItemProperty -Path $ifeoKey -Name Debugger -Force
            Write-Host "Removed Debugger value from $ifeoKey"
        }
        else {
            Write-Host 'No Debugger value present.'
        }
        if ((Get-Item $ifeoKey).GetValueNames().Count -eq 0) {
            Remove-Item -Path $ifeoKey -Force
            Write-Host 'Removed the now empty IFEO key.'
        }
    }
    else {
        Write-Host 'IFEO key for notepad.exe does not exist.'
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
        Write-Host "Deleted $InstallDir"
    }
    Write-Host 'Done. notepad.exe is back to the system one.'
    return
}

# ---------------------------------------------------------------- install
$pkg = Assert-NotepadPackage
if (-not $pkg) { throw 'Install the MSIX package first.' }

$spec = Get-ModeSpec $Mode

Write-Step "Installing redirector ($Mode)"
$source = if ($SourceFile) { (Resolve-Path $SourceFile).Path } else { Join-Path $PSScriptRoot $spec.FileName }
if (-not (Test-Path $source)) { throw "Redirector script not found: $source" }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$target = Join-Path $InstallDir $spec.FileName
Copy-Item -Path $source -Destination $target -Force
Write-Host "Script   : $target"

Write-Step "Pointing IFEO Debugger at it (host: $($spec.Host))"
New-Item -Path $ifeoKey -Force | Out-Null
if ($Mode -eq 'cmd') {
    # No quotes around the script path on purpose: the path has no spaces, and cmd.exe has the
    # notorious "strip the outer quotes after /c" rule that would break a quoted path here.
    if ($target -match '\s') {
        Write-Warning "InstallDir contains spaces; cmd.exe /c may mis-parse it. Prefer a space-free path."
    }
    $debuggerValue = '"' + $spec.Host + '" ' + $spec.HostArgs + ' ' + $target
}
else {
    $debuggerValue = '"' + $spec.Host + '" ' + $spec.HostArgs + ' "' + $target + '"'
}
Set-ItemProperty -Path $ifeoKey -Name Debugger -Value $debuggerValue -Type String
Write-Host "Debugger : $debuggerValue"

Write-Step 'Result'
Write-Host 'Typing "notepad.exe" (or any app calling it) now opens Notepad++ from the MSIX package.'
Write-Host 'Remove with: powershell -ExecutionPolicy Bypass -File .\notepad-redirect.ps1 -Uninstall'

# ---------------------------------------------------------------- verify
if ($Verify) {
    Write-Step 'Verifying'
    $probe = Join-Path $env:TEMP ('npp-redirect-probe-{0}.txt' -f (Get-Date -Format 'HHmmss'))
    Set-Content -Path $probe -Value 'redirect probe' -Encoding UTF8
    Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $before = @{
        cmd     = @(Get-Process -Name 'cmd'     -ErrorAction SilentlyContinue).Count
        conhost = @(Get-Process -Name 'conhost' -ErrorAction SilentlyContinue).Count
    }

    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList "`"$probe`""

    # Sample for ~1.5 s: a cmd.exe based redirector shows up here (that is the "flash").
    $peak = @{ cmd = $before.cmd; conhost = $before.conhost }
    for ($i = 0; $i -lt 30; $i++) {
        $c = @(Get-Process -Name 'cmd'     -ErrorAction SilentlyContinue).Count
        $h = @(Get-Process -Name 'conhost' -ErrorAction SilentlyContinue).Count
        if ($c -gt $peak.cmd) { $peak.cmd = $c }
        if ($h -gt $peak.conhost) { $peak.conhost = $h }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Seconds 3

    $npp = Get-Process -Name 'Notepad++' -ErrorAction SilentlyContinue
    if ($npp) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($probe)
        $ok = $npp | Where-Object { $_.MainWindowTitle -like "*$leaf*" }
        if ($ok) {
            Write-Host "PASS: Notepad++ opened the file - $($ok[0].MainWindowTitle)" -ForegroundColor Green
        }
        else {
            Write-Host "WARN: Notepad++ started but the file argument did not arrive: '$($npp[0].MainWindowTitle)'" -ForegroundColor Yellow
        }
        $npp | ForEach-Object { $_.CloseMainWindow() | Out-Null }
    }
    else {
        Write-Host 'FAIL: no Notepad++ process. Check that the package is installed and the npp.exe alias is enabled.' -ForegroundColor Red
    }

    $cmdSpawned = ($peak.cmd -gt $before.cmd) -or ($peak.conhost -gt $before.conhost)
    if ($cmdSpawned) {
        Write-Host ("NOTE: cmd/conhost appeared during launch (cmd/conhost peak {0}/{1}) -> console flash expected with -Mode cmd." -f $peak.cmd, $peak.conhost) -ForegroundColor Yellow
    }
    else {
        Write-Host "PASS: no cmd.exe / conhost.exe was created -> no console flash." -ForegroundColor Green
    }
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
}
