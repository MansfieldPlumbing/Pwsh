<#
.SYNOPSIS
Tests the parser commands in scripts/commands/Parsers by bare name through PATH.
.DESCRIPTION
Puts the parser directory first on PATH for this process only and calls each
parser by name, as the app does with PWSH_APP_SCRIPTS. Every case runs; the
exit code is the number of failed cases. Cases derive from the donor tests at
github.com/MansfieldPlumbing/subsystem 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb
(src/runspace/scripts/zoo/Test-Parsers.ps1), plus empty-input cases and cases
that pin the documented limitations so a behaviour change is noticed.
#>
[CmdletBinding()]
param()

$parsers = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/commands/Parsers'
$env:PATH = $parsers + [IO.Path]::PathSeparator + $env:PATH

$failures = [Collections.Generic.List[string]]::new()
function Assert-Case([string] $Name, $Actual, $Expected) {
    if ("$Actual" -cne "$Expected") { $failures.Add("$Name expected '$Expected', got '$Actual'") }
}

foreach ($command in 'ConvertFrom-KeyValue', 'ConvertFrom-Settings', 'ConvertFrom-Table', 'ConvertFrom-DumpsysTree') {
    $info = Get-Command $command -ErrorAction SilentlyContinue
    Assert-Case "$command resolves as ExternalScript" $info.CommandType 'ExternalScript'
    Assert-Case "$command resolves from Parsers" (Split-Path -Parent $info.Source) $parsers
    Assert-Case "$command has a synopsis" ([bool](Get-Help $command).Synopsis.Trim()) $true
}

# ConvertFrom-KeyValue
$kv = "Level: 100", "Technology: Li-ion", "[sys.usb.config]: [adb]", "[sys.usb.state]: [adb]" | ConvertFrom-KeyValue
Assert-Case 'KeyValue Level' $kv.Level '100'
Assert-Case 'KeyValue Technology' $kv.Technology 'Li-ion'
Assert-Case 'KeyValue getprop form' $kv.'sys.usb.config' 'adb'
$records = "a=1", "", "a=2" | ConvertFrom-KeyValue
Assert-Case 'KeyValue blank line splits records' @($records).Count 2
$pairs = "a=1", "b: 2" | ConvertFrom-KeyValue -AsKeyValuePair
Assert-Case 'KeyValue -AsKeyValuePair count' @($pairs).Count 2
Assert-Case 'KeyValue no separators yields nothing' @("just text" | ConvertFrom-KeyValue).Count 0

# ConvertFrom-Settings
$settings = "airplane_mode_on=0", "device_name=motorola razr+ 2024", "=orphan", "no separator" | ConvertFrom-Settings
Assert-Case 'Settings count ignores invalid lines' @($settings).Count 2
Assert-Case 'Settings key 0' $settings[0].Key 'airplane_mode_on'
Assert-Case 'Settings value 1 keeps spaces' $settings[1].Value 'motorola razr+ 2024'
Assert-Case 'Settings value keeps later =' ("k=a=b" | ConvertFrom-Settings).Value 'a=b'

# ConvertFrom-Table
$table = "PID PPID USER RSS_KB Name", "123 1 root 4567 system_server", "789 123 radio 1234 com.android.phone" | ConvertFrom-Table
Assert-Case 'Table count' @($table).Count 2
Assert-Case 'Table PID 1' $table[1].PID '789'
Assert-Case 'Table Name 1' $table[1].Name 'com.android.phone'
Assert-Case 'Table last column takes the rest' ("A B", "1 two words" | ConvertFrom-Table).B 'two words'
Assert-Case 'Table short row pads with null' ($null -eq ("A B C", "1" | ConvertFrom-Table).C) $true
# Documented limitation: a multi-word header splits into two columns.
$df = "Filesystem Size Mounted on", "/dev/x 1G /data" | ConvertFrom-Table
Assert-Case 'Table limitation: multi-word header' "$($df.Mounted)|$($df.on)" '/data|'
Assert-Case 'Table -Header works around it' ("/dev/x 1G /data" | ConvertFrom-Table -Header Filesystem, Size, MountedOn).MountedOn '/data'

# ConvertFrom-DumpsysTree
$tree = "Settings:", "  version=4", "  min_futurity=+5s0ms", "Whitelist system apps:", "  com.android.providers.calendar", "  com.motorola.mobiledesktop.core" | ConvertFrom-DumpsysTree
Assert-Case 'Tree nested property' $tree.Settings.version '4'
Assert-Case 'Tree nested property with sign' $tree.Settings.min_futurity '+5s0ms'
Assert-Case 'Tree string list count' $tree.'Whitelist system apps'.Count 2
Assert-Case 'Tree string list item' $tree.'Whitelist system apps'[1] 'com.motorola.mobiledesktop.core'
$repeated = "Item:", "  a=1", "Item:", "  a=2" | ConvertFrom-DumpsysTree
Assert-Case 'Tree repeated name becomes array' @($repeated.Item).Count 2
Assert-Case 'Tree blank lines from a pipeline bind' ("Power:", "", "  level=5", "" | ConvertFrom-DumpsysTree).Power.level '5'
Assert-Case 'Table blank lines from a pipeline bind' @("A B", "", "1 2" | ConvertFrom-Table).Count 1
# Documented limitation: several pairs on one line stay in one value.
Assert-Case 'Tree limitation: one line, two pairs' ("Root:", "  mEnabled=true mLevel=5" | ConvertFrom-DumpsysTree).Root.mEnabled 'true mLevel=5'

foreach ($failure in $failures) { Write-Host "FAIL $failure" }
Write-Host ("Parsers: {0} failure(s)" -f $failures.Count)
exit $failures.Count
