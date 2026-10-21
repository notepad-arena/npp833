#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the default Windows notepad.exe (undo replace-notepad.ps1).

.DESCRIPTION
    Removes the Image File Execution Options "Debugger" value of notepad.exe and deletes the
    redirector folder. It does not touch the MSIX package - uninstall that separately if you
    want to (Settings > Apps, or Remove-AppxPackage).

    Works even when the package is already gone: the leftover IFEO value is removed first, so a
    dangling redirect (notepad.exe pointing at a package that no longer exists) is repaired.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\restore-notepad.ps1

.NOTES
    Requires elevation (writes HKLM). The script re-launches itself with UAC.
    Keep this file pure ASCII (Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI).
#>
[CmdletBinding()]
param(
    [string] $InstallDir = (Join-Path $env:ProgramData 'NppMsixRedirect')
)

$ErrorActionPreference = 'Stop'

$ifeoKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'

function Step([string] $text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- elevation
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are required - asking for elevation (UAC)...' -ForegroundColor Yellow
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    return
}

# ---------------------------------------------------------------- remove IFEO value
Step 'Removing the IFEO Debugger value'
if (Test-Path $ifeoKey) {
    $props = Get-ItemProperty -Path $ifeoKey
    if ($null -ne $props.Debugger) {
        Write-Host "Was: $($props.Debugger)"
        Remove-ItemProperty -Path $ifeoKey -Name Debugger -Force
        Write-Host 'Removed.'
    }
    else {
        Write-Host 'No Debugger value present (already restored).'
    }
    if ((Get-Item $ifeoKey).GetValueNames().Count -eq 0) {
        Remove-Item -Path $ifeoKey -Force
        Write-Host 'Removed the now empty IFEO key.'
    }
}
else {
    Write-Host 'IFEO key for notepad.exe does not exist (already restored).'
}

# ---------------------------------------------------------------- remove the script folder
Step 'Removing the redirector folder'
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "Deleted $InstallDir"
}
else {
    Write-Host "$InstallDir does not exist."
}

Step 'Done'
Write-Host 'The default Windows notepad is back.'
Write-Host 'Re-apply with: powershell -ExecutionPolicy Bypass -File .\replace-notepad.ps1'
