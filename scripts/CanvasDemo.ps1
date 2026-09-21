#requires -Version 7.0
using namespace System
using namespace System.Diagnostics

param(
    [Android.App.Activity] $Activity = $global:Activity
)

# Traceable Android platform-edge port of the original desktop terminal donor.
# The packed cells and producer functions below remain the application. Android
# replaces only DirectPort construction, input admission, and presentation.
enum CanvasMode { Touch; Pan; Colors; Charset; Grid; Noise }

# Keep the donor state alive when an Activity is replaced or this script is
# reloaded. Android objects live separately in $script:AndroidCanvasEdge.
if ($null -eq $script:Cells) {
    $script:Cells = [uint32[]]::new(1)
    $script:Columns = 1
    $script:Rows = 1
    $script:Mode = [CanvasMode]::Touch
    $global:CanvasSelectedModeIndex = 0
    $script:Frame = 0
    # Android physical pixels are denser than the donor's 1000 x 650 desktop
    # window. Scale 2 yields a comparable approximately 4,000-cell workload.
    $script:Scale = 2
    $script:PanX = 0.0
    $script:PanY = 0.0
    $script:Dirty = $true
    $script:WasAnimating = $false
    $script:Ready = $false
    $script:Rng = [Random]::new()
    $script:NoiseBytes = [byte[]]::new(2)
    $script:TouchX = [Collections.Generic.List[int]]::new()
    $script:TouchY = [Collections.Generic.List[int]]::new()
    $script:TouchAt = [Collections.Generic.List[long]]::new()
    $script:LastTouchCell = -1
    $script:LastResizeSerial = [uint64]::MaxValue
    $script:LastFps = 0.0
    $script:LastBuild = 0.0
    $script:LastDropped = [uint64]0
    $script:EmitSample = $true
}

$global:labels = @(
    @{ Text = ' 1 TOUCH '; Mode = [CanvasMode]::Touch },
    @{ Text = ' 2 PAN '; Mode = [CanvasMode]::Pan },
    @{ Text = ' 3 COLORS '; Mode = [CanvasMode]::Colors },
    @{ Text = ' 4 GLYPHS '; Mode = [CanvasMode]::Charset },
    @{ Text = ' 5 GRID '; Mode = [CanvasMode]::Grid },
    @{ Text = ' 6 NOISE '; Mode = [CanvasMode]::Noise }
)

function global:Set-Mode([CanvasMode] $Mode) {
    $wasAnimated = $script:Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
    $script:Mode = $Mode
    $isAnimated = $Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
    if ($wasAnimated -and -not $isAnimated) { $script:WasAnimating = $true }
    $script:Dirty = $true
    $script:EmitSample = $true
}

function global:Add-TouchCell([int] $X, [int] $Y) {
    if ($X -lt 0 -or $X -ge $script:Columns -or $Y -lt 1 -or $Y -ge $script:Rows) { return }
    $cell = $Y * $script:Columns + $X
    if ($cell -eq $script:LastTouchCell) { return }
    $script:LastTouchCell = $cell
    $script:TouchX.Add($X)
    $script:TouchY.Add($Y)
    $script:TouchAt.Add([Environment]::TickCount64)
    $script:Dirty = $true
}

function global:Put-Text([uint32[]] $Cells, [int] $Columns, [int] $Rows, [int] $X, [int] $Y,
                  [string] $Text, [int] $Foreground, [int] $Background) {
    if ($Y -lt 0 -or $Y -ge $Rows) { return }
    for ($i = 0; $i -lt $Text.Length -and ($X + $i) -lt $Columns; $i++) {
        if (($X + $i) -ge 0) {
            $Cells[$Y * $Columns + $X + $i] = [uint32](($Background -shl 24) -bor ($Foreground -shl 16) -bor [int]$Text[$i])
        }
    }
}

function global:Build-Cells([int] $ViewWidth, [int] $ViewHeight) {
    $cellWidth = 9 * $script:Scale
    $cellHeight = 18 * $script:Scale
    $columns = [Math]::Clamp([int][Math]::Floor($ViewWidth / $cellWidth), 1, 512)
    $rows = [Math]::Clamp([int][Math]::Floor($ViewHeight / $cellHeight), 2, 512)
    while (($columns * $rows) -gt 262144) { $rows-- }
    $shape = $columns -ne $script:Columns -or $rows -ne $script:Rows
    if ($shape) {
        $script:Columns = $columns
        $script:Rows = $rows
        $script:Cells = [uint32[]]::new($columns * $rows)
        $script:NoiseBytes = [byte[]]::new(2 * $columns * $rows)
    }
    else { [Array]::Clear($script:Cells, 0, $script:Cells.Length) }

    $cells = $script:Cells
    $mode = $script:Mode
    $px = [int][Math]::Floor($script:PanX)
    $py = [int][Math]::Floor($script:PanY)
    $centerX = [int]($columns / 2)
    $centerY = [int]($rows / 2)
    $band = [Math]::Max(1.0, $columns / 16.0)

    # Select the producer once per frame, never once per cell.
    if ($mode -eq [CanvasMode]::Grid) {
        for ($y = 1; $y -lt $rows; $y++) {
            $rowAt = $y * $columns
            for ($x = 0; $x -lt $columns; $x++) {
                $cp = 32; $fg = 15; $bg = if ((($x + $y) -band 1) -eq 0) { 8 } else { 0 }
                if ($x -eq 0 -or $y -eq 1 -or $x -eq ($columns - 1) -or $y -eq ($rows - 1)) { $bg = 1; $cp = 35 }
                if (($x % 10) -eq 0 -and (($y - 1) % 5) -eq 0) { $bg = 4; $cp = 79 }
                $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
            }
        }
    }
    elseif ($mode -eq [CanvasMode]::Colors) {
        for ($y = 1; $y -lt $rows; $y++) {
            $rowAt = $y * $columns; $cp = 65 + ($y % 26)
            for ($x = 0; $x -lt $columns; $x++) {
                $bg = [int][Math]::Floor($x / $band) % 16; $fg = ($bg + 8) % 16
                $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
            }
        }
    }
    elseif ($mode -eq [CanvasMode]::Charset) {
        for ($y = 1; $y -lt $rows; $y++) {
            $rowAt = $y * $columns; $fg = ($y % 15) + 1
            for ($x = 0; $x -lt $columns; $x++) {
                $cp = 33 + (($rowAt + $x + $script:Frame) % 94)
                $cells[$rowAt + $x] = [uint32](($fg -shl 16) -bor $cp)
            }
        }
    }
    elseif ($mode -eq [CanvasMode]::Noise) {
        # Entropy generation stays in one native call; PowerShell only packs cells.
        $script:Rng.NextBytes($script:NoiseBytes)
        for ($y = 1; $y -lt $rows; $y++) {
            $rowAt = $y * $columns
            for ($x = 0; $x -lt $columns; $x++) {
                $at = $rowAt + $x; $v = $script:NoiseBytes[2 * $at]
                if (($v -band 15) -eq 0) {
                    $cp = 33 + ($v % 90); $fg = $script:NoiseBytes[2 * $at + 1] -band 15
                    $cells[$at] = [uint32](($fg -shl 16) -bor $cp)
                }
            }
        }
    }
    elseif ($mode -eq [CanvasMode]::Pan) {
        for ($y = 1; $y -lt $rows; $y++) {
            $rowAt = $y * $columns; $wy = ($y - 1) - $py
            for ($x = 0; $x -lt $columns; $x++) {
                $cp = 32; $fg = 15; $bg = 0; $wx = $x - $px
                if ((([Math]::Abs($wx) -band 1) -eq 0) -eq (([Math]::Abs($wy) -band 1) -eq 0)) { $bg = 8 }
                if ($wx -eq 0 -and $wy -eq 0) { $bg = 4; $cp = 88 }
                elseif (($wx % 10) -eq 0 -and ($wy % 10) -eq 0) { $cp = 43 }
                if ($x -eq $centerX -and $y -eq $centerY) { $bg = 1; $cp = 64 }
                $cells[$rowAt + $x] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp)
            }
        }
    }

    # Oldest -> newest: normal last-write-wins makes the newest touch authoritative.
    $now = [Environment]::TickCount64
    for ($i = $script:TouchAt.Count - 1; $i -ge 0; $i--) {
        if (($now - $script:TouchAt[$i]) -ge 500) {
            $script:TouchAt.RemoveAt($i); $script:TouchX.RemoveAt($i); $script:TouchY.RemoveAt($i)
        }
    }
    for ($i = 0; $i -lt $script:TouchAt.Count; $i++) {
        $age = $now - $script:TouchAt[$i]
        if ($age -lt 100) { $bg = 14; $fg = 0; $cp = 88 }
        elseif ($age -lt 300) { $bg = 6; $fg = 15; $cp = 120 }
        else { $bg = 8; $fg = 15; $cp = 46 }
        $at = $script:TouchY[$i] * $columns + $script:TouchX[$i]
        if ($at -ge 0 -and $at -lt $cells.Length) { $cells[$at] = [uint32](($bg -shl 24) -bor ($fg -shl 16) -bor $cp) }
    }

    if ($mode -eq [CanvasMode]::Touch) {
        Put-Text $cells $columns $rows 3 3 ' CANVAS HOST: ANDROID GPU CANVAS ' 15 4
        $status = if ($script:TouchX.Count) {
            ' COORDS: [X:{0:D3} Y:{1:D3}] ' -f $script:TouchX[$script:TouchX.Count - 1], $script:TouchY[$script:TouchY.Count - 1]
        } else { ' WAITING FOR INPUT... ' }
        Put-Text $cells $columns $rows 3 5 $status 10 0
    }

    # Toolbar is itself cells; click ranges are reconstructed from these labels.
    $toolbarX = 0
    for ($buttonIndex = 0; $buttonIndex -lt $labels.Count; $buttonIndex++) {
        $button = $labels[$buttonIndex]
        $focused = $buttonIndex -eq $global:CanvasSelectedModeIndex
        $active = $button.Mode -eq $mode
        Put-Text $cells $columns $rows $toolbarX 0 $button.Text `
            $(if ($focused) { 15 } elseif ($active) { 14 } else { 7 }) `
            $(if ($focused) { 4 } elseif ($active) { 8 } else { 8 })
        $toolbarX += $button.Text.Length
    }
    if ($toolbarX -lt $columns) {
        $telemetry = ' {0}x{1} {2:0}fps {3:0.0}ms D{4} ' -f $columns, $rows, $script:LastFps, $script:LastBuild, $script:LastDropped
        Put-Text $cells $columns $rows $toolbarX 0 $telemetry 8 0
    }
    return $shape
}

$script:CanvasPalette = [int[]]@(
    [Android.Graphics.Color]::Rgb(9, 12, 18).ToArgb(),
    [Android.Graphics.Color]::Rgb(205, 49, 49).ToArgb(),
    [Android.Graphics.Color]::Rgb(13, 188, 121).ToArgb(),
    [Android.Graphics.Color]::Rgb(229, 229, 16).ToArgb(),
    [Android.Graphics.Color]::Rgb(36, 114, 200).ToArgb(),
    [Android.Graphics.Color]::Rgb(188, 63, 188).ToArgb(),
    [Android.Graphics.Color]::Rgb(17, 168, 205).ToArgb(),
    [Android.Graphics.Color]::Rgb(229, 229, 229).ToArgb(),
    [Android.Graphics.Color]::Rgb(102, 102, 102).ToArgb(),
    [Android.Graphics.Color]::Rgb(241, 76, 76).ToArgb(),
    [Android.Graphics.Color]::Rgb(35, 209, 139).ToArgb(),
    [Android.Graphics.Color]::Rgb(245, 245, 67).ToArgb(),
    [Android.Graphics.Color]::Rgb(59, 142, 234).ToArgb(),
    [Android.Graphics.Color]::Rgb(214, 112, 214).ToArgb(),
    [Android.Graphics.Color]::Rgb(41, 184, 219).ToArgb(),
    [Android.Graphics.Color]::Rgb(255, 255, 255).ToArgb()
)

function global:Get-AndroidCanvasBounds {
    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or $surface.Width -le 0 -or $surface.Height -le 0) { return $null }

    $left = 0; $top = 0; $right = 0; $bottom = 0
    [Android.Views.WindowInsets] $windowInsets = $surface.RootWindowInsets
    if ($null -ne $windowInsets) {
        [Android.Graphics.Insets] $bars = $windowInsets.GetInsets([Android.Views.WindowInsets+Type]::SystemBars())
        $left = $bars.Left; $top = $bars.Top; $right = $bars.Right; $bottom = $bars.Bottom
        [Android.Views.DisplayCutout] $cutout = $windowInsets.DisplayCutout
        if ($null -ne $cutout) {
            $left = [Math]::Max($left, $cutout.SafeInsetLeft)
            $top = [Math]::Max($top, $cutout.SafeInsetTop)
            $right = [Math]::Max($right, $cutout.SafeInsetRight)
            $bottom = [Math]::Max($bottom, $cutout.SafeInsetBottom)
        }
    }

    [pscustomobject]@{
        Left = $left
        Top = $top
        Right = $right
        Bottom = $bottom
        Width = [Math]::Max(1, $surface.Width - $left - $right)
        Height = [Math]::Max(1, $surface.Height - $top - $bottom)
        SurfaceWidth = $surface.Width
        SurfaceHeight = $surface.Height
    }
}

function global:Present-CellsWithCanvasCalls {
    param([Parameter(Mandatory)] $Bounds)

    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or -not $surface.Holder.Surface.IsValid) { return $false }
    [Android.Graphics.Canvas] $canvas = $null
    try {
        $canvas = $surface.Holder.LockHardwareCanvas()
        if ($null -eq $canvas) { return $false }
        [Android.Graphics.Paint] $paint = $script:AndroidCanvasEdge.Paint
        $canvas.DrawColor([Android.Graphics.Color]::Rgb(9, 12, 18))

        [double] $cellWidth = $Bounds.Width / [double]$script:Columns
        [double] $cellHeight = $Bounds.Height / [double]$script:Rows
        $paint.TextSize = [single]($cellHeight * 0.78)
        [Android.Graphics.Paint+FontMetrics] $font = $paint.FontMetrics
        [single] $baselineOffset = [single](($cellHeight - ($font.Descent - $font.Ascent)) / 2.0 - $font.Ascent)

        for ($y = 0; $y -lt $script:Rows; $y++) {
            $x = 0
            while ($x -lt $script:Columns) {
                [uint32] $packed = $script:Cells[$y * $script:Columns + $x]
                $foreground = ($packed -shr 16) -band 0xff
                $background = ($packed -shr 24) -band 0xff
                $start = $x
                [Text.StringBuilder] $text = [Text.StringBuilder]::new()
                while ($x -lt $script:Columns) {
                    $packed = $script:Cells[$y * $script:Columns + $x]
                    if ((($packed -shr 16) -band 0xff) -ne $foreground -or
                        (($packed -shr 24) -band 0xff) -ne $background) { break }
                    $codepoint = $packed -band 0xffff
                    [void]$text.Append($(if ($codepoint) { [char]$codepoint } else { ' ' }))
                    $x++
                }

                [single] $left = [single]($Bounds.Left + $start * $cellWidth)
                [single] $top = [single]($Bounds.Top + $y * $cellHeight)
                if ($background -ne 0) {
                    $paint.Color = [Android.Graphics.Color]::new($script:CanvasPalette[$background -band 15])
                    $canvas.DrawRect($left, $top,
                        [single]($left + $text.Length * $cellWidth), [single]($top + $cellHeight), $paint)
                }
                if ($text.ToString().Trim().Length) {
                    $paint.Color = [Android.Graphics.Color]::new($script:CanvasPalette[$foreground -band 15])
                    $canvas.DrawText($text.ToString(), $left, [single]($top + $baselineOffset), $paint)
                }
            }
        }
        return $canvas.IsHardwareAccelerated
    }
    catch {
        [Android.Util.Log]::Error('PowerShell', "Canvas presentation failed: $_")
        return $false
    }
    finally {
        if ($null -ne $canvas) { $surface.Holder.UnlockCanvasAndPost($canvas) }
    }
}

function global:Initialize-AndroidPackedPresenter {
    param([Parameter(Mandatory)] $Bounds)

    $edge = $script:AndroidCanvasEdge
    $cellWidth = [int][Math]::Ceiling($Bounds.Width / [double]$script:Columns)
    $cellHeight = [int][Math]::Ceiling($Bounds.Height / [double]$script:Rows)
    $shape = "$($script:Columns)x$($script:Rows):${cellWidth}x${cellHeight}"
    if ($edge.PackedShape -eq $shape -and $null -ne $edge.PackedShader) { return }

    if ($null -ne $edge.PackedBitmap) { $edge.PackedBitmap.Dispose() }
    if ($null -ne $edge.GlyphBitmap) { $edge.GlyphBitmap.Dispose() }
    if ($null -ne $edge.PaletteBitmap) { $edge.PaletteBitmap.Dispose() }
    if ($null -ne $edge.PackedPaint) { $edge.PackedPaint.Dispose() }

    $packedBytes = [byte[]]::new($script:Columns * $script:Rows * 4)
    [Java.Nio.ByteBuffer] $packedBuffer = [Java.Nio.ByteBuffer]::AllocateDirect($packedBytes.Length)
    [Android.Graphics.Bitmap] $packedBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        $script:Columns, $script:Rows, [Android.Graphics.Bitmap+Config]::Argb8888)
    [Android.Graphics.BitmapShader] $packedInput = [Android.Graphics.BitmapShader]::new(
        $packedBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $packedInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    [Android.Graphics.Bitmap] $glyphBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        16 * $cellWidth, 8 * $cellHeight, [Android.Graphics.Bitmap+Config]::Argb8888)
    [Android.Graphics.Canvas] $glyphCanvas = [Android.Graphics.Canvas]::new($glyphBitmap)
    [Android.Graphics.Paint] $glyphPaint = [Android.Graphics.Paint]::new()
    $glyphPaint.AntiAlias = $true
    $glyphPaint.Color = [Android.Graphics.Color]::White
    $glyphPaint.TextSize = [single]($cellHeight * 0.78)
    [void]$glyphPaint.SetTypeface([Android.Graphics.Typeface]::Monospace)
    [Android.Graphics.Rect] $glyphBounds = [Android.Graphics.Rect]::new()
    for ($codepoint = 33; $codepoint -lt 127; $codepoint++) {
        $tileX = $codepoint % 16
        $tileY = [int][Math]::Floor($codepoint / 16)
        $glyphText = [string][char]$codepoint
        $glyphBounds.SetEmpty()
        $glyphPaint.GetTextBounds($glyphText, 0, 1, $glyphBounds)
        [single] $glyphX = [single](
            $tileX * $cellWidth + ($cellWidth - $glyphBounds.Width()) / 2.0 - $glyphBounds.Left)
        [single] $glyphY = [single](
            $tileY * $cellHeight + ($cellHeight - $glyphBounds.Height()) / 2.0 - $glyphBounds.Top)
        $glyphCanvas.DrawText(
            $glyphText,
            $glyphX,
            $glyphY,
            $glyphPaint)
    }
    $glyphCanvas.Dispose()
    $glyphPaint.Dispose()

    [Android.Graphics.BitmapShader] $glyphInput = [Android.Graphics.BitmapShader]::new(
        $glyphBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $glyphInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    [Android.Graphics.Bitmap] $paletteBitmap = [Android.Graphics.Bitmap]::CreateBitmap(
        16, 1, [Android.Graphics.Bitmap+Config]::Argb8888)
    $paletteBitmap.SetPixels($script:CanvasPalette, 0, 16, 0, 0, 16, 1)
    [Android.Graphics.BitmapShader] $paletteInput = [Android.Graphics.BitmapShader]::new(
        $paletteBitmap,
        [Android.Graphics.Shader+TileMode]::Clamp,
        [Android.Graphics.Shader+TileMode]::Clamp)
    $paletteInput.FilterMode = [int][Android.Graphics.BitmapShaderFilterMode]::Nearest

    $program = @'
uniform shader packedCells;
uniform shader glyphAtlas;
uniform shader colors;
uniform float2 origin;
uniform float2 contentSize;
uniform float2 cellSize;
uniform float2 glyphCellSize;
uniform int2 gridSize;

half4 main(float2 p) {
    float2 q = p - origin;
    if (q.x < 0.0 || q.y < 0.0 || q.x >= contentSize.x || q.y >= contentSize.y) {
        return colors.eval(float2(0.5, 0.5));
    }

    int2 cellAt = int2(floor(q / cellSize));
    half4 cellValue = packedCells.eval(float2(cellAt) + float2(0.5));

    int codepointLow = int(floor(float(cellValue.r) * 255.0 + 0.5));
    int codepointHigh = int(floor(float(cellValue.g) * 255.0 + 0.5));
    int foreground = int(floor(float(cellValue.b) * 255.0 + 0.5));
    int background = int(floor(float(cellValue.a) * 255.0 + 0.5));
    int codepoint = codepointLow + codepointHigh * 256;

    half4 backgroundColor = colors.eval(float2(float(background) + 0.5, 0.5));
    if (codepoint <= 32 || codepoint >= 127) {
        return backgroundColor;
    }

    float2 withinCell = q - floor(q / cellSize) * cellSize;
    int tileY = codepoint / 16;
    int tileX = codepoint - tileY * 16;
    float2 tile = float2(float(tileX), float(tileY));
    float2 glyphAt = tile * glyphCellSize + (withinCell / cellSize) * glyphCellSize;
    half glyphCoverage = glyphAtlas.eval(glyphAt).a;
    half4 foregroundColor = colors.eval(float2(float(foreground) + 0.5, 0.5));
    return mix(backgroundColor, foregroundColor, glyphCoverage);
}
'@

    [Android.Graphics.RuntimeShader] $runtimeShader = [Android.Graphics.RuntimeShader]::new($program)
    $runtimeShader.SetInputBuffer('packedCells', $packedInput)
    $runtimeShader.SetInputShader('glyphAtlas', $glyphInput)
    $runtimeShader.SetInputShader('colors', $paletteInput)

    [Android.Graphics.Paint] $packedPaint = [Android.Graphics.Paint]::new()
    $packedPaint.AntiAlias = $false
    [void]$packedPaint.SetShader($runtimeShader)

    $edge.PackedBytes = $packedBytes
    $edge.PackedBuffer = $packedBuffer
    $edge.PackedBitmap = $packedBitmap
    $edge.PackedInput = $packedInput
    $edge.GlyphBitmap = $glyphBitmap
    $edge.GlyphInput = $glyphInput
    $edge.PaletteBitmap = $paletteBitmap
    $edge.PaletteInput = $paletteInput
    $edge.PackedShader = $runtimeShader
    $edge.PackedPaint = $packedPaint
    $edge.GlyphCellWidth = $cellWidth
    $edge.GlyphCellHeight = $cellHeight
    $edge.PackedShape = $shape
    [Android.Util.Log]::Info('PowerShell',
        "Canvas packed presenter READY cells=$($script:Columns)x$($script:Rows) atlas=$($glyphBitmap.Width)x$($glyphBitmap.Height)")
}

function global:Present-CellsWithPackedShader {
    param([Parameter(Mandatory)] $Bounds)

    [Android.Views.SurfaceView] $surface = $script:AndroidCanvasEdge.Surface
    if ($null -eq $surface -or -not $surface.Holder.Surface.IsValid) { return $false }
    $edge = $script:AndroidCanvasEdge
    [Android.Graphics.Canvas] $canvas = $null

    Initialize-AndroidPackedPresenter $Bounds

    $uploadAt = [Stopwatch]::GetTimestamp()
    [Buffer]::BlockCopy($script:Cells, 0, $edge.PackedBytes, 0, $edge.PackedBytes.Length)
    [void]$edge.PackedBuffer.Clear()
    [void]$edge.PackedBuffer.Put($edge.PackedBytes)
    [void]$edge.PackedBuffer.Rewind()
    $edge.PackedBitmap.CopyPixelsFromBuffer($edge.PackedBuffer)
    $uploadedAt = [Stopwatch]::GetTimestamp()

    if (-not $edge.PackedProbeLogged) {
        [Android.Graphics.Color] $cell0 = $edge.PackedBitmap.GetPixel(0, 0)
        [Android.Graphics.Color] $cell1 = $edge.PackedBitmap.GetPixel(1, 0)
        $atlasInk = 0
        $probeCodepoint = 65
        $probeTileX = $probeCodepoint % 16
        $probeTileY = [int][Math]::Floor($probeCodepoint / 16)
        for ($probeY = 0; $probeY -lt $edge.GlyphCellHeight; $probeY++) {
            for ($probeX = 0; $probeX -lt $edge.GlyphCellWidth; $probeX++) {
                [Android.Graphics.Color] $atlasPixel = $edge.GlyphBitmap.GetPixel(
                    $probeTileX * $edge.GlyphCellWidth + $probeX,
                    $probeTileY * $edge.GlyphCellHeight + $probeY)
                if ($atlasPixel.A -gt 0) { $atlasInk++ }
            }
        }
        [Android.Util.Log]::Info('PowerShell',
            "Canvas packed probe c0=$($cell0.R),$($cell0.G),$($cell0.B),$($cell0.A) c1=$($cell1.R),$($cell1.G),$($cell1.B),$($cell1.A) atlasA=$atlasInk")
        $edge.PackedProbeLogged = $true
    }

    $edge.PackedShader.SetFloatUniform('origin', [single]$Bounds.Left, [single]$Bounds.Top)
    $edge.PackedShader.SetFloatUniform('contentSize', [single]$Bounds.Width, [single]$Bounds.Height)
    $edge.PackedShader.SetFloatUniform(
        'cellSize',
        [single]($Bounds.Width / [double]$script:Columns),
        [single]($Bounds.Height / [double]$script:Rows))
    $edge.PackedShader.SetFloatUniform(
        'glyphCellSize',
        [single]$edge.GlyphCellWidth,
        [single]$edge.GlyphCellHeight)
    $edge.PackedShader.SetIntUniform('gridSize', $script:Columns, $script:Rows)

    $submitAt = [Stopwatch]::GetTimestamp()
    $hardwareAccelerated = $false
    try {
        $canvas = $surface.Holder.LockHardwareCanvas()
        if ($null -eq $canvas) { return $false }
        $canvas.DrawPaint($edge.PackedPaint)
        $hardwareAccelerated = $canvas.IsHardwareAccelerated
    }
    finally {
        if ($null -ne $canvas) { $surface.Holder.UnlockCanvasAndPost($canvas) }
    }
    $submittedAt = [Stopwatch]::GetTimestamp()
    $edge.UploadTotal += 1000.0 * ($uploadedAt - $uploadAt) / $edge.Frequency
    $edge.SubmitTotal += 1000.0 * ($submittedAt - $submitAt) / $edge.Frequency
    return $hardwareAccelerated
}

function global:Present-Cells {
    param([Parameter(Mandatory)] $Bounds)

    if (-not $script:AndroidCanvasEdge.PackedPresenterFailed) {
        try {
            return Present-CellsWithPackedShader $Bounds
        }
        catch {
            $script:AndroidCanvasEdge.PackedPresenterFailed = $true
            [Android.Util.Log]::Error('PowerShell',
                "Canvas packed presenter failed; retaining checkpoint presenter: $_ stack=$($_.ScriptStackTrace)")
        }
    }
    return Present-CellsWithCanvasCalls $Bounds
}

function global:Invoke-AndroidCanvasInput {
    param([Parameter(Mandatory)][Android.Views.MotionEvent] $MotionEvent)

    $bounds = Get-AndroidCanvasBounds
    if ($null -eq $bounds) { return }
    $action = [int]$MotionEvent.ActionMasked
    $pointerCount = $MotionEvent.PointerCount
    $x = [single]$MotionEvent.GetX(0)
    $y = [single]$MotionEvent.GetY(0)

    if ($action -eq [int][Android.Views.MotionEventActions]::Down) {
        $identity = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($MotionEvent)
        [Android.Util.Log]::Info('PowerShell',
            "Canvas input type=$($MotionEvent.GetType().FullName) identity=$identity pointers=$pointerCount")
    }

    if ($pointerCount -ge 2) {
        $dx = $MotionEvent.GetX(1) - $x
        $dy = $MotionEvent.GetY(1) - $y
        $distance = [Math]::Sqrt($dx * $dx + $dy * $dy)
        if ($script:AndroidCanvasEdge.LastPinchDistance -gt 0 -and
            $action -eq [int][Android.Views.MotionEventActions]::Move) {
            $nextScale = [int][Math]::Round($script:Scale * $distance / $script:AndroidCanvasEdge.LastPinchDistance)
            $script:Scale = [Math]::Clamp($nextScale, 1, 8)
            $script:Dirty = $true
        }
        $script:AndroidCanvasEdge.LastPinchDistance = $distance
        return
    }
    $script:AndroidCanvasEdge.LastPinchDistance = 0.0

    $columns = [Math]::Max(1, $script:Columns)
    $rows = [Math]::Max(2, $script:Rows)
    $cellX = [Math]::Clamp([int][Math]::Floor(($x - $bounds.Left) / [Math]::Max(1.0, $bounds.Width / $columns)), 0, $columns - 1)
    $cellY = [Math]::Clamp([int][Math]::Floor(($y - $bounds.Top) / [Math]::Max(1.0, $bounds.Height / $rows)), 0, $rows - 1)
    $leftDown = $action -in @(
        [int][Android.Views.MotionEventActions]::Down,
        [int][Android.Views.MotionEventActions]::Move)

    if ($leftDown -and -not $script:AndroidCanvasEdge.PreviousLeft -and $cellY -eq 0) {
        $hitX = 0
        for ($buttonIndex = 0; $buttonIndex -lt $labels.Count; $buttonIndex++) {
            $button = $labels[$buttonIndex]
            if ($cellX -ge $hitX -and $cellX -lt ($hitX + $button.Text.Length)) {
                $global:CanvasSelectedModeIndex = $buttonIndex
                Set-Mode $button.Mode
                break
            }
            $hitX += $button.Text.Length
        }
    }
    elseif ($leftDown -and $cellY -gt 0) {
        if ($script:Mode -eq [CanvasMode]::Pan -and $script:AndroidCanvasEdge.PreviousLeft) {
            $script:PanX -= ($x - $script:AndroidCanvasEdge.PreviousX) / [Math]::Max(1.0, $bounds.Width / $columns)
            $script:PanY -= ($y - $script:AndroidCanvasEdge.PreviousY) / [Math]::Max(1.0, $bounds.Height / $rows)
            $script:Dirty = $true
        }
        Add-TouchCell $cellX $cellY
    }
    if (-not $leftDown) { $script:LastTouchCell = -1 }
    $script:AndroidCanvasEdge.PreviousLeft = $leftDown
    $script:AndroidCanvasEdge.PreviousX = $x
    $script:AndroidCanvasEdge.PreviousY = $y
}

function global:Invoke-AndroidCanvasFrame {
    $edge = $script:AndroidCanvasEdge
    $nowTicks = [Stopwatch]::GetTimestamp()
    $animated = $script:Mode -in @([CanvasMode]::Charset, [CanvasMode]::Noise)
    $live = $script:Dirty -or $animated -or ($script:TouchAt.Count -gt 0)
    if (-not $live) { return }

    $bounds = Get-AndroidCanvasBounds
    if ($null -eq $bounds) { return }
    $boundsKey = "$($bounds.SurfaceWidth)x$($bounds.SurfaceHeight):$($bounds.Left),$($bounds.Top),$($bounds.Right),$($bounds.Bottom)"
    if ($boundsKey -ne $edge.BoundsKey) {
        $edge.BoundsKey = $boundsKey
        $script:Dirty = $true
        [Android.Util.Log]::Info('PowerShell', "Canvas bounds=$boundsKey content=$($bounds.Width)x$($bounds.Height)")
    }

    if (-not $edge.FrameRateRequested -and $edge.Surface.Holder.Surface.IsValid) {
        $edge.Surface.Holder.Surface.SetFrameRate(
            [single]120.0,
            [int][Android.Views.SurfaceFrameRateCompatibility]::FixedSource,
            [int][Android.Views.SurfaceChangeFrameRate]::Always)
        $edge.FrameRateRequested = $true
        [Android.Util.Log]::Info('PowerShell', 'Canvas surface requested 120fps')
    }

    $buildAt = $nowTicks
    $shape = Build-Cells $bounds.Width $bounds.Height
    $cellsBuiltAt = [Stopwatch]::GetTimestamp()
    $submitted = Present-Cells $bounds
    $builtAt = [Stopwatch]::GetTimestamp()
    if ($submitted) {
        if (-not $script:Ready) {
            [Android.Util.Log]::Info('PowerShell', 'Canvas READY')
            $script:Ready = $true
        }
        if ($shape) {
            [Android.Util.Log]::Info('PowerShell', "Canvas RESIZE $($script:Columns)x$($script:Rows)")
        }
        $script:Frame++
        $script:Dirty = $false
        $edge.SampleFrames++
        $edge.CellBuildTotal += 1000.0 * ($cellsBuiltAt - $buildAt) / $edge.Frequency
        $edge.BuildTotal += 1000.0 * ($builtAt - $buildAt) / $edge.Frequency
        if ($null -ne $edge.HintSession) {
            $actualNanos = [long](1000000000.0 * ($builtAt - $buildAt) / $edge.Frequency)
            $edge.HintSession.ReportActualWorkDuration([Math]::Max([long]1, $actualNanos))
        }
        if ($script:WasAnimating -and -not $animated) { $script:WasAnimating = $false }
        if ($animated) { $script:WasAnimating = $true }
    }
    else { $script:LastDropped++ }

    if (($builtAt - $edge.SampleAt) -ge $edge.Frequency) {
        $elapsed = ($builtAt - $edge.SampleAt) / $edge.Frequency
        $script:LastFps = $edge.SampleFrames / $elapsed
        $script:LastBuild = $edge.BuildTotal / [Math]::Max(1, $edge.SampleFrames)
        if ($script:EmitSample -or $animated) {
            [Android.Util.Log]::Info('PowerShell',
                ('Canvas FPS={0:0} CELL={1:0.00}ms UP={2:0.00}ms SUBMIT={3:0.00}ms TOTAL={4:0.00}ms D{5}' -f
                    $script:LastFps,
                    ($edge.CellBuildTotal / [Math]::Max(1, $edge.SampleFrames)),
                    ($edge.UploadTotal / [Math]::Max(1, $edge.SampleFrames)),
                    ($edge.SubmitTotal / [Math]::Max(1, $edge.SampleFrames)),
                    $script:LastBuild,
                    $script:LastDropped))
            $script:EmitSample = $false
        }
        $edge.SampleAt = $builtAt
        $edge.SampleFrames = 0
        $edge.CellBuildTotal = 0.0
        $edge.UploadTotal = 0.0
        $edge.SubmitTotal = 0.0
        $edge.BuildTotal = 0.0
    }
}

$activity = $Activity
if ($null -eq $activity) {
    throw 'CanvasDemo.ps1 requires AndroidSMA to provide $Activity, or an Activity passed with -Activity.'
}
$generation = [Guid]::NewGuid()
$frequency = [double][Stopwatch]::Frequency
if ($null -ne $script:AndroidCanvasEdge) {
    $script:AndroidCanvasEdge.Active = $false
    if ($null -ne $script:AndroidCanvasEdge.HintSession) {
        $script:AndroidCanvasEdge.HintSession.Close()
    }
}
[Android.Graphics.Paint] $paint = [Android.Graphics.Paint]::new()
$paint.AntiAlias = $true
[void]$paint.SetTypeface([Android.Graphics.Typeface]::Monospace)
$edge = [pscustomobject]@{
    Activity = $activity
    Surface = $null
    Paint = $paint
    Generation = $generation
    Active = $true
    Tick = $null
    Touch = $null
    KeyPress = $null
    HintManager = $null
    HintSession = $null
    TargetNanos = [long]8333333
    FrameRateRequested = $false
    PackedPresenterFailed = $false
    PackedProbeLogged = $false
    PackedShape = ''
    PackedBytes = $null
    PackedBuffer = $null
    PackedBitmap = $null
    PackedInput = $null
    GlyphBitmap = $null
    GlyphInput = $null
    PaletteBitmap = $null
    PaletteInput = $null
    PackedShader = $null
    PackedPaint = $null
    GlyphCellWidth = 0
    GlyphCellHeight = 0
    Frequency = $frequency
    SampleAt = [Stopwatch]::GetTimestamp()
    SampleFrames = 0
    CellBuildTotal = 0.0
    UploadTotal = 0.0
    SubmitTotal = 0.0
    BuildTotal = 0.0
    BoundsKey = ''
    PreviousLeft = $false
    PreviousX = 0.0
    PreviousY = 0.0
    LastPinchDistance = 0.0
}
$script:AndroidCanvasEdge = $edge
$script:Dirty = $true

[scriptblock] $touch = {
    param($sender, $eventArgs)
    try {
        [Android.Views.MotionEvent] $motionEvent = $eventArgs.Event
        Invoke-AndroidCanvasInput $motionEvent
        $eventArgs.Handled = $true
    }
    catch {
        [Android.Util.Log]::Error('PowerShell',
            "Canvas touch failed: $_ stack=$($_.ScriptStackTrace)")
    }
}.GetNewClosure()
$edge.Touch = $touch

[scriptblock] $keyPress = {
    param($sender, $eventArgs)

    if ($eventArgs.Event.Action -ne [Android.Views.KeyEventActions]::Down) { return }
    $keyCode = $eventArgs.KeyCode
    $lastIndex = $labels.Count - 1
    if ($keyCode -eq [Android.Views.Keycode]::DpadLeft) {
        $global:CanvasSelectedModeIndex = if ($global:CanvasSelectedModeIndex -le 0) { $lastIndex } else { $global:CanvasSelectedModeIndex - 1 }
        Set-Mode $labels[$global:CanvasSelectedModeIndex].Mode
    }
    elseif ($keyCode -eq [Android.Views.Keycode]::DpadRight) {
        $global:CanvasSelectedModeIndex = if ($global:CanvasSelectedModeIndex -ge $lastIndex) { 0 } else { $global:CanvasSelectedModeIndex + 1 }
        Set-Mode $labels[$global:CanvasSelectedModeIndex].Mode
    }
    else { return }
    $script:Dirty = $true
    $eventArgs.Handled = $true
    [Android.Util.Log]::Info('PowerShell',
        "Canvas remote key=$keyCode mode=$($labels[$global:CanvasSelectedModeIndex].Text.Trim())")
}.GetNewClosure()
$edge.KeyPress = $keyPress

[Action] $onAnimation = [Action]{
    try {
        if ($edge.Active -and $null -ne $edge.Surface -and $edge.Surface.IsAttachedToWindow) {
            $edge.Surface.PostOnAnimation($edge.Tick)
            Invoke-AndroidCanvasFrame
        }
    }
    catch {
        [Android.Util.Log]::Error('PowerShell',
            "Canvas tick failed: $_ stack=$($_.ScriptStackTrace)")
    }
}.GetNewClosure()
[Dev.MansfieldPlumbing.Pwsh.RecoveryProgram]::SetAnimationCallback($onAnimation)
$callbackMethod = [Dev.MansfieldPlumbing.Pwsh.RecoveryProgram].GetMethod(
    'RunAnimationCallback',
    [Reflection.BindingFlags]'Public,Static')
[Action] $animationCallback = $callbackMethod.CreateDelegate([Action])
$tick = [Java.Lang.Runnable]::new($animationCallback)
$edge.Tick = $tick

[Action] $attach = [Action]{
    [Android.Views.SurfaceView] $surface = [Android.Views.SurfaceView]::new($activity)
    $surface.KeepScreenOn = $true
    $surface.Focusable = $true
    $surface.FocusableInTouchMode = $true
    [single] $requestedFrameRate = 0
    if ([int][Android.OS.Build+VERSION]::SdkInt -ge 35) {
        $surface.RequestedFrameRate = [single]120.0
        $requestedFrameRate = $surface.RequestedFrameRate
    }
    $surface.add_Touch($touch)
    $surface.add_KeyPress($keyPress)
    $edge.Surface = $surface
    $activity.SetContentView($surface)
    [Android.Util.Log]::Info('PowerShell',
        "Canvas window touchBoost=$($activity.Window.FrameRateBoostOnTouchEnabled) requestedFrameRate=$requestedFrameRate")
    [void]$surface.RequestFocus()

    try {
        [Android.OS.PerformanceHintManager] $hintManager =
            $activity.GetSystemService([Android.Content.Context]::PerformanceHintService)
        if ($null -ne $hintManager) {
            $edge.HintManager = $hintManager
            $edge.HintSession = $hintManager.CreateHintSession(
                [int[]]@([Android.OS.Process]::MyTid()), $edge.TargetNanos)
            [Android.Util.Log]::Info('PowerShell',
                "Canvas performance hint tid=$([Android.OS.Process]::MyTid()) target=$($edge.TargetNanos)ns preferred=$($hintManager.PreferredUpdateRateNanos)ns")
        }
    }
    catch {
        [Android.Util.Log]::Warn('PowerShell',
            "Canvas performance hint unavailable: $_")
    }

    $surface.PostOnAnimation($tick)
    [Android.Util.Log]::Info('PowerShell',
        "Canvas attached view=$($surface.GetType().FullName) generation=$generation scheduler=PostOnAnimation")
}.GetNewClosure()

$activity.RunOnUiThread($attach)
