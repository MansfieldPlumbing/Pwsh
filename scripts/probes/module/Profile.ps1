# AndroidCanvas.psm1 demo: a terminal-shaped frame and the eight ANSI colors.
# Place with the module: tools/Invoke-DeviceScript.ps1 copies every file in
# the directory, so copy modules/AndroidCanvas.psm1 next to this file first.
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))
Initialize-AndroidCanvas -NativeActivity $NativeActivityHandle
Register-WindowDrawHandler {
    param($Canvas)
    $size = Get-CanvasSize $Canvas
    $text = [float]([Math]::Min($size.Width, $size.Height) / 22)
    $cell = Get-TextCell $text
    Clear-Canvas $Canvas -Color (ConvertTo-ArgbColor 12 12 12)
    $y = $cell.Height * 1.5
    foreach ($line in @(
        "Pwsh $($PSVersionTable.PSVersion) on .NET $([Environment]::Version)",
        "$([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture), AndroidCanvas.psm1",
        'PS /data/user/0/dev.mansfieldplumbing.pwsh/files> _')) {
        Add-CanvasText $Canvas $line -X $cell.Width -Y $y -Size $text -Color (ConvertTo-ArgbColor 204 204 204)
        $y += $cell.Height
    }
    $ansi = @(@(12, 12, 12), @(197, 15, 31), @(19, 161, 14), @(193, 156, 0), @(0, 55, 218), @(136, 23, 152), @(58, 150, 221), @(204, 204, 204))
    $w = $size.Width / 8.0
    for ($c = 0; $c -lt 8; $c++) {
        Add-CanvasRect $Canvas ($c * $w) ($size.Height * 0.50) (($c + 1) * $w) ($size.Height * 0.62) -Color (ConvertTo-ArgbColor $ansi[$c][0] $ansi[$c][1] $ansi[$c][2])
    }
    Write-AndroidLog ('MODULE drew {0}x{1} cell {2:N1}x{3:N1}' -f $size.Width, $size.Height, $cell.Width, $cell.Height)
}
Write-AndroidLog 'MODULE handler registered'