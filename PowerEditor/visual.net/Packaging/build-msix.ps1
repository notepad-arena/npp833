#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the Notepad++ MSIX packages (x86 + x64) and optionally an MSIXBundle, then signs it.

.DESCRIPTION
    1. Builds notepadPlus.sln for Win32 and x64 so libSciLexer.lib / notepad++.exe exist.
    2. Builds Packaging\NppPackaging.wapproj (Windows Application Packaging Project).
       With AppxBundle=Always + AppxBundlePlatforms=x86|x64 the AppxPackage targets build
       both architectures and bundle them into a single .msixbundle.
    3. Optionally signs the produced package(s) with signtool.

    Output: PowerEditor\visual.net\Packaging\AppPackages\

.PARAMETER CreateTestCert
    Creates a self-signed code-signing certificate (CN must equal Identity/@Publisher in
    Package.appxmanifest) and exports it to Packaging\npp-msix-dev.pfx. Use -TrustCert to
    also install it into LocalMachine\TrustedPeople (needs an elevated shell) so that
    Add-AppxPackage / double-click install works.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -CreateTestCert -TrustCert -Sign

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build-msix.ps1 -Configuration Release -Sign -Install

.NOTES
    Keep this file pure ASCII - Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [ValidateSet('Debug','Release')] [string] $Configuration = 'Release',
    [string[]] $Platforms = @('x86','x64','ARM64'),
    [ValidateSet('system','permonitorv2')] [string] $DpiAwareness = 'permonitorv2',
    [switch]   $NoBundle,
    [switch]   $Sign,
    [string]   $PfxPath,
    [string]   $PfxPassword,
    [switch]   $CreateTestCert,
    [switch]   $TrustCert,
    [switch]   $Install,
    [switch]   $Verify,
    [string]   $TargetPlatformVersion,
    [string]   $MsBuildPath
)

$ErrorActionPreference = 'Stop'
$root      = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path   # repo root
$vcxSln    = Join-Path $PSScriptRoot '..\notepadPlus.sln'
$wapproj   = Join-Path $PSScriptRoot 'NppPackaging.wapproj'
$manifest  = Join-Path $PSScriptRoot 'Package.appxmanifest'
$appPkgs   = Join-Path $PSScriptRoot 'AppPackages'
$testPfx   = Join-Path $PSScriptRoot 'npp-msix-dev.pfx'
$testCer   = Join-Path $PSScriptRoot 'npp-msix-dev.cer'

# Normalise platform names (accept win32/arm64 spellings) and keep the packaging order.
$Platforms = @($Platforms | ForEach-Object {
    switch ($_.ToLowerInvariant()) {
        'x86'   { 'x86'   }
        'win32' { 'x86'   }
        'x64'   { 'x64'   }
        'arm64' { 'ARM64' }
        default { throw "Unsupported platform: $_ (use x86, x64, arm64)" }
    }
} | Select-Object -Unique)

# DPI awareness of the packaged exe:
#   permonitorv2 = dpiAware.PerMonitorV2.manifest (WACK clean, crisp on high DPI startup)
#   system       = dpiAware.manifest (upstream default)
$dpiManifest = switch ($DpiAwareness) {
    'system'       { '..\src\dpiAware.manifest' }
    'permonitorv2' { '..\src\dpiAware.PerMonitorV2.manifest' }
}
$dpiArg = @("/p:NppDpiManifest=$dpiManifest")

function Write-Step([string] $text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- tool discovery
function Find-MSBuild {
    if ($MsBuildPath) { return $MsBuildPath }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $p = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
                        -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
        if ($p) { return $p }
    }
    $fallback = 'C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'MSBuild.exe not found. Pass -MsBuildPath explicitly.'
}

function Find-SignTool {
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path $kits)) { return $null }
    Get-ChildItem $kits -Directory |
        Where-Object { $_.Name -match '^10\.' } |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

function Get-ManifestPublisher {
    # XmlDocument honours the <?xml encoding="utf-8"?> declaration (Get-Content would read BOM-less
    # UTF-8 as ANSI under Windows PowerShell 5.1 and corrupt non-ASCII text).
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($manifest)
    $doc.Package.Identity.Publisher
}

$msbuild = Find-MSBuild
$publisher = Get-ManifestPublisher
Write-Host "MSBuild   : $msbuild"
Write-Host "Publisher : $publisher"
Write-Host "Platforms : $($Platforms -join ', ')"

# ---------------------------------------------------------------- test certificate
if ($CreateTestCert) {
    Write-Step "Creating self-signed test certificate ($publisher)"
    $cert = Get-ChildItem Cert:\CurrentUser\My |
            Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey } |
            Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate `
            -Type CodeSigningCert `
            -Subject $publisher `
            -KeyUsage DigitalSignature `
            -FriendlyName 'Notepad++ MSIX dev' `
            -CertStoreLocation Cert:\CurrentUser\My `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    }
    if (-not $PfxPassword) { $PfxPassword = 'npp' }
    $secure = ConvertTo-SecureString -String $PfxPassword -Force -AsPlainText
    Export-PfxCertificate -Cert $cert -FilePath $testPfx -Password $secure | Out-Null
    Export-Certificate   -Cert $cert -FilePath $testCer -Type CERT           | Out-Null
    Write-Host "Exported  : $testPfx"
    Write-Host "Thumbprint: $($cert.Thumbprint)"

    if ($TrustCert) {
        Write-Step 'Trusting certificate in LocalMachine\TrustedPeople'
        Import-Certificate -FilePath $testCer -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
        Write-Host 'Trusted (local sideload installs will now work).'
    }

    if (-not $PfxPath) { $PfxPath = $testPfx }
}

if ($Sign -and -not $PfxPath -and (Test-Path $testPfx)) { $PfxPath = $testPfx }
# The test certificate is exported with the default password 'npp'; keep -Sign usable without -PfxPassword.
if ($Sign -and $PfxPath -and -not $PfxPassword -and $PfxPath -eq $testPfx) { $PfxPassword = 'npp' }

# ---------------------------------------------------------------- build
Write-Step "Building notepadPlus.sln ($Configuration / $($Platforms -join ' + '))"
foreach ($platform in $Platforms) {
    $slnPlatform = switch ($platform) { 'x86' { 'Win32' } 'x64' { 'x64' } 'ARM64' { 'ARM64' } }
    Write-Host "-> $slnPlatform"
    & $msbuild $vcxSln "/p:Configuration=$Configuration" "/p:Platform=$slnPlatform" `
        @dpiArg `
        /m /nologo /verbosity:minimal /p:TrackFileAccess=false
    if ($LASTEXITCODE -ne 0) { throw "Solution build failed for platform $slnPlatform (exit $LASTEXITCODE)." }
}

Write-Step "Packaging (NppPackaging.wapproj)"
$bundlePlatforms = (@('x86','x64','ARM64') | Where-Object { $Platforms -contains $_ }) -join '|'
$appxBundle = if ($NoBundle) { 'Never' } else { 'Always' }
# -TargetPlatformVersion lets you build the package with a newer SDK (e.g. a Windows 11 SDK)
# without editing the project. Remember to bump MaxVersionTested in Package.appxmanifest too.
$sdkArg = @()
if ($TargetPlatformVersion) { $sdkArg = @("/p:NppTargetPlatformVersion=$TargetPlatformVersion") }
& $msbuild $wapproj `
    "/p:Configuration=$Configuration" `
    '/p:Platform=x86' `
    "/p:AppxBundle=$appxBundle" `
    "/p:AppxBundlePlatforms=$bundlePlatforms" `
    /p:AppxPackageSigningEnabled=false `
    @dpiArg `
    @sdkArg `
    /m /nologo /verbosity:minimal
if ($LASTEXITCODE -ne 0) { throw "Packaging failed (exit $LASTEXITCODE)." }

# ---------------------------------------------------------------- sign
$packages = @()
if (Test-Path $appPkgs) {
    $packages = Get-ChildItem $appPkgs -Recurse -Include '*.msixbundle','*.msix' -File |
                Sort-Object LastWriteTime -Descending
}
if (-not $packages) { throw "No package produced under $appPkgs" }

if ($Sign) {
    $signtool = Find-SignTool
    if (-not $signtool) { throw 'signtool.exe not found (Windows 10 SDK missing).' }
    if (-not $PfxPath    -or -not (Test-Path $PfxPath)) { throw "PFX not found: $PfxPath (use -CreateTestCert or -PfxPath)." }

    Write-Step "Signing with $signtool"
    foreach ($pkg in $packages) {
        $signArgs = @('sign', '/fd', 'SHA256', '/f', $PfxPath)
        if ($PfxPassword) { $signArgs += @('/p', $PfxPassword) }
        $signArgs += @('/d', 'Notepad++', $pkg.FullName)
        & $signtool @signArgs
        if ($LASTEXITCODE -ne 0) { throw "signtool failed on $($pkg.Name) (exit $LASTEXITCODE)." }
        Write-Host "Signed: $($pkg.Name)"
    }
}

# ---------------------------------------------------------------- report / install
Write-Step 'Result'
foreach ($pkg in $packages) {
    Write-Host ("{0,-46} {1,8:N1} MB  {2}" -f $pkg.Name, ($pkg.Length / 1MB), $pkg.FullName)
}

# ---------------------------------------------------------------- WACK (Windows App Certification Kit)
# Optional, but it is THE official validator and the only practical way to check the package
# against both Windows 10 and Windows 11 requirements from one machine. Run it once per OS.
if ($Verify) {
    $appcert = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\App Certification Kit\appcert.exe'
    if (-not (Test-Path $appcert)) { throw "appcert.exe not found (Windows App Certification Kit missing): $appcert" }
    if (-not $Sign) { Write-Warning 'WACK installs the package to test it; an unsigned package will fail to deploy.' }

    $target = $packages | Where-Object { $_.Extension -eq '.msixbundle' } | Select-Object -First 1
    if (-not $target) { $target = $packages[0] }
    $report = Join-Path $appPkgs 'wack-report.xml'

    Write-Step "WACK: $($target.Name)"
    & $appcert reset 2>&1 | Out-Null
    & $appcert test -appxpackagepath $target.FullName -reportoutputpath $report 2>&1 |
        Where-Object { $_ -match '任务执行结果|最终|已测试完' } | ForEach-Object { Write-Host "  $_" }

    if (-not (Test-Path $report)) { throw "WACK produced no report at $report" }
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($report)
    $tests = @($doc.SelectNodes('//REQUIREMENT/TEST'))
    $pass  = @($tests | Where-Object { $_.RESULT.InnerText -eq 'PASS' })
    $fail  = @($tests | Where-Object { $_.RESULT.InnerText -eq 'FAIL' })
    $warn  = @($tests | Where-Object { $_.RESULT.InnerText -eq 'WARNING' })

    Write-Host ("`nOverall: {0}   PASS={1}  FAIL={2}  WARNING={3}" -f $doc.REPORT.OVERALL_RESULT, $pass.Count, $fail.Count, $warn.Count)
    foreach ($t in ($fail + $warn)) {
        $optional = if ($t.OPTIONAL -eq 'TRUE') { 'optional' } else { 'required' }
        Write-Host ("  [{0}/{1}] {2}" -f $t.RESULT.InnerText, $optional, $t.NAME) -ForegroundColor Yellow
        $t.SelectNodes('MESSAGES/MESSAGE') | Select-Object -First 3 |
            ForEach-Object { Write-Host "      $($_.TEXT)" }
    }
    Write-Host "Report: $report"
    if ($fail.Count -gt 0) { Write-Warning "WACK reported $($fail.Count) failing test(s); see above." }
}

if ($Install) {
    $target = $packages | Where-Object { $_.Extension -eq '.msixbundle' } | Select-Object -First 1
    if (-not $target) { $target = $packages[0] }
    if (-not $Sign) { Write-Warning 'Installing an unsigned package will fail; use -Sign.' }
    Write-Step "Installing $($target.Name)"
    Add-AppxPackage -Path $target.FullName
    Write-Host 'Installed. Run "npp.exe" or launch Notepad++ from the Start menu.'
}
