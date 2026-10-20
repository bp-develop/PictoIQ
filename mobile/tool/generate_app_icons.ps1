Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$masterSize = 1024
$master = [System.Drawing.Bitmap]::new($masterSize, $masterSize)
$graphics = [System.Drawing.Graphics]::FromImage($master)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

function Fill-RoundedRectangle($graphics, $brush, [float]$x, [float]$y, [float]$width, [float]$height, [float]$radius) {
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $diameter = $radius * 2
    $path.AddArc($x, $y, $diameter, $diameter, 180, 90)
    $path.AddArc($x + $width - $diameter, $y, $diameter, $diameter, 270, 90)
    $path.AddArc($x + $width - $diameter, $y + $height - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($x, $y + $height - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    $graphics.FillPath($brush, $path)
    $path.Dispose()
}

$background = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Rectangle]::new(0, 0, $masterSize, $masterSize),
    [System.Drawing.Color]::FromArgb(21, 58, 54),
    [System.Drawing.Color]::FromArgb(84, 116, 76),
    45
)
$graphics.FillRectangle($background, 0, 0, $masterSize, $masterSize)
$background.Dispose()

$ambient = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(30, 164, 208, 162))
$graphics.FillEllipse($ambient, 666, -20, 380, 380)
$ambient.Dispose()

$shadow = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(45, 0, 20, 17))
Fill-RoundedRectangle $graphics $shadow 160 310 704 548 100
$shadow.Dispose()

$cream = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(244, 243, 233))
Fill-RoundedRectangle $graphics $cream 365 199 294 178 50
Fill-RoundedRectangle $graphics $cream 160 286 704 548 100
$cream.Dispose()

$lensOuter = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(24, 63, 58))
$lensRing = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(134, 198, 164))
$lensInner = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.Rectangle]::new(378, 420, 268, 268),
    [System.Drawing.Color]::FromArgb(70, 123, 104),
    [System.Drawing.Color]::FromArgb(23, 62, 58),
    45
)
$lensCenter = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(38, 79, 73))
$highlight = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(201, 231, 189))
$graphics.FillEllipse($lensOuter, 308, 350, 408, 408)
$graphics.FillEllipse($lensRing, 342, 384, 340, 340)
$graphics.FillEllipse($lensInner, 379, 421, 266, 266)
$graphics.FillEllipse($lensCenter, 438, 480, 148, 148)
$graphics.FillEllipse($highlight, 459, 499, 44, 44)
$lensOuter.Dispose()
$lensRing.Dispose()
$lensInner.Dispose()
$lensCenter.Dispose()
$highlight.Dispose()

$sparkleBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 212, 121))
$sparklePoints = [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(766, 153), [System.Drawing.PointF]::new(788, 220),
    [System.Drawing.PointF]::new(855, 242), [System.Drawing.PointF]::new(788, 264),
    [System.Drawing.PointF]::new(766, 331), [System.Drawing.PointF]::new(744, 264),
    [System.Drawing.PointF]::new(677, 242), [System.Drawing.PointF]::new(744, 220)
)
$graphics.FillPolygon($sparkleBrush, $sparklePoints)
$graphics.FillEllipse($sparkleBrush, 844, 337, 24, 24)
$sparkleBrush.Dispose()

$badge = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(237, 156, 114))
$graphics.FillEllipse($badge, 671, 646, 184, 184)
$badge.Dispose()
$checkPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 250, 240), 25)
$checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$graphics.DrawLines($checkPen, [System.Drawing.PointF[]]@(
    [System.Drawing.PointF]::new(719, 737),
    [System.Drawing.PointF]::new(749, 766),
    [System.Drawing.PointF]::new(810, 696)
))
$checkPen.Dispose()

$graphics.Dispose()

$brandDirectory = Join-Path $root 'assets/brand'
New-Item -ItemType Directory -Force -Path $brandDirectory | Out-Null
$master.Save((Join-Path $brandDirectory 'pictoiq-icon.png'), [System.Drawing.Imaging.ImageFormat]::Png)

function Save-Icon($source, $destination, [int]$size) {
    $bitmap = [System.Drawing.Bitmap]::new($size, $size)
    $canvas = [System.Drawing.Graphics]::FromImage($bitmap)
    $canvas.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $canvas.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $canvas.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $canvas.DrawImage($source, 0, 0, $size, $size)
    $canvas.Dispose()
    $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$androidSizes = @{ 'mipmap-mdpi' = 48; 'mipmap-hdpi' = 72; 'mipmap-xhdpi' = 96; 'mipmap-xxhdpi' = 144; 'mipmap-xxxhdpi' = 192 }
foreach ($entry in $androidSizes.GetEnumerator()) {
    $directory = Join-Path $root "android/app/src/main/res/$($entry.Key)"
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Save-Icon $master (Join-Path $directory 'ic_launcher.png') $entry.Value
}

$iosDirectory = Join-Path $root 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
$contentsPath = Join-Path $iosDirectory 'Contents.json'
$contents = Get-Content -Raw $contentsPath | ConvertFrom-Json
foreach ($entry in $contents.images) {
    $points = [double]($entry.size.Split('x')[0])
    $scale = [double]($entry.scale.TrimEnd('x'))
    $pixels = [int][Math]::Round($points * $scale)
    Save-Icon $master (Join-Path $iosDirectory $entry.filename) $pixels
}

$master.Dispose()
Write-Output 'Generated PictoIQ brand master, Android launcher icons, and iOS app icons.'
