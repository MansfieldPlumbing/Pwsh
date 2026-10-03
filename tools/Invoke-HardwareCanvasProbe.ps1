<#
.SYNOPSIS
Runs the P1 fixture on one attached backend, preserving private startup files.
.DESCRIPTION
Use a setup.ps1 -Debuggable APK. Captures and receipts go under build/.
The fixture is diagnostic PowerShell, not proof of managed lowering or IME.
An existing Profile.ps1 is moved aside and restored, including on failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Apk,
    [Parameter(Mandatory)][string] $Font,
    [ValidateSet('x86_64','arm64-v8a','armeabi-v7a')][string] $Abi = 'x86_64',
    [string] $Adb = 'adb',
    [string] $OutputDirectory = '',
    [switch] $Resize,
    [ValidateRange(1,60)][int] $IdleSeconds = 10,
    [ValidateRange(40,60)][int] $AliveSeconds = 40
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$Apk = (Resolve-Path -LiteralPath $Apk).Path
$Font = (Resolve-Path -LiteralPath $Font).Path
$Adb = (Get-Command $Adb -CommandType Application | Select-Object -First 1).Source
if ((Get-FileHash -LiteralPath $Font).Hash -cne 'C5DAB901C52362ECC94D3A1D2C88A5C060464EB9EB58BB5B0D64D17066AF4D7F') {
    throw 'The fixture requires the roadmap-pinned Fluent font.'
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ('build/p1-' + [guid]::NewGuid().ToString('N')) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repo 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $OutputDirectory.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Probe output must be below build/.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory to preserve prior receipts.' }
[void](New-Item -ItemType Directory -Path $OutputDirectory)
$targets = @(foreach ($line in (& $Adb devices)) {
    if ($line -match '^([^\s]+)\s+device$') {
        $candidate = $Matches[1]
        if (("$(& $Adb -s $candidate shell getprop ro.product.cpu.abi)").Trim() -ceq $Abi) { $candidate }
    }
})
if ($targets.Count -ne 1) { throw "Expected one attached $Abi backend; found $($targets.Count)." }
$serial = $targets[0]
$package = 'dev.mansfieldplumbing.pwsh'
function Invoke-Adb {
    $result = @(& $Adb -s $serial @args 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'An adb operation failed; startup backups remain in the app and receipt directory.' }
    return $result
}
function Invoke-AdbBytes {
    param([string[]] $Arguments, [string] $InputPath, [string] $OutputPath)
    $info = [Diagnostics.ProcessStartInfo]::new($Adb)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in @('-s',$serial) + $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($info)
    try {
        $errorRead = $process.StandardError.ReadToEndAsync()
        if ($InputPath) {
            $inputStream = [IO.File]::OpenRead($InputPath)
            try { $inputStream.CopyTo($process.StandardInput.BaseStream) } finally { $inputStream.Dispose() }
        }
        $process.StandardInput.Close()
        if ($OutputPath) {
            $outputStream = [IO.File]::Create($OutputPath)
            try { $process.StandardOutput.BaseStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
        }
        else { [void]$process.StandardOutput.ReadToEnd() }
        $process.WaitForExit(); [void]$errorRead.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Binary adb transfer failed.' }
    }
    finally { $process.Dispose() }
}
function Get-ProbeLines {
    @(Invoke-Adb logcat -d -v brief "--pid=$appPid" -s Pwsh:V | Where-Object {
        $_ -match 'P1 (FRAME|READY|PRESENT|COMMANDS|TELEMETRY)|AndroidCanvas(:| cleanup:| window released)|GATE2[abcd]|RunPowerShell returned'
    })
}
function Save-ProbeCapture([string] $Name) {
    Invoke-AdbBytes -Arguments @('exec-out','screencap','-p') -OutputPath (Join-Path $OutputDirectory ($Name + '.png'))
}
$receipt = [ordered]@{
    Gate = 'P1'; Abi = $Abi; Utc = [DateTime]::UtcNow.ToString('o')
    ApkSha256 = (Get-FileHash -LiteralPath $Apk).Hash
    ModuleSha256 = (Get-FileHash (Join-Path $repo 'modules/AndroidCanvas.psm1')).Hash
    FixtureSha256 = (Get-FileHash (Join-Path $repo 'scripts/probes/hardware-canvas/Profile.ps1')).Hash
    FontSha256 = (Get-FileHash -LiteralPath $Font).Hash
    AdbSha256 = (Get-FileHash -LiteralPath $Adb).Hash
    Api = ("$(Invoke-Adb shell getprop ro.build.version.sdk)").Trim()
    Emulator = ("$(Invoke-Adb shell getprop ro.kernel.qemu)").Trim() -eq '1'
    HwuiRenderer = ("$(Invoke-Adb shell getprop debug.hwui.renderer)").Trim()
    GraphicsBackend = @(Invoke-Adb shell dumpsys SurfaceFlinger | Where-Object { $_ -match '^GLES:' })
    ProfileRestored = $false; Passed = $false
}
$stage = 'p1-' + [guid]::NewGuid().ToString('N')
$originalProfiles = @(); $movedProfiles = [Collections.Generic.List[string]]::new()
$fixturePlaced = $false; $appPid = ''; $failure = $null
$restoreDisplay = $false; $previousOverride = ''
try {
    Invoke-Adb install -r $Apk | Out-Null
    Invoke-Adb shell run-as $package true | Out-Null
    Invoke-Adb shell am force-stop $package | Out-Null
    Invoke-Adb shell run-as $package mkdir -p "files/$stage" | Out-Null
    $originalProfiles = @(Invoke-Adb shell run-as $package ls files | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '(?i)^profile\.ps1$' })
    foreach ($name in $originalProfiles) {
        Invoke-AdbBytes -Arguments @('exec-out','run-as',$package,'cat',"files/$name") -OutputPath (Join-Path $OutputDirectory ('previous-profile-' + $movedProfiles.Count + '.ps1'))
        Invoke-Adb shell run-as $package mv "files/$name" "files/$stage/previous-$name" | Out-Null
        $movedProfiles.Add($name)
    }
    $inputs = @{
        'Profile.ps1' = Join-Path $repo 'scripts/probes/hardware-canvas/Profile.ps1'
        'AndroidCanvas.psm1' = Join-Path $repo 'modules/AndroidCanvas.psm1'
        'FluentSystemIcons-Regular.ttf' = $Font
    }
    foreach ($entry in $inputs.GetEnumerator()) {
        Invoke-AdbBytes -Arguments @('exec-in','run-as',$package,'sh','-c',"cat > files/$stage/$($entry.Key)") -InputPath $entry.Value
    }
    $startup = Join-Path $OutputDirectory 'startup.ps1'
    [IO.File]::WriteAllText($startup, "& ([IO.Path]::Combine(`$PSScriptRoot, '$stage', 'Profile.ps1'))", [Text.UTF8Encoding]::new($false))
    $fixturePlaced = $true
    Invoke-AdbBytes -Arguments @('exec-in','run-as',$package,'sh','-c','cat > files/Profile.ps1') -InputPath $startup
    Invoke-Adb shell am start -W -n "$package/android.app.NativeActivity" | Out-Null
    $appPid = ("$(Invoke-Adb shell pidof $package)").Trim()
    if ($appPid -notmatch '^\d+$') { throw 'The application did not remain running after launch.' }
    # Blocking logcat waits observe fixture markers; no polling loop.
    function Start-MarkerWait([string] $Pattern) {
        $waitInfo = [Diagnostics.ProcessStartInfo]::new($Adb)
        $waitInfo.UseShellExecute = $false; $waitInfo.CreateNoWindow = $true
        $waitInfo.RedirectStandardOutput = $true; $waitInfo.RedirectStandardError = $true
        foreach ($argument in @('-s',$serial,'logcat',"--pid=$appPid",'-s','Pwsh:V','-e',$Pattern,'-m','1')) { $waitInfo.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($waitInfo)
        [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    }
    function Complete-MarkerWait($Wait, [int] $Seconds, [string] $Failure) {
        try {
            if (-not $Wait.Process.WaitForExit($Seconds * 1000)) { $Wait.Process.Kill(); throw $Failure }
            [void]$Wait.Out.GetAwaiter().GetResult(); [void]$Wait.Err.GetAwaiter().GetResult()
        }
        finally { $Wait.Process.Dispose() }
    }
    Complete-MarkerWait (Start-MarkerWait 'P1 FRAME|AndroidCanvas:|RunPowerShell returned 0x8') 60 'No frame marker within 60 seconds.'
    Start-Sleep -Seconds 2
    Save-ProbeCapture 'initial'
    $initial = @(Get-ProbeLines)
    $before = @($initial | Where-Object { $_ -match 'P1 FRAME' }).Count
    Start-Sleep -Seconds $IdleSeconds
    $afterIdle = @(Get-ProbeLines)
    $after = @($afterIdle | Where-Object { $_ -match 'P1 FRAME' }).Count
    $receipt.IdleSeconds = $IdleSeconds; $receipt.IdleAdditionalFrames = $after - $before
    Invoke-Adb shell input tap 400 600 | Out-Null
    Start-Sleep -Seconds 1
    Save-ProbeCapture 'after-input'
    $afterInput = @(Get-ProbeLines)
    $receipt.InputAdditionalFrames = @($afterInput | Where-Object { $_ -match 'P1 FRAME' }).Count - $after
    if ($Resize) {
        $wmLines = @(Invoke-Adb shell wm size)
        foreach ($line in $wmLines) { if ($line -match '^Override size: (\d+x\d+)$') { $previousOverride = $Matches[1] } }
        $restoreDisplay = $true
        Invoke-Adb shell wm size 900x1600 | Out-Null
        Start-Sleep -Seconds 3
        Save-ProbeCapture 'after-resize'
        $resized = @(Get-ProbeLines)
        $receipt.FrameSizes = @($resized | ForEach-Object { if ($_ -match 'P1 FRAME.*size=(\d+x\d+)') { $Matches[1] } } | Select-Object -Unique)
        $receipt.ResizeObserved = $receipt.FrameSizes.Count -gt 1
        if ($previousOverride) { Invoke-Adb shell wm size $previousOverride | Out-Null } else { Invoke-Adb shell wm size reset | Out-Null }
        $restoreDisplay = $false
        Start-Sleep -Seconds 2
    }
    # Relaunch only after the window is actually destroyed: a fixed delay can
    # resume the activity before it stops, and then no window is released.
    $releaseWait = Start-MarkerWait 'AndroidCanvas window released|AndroidCanvas:'
    Invoke-Adb shell input keyevent KEYCODE_HOME | Out-Null
    Complete-MarkerWait $releaseWait 30 'The window was not released within 30 seconds of HOME.'
    Invoke-Adb shell am start -W -n "$package/android.app.NativeActivity" | Out-Null
    Start-Sleep -Seconds 2
    Save-ProbeCapture 'after-resume'
    # Keep startup files staged through the established post-result lifetime
    # window. A short frame check missed an asynchronous TLS abort once.
    Start-Sleep -Seconds $AliveSeconds
    $receipt.PostResultAliveSeconds = $AliveSeconds
    $lines = @(Get-ProbeLines)
    $receipt.Markers = $lines
    $receipt.HardwareFrames = @($lines | Where-Object { $_ -match 'P1 FRAME.*hardware=True' }).Count
    $receipt.CommandsPassed = @($lines | Where-Object { $_ -match 'P1 COMMANDS.*passed' }).Count -gt 0
    $receipt.TelemetryDisabled = @($lines | Where-Object { $_ -match 'P1 TELEMETRY disabled; no client' }).Count -gt 0
    $receipt.WindowReleases = @($lines | Where-Object { $_ -match 'AndroidCanvas window released' }).Count
    $receipt.Errors = @($lines | Where-Object { $_ -match 'AndroidCanvas(:| cleanup:)|RunPowerShell returned 0x8|GATE2A .*failed' }).Count
    # The relaunch after HOME must draw again: frames logged after the last
    # window release. Android may resume the activity or re-create it in the
    # same process; either way a working session draws.
    $lastRelease = -1
    for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match 'AndroidCanvas window released') { $lastRelease = $k } }
    $receipt.RelaunchFrames = if ($lastRelease -ge 0) { @($lines[($lastRelease + 1)..($lines.Count - 1)] | Where-Object { $_ -match 'P1 FRAME.*hardware=True' }).Count } else { 0 }
    $receipt.ActivityRecreated = @($lines | Where-Object { $_ -match 'GATE2A' -and $_ -match 'Admit|coreclr' }).Count -gt 1
    $receipt.AliveSameProcess = ("$(Invoke-Adb shell pidof $package)").Trim() -ceq $appPid
    $receipt.CrashLines = @(Invoke-Adb logcat -d -b crash "--pid=$appPid" | Where-Object { $_ -notmatch '^---------|^\s*$' }).Count
    # Native tombstones are emitted by a separate debugger process. Check the
    # embedded app PID as well as messages emitted directly by the app.
    $receipt.NativeCrashRecords = @(Invoke-Adb logcat -d -b crash -v brief -e "pid: $appPid," | Where-Object {
        $_ -match ("pid:\s*" + $appPid + ',\s+tid:.*>>> ' + [regex]::Escape($package) + ' <<<')
    }).Count
    $receipt.JniErrors = @(Invoke-Adb logcat -d -v brief "--pid=$appPid" -e 'JNI DETECTED ERROR|JNI WARNING|JNI ERROR').Count
    $receipt.Passed = $receipt.HardwareFrames -gt 0 -and $receipt.Errors -eq 0 -and
        $receipt.AliveSameProcess -and $receipt.CrashLines -eq 0 -and $receipt.NativeCrashRecords -eq 0 -and $receipt.JniErrors -eq 0 -and
        $receipt.IdleAdditionalFrames -eq 0 -and $receipt.InputAdditionalFrames -gt 0
    if (-not $receipt.CommandsPassed -or -not $receipt.TelemetryDisabled -or $receipt.WindowReleases -lt 1 -or $receipt.RelaunchFrames -lt 1) { $receipt.Passed = $false }
    if ($Resize -and -not $receipt.ResizeObserved) { $receipt.Passed = $false }
}
catch { $failure = $_; $receipt.Failure = $_.Exception.Message }
finally {
    try {
        if ($restoreDisplay) {
            if ($previousOverride) { Invoke-Adb shell wm size $previousOverride | Out-Null } else { Invoke-Adb shell wm size reset | Out-Null }
        }
        if ($fixturePlaced) {
            $present = @(Invoke-Adb shell run-as $package ls files | Where-Object { $_.Trim() -ceq 'Profile.ps1' })
            if ($present.Count) { Invoke-Adb shell run-as $package mv files/Profile.ps1 "files/$stage/startup.ps1" | Out-Null }
        }
        foreach ($name in $movedProfiles) { Invoke-Adb shell run-as $package mv "files/$stage/previous-$name" "files/$name" | Out-Null }
        $receipt.ProfileRestored = $true
    }
    catch { $receipt.RestoreFailure = 'Restore the preserved startup files from the private staging directory.'; $receipt.Passed = $false }
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'receipt.json') -Encoding utf8
}
[pscustomobject]@{ Abi=$Abi; Passed=$receipt.Passed; ProfileRestored=$receipt.ProfileRestored; Receipt=Join-Path $OutputDirectory 'receipt.json' }
if ($failure) { throw $failure }
if (-not $receipt.Passed) { throw 'P1 marker, idle, input, liveness or crash acceptance failed; inspect the receipt.' }
