# Canvas probe: Android's own Canvas, Paint and Typeface through JNI on the
# NativeActivity window's Surface (ANativeWindow_toSurface). Draws monospace
# text lines and a band of the eight Campbell ANSI colors, then logs where.
$ErrorActionPreference = 'Stop'
. ([IO.Path]::Combine($PSScriptRoot, 'Jni.ps1'))
Add-NativeImport 'ANativeWindow_toSurface' 'libandroid.so' ([IntPtr]) @([IntPtr], [IntPtr])
Add-NativeImport 'ANativeWindow_setBuffersGeometry' 'libandroid.so' ([int]) @([IntPtr], [int], [int], [int])
Complete-NativeImports

$I = [IntPtr]
$global:Jni.CallFloatMethodA = Get-Jni CallFloatMethodA ([float]) @($I, $I, $I, $I)

# Classes are local references valid only during this call; keep global ones.
function Get-GlobalClass([string] $Name) { $l = Get-JClass $Name; $g = $global:Jni.NewGlobalRef.Invoke($global:JniEnv, $l); $global:Jni.DeleteLocalRef.Invoke($global:JniEnv, $l); $g }
$surfaceClass = Get-GlobalClass 'android/view/Surface'
$canvasClass = Get-GlobalClass 'android/graphics/Canvas'
$paintClass = Get-GlobalClass 'android/graphics/Paint'
$typefaceClass = Get-GlobalClass 'android/graphics/Typeface'
$global:K = @{
    PaintClass = $paintClass
    LockCanvas = Get-JMethod $surfaceClass 'lockCanvas' '(Landroid/graphics/Rect;)Landroid/graphics/Canvas;'
    UnlockCanvasAndPost = Get-JMethod $surfaceClass 'unlockCanvasAndPost' '(Landroid/graphics/Canvas;)V'
    GetWidth = Get-JMethod $canvasClass 'getWidth' '()I'
    GetHeight = Get-JMethod $canvasClass 'getHeight' '()I'
    DrawColor = Get-JMethod $canvasClass 'drawColor' '(I)V'
    DrawRect = Get-JMethod $canvasClass 'drawRect' '(FFFFLandroid/graphics/Paint;)V'
    DrawText = Get-JMethod $canvasClass 'drawText' '(Ljava/lang/String;FFLandroid/graphics/Paint;)V'
    PaintInit = Get-JMethod $paintClass '<init>' '(I)V'
    SetColor = Get-JMethod $paintClass 'setColor' '(I)V'
    SetTextSize = Get-JMethod $paintClass 'setTextSize' '(F)V'
    SetTypeface = Get-JMethod $paintClass 'setTypeface' '(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;'
    MeasureText = Get-JMethod $paintClass 'measureText' '(Ljava/lang/String;)F'
    GetFontSpacing = Get-JMethod $paintClass 'getFontSpacing' '()F'
    AntiAlias = $global:Jni.GetStaticIntField.Invoke($global:JniEnv, $paintClass, (Get-JField $paintClass 'ANTI_ALIAS_FLAG' 'I' -Static))
}
$mono = $global:Jni.GetStaticObjectField.Invoke($global:JniEnv, $typefaceClass, (Get-JField $typefaceClass 'MONOSPACE' 'Landroid/graphics/Typeface;' -Static))
$global:K.Monospace = $global:Jni.NewGlobalRef.Invoke($global:JniEnv, $mono)
$global:Ansi = @(
    @(12, 12, 12), @(197, 15, 31), @(19, 161, 14), @(193, 156, 0),
    @(0, 55, 218), @(136, 23, 152), @(58, 150, 221), @(204, 204, 204))   # Campbell 0-7
$global:Lines = @(
    "Pwsh $($PSVersionTable.PSVersion) on .NET $([Environment]::Version)",
    "$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture) | Android $($global:JniM::ReadInt32($global:JniActivity, 6 * [IntPtr]::Size))",
    'Canvas + Paint + Typeface.MONOSPACE through JNI',
    'PS /data/user/0/dev.mansfieldplumbing.pwsh/files> _')

function global:Show-Terminal([IntPtr] $Window) {
    $j = $global:Jni; $e = $global:JniEnv; $k = $global:K
    [void]$global:Ndk::ANativeWindow_setBuffersGeometry($Window, 0, 0, 1)   # WINDOW_FORMAT_RGBA_8888
    $surface = $global:Ndk::ANativeWindow_toSurface($e, $Window)
    $canvas = Invoke-JniA $j.CallObjectMethodA $surface $k.LockCanvas @([IntPtr]::Zero)
    try {
        $w = Invoke-JniA $j.CallIntMethodA $canvas $k.GetWidth; $h = Invoke-JniA $j.CallIntMethodA $canvas $k.GetHeight
        Invoke-JniA $j.CallVoidMethodA $canvas $k.DrawColor @((ConvertTo-ArgbInt 12 12 12))
        $paint = Invoke-JniA $j.NewObjectA $k.PaintClass $k.PaintInit @([int]$k.AntiAlias)
        [void](Invoke-JniA $j.CallObjectMethodA $paint $k.SetTypeface @([IntPtr]$k.Monospace))
        Invoke-JniA $j.CallVoidMethodA $paint $k.SetTextSize @([float]([Math]::Min($w, $h) / 22))
        $spacing = Invoke-JniA $j.CallFloatMethodA $paint $k.GetFontSpacing
        $m = New-JString 'M'; $cell = Invoke-JniA $j.CallFloatMethodA $paint $k.MeasureText @([IntPtr]$m); $j.DeleteLocalRef.Invoke($e, $m)
        Invoke-JniA $j.CallVoidMethodA $paint $k.SetColor @((ConvertTo-ArgbInt 204 204 204))
        $y = [float]$spacing * 1.5
        foreach ($line in $global:Lines) {
            $s = New-JString $line
            Invoke-JniA $j.CallVoidMethodA $canvas $k.DrawText @([IntPtr]$s, [float]$cell, [float]$y, [IntPtr]$paint)
            $j.DeleteLocalRef.Invoke($e, $s); $y += [float]$spacing
        }
        # ANSI band: eight equal cells across the full width at 50-62% height.
        $top = [float]($h * 0.50); $bottom = [float]($h * 0.62); $cw = $w / 8.0
        for ($c = 0; $c -lt 8; $c++) {
            $rgb = $global:Ansi[$c]
            Invoke-JniA $j.CallVoidMethodA $paint $k.SetColor @((ConvertTo-ArgbInt $rgb[0] $rgb[1] $rgb[2]))
            Invoke-JniA $j.CallVoidMethodA $canvas $k.DrawRect @([float]($c * $cw), $top, [float](($c + 1) * $cw), $bottom, [IntPtr]$paint)
        }
        $j.DeleteLocalRef.Invoke($e, $paint)
        Write-AndroidLog ('CANVAS drew {0}x{1} cell {2:N1}x{3:N1} lines {4} band {5:N0}-{6:N0}' -f $w, $h, $cell, $spacing, $global:Lines.Count, $top, $bottom)
    }
    finally {
        Invoke-JniA $j.CallVoidMethodA $surface $k.UnlockCanvasAndPost @([IntPtr]$canvas)
        $j.DeleteLocalRef.Invoke($e, $canvas); $j.DeleteLocalRef.Invoke($e, $surface)
    }
}

$cbType = Get-NativeDelegateType ([void]) @([IntPtr], [IntPtr])
$handler = { param([IntPtr] $Activity, [IntPtr] $Window)
    try { Show-Terminal $Window } catch { Write-AndroidLog ('CANVAS threw ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) 6 } }
$global:CanvasCreated = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $cbType)
$global:CanvasRedraw = [Management.Automation.LanguagePrimitives]::ConvertTo($handler, $cbType)
$callbacks = $global:JniM::ReadIntPtr($global:JniActivity, 0)
$global:JniM::WriteIntPtr($callbacks, 7 * [IntPtr]::Size, $global:JniM::GetFunctionPointerForDelegate($global:CanvasCreated))   # onNativeWindowCreated
$global:JniM::WriteIntPtr($callbacks, 9 * [IntPtr]::Size, $global:JniM::GetFunctionPointerForDelegate($global:CanvasRedraw))    # onNativeWindowRedrawNeeded
Write-AndroidLog 'CANVAS callbacks installed'
