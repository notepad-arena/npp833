#Requires -Version 5.1
<#
    Generates the MSIX PNG assets from the in-repo icon (PowerEditor\src\icons\chameleon.ico).
    Only needed when the icon changes; the generated PNGs are committed under Packaging\Assets.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\make-assets.ps1

    NOTE: keep this file pure ASCII - Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI.
#>
[CmdletBinding()]
param(
    [string] $SourceIcon,
    [string] $OutDir,
    [string] $TileBackground = '#FF1E1E1E'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $SourceIcon) { $SourceIcon = Join-Path $PSScriptRoot '..\..\misc\chameleon\chameleon-pencil-200.png' }
if (-not $OutDir)     { $OutDir     = Join-Path $PSScriptRoot 'Assets' }

if (-not (Test-Path $SourceIcon)) { throw "Source icon not found: $SourceIcon" }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Accept either a .png or a .ico (largest frame that System.Drawing can decode)
$icon = $null
if ($SourceIcon.ToLowerInvariant().EndsWith('.ico')) {
    foreach ($size in 256, 128, 96, 64, 48) {
        try {
            $icon   = New-Object System.Drawing.Icon($SourceIcon, $size, $size)
            $source = $icon.ToBitmap()
            break
        } catch {
            $icon = $null
        }
    }
    if (-not $source) { throw "Could not decode any frame of $SourceIcon" }
} else {
    $source = New-Object System.Drawing.Bitmap($SourceIcon)
}
Write-Host ("Source: {0} ({1}x{2})" -f $SourceIcon, $source.Width, $source.Height)

function New-Asset {
    param(
        [int]    $Width,
        [int]    $Height,
        [string] $FileName,
        [string] $Background = 'Transparent',
        [double] $Scale = 0.78
    )

    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        if ($Background -eq 'Transparent') {
            $g.Clear([System.Drawing.Color]::Transparent)
        } else {
            $g.Clear([System.Drawing.ColorTranslator]::FromHtml($Background))
        }

        # Scale proportionally and center
        $max   = [Math]::Min($Width, $Height) * $Scale
        $ratio = [Math]::Min($max / $source.Width, $max / $source.Height)
        $w = [int]($source.Width * $ratio)
        $h = [int]($source.Height * $ratio)
        $x = [int](($Width - $w) / 2)
        $y = [int](($Height - $h) / 2)

        $g.DrawImage($source, (New-Object System.Drawing.Rectangle($x, $y, $w, $h)))
    }
    finally {
        $g.Dispose()
    }

    $path = Join-Path $OutDir $FileName
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  {0,-58} {1}x{2}" -f $FileName, $Width, $Height)
}

Write-Host "Generating MSIX assets into $OutDir"

# Required sizes referenced by Package.appxmanifest at default (100%) scale
New-Asset -Width 50  -Height 50  -FileName 'StoreLogo.png'         -Background 'Transparent'
New-Asset -Width 44  -Height 44  -FileName 'Square44x44Logo.png'   -Background 'Transparent' -Scale 0.92
New-Asset -Width 150 -Height 150 -FileName 'Square150x150Logo.png' -Background $TileBackground
New-Asset -Width 310 -Height 150 -FileName 'Wide310x150Logo.png'   -Background $TileBackground
New-Asset -Width 620 -Height 300 -FileName 'SplashScreen.png'      -Background $TileBackground -Scale 0.6

# Optional taskbar / start menu variants (unplated)
New-Asset -Width 16  -Height 16  -FileName 'Square44x44Logo.targetsize-16_altform-unplated.png'  -Background 'Transparent' -Scale 1.0
New-Asset -Width 24  -Height 24  -FileName 'Square44x44Logo.targetsize-24_altform-unplated.png'  -Background 'Transparent' -Scale 1.0
New-Asset -Width 48  -Height 48  -FileName 'Square44x44Logo.targetsize-48_altform-unplated.png'  -Background 'Transparent' -Scale 0.95
New-Asset -Width 256 -Height 256 -FileName 'Square44x44Logo.targetsize-256_altform-unplated.png' -Background 'Transparent' -Scale 0.92

$source.Dispose()
if ($icon) { $icon.Dispose() }
Write-Host 'Done.'
