Add-Type -AssemblyName System.Drawing

$srcPath = "C:\Users\xieyi\Downloads\IMG_20260705_202340.png"
$dstDir = "c:\Users\xieyi\Documents\trae_projects\qb 安卓\qbittorrent-android\apk-project\app\src\main\res"

$sizes = @{
    "mipmap-mdpi" = 48
    "mipmap-hdpi" = 72
    "mipmap-xhdpi" = 96
    "mipmap-xxhdpi" = 144
    "mipmap-xxxhdpi" = 192
}

function Create-RoundedRectIcon {
    param(
        [System.Drawing.Image]$srcImg,
        [int]$size,
        [float]$cornerRadiusRatio = 0.2
    )
    
    $bitmap = New-Object System.Drawing.Bitmap($size, $size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    
    # Create rounded rectangle path
    $cornerRadius = [int]($size * $cornerRadiusRatio)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.X, $rect.Y, $cornerRadius * 2, $cornerRadius * 2, 180, 90)
    $path.AddArc($rect.X + $rect.Width - $cornerRadius * 2, $rect.Y, $cornerRadius * 2, $cornerRadius * 2, 270, 90)
    $path.AddArc($rect.X + $rect.Width - $cornerRadius * 2, $rect.Y + $rect.Height - $cornerRadius * 2, $cornerRadius * 2, $cornerRadius * 2, 0, 90)
    $path.AddArc($rect.X, $rect.Y + $rect.Height - $cornerRadius * 2, $cornerRadius * 2, $cornerRadius * 2, 90, 90)
    $path.CloseFigure()
    
    # Clip to rounded rectangle
    $graphics.SetClip($path)
    
    # Draw image
    $graphics.DrawImage($srcImg, 0, 0, $size, $size)
    
    $graphics.Dispose()
    return $bitmap
}

$srcImg = [System.Drawing.Image]::FromFile($srcPath)

foreach ($dir in $sizes.Keys) {
    $size = $sizes[$dir]
    $outDir = Join-Path $dstDir $dir
    $outPath = Join-Path $outDir "ic_launcher.png"
    
    if (!(Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    
    $icon = Create-RoundedRectIcon -srcImg $srcImg -size $size
    $icon.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $icon.Dispose()
    
    Write-Host "Created: $outPath ($size x $size)"
}

$srcImg.Dispose()
Write-Host "Done! All icons created."
