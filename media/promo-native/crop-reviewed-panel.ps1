param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
try {
    if ($X -lt 0 -or $Y -lt 0 -or $Width -le 0 -or $Height -le 0 -or
        ($X + $Width) -gt $image.Width -or ($Y + $Height) -gt $image.Height) {
        throw 'Panel crop extends beyond the source image.'
    }
    $crop = [System.Drawing.Bitmap]::new($Width, $Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($crop)
        try {
            $graphics.DrawImage($image, [System.Drawing.Rectangle]::new(0, 0, $Width, $Height),
                [System.Drawing.Rectangle]::new($X, $Y, $Width, $Height),
                [System.Drawing.GraphicsUnit]::Pixel)
        }
        finally { $graphics.Dispose() }
        $crop.Save([System.IO.Path]::GetFullPath($Destination), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $crop.Dispose() }
}
finally { $image.Dispose() }
