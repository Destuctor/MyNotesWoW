<#
.SYNOPSIS
    Converts an image to the uncompressed 32-bit TGA that WoW will actually load,
    with optional cropping, power-of-two padding and desaturation.

.DESCRIPTION
    WoW refuses PNG outright and wants TGA uncompressed, 24/32-bit, with
    power-of-two dimensions. The addon's own icon had to be re-exported by hand
    for exactly this reason; this script is so that never has to happen again.

    TGA is written by hand rather than through an encoder: .NET ships no TGA
    encoder, but the uncompressed form is just an 18-byte header followed by
    bottom-up BGRA rows.

    -Desaturate is the important one for UI art. A greyscale texture can be
    tinted to any colour at runtime with SetVertexColor, so one file serves
    every palette. Art exported in its final colour is locked to that colour.

.EXAMPLE
    # Whole image, greyscale, padded to the next power of two
    .\ConvertToTGA.ps1 -In mockup.png -Out cap.tga -Desaturate

.EXAMPLE
    # Cut one 120x110 piece out at (20,85), pad to 128x128, greyscale
    .\ConvertToTGA.ps1 -In mockup.png -Out cap.tga -X 20 -Y 85 -W 120 -H 110 -Pad 128 -Desaturate

.EXAMPLE
    # Just report the source dimensions, so crop numbers can be worked out
    .\ConvertToTGA.ps1 -In mockup.png -Info
#>
param(
    [Parameter(Mandatory = $true)][string]$In,
    [string]$Out,
    [int]$X = 0,
    [int]$Y = 0,
    [int]$W = 0,
    [int]$H = 0,
    [int]$Pad = 0,
    [switch]$Desaturate,
    [switch]$Info,
    # Derives alpha from brightness, for art rendered onto a dark background
    # with no transparency of its own. Anything at or below -KeyLow becomes
    # fully transparent, at or above -KeyHigh fully opaque, with a linear ramp
    # between. This is a key, not a real cut-out: dark recesses inside the
    # ornament go partly transparent too, so prefer a source with a real alpha
    # channel whenever one exists.
    [switch]$AlphaFromLuma,
    [int]$KeyLow = 18,
    [int]$KeyHigh = 60
)

Add-Type -AssemblyName System.Drawing

if (-not (Test-Path $In)) {
    Write-Error "Input not found: $In"
    exit 1
}

$source = [System.Drawing.Image]::FromFile((Resolve-Path $In))
Write-Output ("Source: {0} x {1}  ({2})" -f $source.Width, $source.Height, $source.PixelFormat)

if ($Info) {
    $source.Dispose()
    exit 0
}

if (-not $Out) {
    Write-Error "-Out is required unless -Info is given."
    $source.Dispose()
    exit 1
}

# Crop region defaults to the whole image.
if ($W -le 0) { $W = $source.Width - $X }
if ($H -le 0) { $H = $source.Height - $Y }

if ($X -lt 0 -or $Y -lt 0 -or ($X + $W) -gt $source.Width -or ($Y + $H) -gt $source.Height) {
    Write-Error ("Crop {0},{1} {2}x{3} falls outside the {4}x{5} source." -f $X, $Y, $W, $H, $source.Width, $source.Height)
    $source.Dispose()
    exit 1
}

# Next power of two, unless one was given explicitly.
function Get-NextPowerOfTwo([int]$value) {
    $p = 1
    while ($p -lt $value) { $p *= 2 }
    return $p
}

if ($Pad -gt 0) {
    $outW = $Pad
    $outH = $Pad
} else {
    $outW = Get-NextPowerOfTwo $W
    $outH = Get-NextPowerOfTwo $H
}

# The crop is drawn into the top-left of a transparent power-of-two canvas
# rather than stretched to fill it, so nothing is distorted. The padding is
# fully transparent, so it costs nothing visually - the UV coords below say
# which part of the file is real.
$canvas = New-Object System.Drawing.Bitmap($outW, $outH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($canvas)
$graphics.Clear([System.Drawing.Color]::Transparent)
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

$destRect = New-Object System.Drawing.Rectangle(0, 0, $W, $H)
$srcRect = New-Object System.Drawing.Rectangle($X, $Y, $W, $H)
$graphics.DrawImage($source, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$graphics.Dispose()
$source.Dispose()

# Read every pixel once, into a BGRA byte array in TGA's bottom-up row order.
$bytes = New-Object byte[] ($outW * $outH * 4)
$index = 0

for ($row = $outH - 1; $row -ge 0; $row--) {
    for ($col = 0; $col -lt $outW; $col++) {
        $pixel = $canvas.GetPixel($col, $row)

        $b = $pixel.B
        $g = $pixel.G
        $r = $pixel.R

        if ($Desaturate) {
            # Rec. 601 luma. A flat average washes out the metallic contrast
            # that makes a bevel read as a bevel.
            $luma = [int](0.299 * $pixel.R + 0.587 * $pixel.G + 0.114 * $pixel.B)
            if ($luma -gt 255) { $luma = 255 }
            $b = $luma; $g = $luma; $r = $luma
        }

        $a = $pixel.A

        if ($AlphaFromLuma) {
            $l = 0.299 * $pixel.R + 0.587 * $pixel.G + 0.114 * $pixel.B

            if ($l -le $KeyLow) {
                $a = 0
            } elseif ($l -ge $KeyHigh) {
                $a = 255
            } else {
                $a = [int](255 * (($l - $KeyLow) / ($KeyHigh - $KeyLow)))
            }

            # Padding must stay fully transparent regardless of the key: the
            # source pixel there is transparent black, whose luma is 0 anyway,
            # but an opaque-black source would otherwise key to visible.
            if ($pixel.A -eq 0) { $a = 0 }
        }

        $bytes[$index]     = $b
        $bytes[$index + 1] = $g
        $bytes[$index + 2] = $r
        $bytes[$index + 3] = $a
        $index += 4
    }
}

$canvas.Dispose()

# 18-byte header: uncompressed true-colour, 32 bits, 8 alpha bits.
$header = New-Object byte[] 18
$header[2] = 2                                   # image type: uncompressed RGB
$header[12] = [byte]($outW -band 0xFF)
$header[13] = [byte](($outW -shr 8) -band 0xFF)
$header[14] = [byte]($outH -band 0xFF)
$header[15] = [byte](($outH -shr 8) -band 0xFF)
$header[16] = 32                                 # bits per pixel
$header[17] = 8                                  # alpha depth; origin bottom-left

$outPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Out))
$stream = [System.IO.File]::Create($outPath)
$stream.Write($header, 0, $header.Length)
$stream.Write($bytes, 0, $bytes.Length)
$stream.Close()

Write-Output ("Wrote {0}  ({1} x {2}, 32-bit uncompressed TGA, {3:N0} bytes)" -f $Out, $outW, $outH, (Get-Item $outPath).Length)

if ($W -ne $outW -or $H -ne $outH) {
    # The Lua side needs these to show only the real part of the padded file.
    $u = $W / $outW
    $v = $H / $outH
    Write-Output ("Art occupies the top-left {0}x{1}. In Lua:" -f $W, $H)
    Write-Output ("    texture:SetTexCoord(0, {0:N6}, 0, {1:N6})" -f $u, $v)
}
