<#
.SYNOPSIS
    Runs a script as Profile.ps1 in the installed Pwsh app on attached devices
    and reports what happened. No rebuild: the app must be a -Debuggable build
    so that run-as can write its private files directory.

.DESCRIPTION
    For each selected device: optionally installs an APK, places the script
    (or every file of a directory holding Profile.ps1) in the app's files
    directory, starts the activity, waits for the host's RunPowerShell marker,
    lets callbacks run for -SettleSeconds, and reports the app's log lines
    (tag Pwsh), the launch time, whether the process is still alive after
    -AliveSeconds, and crash-buffer lines for the process. -CapturePath saves a
    raw screencap per device for inspection.

    Devices are selected by model (ro.product.model), 'emulator', or 'all'.
    Serials are used internally and never printed. The tool touches only the
    app's own package, process and private files, and writes nothing inside
    the repository.

.EXAMPLE
    .\tools\Invoke-DeviceScript.ps1 -Path .\scripts\ScreenProbe.ps1
.EXAMPLE
    .\tools\Invoke-DeviceScript.ps1 -Path .\work\jni -Device emulator -Apk .\build\dev.mansfieldplumbing.pwsh.apk
.EXAMPLE
    .\tools\Invoke-DeviceScript.ps1 -Clear -Device all
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run', Position = 0)][string] $Path,
    [string[]] $Device = @('all'),
    [Parameter(ParameterSetName = 'Run')][string] $Apk,
    [Parameter(ParameterSetName = 'Run')][ValidateRange(0, 600)][int] $SettleSeconds = 3,
    [Parameter(ParameterSetName = 'Run')][ValidateRange(0, 600)][int] $AliveSeconds = 10,
    [Parameter(ParameterSetName = 'Run')][ValidateRange(5, 900)][int] $TimeoutSeconds = 90,
    [Parameter(ParameterSetName = 'Run')][string] $CapturePath,
    [Parameter(Mandatory, ParameterSetName = 'Clear')][switch] $Clear,
    [string] $Adb
)
$ErrorActionPreference = 'Stop'
$package = 'dev.mansfieldplumbing.pwsh'

if (-not $Adb) {
    $Adb = (Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $Adb) {
        foreach ($root in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT) | Where-Object { $_ }) {
            $candidate = Join-Path $root ('platform-tools/adb' + $(if ($IsWindows) { '.exe' } else { '' }))
            if (Test-Path -LiteralPath $candidate) { $Adb = $candidate; break }
        }
    }
    if (-not $Adb) { throw 'adb not found: put it on PATH, set ANDROID_HOME, or pass -Adb.' }
}

# The files to place. A directory must hold Profile.ps1 (any case); a file is
# placed as Profile.ps1.
$files = [ordered]@{}
if ($PSCmdlet.ParameterSetName -eq 'Run') {
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $item.FullName -File) {
            if ($f.Name -notmatch '^[A-Za-z0-9._-]+$') { throw "File name not accepted for run-as placement: $($f.Name)" }
            $files[$f.Name] = $f.FullName
        }
        if (-not @($files.Keys | Where-Object { $_ -ieq 'Profile.ps1' })) { throw "$Path holds no Profile.ps1." }
    }
    else { $files['Profile.ps1'] = $item.FullName }
    if ($Apk) { $Apk = (Resolve-Path -LiteralPath $Apk).Path }
    if ($CapturePath) { [void](New-Item -ItemType Directory -Force -Path $CapturePath); $CapturePath = (Resolve-Path -LiteralPath $CapturePath).Path }
}

$targets = foreach ($line in (& $Adb devices | Select-Object -Skip 1 | Where-Object { $_ -match "`tdevice$" })) {
    $serial = ($line -split "`t")[0]
    $model = "$(& $Adb -s $serial shell getprop ro.product.model)".Trim()
    $emulator = "$(& $Adb -s $serial shell getprop ro.kernel.qemu)".Trim() -eq '1'
    $name = if ($emulator) { 'emulator' } else { $model }
    if ($Device -contains 'all' -or $Device -contains $name -or $Device -contains $model) {
        [pscustomobject]@{ Serial = $serial; Name = $name; Abi = "$(& $Adb -s $serial shell getprop ro.product.cpu.abi)".Trim() }
    }
}
if (-not $targets) { throw "No attached device matches: $($Device -join ', ')." }

$run = {
    param($Target, $Adb, $Package, $Files, $Apk, $Clear, $SettleSeconds, $AliveSeconds, $TimeoutSeconds, $CapturePath)
    $ErrorActionPreference = 'Stop'
    $s = $Target.Serial
    function Adb { & $Adb -s $s @args }
    $result = [ordered]@{ Device = $Target.Name; Abi = $Target.Abi }

    if ($Apk) { $result.Install = (Adb install -r $Apk 2>&1 | Select-Object -Last 1) }
    $probe = Adb shell run-as $Package true 2>&1
    if ($LASTEXITCODE -ne 0) { $result.Result = "run-as refused (not a -Debuggable build?): $probe"; return [pscustomobject]$result }

    Adb shell am force-stop $Package | Out-Null
    $existing = @(Adb shell run-as $Package ls files 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._-]+\.ps1$' })
    foreach ($name in $existing) { Adb shell run-as $Package rm -f "files/$name" | Out-Null }
    if ($Clear) { $result.Result = "cleared $($existing.Count) script(s)"; return [pscustomobject]$result }
    foreach ($entry in $Files.GetEnumerator()) {
        [IO.File]::ReadAllText($entry.Value) | & $Adb -s $s exec-in run-as $Package sh -c "cat > files/$($entry.Key)"
    }

    $component = "$(Adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $Package | Select-Object -Last 1)".Trim()
    if ($component -notmatch '/') { $component = "$(Adb shell cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER $Package | Select-Object -Last 1)".Trim() }
    if ($component -notmatch '/') { $result.Result = 'no launcher activity resolved'; return [pscustomobject]$result }

    Adb logcat -c
    $started = "$(Adb shell date +%s)".Trim()
    Adb shell input keyevent KEYCODE_WAKEUP | Out-Null
    $launch = @(Adb shell am start -W -n $component)
    $total = @($launch | Where-Object { $_ -match '^TotalTime:\s*\d+' } | Select-Object -First 1)
    $result.LaunchMs = if ($total) { [int]($total[0] -replace '\D', '') } else { $null }
    $result.LaunchState = (@($launch | Where-Object { $_ -match '^(Status|LaunchState):' }) -join ' ').Trim()
    $procId = "$(Adb shell pidof $Package)".Trim()
    if (-not $procId) { $result.Result = 'process did not start'; return [pscustomobject]$result }

    # Block on the host's marker, bounded so a missing marker cannot hang the run.
    $out = [IO.Path]::GetTempFileName()
    $wait = Start-Process $Adb -ArgumentList '-s', $s, 'logcat', "--pid=$procId", '-e', 'RunPowerShell returned|Admit returned 0x[0-9a-f]+, expected', '-m', '1' -PassThru -NoNewWindow -RedirectStandardOutput $out
    if (-not $wait.WaitForExit($TimeoutSeconds * 1000)) { $wait.Kill(); $result.Timeout = $true }
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    Start-Sleep -Seconds $SettleSeconds

    if ($CapturePath) {
        $raw = Join-Path $CapturePath ("{0}.raw" -f ($Target.Name -replace '\W', ''))
        if ($IsWindows) { cmd /c "`"$Adb`" -s $s exec-out screencap > `"$raw`"" } else { sh -c "'$Adb' -s '$s' exec-out screencap > '$raw'" }
        $result.Capture = $raw
    }
    $lines = @(Adb logcat -d -v time --pid=$procId -s Pwsh:V | Where-Object { $_ -match '\bPwsh\b' })
    $returned = @($lines | Where-Object { $_ -match 'RunPowerShell returned (0x[0-9a-fA-F]+)' } | Select-Object -Last 1)
    $result.Returned = if ($returned -and $returned[0] -match 'RunPowerShell returned (0x[0-9a-fA-F]+)') { $Matches[1] } else { '' }
    Start-Sleep -Seconds $AliveSeconds
    $lines = @(Adb logcat -d -v time --pid=$procId -s Pwsh:V | Where-Object { $_ -match '\bPwsh\b' })
    $result.Alive = "$(Adb shell pidof $Package)".Trim() -eq $procId
    $result.CrashLines = @(Adb logcat -d -b crash -v threadtime -T $started 2>$null | Where-Object { $_ -match [regex]::Escape($Package) -or $_ -match "\s$procId\s" }).Count
    # Each line keeps its logcat time of day, so phases can be timed.
    $result.Log = @($lines | ForEach-Object { ($_ -replace '^\S+\s+(\S+)\s+\w/Pwsh\s*\(\s*\d+\):\s*', '$1 ') })
    [pscustomobject]$result
}

$jobs = foreach ($t in $targets) {
    Start-ThreadJob -Name $t.Name -ScriptBlock $run -ArgumentList $t, $Adb, $package, $files, $Apk, $Clear.IsPresent, $SettleSeconds, $AliveSeconds, $TimeoutSeconds, $CapturePath
}
foreach ($job in $jobs) {
    $out = @(Receive-Job $job -Wait -AutoRemoveJob -ErrorAction SilentlyContinue -ErrorVariable failed)
    foreach ($o in $out) { $o }
    foreach ($f in $failed) {
        # A failure inside one device's run is reported, not rethrown, so the
        # other devices' results still arrive.
        $message = "$($f.Exception.Message) | $(([string]$f.ScriptStackTrace -split "`n")[0])"
        foreach ($t in $targets) { $message = $message.Replace($t.Serial, '<device>') }   # serials are personal data; never print them
        [pscustomobject]@{ Device = $job.Name; Result = "tool error: $message" }
    }
}
