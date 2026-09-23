<#
    make-icon.ps1  -  Rebuild eye.ico from eye.svg.

    Microsoft Edge (built into Windows 10/11) renders the SVG at each icon size,
    and the results are packed into one .ico file for the tray and Awake.exe.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File make-icon.ps1
          ... -Svg my-icon.svg -Out my-icon.ico     use your own design
#>
param([string]$Svg = 'eye.svg', [string]$Out = 'eye.ico')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Set-Location $PSScriptRoot

$svgPath = (Resolve-Path $Svg).ProviderPath
$outPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Out))
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge is needed to render the SVG, but it was not found.' }

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$tmp = Join-Path $env:TEMP ('make-icon-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$frames = New-Object System.Collections.ArrayList

try {
    foreach ($s in $sizes) {
        # Render the SVG at exactly $s x $s pixels on a transparent page.
        $html = Join-Path $tmp "$s.html"
        $png  = Join-Path $tmp "$s.png"
        "<html><body style='margin:0;background:transparent'><img src='$(([Uri]$svgPath).AbsoluteUri)' width='$s' height='$s' style='display:block'></body></html>" |
            Set-Content -Path $html -Encoding UTF8
        $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
                      '--default-background-color=00000000', "--user-data-dir=`"$tmp\profile`"",
                      '--window-size=400,400', "--screenshot=`"$png`"", ([Uri]$html).AbsoluteUri)
        Start-Process -FilePath $edge -ArgumentList $edgeArgs -Wait -WindowStyle Hidden
        for ($i = 0; $i -lt 50 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 200 }
        if (-not (Test-Path $png)) { throw "Edge did not render the $s px image." }

        $page = [System.Drawing.Bitmap]::FromFile($png)
        try {
            $frame = $page.Clone((New-Object System.Drawing.Rectangle 0, 0, $s, $s), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        } finally { $page.Dispose() }
        [void]$frames.Add($frame)
        Write-Host "  rendered $s x $s"
    }

    # Encode each frame: 256 px as PNG, smaller sizes as 32-bit BMP (the most compatible form).
    $images = foreach ($bmp in $frames) {
        $s = $bmp.Width
        if ($s -ge 256) {
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            , $ms.ToArray()
            continue
        }
        $rect = New-Object System.Drawing.Rectangle 0, 0, $s, $s
        $data = $bmp.LockBits($rect, 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $pixels = New-Object byte[] ($data.Stride * $s)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
        $bmp.UnlockBits($data)

        $maskRow = [int]([Math]::Ceiling($s / 32.0) * 4)
        $ms = New-Object System.IO.MemoryStream
        $w  = New-Object System.IO.BinaryWriter $ms
        # BITMAPINFOHEADER (height is doubled: colour rows + AND-mask rows)
        $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
        $w.Write([int]0); $w.Write([int]($s * $s * 4 + $maskRow * $s)); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
        for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($pixels, $y * $data.Stride, $s * 4) }   # bottom-up BGRA
        $w.Write((New-Object byte[] ($maskRow * $s)))                                         # AND mask (alpha is used instead)
        $w.Flush()
        , $ms.ToArray()
    }

    # ICONDIR + ICONDIRENTRY table + image data
    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter $ms
    $w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    for ($i = 0; $i -lt $frames.Count; $i++) {
        $s = $frames[$i].Width
        $dim = if ($s -ge 256) { 0 } else { $s }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$images[$i].Length); $w.Write([int]$offset)
        $offset += $images[$i].Length
    }
    foreach ($img in $images) { $w.Write($img) }
    $w.Flush()
    [IO.File]::WriteAllBytes($outPath, $ms.ToArray())
    Write-Host "Saved $outPath" -ForegroundColor Green
}
finally {
    foreach ($f in $frames) { $f.Dispose() }
    Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
