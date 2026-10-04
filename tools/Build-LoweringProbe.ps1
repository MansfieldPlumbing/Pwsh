<#
.SYNOPSIS
    Stages the PSLowering device probe: compiled fixtures, their PowerShell
    sources, the oracle vectors and scripts/probes/lowering/Profile.ps1.
.DESCRIPTION
    PSLowering is taken from GitHub at a pinned commit into the git-ignored
    build/cache, never from another checkout; the fetched commit must be the
    pinned one, which fixes every file's content. Every fixture class that
    tests/oracle/OracleVectors.ps1 calls is compiled with -Deterministic.
    The staged directory is what tools/Invoke-DeviceScript.ps1 places in the
    app's private files directory.
.EXAMPLE
    .\tools\Build-LoweringProbe.ps1
    .\tools\Invoke-DeviceScript.ps1 -Path .\build\probes\lowering -AliveSeconds 20
#>
[CmdletBinding()]
param(
    [string] $Commit = '25427b25d9a7f4fd16568d74568cf6d2641b13e0'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $root "build/cache/pslowering/$Commit"
$stage = Join-Path $root 'build/probes/lowering'

if (-not (Test-Path -LiteralPath (Join-Path $cache '.git'))) {
    $null = New-Item -ItemType Directory -Force -Path $cache
    git -C $cache init -q
    git -C $cache fetch -q --depth 1 https://github.com/MansfieldPlumbing/PSLowering.git $Commit
    if ($LASTEXITCODE -ne 0) { throw "Fetching PSLowering $Commit failed." }
    git -C $cache -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
}
$head = "$(git -C $cache rev-parse HEAD)".Trim()
if ($head -ne $Commit) { throw "PSLowering cache is at $head, expected $Commit." }
if (@(git -C $cache status --porcelain).Count) { throw "PSLowering cache at $Commit has local changes." }

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $stage

Import-Module (Join-Path $cache 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force
$vectors = . (Join-Path $cache 'tests/oracle/OracleVectors.ps1')
$classes = $vectors | Select-Object Fixture, Class -Unique
foreach ($c in $classes) {
    $fixture = Join-Path $cache "tests/fixtures/$($c.Fixture)"
    Copy-Item -LiteralPath $fixture -Destination $stage -Force
    $null = Export-LoweredAssembly -SourcePath $fixture -ClassName $c.Class -OutputPath (Join-Path $stage "$($c.Class).dll") -Deterministic
}
Copy-Item -LiteralPath (Join-Path $cache 'tests/oracle/OracleVectors.ps1') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'scripts/probes/lowering/Profile.ps1') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'modules/AndroidCanvas.psm1') -Destination $stage

[pscustomobject]@{
    PSLowering = $Commit
    Classes    = @($classes).Count
    Calls      = ($vectors | ForEach-Object { $_.Inputs.Count } | Measure-Object -Sum).Sum
    Stage      = $stage
    Files      = @(Get-ChildItem -LiteralPath $stage -File).Count
    Compiler   = "PowerShell $($PSVersionTable.PSVersion) on $([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
}
