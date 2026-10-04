# Runs PSLowering's source oracle in the Pwsh app: every vector in
# OracleVectors.ps1 is called once as the fixture's PowerShell class, run by
# SMA on the device, and once from the assembly PSLowering compiled on the
# PC, loaded by path from the app's private files directory. Results must
# agree in value and type, or both calls must throw. Staged by
# tools/Build-LoweringProbe.ps1; see docs/lowering.md.
$ErrorActionPreference = 'Stop'
Import-Module ([IO.Path]::Combine($PSScriptRoot, 'AndroidCanvas.psm1'))

function Get-SourceType([string] $Path, [string] $Class) {
    . $Path
    $type = $Class -as [type]
    if (-not $type -or -not $type.Assembly.IsDynamic) { throw "$Path does not define PowerShell class $Class." }
    $type
}

function Invoke-Side([type] $Type, [string] $Method, [object[]] $Arguments) {
    $m = $Type.GetMethod($Method)
    $target = if ($m.IsStatic) { $null } else { [Activator]::CreateInstance($Type) }
    try { [pscustomobject]@{ Value = $m.Invoke($target, $Arguments); Error = $null } }
    catch {
        $e = $_.Exception
        while ($e -is [Reflection.TargetInvocationException] -or $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }
        [pscustomobject]@{ Value = $null; Error = $e.GetType().Name }
    }
}

function Test-Same($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $null -eq $A -and $null -eq $B }
    if ($A.GetType() -ne $B.GetType()) { return $false }
    if ($A -is [Array]) {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) { if (-not (Test-Same $A[$i] $B[$i])) { return $false } }
        return $true
    }
    if ($A -is [double] -and [double]::IsNaN($A)) { return [double]::IsNaN($B) }
    if ($A -is [float] -and [float]::IsNaN($A)) { return [float]::IsNaN($B) }
    [object]::Equals($A, $B)
}

try {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $calls = 0
    $divergences = [Collections.Generic.List[string]]::new()
    $compiled = @{}
    foreach ($v in . ([IO.Path]::Combine($PSScriptRoot, 'OracleVectors.ps1'))) {
        $source = Get-SourceType ([IO.Path]::Combine($PSScriptRoot, $v.Fixture)) $v.Class
        if (-not $compiled.ContainsKey($v.Class)) {
            $dll = [IO.Path]::Combine($PSScriptRoot, "$($v.Class).dll")
            $compiled[$v.Class] = [Reflection.Assembly]::LoadFile($dll).GetType($v.Class, $true)
        }
        foreach ($arguments in $v.Inputs) {
            $calls++
            $s = Invoke-Side $source $v.Method $arguments
            $c = Invoke-Side $compiled[$v.Class] $v.Method $arguments
            $same = if ($s.Error -or $c.Error) { [bool]$s.Error -and [bool]$c.Error } else { Test-Same $s.Value $c.Value }
            if (-not $same) {
                $sText = if ($s.Error) { "throws $($s.Error)" } else { "$($s.Value)" }
                $cText = if ($c.Error) { "throws $($c.Error)" } else { "$($c.Value)" }
                $divergences.Add("$($v.Class).$($v.Method) call $calls PowerShell: $sText compiled: $cText")
            }
        }
    }
    foreach ($d in $divergences | Select-Object -First 10) { Write-AndroidLog "LOWERING DIVERGE $d" 5 }
    Write-AndroidLog ('LOWERING calls {0} divergences {1} assemblies {2} in {3:N0} ms on {4} {5}' -f
        $calls, $divergences.Count, $compiled.Count, $clock.Elapsed.TotalMilliseconds,
        [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription,
        [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
}
catch {
    try { Write-AndroidLog ('LOWERING threw ' + $_.Exception.GetType().FullName + ': ' + $_.Exception.Message) 6 } catch { }
}
