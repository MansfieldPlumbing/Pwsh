#requires -Version 7.4
using module ./UsbAdb.psm1
<#
.SYNOPSIS
    Android Debug Bridge in PowerShell: a drop-in replacement for adb.exe.
.DESCRIPTION
    The same verbs, -s device selection and text output as adb.exe, over the
    WinUSB transport in UsbAdb.psm1: no adb.exe, no server on TCP 5037, no C#.
    For structured results in scripts, use the module's Invoke-AdbShell,
    Send-AdbFile, Receive-AdbFile and Install-AdbPackage instead.
    A failing remote command sets the exit code; it never ends the host.
.EXAMPLE
    adb devices -l
.EXAMPLE
    adb shell -s 0 getprop ro.build.version.sdk
.EXAMPLE
    adb install -s 1 -r ./app.apk
.NOTES
    Adapted on 2026-10-03 from the owner's ADB working folder (adb.ps1, SHA-256
    F4CA28E26286B1AA5536E08E33FFFA723854B578FB4CF5823E41051D7B315865): device
    selection moved into the module, install added, exit codes instead of
    $host.SetShouldExit.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $CommandArgs = @()
)

$ErrorActionPreference = 'Stop'

# adb.exe takes -s <device> anywhere after the verb.
$selector = ''
$rest = [System.Collections.Generic.List[string]]::new()
for ($i = 0; $i -lt $CommandArgs.Count; $i++) {
    if ($CommandArgs[$i] -ceq '-s' -and ($i + 1) -lt $CommandArgs.Count) { $selector = $CommandArgs[++$i] }
    else { $rest.Add($CommandArgs[$i]) }
}

switch ($Command.ToLowerInvariant()) {
    'start-server' { Start-AdbServer; 'connection holder running' }
    'kill-server' { Stop-AdbServer }
    'devices' {
        'List of devices attached'
        foreach ($d in @(Get-AdbDevice)) {
            $state = if ($d.IsAccessible) { 'device' } else { 'unauthorized' }
            if ($rest -contains '-l') {
                $extra = "usb:$($d.RedactedInstanceId)"
                if (-not $d.IsAccessible) { $extra += " error:$($d.AccessError)" }
                "[{0}] {1}`t{2}`t{3}" -f $d.Index, $d.FriendlyName, $state, $extra
            }
            else { "[{0}] {1}`t{2}" -f $d.Index, $d.FriendlyName, $state }
        }
    }
    'shell' {
        if ($rest.Count -eq 0) { throw 'Usage: adb shell [-s <device>] <command>' }
        $r = Invoke-AdbShell -Command ($rest -join ' ') -Device $selector
        if ($r.Stdout) { [Console]::Out.Write($r.Stdout) }
        if ($r.Stderr) { [Console]::Error.Write($r.Stderr) }
        exit $r.ExitCode
    }
    'push' {
        if ($rest.Count -lt 2) { throw 'Usage: adb push [-s <device>] <local> <remote>' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Send-AdbFile -Path $rest[0] -Destination $rest[1] -Device $selector
        '{0}: 1 file pushed. {1} bytes in {2:F3}s' -f $rest[0], (Get-Item -LiteralPath $rest[0]).Length, $sw.Elapsed.TotalSeconds
    }
    'pull' {
        if ($rest.Count -lt 2) { throw 'Usage: adb pull [-s <device>] <remote> <local>' }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Receive-AdbFile -Source $rest[0] -Destination $rest[1] -Device $selector
        '{0}: 1 file pulled. {1} bytes in {2:F3}s' -f $rest[0], (Get-Item -LiteralPath $rest[1]).Length, $sw.Elapsed.TotalSeconds
    }
    'install' {
        $apk = @($rest | Where-Object { $_ -notlike '-*' })
        if ($apk.Count -ne 1) { throw 'Usage: adb install [-s <device>] [-r] <apk>' }
        $r = Install-AdbPackage -Path $apk[0] -Device $selector -Replace:($rest -contains '-r')
        $r.Output
    }
    'pubkey' { [UsbAdbCrypto]::GetPublicKeyString() }
    'version' {
        'Android Debug Bridge in PowerShell (WinUSB transport)'
        'Protocol version 0x01000001, MAX_PAYLOAD 1048576, shell_v2, sync_v1'
    }
    default {
        @'
Android Debug Bridge in PowerShell

  adb devices [-l]
  adb start-server | kill-server
  adb shell   [-s <device>] <command>
  adb push    [-s <device>] <local> <remote>
  adb pull    [-s <device>] <remote> <local>
  adb install [-s <device>] [-r] <apk>
  adb pubkey
  adb version

  -s <index>   zero-based index from 'adb devices'
  -s <name>    unique substring of the device's friendly name
'@
    }
}
