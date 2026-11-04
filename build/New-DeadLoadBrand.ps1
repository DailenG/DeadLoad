<#
    .SYNOPSIS
        Writes the DeadLoad brand assets (mark SVGs, lockups, favicon, PNG sizes, multi-size ICO)
        from one set of polygon coordinates (docs/design/DEADLOAD_DESIGN_SYSTEM.md section 5,
        docs/design/IMPLEMENTATION-PLAN.md decision 8).

    .DESCRIPTION
        Geometry. The mark is three stacked structural slabs drawn in 2:1 dimetric projection
        (every receding edge rises one unit per two across). 2:1 is used instead of true
        isometric because its edges land on whole pixels at small sizes, so the hand-tuned
        bitmaps below and the vector drawing are the same shape.

        All vector coordinates live in a 256 x 256 design space, in $Mark:
          - The mark box is x 32..224, y 32..224 (192 x 192, a 32-unit margin). Its vertical
            outer edges sit on multiples of 32, so they fall on pixel boundaries at 16, 32, 48,
            64 and 256 px.
          - TopFace: the top plate, a rhombus 192 wide and 96 tall: (128,32) (224,80) (128,128)
            (32,80).
          - Opening: the one negative-space opening, a rhombus in the same proportion cut out of
            the top plate (the slab penetration, read as load removed). It is a real hole in both
            the colored and the one-color variants.
          - Under: the visible sides of the top slab (24 units thick), extended up beneath the
            top plate (but clear of the opening) so the two colors overlap instead of meeting at
            an anti-aliased seam.
          - Slab1: the top slab as one hexagon (the one-color silhouette uses it, with Opening).
          - Slab2, Slab3: the lower slabs, whose top faces are hidden, so only their sides show:
            chevron bands 24 thick, each 36 below the one above (a 12-unit gap, the "aligned
            edges" of the stack).
        Colors come from design/tokens.json: Accent (the top plate) and Body (the slab sides).
        Primary: navy body, blue top plate (light backgrounds). OnDark: near-white body, light
        blue top plate. Mono: one color, one silhouette. No gradients, no text in the icon.

        App icon (PNG sizes and ICO). The ICO has no color-scheme switch, and the taskbar and
        tray may be light or dark, so the app icon is a navy rounded tile carrying a white mark
        with a light blue top plate (the mood board's app icon): it reads on both. On the tile
        the mark is scaled by $TileScale (5/6) about the center, so its outer edges are
        x 48..208, again whole pixels at 16, 32, 48, 64 and 256 px.

        Small sizes. Anti-aliased 2:1 edges and 12-unit gaps blur below about 40 px, so 16, 20,
        24 and 32 px use hand-tuned, pixel-aligned bitmaps ($PixelMarks): the same stack (top
        plate, slab sides, two bands, one opening) with whole-pixel bands and one-pixel gaps.
        Mark16 (16 x 16) is also deadload-mark-16.svg and favicon.svg and sits in the 24 px
        tile; Mark12 (12 x 14) is the mark inside the 16 and 20 px tiles; Mark20 (20 x 21) is
        the mark inside the 32 px tile. Edit them as pictures: 'A' accent, 'B' body,
        '.' empty.

        Outputs (relative to the repository root):
          design/brand/deadload-mark.svg, -mark-mono.svg, -mark-onDark.svg, -mark-16.svg,
          deadload-lockup.svg, -lockup-onDark.svg, favicon.svg,
          design/brand/png/deadload-<size>.png (16 20 24 32 40 48 64 128 256, the app icon),
          design/brand/deadload.ico (16 20 24 32 40 48 64 256; 256 PNG-compressed, the rest
          32-bit DIB), copied to src/tray/DeadLoad.ico, and site/assets/brand/ (every SVG plus
          deadload-32.png, deadload-180.png (full-bleed square for Apple touch icons),
          deadload-192.png and deadload-512.png).
        The lockups set the wordmark in <text> with the web font stack from tokens.json, so
        their exact letterforms depend on the fonts installed where they are shown; textLength
        fixes the wordmark's width so the layout and clear space hold with any fallback font.

        Deterministic and idempotent: the same inputs give byte-identical files, and a file is
        rewritten only when its bytes change. Returns one summary object; prose goes to
        Write-Verbose. Windows PowerShell 5.1 and PowerShell 7.

    .PARAMETER RepoRoot
        Repository root (default: the parent of this script's folder).

    .PARAMETER ContactSheetPath
        Also write a review sheet: every app icon size, enlarged small sizes and the bare marks,
        on light (#F8FAFC) and dark (#0F172A) panels.

    .EXAMPLE
        pwsh -NoProfile -File build/New-DeadLoadBrand.ps1 -ContactSheetPath out/brand-check.png
#>
[CmdletBinding()]
param
(
    [string]$RepoRoot,
    [string]$ContactSheetPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath
Add-Type -AssemblyName System.Drawing

$inv = [System.Globalization.CultureInfo]::InvariantCulture

# --- Geometry (256 x 256 design space) -------------------------------------------------------

$Mark = [ordered]@{
    TopFace = @(@(128, 32), @(224, 80), @(128, 128), @(32, 80))
    Opening = @(@(128, 62), @(164, 80), @(128, 98), @(92, 80))
    Under   = @(@(32, 80), @(128, 116), @(224, 80), @(224, 104), @(128, 152), @(32, 104))
    Slab1   = @(@(128, 32), @(224, 80), @(224, 104), @(128, 152), @(32, 104), @(32, 80))
    Slab2   = @(@(32, 116), @(128, 164), @(224, 116), @(224, 140), @(128, 188), @(32, 140))
    Slab3   = @(@(32, 152), @(128, 200), @(224, 152), @(224, 176), @(128, 224), @(32, 176))
}

# Each layer is filled even-odd, so a ring inside another ring is a hole.
$TwoToneLayers = @(
    @{ Role = 'Body'; Rings = @($Mark.Under, $Mark.Slab2, $Mark.Slab3) },
    @{ Role = 'Accent'; Rings = @($Mark.TopFace, $Mark.Opening) }
)
$MonoLayers = @(
    @{ Role = 'Body'; Rings = @($Mark.Slab1, $Mark.Opening, $Mark.Slab2, $Mark.Slab3) }
)

$TileScale = 5.0 / 6.0
$TileRadius = 40

# Hand-tuned pixel marks: 'A' accent (top plate), 'B' body (slab sides), '.' empty.
$PixelMarks = @{
    Mark16 = @(
        '......AAAA......',
        '....AAAAAAAA....',
        '..AAAAAAAAAAAA..',
        'AAAAAA....AAAAAA',
        'AAAAAA....AAAAAA',
        'BBAAAAAAAAAAAABB',
        'BBBBAAAAAAAABBBB',
        '..BBBBAAAABBBB..',
        'BB..BBBBBBBB..BB',
        'BBBB..BBBB..BBBB',
        '..BBBB....BBBB..',
        'BB..BBBBBBBB..BB',
        'BBBB..BBBB..BBBB',
        '..BBBB....BBBB..',
        '....BBBBBBBB....',
        '......BBBB......'
    )
    Mark12 = @(
        '....AAAA....',
        '..AAAAAAAA..',
        'AAAA....AAAA',
        'AAAA....AAAA',
        'BBAAAAAAAABB',
        'BBBBAAAABBBB',
        '..BBBBBBBB..',
        'BB..BBBB..BB',
        'BBBB....BBBB',
        '..BBBBBBBB..',
        'BB..BBBB..BB',
        'BBBB....BBBB',
        '..BBBBBBBB..',
        '....BBBB....'
    )
    Mark20 = @(
        '........AAAA........',
        '......AAAAAAAA......',
        '....AAAAAAAAAAAA....',
        '..AAAAAA....AAAAAA..',
        'AAAAAA........AAAAAA',
        'AAAAAA........AAAAAA',
        'BBAAAAAA....AAAAAABB',
        'BBBBAAAAAAAAAAAABBBB',
        'BBBBBBAAAAAAAABBBBBB',
        '..BBBBBBAAAABBBBBB..',
        'BB..BBBBBBBBBBBB..BB',
        'BBBB..BBBBBBBB..BBBB',
        'BBBBBB..BBBB..BBBBBB',
        '..BBBBBB....BBBBBB..',
        'BB..BBBBBBBBBBBB..BB',
        'BBBB..BBBBBBBB..BBBB',
        'BBBBBB..BBBB..BBBBBB',
        '..BBBBBB....BBBBBB..',
        '....BBBBBBBBBBBB....',
        '......BBBBBBBB......',
        '........BBBB........'
    )
    Mark24 = @(
        '..........AAAA..........',
        '........AAAAAAAA........',
        '......AAAAAAAAAAAA......',
        '....AAAAAAAAAAAAAAAA....',
        '..AAAAAAAA....AAAAAAAA..',
        'AAAAAAAA........AAAAAAAA',
        'AAAAAAAA........AAAAAAAA',
        'BBAAAAAAAA....AAAAAAAABB',
        'BBBBAAAAAAAAAAAAAAAABBBB',
        'BBBBBBAAAAAAAAAAAABBBBBB',
        '..BBBBBBAAAAAAAABBBBBB..',
        '....BBBBBBAAAABBBBBB....',
        'BB....BBBBBBBBBBBB....BB',
        'BBBB....BBBBBBBB....BBBB',
        'BBBBBB....BBBB....BBBBBB',
        '..BBBBBB........BBBBBB..',
        '....BBBBBB....BBBBBB....',
        'BB....BBBBBBBBBBBB....BB',
        'BBBB....BBBBBBBB....BBBB',
        'BBBBBB....BBBB....BBBBBB',
        '..BBBBBB........BBBBBB..',
        '....BBBBBB....BBBBBB....',
        '......BBBBBBBBBBBB......',
        '........BBBBBBBB........',
        '..........BBBB..........'
    )
    Mark28 = @(
        '............AAAA............',
        '..........AAAAAAAA..........',
        '........AAAAAAAAAAAA........',
        '......AAAAAAAAAAAAAAAA......',
        '....AAAAAAAAAAAAAAAAAAAA....',
        '..AAAAAAAAA......AAAAAAAAA..',
        'AAAAAAAAA..........AAAAAAAAA',
        'AAAAAAAAA..........AAAAAAAAA',
        'BBAAAAAAAAA......AAAAAAAAABB',
        'BBBBAAAAAAAAAAAAAAAAAAAABBBB',
        'BBBBBBAAAAAAAAAAAAAAAABBBBBB',
        'BBBBBBBBAAAAAAAAAAAABBBBBBBB',
        '..BBBBBBBBAAAAAAAABBBBBBBB..',
        '....BBBBBBBBAAAABBBBBBBB....',
        'BB....BBBBBBBBBBBBBBBB....BB',
        'BBBB....BBBBBBBBBBBB....BBBB',
        'BBBBBB....BBBBBBBB....BBBBBB',
        'BBBBBBBB....BBBB....BBBBBBBB',
        '..BBBBBBBB........BBBBBBBB..',
        '....BBBBBBBB....BBBBBBBB....',
        'BB....BBBBBBBBBBBBBBBB....BB',
        'BBBB....BBBBBBBBBBBB....BBBB',
        'BBBBBB....BBBBBBBB....BBBBBB',
        'BBBBBBBB....BBBB....BBBBBBBB',
        '..BBBBBBBB........BBBBBBBB..',
        '....BBBBBBBB....BBBBBBBB....',
        '......BBBBBBBBBBBBBBBB......',
        '........BBBBBBBBBBBB........',
        '..........BBBBBBBB..........',
        '............BBBB............'
    )
}

# Which sizes of which variant are drawn from a pixel mark, and where it sits.
$PixelFrames = @{
    'Tile-16'    = @{ Mark = 'Mark12'; X = 2; Y = 1 }
    'Tile-20'    = @{ Mark = 'Mark16'; X = 2; Y = 2 }
    'Tile-24'    = @{ Mark = 'Mark16'; X = 4; Y = 4 }
    'Tile-32'    = @{ Mark = 'Mark20'; X = 6; Y = 5 }
    'Tile-40'    = @{ Mark = 'Mark24'; X = 8; Y = 7 }
    'Tile-48'    = @{ Mark = 'Mark28'; X = 10; Y = 9 }
    'Primary-16' = @{ Mark = 'Mark16'; X = 0; Y = 0 }
    'OnDark-16'  = @{ Mark = 'Mark16'; X = 0; Y = 0 }
    'Mono-16'    = @{ Mark = 'Mark16'; X = 0; Y = 0 }
}

$AppIconSizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$IcoSizes = @(16, 20, 24, 32, 40, 48, 64, 256)

# --- Tokens ----------------------------------------------------------------------------------

$tokensPath = Join-Path $RepoRoot 'design/tokens.json'
$tokens = Get-Content -LiteralPath $tokensPath -Raw | ConvertFrom-Json
$light = $tokens.color.light
$dark = $tokens.color.dark
$Colors = @{
    Navy       = $light.brandNavy
    Blue       = $light.brandBlue
    BlueOnDark = $dark.brandBlue
    TextOnDark = $dark.textPrimary
    White      = $light.card
    Canvas     = $light.canvas
    CanvasDark = $dark.canvas
}
$fontStack = (@($tokens.font.web) | ForEach-Object {
        if ($_ -match '\s') { "'" + $_ + "'" } else { $_ }
    }) -join ', '
$fontWeight = [int]$tokens.font.weight.semibold

$Variants = @{
    Primary = @{ Background = $null; Body = $Colors.Navy; Accent = $Colors.Blue; Scale = 1.0; Mono = $false }
    OnDark  = @{ Background = $null; Body = $Colors.TextOnDark; Accent = $Colors.BlueOnDark; Scale = 1.0; Mono = $false }
    Mono    = @{ Background = $null; Body = $Colors.Navy; Accent = $Colors.Navy; Scale = 1.0; Mono = $true }
    Tile    = @{ Background = 'Tile'; Body = $Colors.White; Accent = $Colors.BlueOnDark; Scale = $TileScale; Mono = $false }
    Square  = @{ Background = 'Square'; Body = $Colors.White; Accent = $Colors.BlueOnDark; Scale = $TileScale; Mono = $false }
}

# --- Helpers ---------------------------------------------------------------------------------

function Format-Number([double]$Value)
{
    return $Value.ToString('0.###', $inv)
}

function Convert-Point([double[]]$Point, [double]$Scale)
{
    # Scale about the center of the design space.
    return @((128 + ($Point[0] - 128) * $Scale), (128 + ($Point[1] - 128) * $Scale))
}

function Get-PathData($Rings, [double]$Scale)
{
    $parts = foreach ($ring in $Rings)
    {
        $pts = foreach ($p in $ring)
        {
            $q = Convert-Point -Point $p -Scale $Scale
            (Format-Number $q[0]) + ' ' + (Format-Number $q[1])
        }
        'M' + ($pts -join ' L') + ' Z'
    }
    return ($parts -join ' ')
}

function Get-PixelPathData([string[]]$Rows, [char]$Want)
{
    # One rectangle per horizontal run, so the 16 px silhouette stays on the pixel grid.
    $parts = New-Object System.Collections.Generic.List[string]
    for ($y = 0; $y -lt $Rows.Count; $y++)
    {
        $row = $Rows[$y]
        $x = 0
        while ($x -lt $row.Length)
        {
            if ($row[$x] -eq $Want)
            {
                $start = $x
                while ($x -lt $row.Length -and $row[$x] -eq $Want) { $x++ }
                $parts.Add(('M{0} {1}h{2}v1h-{2}Z' -f $start, $y, ($x - $start)))
            }
            else { $x++ }
        }
    }
    return ($parts -join '')
}

function Get-Bytes([string]$Text)
{
    # The leading comma keeps the array whole; PowerShell would otherwise unroll it byte by byte.
    return , (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text.Replace("`r`n", "`n"))
}

$script:written = New-Object System.Collections.Generic.List[string]
$script:unchanged = 0

function Write-Asset([string]$RelativePath, [byte[]]$Bytes)
{
    $path = Join-Path $RepoRoot $RelativePath
    $dir = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path -LiteralPath $path)
    {
        $old = [System.IO.File]::ReadAllBytes($path)
        if ($old.Length -eq $Bytes.Length -and [Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($Bytes))
        {
            $script:unchanged++
            return
        }
    }
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    $script:written.Add($RelativePath)
    Write-Verbose ('Wrote ' + $RelativePath)
}

function ConvertTo-Color([string]$Hex)
{
    $h = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(255,
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function New-RoundedRectPath([float]$X, [float]$Y, [float]$Width, [float]$Height, [float]$Radius)
{
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $Radius
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $Width - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $Width - $d), ($Y + $Height - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $Height - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function New-Canvas([int]$Width, [int]$Height)
{
    $bmp = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ Bitmap = $bmp; Graphics = $g }
}

function New-MarkBitmap([int]$Size, [string]$Variant)
{
    $v = $Variants[$Variant]
    $canvas = New-Canvas -Width $Size -Height $Size
    $bmp = $canvas.Bitmap
    $g = $canvas.Graphics
    $f = $Size / 256.0
    try
    {
        if ($v.Background)
        {
            $brush = New-Object System.Drawing.SolidBrush(ConvertTo-Color $Colors.Navy)
            if ($v.Background -eq 'Tile')
            {
                $path = New-RoundedRectPath -X 0 -Y 0 -Width $Size -Height $Size -Radius ($TileRadius * $f)
                $g.FillPath($brush, $path)
                $path.Dispose()
            }
            else { $g.FillRectangle($brush, 0, 0, $Size, $Size) }
            $brush.Dispose()
        }

        $frame = $PixelFrames[$Variant + '-' + $Size]
        if ($frame)
        {
            $rows = $PixelMarks[$frame.Mark]
            $accent = ConvertTo-Color $v.Accent
            $body = ConvertTo-Color $v.Body
            for ($y = 0; $y -lt $rows.Count; $y++)
            {
                for ($x = 0; $x -lt $rows[$y].Length; $x++)
                {
                    $ch = $rows[$y][$x]
                    if ($ch -eq 'A') { $bmp.SetPixel($frame.X + $x, $frame.Y + $y, $accent) }
                    elseif ($ch -eq 'B') { $bmp.SetPixel($frame.X + $x, $frame.Y + $y, $body) }
                }
            }
        }
        else
        {
            $layers = $TwoToneLayers
            if ($v.Mono) { $layers = $MonoLayers }
            foreach ($layer in $layers)
            {
                $gp = New-Object System.Drawing.Drawing2D.GraphicsPath([System.Drawing.Drawing2D.FillMode]::Alternate)
                foreach ($ring in $layer.Rings)
                {
                    $pts = foreach ($p in $ring)
                    {
                        $q = Convert-Point -Point $p -Scale $v.Scale
                        New-Object System.Drawing.PointF(([float]($q[0] * $f)), ([float]($q[1] * $f)))
                    }
                    $gp.AddPolygon([System.Drawing.PointF[]]$pts)
                }
                $brush = New-Object System.Drawing.SolidBrush(ConvertTo-Color $v[$layer.Role])
                $g.FillPath($brush, $gp)
                $brush.Dispose()
                $gp.Dispose()
            }
        }
    }
    finally { $g.Dispose() }
    return $bmp
}

function Get-PngBytes([System.Drawing.Bitmap]$Bitmap)
{
    $ms = New-Object System.IO.MemoryStream
    try
    {
        $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        return , $ms.ToArray()
    }
    finally { $ms.Dispose() }
}

function Get-DibBytes([System.Drawing.Bitmap]$Bitmap)
{
    # 32-bit BGRA DIB as an ICO entry stores it: bottom-up rows, height doubled for the AND mask.
    $w = $Bitmap.Width
    $h = $Bitmap.Height
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try
    {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    }
    finally { $Bitmap.UnlockBits($data) }

    $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try
    {
        $bw.Write([uint32]40)
        $bw.Write([int32]$w)
        $bw.Write([int32]($h * 2))
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]0)
        $bw.Write([uint32]($w * $h * 4 + $maskStride * $h))
        $bw.Write([int32]0)
        $bw.Write([int32]0)
        $bw.Write([uint32]0)
        $bw.Write([uint32]0)
        for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($pixels, $y * $stride, $w * 4) }
        for ($y = $h - 1; $y -ge 0; $y--)
        {
            $row = New-Object byte[] $maskStride
            for ($x = 0; $x -lt $w; $x++)
            {
                if ($pixels[$y * $stride + $x * 4 + 3] -eq 0)
                {
                    $row[[int][Math]::Floor($x / 8)] = $row[[int][Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8))
                }
            }
            $bw.Write($row)
        }
        $bw.Flush()
        return , $ms.ToArray()
    }
    finally { $bw.Dispose() }
}

function Get-IcoBytes($Frames)
{
    # $Frames: ordered list of @{ Size; Bytes }; 256 is stored as PNG, the rest as DIB.
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    try
    {
        $bw.Write([uint16]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]$Frames.Count)
        $offset = 6 + 16 * $Frames.Count
        foreach ($fr in $Frames)
        {
            $dim = $fr.Size
            if ($dim -ge 256) { $dim = 0 }
            $bw.Write([byte]$dim)
            $bw.Write([byte]$dim)
            $bw.Write([byte]0)
            $bw.Write([byte]0)
            $bw.Write([uint16]1)
            $bw.Write([uint16]32)
            $bw.Write([uint32]$fr.Bytes.Length)
            $bw.Write([uint32]$offset)
            $offset += $fr.Bytes.Length
        }
        foreach ($fr in $Frames) { $bw.Write([byte[]]$fr.Bytes) }
        $bw.Flush()
        return , $ms.ToArray()
    }
    finally { $bw.Dispose() }
}

# --- SVG -------------------------------------------------------------------------------------

function Get-MarkSvgBody([string]$Variant, [string]$Indent)
{
    $v = $Variants[$Variant]
    $layers = $TwoToneLayers
    if ($v.Mono) { $layers = $MonoLayers }
    $lines = foreach ($layer in $layers)
    {
        $Indent + '<path fill="' + $v[$layer.Role] + '" fill-rule="evenodd" d="' + (Get-PathData -Rings $layer.Rings -Scale $v.Scale) + '"/>'
    }
    return ($lines -join "`n")
}

function New-MarkSvg([string]$Variant)
{
    return @(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img">',
        '  <title>DeadLoad</title>',
        (Get-MarkSvgBody -Variant $Variant -Indent '  '),
        '</svg>',
        ''
    ) -join "`n"
}

function New-Mark16Svg
{
    $rows = $PixelMarks.Mark16
    return @(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" shape-rendering="crispEdges" role="img">',
        '  <title>DeadLoad</title>',
        ('  <path fill="' + $Colors.Navy + '" d="' + (Get-PixelPathData -Rows $rows -Want 'B') + '"/>'),
        ('  <path fill="' + $Colors.Blue + '" d="' + (Get-PixelPathData -Rows $rows -Want 'A') + '"/>'),
        '</svg>',
        ''
    ) -join "`n"
}

function New-FaviconSvg
{
    # The 16 px silhouette (tabs draw favicons at 16 or 32 px), recolored for a dark browser UI.
    $rows = $PixelMarks.Mark16
    return @(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16" shape-rendering="crispEdges">',
        '  <style>',
        ('    .b { fill: ' + $Colors.Navy + '; } .a { fill: ' + $Colors.Blue + '; }'),
        ('    @media (prefers-color-scheme: dark) { .b { fill: ' + $Colors.TextOnDark + '; } .a { fill: ' + $Colors.BlueOnDark + '; } }'),
        '  </style>',
        ('  <path class="b" d="' + (Get-PixelPathData -Rows $rows -Want 'B') + '"/>'),
        ('  <path class="a" d="' + (Get-PixelPathData -Rows $rows -Want 'A') + '"/>'),
        '</svg>',
        ''
    ) -join "`n"
}

function New-LockupSvg([string]$Variant)
{
    # Mark at half scale (96 units tall), clear space 1/4 of that (24) on every side, the
    # wordmark 24 units right of the mark. Font size 72: cap height about 0.7 em, centered on
    # the mark. Width 330 is "DeadLoad" in Segoe UI Semibold at 72 px (measured, 4.58 em per
    # 1 em of size over the 8 letters); textLength holds it for any fallback font.
    $v = $Variants[$Variant]
    $dead = $Colors.Navy
    $load = $Colors.Blue
    if ($Variant -eq 'OnDark')
    {
        $dead = $Colors.TextOnDark
        $load = $Colors.BlueOnDark
    }
    $clear = 24
    $markSize = 96
    $markScale = $markSize / 192.0
    $offset = $clear - 32 * $markScale
    $textX = $clear + $markSize + 24
    $textWidth = 330
    $width = $textX + $textWidth + $clear
    $height = $clear * 2 + $markSize
    $baseline = 98
    return @(
        ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + $width + ' ' + $height + '" width="' + $width + '" height="' + $height + '" role="img">'),
        '  <title>DeadLoad</title>',
        ('  <g transform="translate(' + (Format-Number $offset) + ' ' + (Format-Number $offset) + ') scale(' + (Format-Number $markScale) + ')">'),
        (Get-MarkSvgBody -Variant $Variant -Indent '    '),
        '  </g>',
        ('  <text x="' + $textX + '" y="' + $baseline + '" font-family="' + $fontStack + '" font-size="72" font-weight="' + $fontWeight + '" textLength="' + $textWidth + '" lengthAdjust="spacing"><tspan fill="' + $dead + '">Dead</tspan><tspan fill="' + $load + '">Load</tspan></text>'),
        '</svg>',
        ''
    ) -join "`n"
}

# --- Write -----------------------------------------------------------------------------------

$brand = 'design/brand'
Write-Asset "$brand/deadload-mark.svg" (Get-Bytes (New-MarkSvg -Variant 'Primary'))
Write-Asset "$brand/deadload-mark-mono.svg" (Get-Bytes (New-MarkSvg -Variant 'Mono'))
Write-Asset "$brand/deadload-mark-onDark.svg" (Get-Bytes (New-MarkSvg -Variant 'OnDark'))
Write-Asset "$brand/deadload-mark-16.svg" (Get-Bytes (New-Mark16Svg))
Write-Asset "$brand/deadload-lockup.svg" (Get-Bytes (New-LockupSvg -Variant 'Primary'))
Write-Asset "$brand/deadload-lockup-onDark.svg" (Get-Bytes (New-LockupSvg -Variant 'OnDark'))
Write-Asset "$brand/favicon.svg" (Get-Bytes (New-FaviconSvg))

$appIcons = @{}
foreach ($size in $AppIconSizes)
{
    $bmp = New-MarkBitmap -Size $size -Variant 'Tile'
    $appIcons[$size] = $bmp
    Write-Asset "$brand/png/deadload-$size.png" (Get-PngBytes $bmp)
}

$frames = foreach ($size in $IcoSizes)
{
    if ($size -ge 256) { $bytes = Get-PngBytes $appIcons[$size] }
    else { $bytes = Get-DibBytes $appIcons[$size] }
    @{ Size = $size; Bytes = $bytes }
}
$icoBytes = Get-IcoBytes -Frames @($frames)
Write-Asset "$brand/deadload.ico" $icoBytes
Write-Asset 'src/tray/DeadLoad.ico' $icoBytes

# Load the ICO back the way Windows Forms does; a malformed file throws here, not in the tray.
# System.Drawing.Icon did not select the PNG-compressed frame (measured on 5.1 and 7), so the
# 256 px entry (PNG, which the Windows shell does load) is checked by its signature instead.
$icoPath = Join-Path $RepoRoot "$brand/deadload.ico"
$icoCheck = foreach ($size in $IcoSizes)
{
    if ($size -ge 256) { continue }
    $icon = New-Object System.Drawing.Icon($icoPath, $size, $size)
    try
    {
        if ($icon.Width -ne $size -or $icon.Height -ne $size)
        {
            throw ('deadload.ico: asked for {0} px, System.Drawing loaded {1} x {2}.' -f $size, $icon.Width, $icon.Height)
        }
        $size
    }
    finally { $icon.Dispose() }
}
$pngOffset = [BitConverter]::ToUInt32($icoBytes, 6 + 16 * ($IcoSizes.Count - 1) + 12)
if ($icoBytes[$pngOffset + 1] -ne 0x50 -or $icoBytes[$pngOffset + 2] -ne 0x4E -or $icoBytes[$pngOffset + 3] -ne 0x47)
{
    throw 'deadload.ico: the 256 px entry is not a PNG.'
}

$site = 'site/assets/brand'
foreach ($svg in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot $brand) -Filter '*.svg' | Sort-Object Name))
{
    Write-Asset "$site/$($svg.Name)" ([System.IO.File]::ReadAllBytes($svg.FullName))
}
Write-Asset "$site/deadload-32.png" (Get-PngBytes $appIcons[32])
foreach ($pair in @(@{ Size = 180; Variant = 'Square' }, @{ Size = 192; Variant = 'Tile' }, @{ Size = 512; Variant = 'Tile' }))
{
    $bmp = New-MarkBitmap -Size $pair.Size -Variant $pair.Variant
    try { Write-Asset "$site/deadload-$($pair.Size).png" (Get-PngBytes $bmp) } finally { $bmp.Dispose() }
}

# --- Contact sheet ---------------------------------------------------------------------------

function Add-SheetRow($Graphics, [int]$Top, [int]$Left, [int]$Width, [int]$Height, [string]$Background, [string]$Label, $Images, [int]$Zoom)
{
    $bg = New-Object System.Drawing.SolidBrush(ConvertTo-Color $Background)
    $Graphics.FillRectangle($bg, $Left, $Top, $Width, $Height)
    $bg.Dispose()
    $textColor = '#0F172A'
    if ($Background -eq $Colors.CanvasDark) { $textColor = '#F1F5F9' }
    $tb = New-Object System.Drawing.SolidBrush(ConvertTo-Color $textColor)
    $font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $Graphics.DrawString($Label, $font, $tb, [float]($Left + 12), [float]($Top + 6))
    $x = $Left + 16
    foreach ($img in $Images)
    {
        $w = $img.Width * $Zoom
        $Graphics.DrawImage($img, (New-Object System.Drawing.Rectangle($x, ($Top + 28), $w, ($img.Height * $Zoom))))
        $Graphics.DrawString([string]$img.Width, $font, $tb, [float]$x, [float]($Top + 32 + $img.Height * $Zoom))
        $x += $w + 20
    }
    $font.Dispose()
    $tb.Dispose()
}

$contactSheet = $null
if ($ContactSheetPath)
{
    $bareSizes = @(16, 24, 32, 48, 64, 256)
    $bare = @{}
    foreach ($variant in @('Primary', 'OnDark', 'Mono'))
    {
        $bare[$variant] = foreach ($s in $bareSizes) { New-MarkBitmap -Size $s -Variant $variant }
    }
    $nativeTiles = foreach ($s in $AppIconSizes) { $appIcons[$s] }
    $zoomTiles = foreach ($s in @(16, 20, 24, 32)) { $appIcons[$s] }
    $zoomBare = @($bare['Primary'][0], $bare['Primary'][1], $bare['Primary'][2])
    $zoomBareDark = @($bare['OnDark'][0], $bare['OnDark'][1], $bare['OnDark'][2])

    $half = 920
    $rowHeights = @(320, 320, 320, 320, 320, 320)
    $sheetH = 0
    foreach ($rh in $rowHeights) { $sheetH += $rh }
    $sheet = New-Canvas -Width ($half * 2) -Height $sheetH
    $sg = $sheet.Graphics
    $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $sg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $top = 0
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'App icon (ICO frames), native size, light' $nativeTiles 1
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'App icon (ICO frames), native size, dark' $nativeTiles 1
    $top += 320
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'App icon 16 20 24 32, 8x nearest neighbor (each pixel visible)' $zoomTiles 8
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'App icon 16 20 24 32, 8x, dark' $zoomTiles 8
    $top += 320
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'Mark primary on light' $bare['Primary'] 1
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'Mark onDark on dark' $bare['OnDark'] 1
    $top += 320
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'Mark one-color on light' $bare['Mono'] 1
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'Mark primary on dark (not intended; shows why onDark exists)' $bare['Primary'] 1
    $top += 320
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'Mark primary 16 24 32, 8x' $zoomBare 8
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'Mark onDark 16 24 32, 8x' $zoomBareDark 8
    $top += 320
    $zoomMid = foreach ($s in @(40, 48, 64)) { $appIcons[$s] }
    Add-SheetRow $sg $top 0 $half 320 $Colors.Canvas 'App icon 40 48 64 (anti-aliased), 4x' $zoomMid 4
    Add-SheetRow $sg $top $half $half 320 $Colors.CanvasDark 'App icon 40 48 64, 4x, dark' $zoomMid 4
    $sg.Dispose()
    $sheetFull = $ContactSheetPath
    if (-not [System.IO.Path]::IsPathRooted($sheetFull)) { $sheetFull = Join-Path $RepoRoot $sheetFull }
    $sheetDir = Split-Path -Path $sheetFull -Parent
    if (-not (Test-Path -LiteralPath $sheetDir)) { New-Item -ItemType Directory -Path $sheetDir -Force | Out-Null }
    $sheet.Bitmap.Save($sheetFull, [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Bitmap.Dispose()
    foreach ($list in $bare.Values) { foreach ($b in $list) { $b.Dispose() } }
    $contactSheet = $sheetFull
}

foreach ($b in $appIcons.Values) { $b.Dispose() }

[pscustomobject]@{
    Written      = @($script:written)
    Unchanged    = $script:unchanged
    IcoBytes     = $icoBytes.Length
    IcoDibSizes  = @($icoCheck)
    ContactSheet = $contactSheet
}
