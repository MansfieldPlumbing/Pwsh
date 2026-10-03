# P1 diagnostic only: hardware rasterization and retained drawing primitives.
# The runner stages the module and the font whose identity is in receipt-inputs.json.
# No command execution, frame pump or application/session architecture lives here.
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle -Hardware -TraceFrameTiming
if ([Environment]::GetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT') -cne '1') { throw 'Host telemetry opt-out is missing.' }
$telemetry = [Management.Automation.PSObject].Assembly.GetType('Microsoft.PowerShell.Telemetry.ApplicationInsightsTelemetry', $true)
$staticMembers = [Reflection.BindingFlags]'Public,NonPublic,Static'
if ($telemetry.GetProperty('CanSendTelemetry', $staticMembers).GetValue($null)) { throw 'SMA telemetry is enabled.' }
if ($null -ne $telemetry.GetProperty('s_telemetryClient', $staticMembers).GetValue($null)) { throw 'SMA created a telemetry client.' }
Write-AndroidLog 'P1 TELEMETRY disabled; no client'
$commandFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'AndroidCanvas.psm1' -File)
if ($commandFiles.Count -ne 1) { throw 'Get-ChildItem did not return the staged module.' }
$commandJson = ConvertTo-Json -InputObject $commandFiles[0].Name -Compress
if ((ConvertFrom-Json -InputObject $commandJson) -cne 'AndroidCanvas.psm1') { throw 'The JSON command round trip failed.' }
Write-AndroidLog 'P1 COMMANDS Get-ChildItem, ConvertTo-Json, ConvertFrom-Json passed'
$global:HardwareProbeFont = Get-AndroidTypeface ([IO.Path]::Combine($PSScriptRoot, 'FluentSystemIcons-Regular.ttf'))
$global:HardwareProbeFrames = 0
$global:HardwareProbeDirty = $false
Register-WindowDrawHandler {
    param([IntPtr] $Canvas)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $size = Get-CanvasSize $Canvas
    $w = [float]$size.Width; $h = [float]$size.Height
    $background = ConvertTo-ArgbColor 12 12 12
    $white = ConvertTo-ArgbColor 255 255 255
    $yellow = ConvertTo-ArgbColor 249 241 165
    $green = ConvertTo-ArgbColor 19 161 14
    $blue = ConvertTo-ArgbColor 58 150 221
    Clear-Canvas $Canvas -Color $background
    # A tab-shaped control strip is drawn outside any terminal grid.
    Add-CanvasRoundRect $Canvas ($w * .04) ($h * .08) ($w * .46) ($h * .18) 12 -Color $blue
    Add-CanvasRoundRect $Canvas ($w * .50) ($h * .08) ($w * .92) ($h * .18) 12 -Color $yellow
    $ansi = @(@(12,12,12), @(197,15,31), @(19,161,14), @(193,156,0),
              @(0,55,218), @(136,23,152), @(58,150,221), @(204,204,204))
    for ($i = 0; $i -lt 8; $i++) {
        Add-CanvasRect $Canvas ($w * $i / 8) ($h * .25) ($w * ($i + 1) / 8) ($h * .35) `
            -Color (ConvertTo-ArgbColor $ansi[$i][0] $ansi[$i][1] $ansi[$i][2])
    }
    # Two nested saves exercise translated clipping and both restore levels.
    $outer = Save-CanvasState $Canvas
    try {
        Move-CanvasOrigin $Canvas ($w * .10) ($h * .45)
        [void](Set-CanvasClip $Canvas 0 0 ($w * .80) ($h * .25))
        Add-CanvasRect $Canvas (-$w) (-$h) $w $h -Color $yellow
        $inner = Save-CanvasState $Canvas
        try {
            [void](Set-CanvasClip $Canvas ($w * .20) ($h * .05) ($w * .60) ($h * .15))
            Add-CanvasRect $Canvas (-$w) (-$h) $w $h -Color $blue
        }
        finally { Restore-CanvasState $Canvas $inner }
        Add-CanvasRect $Canvas 0 ($h * .20) ($w * .80) ($h * .25) -Color $green
    }
    finally { Restore-CanvasState $Canvas $outer }
    Add-CanvasRect $Canvas ($w * .02) ($h * .74) ($w * .98) ($h * .77) -Color $white
    Add-CanvasRoundRect $Canvas ($w * .10) ($h * .80) ($w * .50) ($h * .93) 24 -Color $blue
    # U+F6AA is a glyph in the pinned Fluent font, rather than a system font.
    Add-CanvasText $Canvas ([string][char]0xF6AA) -X ($w * .62) -Y ($h * .91) `
        -Size ($h * .08) -Color $white -Typeface $global:HardwareProbeFont
    $global:HardwareProbeFrames++
    $watch.Stop()
    Write-AndroidLog ('P1 FRAME {0} hardware={1} size={2}x{3} submitMs={4:F3}' -f
        $global:HardwareProbeFrames, (Test-CanvasHardware $Canvas), $size.Width, $size.Height, $watch.Elapsed.TotalMilliseconds)
}
Register-InputHandler -Handle {
    param($Event)
    if ($Event.Type -eq 'motion' -and ($Event.Action -band 255) -eq 1) { $global:HardwareProbeDirty = $true }
    return $true
} -AfterInput {
    if ($global:HardwareProbeDirty) { $global:HardwareProbeDirty = $false; Request-WindowDraw }
}
Write-AndroidLog 'P1 READY hardware-only; redraws follow window/input events'
