#requires -Version 7.4

<#
.SYNOPSIS
    Computes the static AssemblyRef closure of root assemblies over pinned
    NuGet packages and reports every image with its provenance.

.DESCRIPTION
    Resolves the NuGet package graph of -RootPackages the way NuGet does (the
    lowest version that satisfies every range, failing when none does), with
    one addition: a dependency whose nuspec names the same repository commit
    as the runtime pack is taken at the runtime pack's version. It then walks
    AssemblyRef metadata from -Roots across the runtime pack and the resolved
    packages, and writes closure.json and closure.md.

    Every package is checked against the SHA-512 in NuGet's catalog. In pinned
    mode it is also checked against -PinFile, the resolved graph must
    reproduce the pins exactly, and a pin the graph does not use fails the run.

    The tool reads packages as bytes; it loads nothing into the session. It
    writes only inside -OutputDirectory and -CacheDirectory, refuses either
    inside a protected root unless it is under -WritableRoot, never
    overwrites a report,
    and fails when a reference is unresolved unless -AcceptUnresolved names it.

.PARAMETER PinFile
    JSON with dotNet, powerShell and packages (id, version, sha512). Written in
    candidate form by -Discover.

.PARAMETER Discover
    Resolve from nuspecs and write pins.candidate.json. Candidate pins are
    catalog hashes, not reviewed decisions.

.PARAMETER DotNet
    Runtime pack version (Microsoft.NETCore.App.Runtime.<rid>). Discover mode
    only; pinned mode reads it from -PinFile.

.PARAMETER PowerShell
    Version of -RootPackages. Discover mode only; pinned mode reads it from
    -PinFile.

.PARAMETER Rid
    Runtime identifier whose runtime pack supplies the framework images.

.PARAMETER Roots
    Assembly names the closure starts from.

.PARAMETER RootPackages
    Packages whose dependency graph is resolved, at -PowerShell.

.PARAMETER AcceptUnresolved
    Assembly names allowed to remain unresolved.

.PARAMETER OutputDirectory
    Where closure.json, closure.md and pins.candidate.json are written. Must
    not already hold any of them.

.PARAMETER CacheDirectory
    Package cache. Every cached package is re-verified on every read.

.PARAMETER ProtectedRoot
    Directories the tool never writes into. Defaults to the repository that
    contains this tool.

.PARAMETER WritableRoot
    Directories inside a protected root that may be written. Defaults to the
    repository's git-ignored build folder.

.PARAMETER Offline
    Use only the cache; requires pinned mode.

.EXAMPLE
    ./tools/Get-AssemblyClosure.ps1 -Discover -DotNet 11.0.0-rc.1.26425.128 -PowerShell 7.7.0-preview.5 -OutputDirectory $env:TEMP\closure\discover -CacheDirectory $env:TEMP\closure\cache

.EXAMPLE
    ./tools/Get-AssemblyClosure.ps1 -PinFile $env:TEMP\closure\pins.json -OutputDirectory $env:TEMP\closure\pinned -CacheDirectory $env:TEMP\closure\cache
#>
[CmdletBinding(DefaultParameterSetName = 'Pinned')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Pinned')]
    [string] $PinFile,

    [Parameter(Mandatory, ParameterSetName = 'Discover')]
    [switch] $Discover,
    [Parameter(Mandatory, ParameterSetName = 'Discover')]
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $DotNet,
    [Parameter(Mandatory, ParameterSetName = 'Discover')]
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $PowerShell,

    [ValidateSet('android-arm64', 'android-x64', 'android-arm')]
    [string] $Rid = 'android-arm64',

    [string[]] $Roots = @(
        'System.Management.Automation',
        'Microsoft.PowerShell.Commands.Utility',
        'Microsoft.PowerShell.Commands.Management',
        'Microsoft.PowerShell.Security'),

    # Packages whose graph is walked. Each is taken at -PowerShell in discover
    # mode.
    [string[]] $RootPackages = @(
        'System.Management.Automation',
        'Microsoft.PowerShell.Commands.Utility',
        'Microsoft.PowerShell.Commands.Management',
        'Microsoft.PowerShell.Security'),

    # Assembly names the closure may leave unresolved. Anything else
    # unresolved fails the run.
    [string[]] $AcceptUnresolved = @(),

    [Parameter(Mandatory)] [string] $OutputDirectory,
    [Parameter(Mandatory)] [string] $CacheDirectory,
    [string[]] $ProtectedRoot = @((Split-Path -Parent $PSScriptRoot)),
    [string[]] $WritableRoot = @((Join-Path (Split-Path -Parent $PSScriptRoot) 'build')),
    [switch] $Offline
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------- guards

# Resolves against PowerShell's current location, not the process directory,
# then normalizes '.' and '..'.
function Get-FullPath([string] $Path) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [IO.Path]::GetFullPath($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathInside([string] $Path, [string] $Root) {
    $base = Get-FullPath $Root
    $Path.Equals($base, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-Unprotected([string] $Path, [string] $Role) {
    $full = Get-FullPath $Path
    if (@($WritableRoot | Where-Object { Test-PathInside $full $_ }).Count) { return $full }
    foreach ($root in $ProtectedRoot) {
        if (Test-PathInside $full $root) { throw "$Role '$full' is inside protected root '$(Get-FullPath $root)'." }
    }
    $full
}

$OutputDirectory = Assert-Unprotected $OutputDirectory 'OutputDirectory'
$CacheDirectory = Assert-Unprotected $CacheDirectory 'CacheDirectory'
foreach ($report in 'closure.json', 'closure.md', 'pins.candidate.json') {
    $existing = Join-Path $OutputDirectory $report
    if (Test-Path -LiteralPath $existing) { throw "Refusing to overwrite '$existing'." }
}
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory, $CacheDirectory)

$probeSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash

# ---------------------------------------------------------------- pins

$pins = $null
if ($PSCmdlet.ParameterSetName -eq 'Pinned') {
    $pinPath = Get-FullPath $PinFile
    $pins = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in 'dotNet', 'powerShell', 'packages') {
        if (-not $pins.ContainsKey($key)) { throw "Pin file lacks '$key'." }
    }
    $DotNet = [string]$pins.dotNet
    $PowerShell = [string]$pins.powerShell
    $pinSha512 = @{}
    foreach ($p in $pins.packages) {
        $key = '{0} {1}' -f $p.id, $p.version
        if ($pinSha512.ContainsKey($key)) { throw "Pin file lists '$key' twice." }
        if ([string]$p.sha512 -notmatch '^[0-9A-F]{128}$') { throw "Pin for '$key' is not an upper-case SHA-512." }
        $pinSha512[$key] = [string]$p.sha512
    }
}
$runtimeTfmRank = 1000 + 10 * [int]($DotNet.Split('.')[0])

# ---------------------------------------------------------------- feed

$serviceIndex = $null
function Get-ServiceAddress([string] $Type) {
    if ($null -eq $script:serviceIndex) { $script:serviceIndex = Invoke-RestMethod 'https://api.nuget.org/v3/index.json' }
    $match = @($script:serviceIndex.resources | Where-Object { @($_.'@type') -contains $Type })
    if ($match.Count -eq 0) { throw "The service index has no '$Type' resource." }
    ([string]$match[0].'@id').TrimEnd('/') + '/'
}

function Get-CatalogSha512([string] $Id, [string] $Version) {
    $leaf = Invoke-RestMethod ('{0}{1}/{2}.json' -f (Get-ServiceAddress 'RegistrationsBaseUrl/3.6.0'), $Id.ToLowerInvariant(), $Version.ToLowerInvariant())
    $entry = Invoke-RestMethod ([string]$leaf.catalogEntry)
    if ([string]$entry.packageHashAlgorithm -cne 'SHA512') { throw "$Id $Version publishes $($entry.packageHashAlgorithm), not SHA512." }
    [Convert]::ToHexString([Convert]::FromBase64String([string]$entry.packageHash))
}

$packageSha512 = [ordered]@{}

# Returns the package bytes after every check that applies has passed.
function Get-PackageBytes([string] $Id, [string] $Version) {
    $key = "$Id $Version"
    $expected = $null
    if ($null -ne $pins) {
        if (-not $pinSha512.ContainsKey($key)) { throw "The resolved graph needs '$key', which the pin file does not list." }
        $expected = $pinSha512[$key]
    }
    if (-not $Offline) {
        $catalog = Get-CatalogSha512 $Id $Version
        if ($null -ne $expected -and $catalog -cne $expected) { throw "Catalog SHA-512 for '$key' is $catalog; the pin is $expected." }
        $expected = $catalog
    }
    if ($null -eq $expected) { throw "No SHA-512 to check '$key' against (offline without a pin)." }

    $lower = $Id.ToLowerInvariant()
    $path = Join-Path $CacheDirectory "$lower.$Version.nupkg"
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Offline) { throw "'$key' is not cached and -Offline is set." }
        $partial = "$path.partial"
        Invoke-WebRequest ('{0}{1}/{2}/{1}.{2}.nupkg' -f (Get-ServiceAddress 'PackageBaseAddress/3.0.0'), $lower, $Version.ToLowerInvariant()) -OutFile $partial
        $downloaded = [Convert]::ToHexString([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($partial)))
        if ($downloaded -cne $expected) {
            Remove-Item -LiteralPath $partial
            throw "Download of '$key' hashes to $downloaded; expected $expected."
        }
        Move-Item -LiteralPath $partial -Destination $path
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA512]::HashData($bytes))
    if ($actual -cne $expected) { throw "Cached '$path' hashes to $actual; expected $expected. Delete it and re-run." }
    $script:packageSha512[$key] = $actual
    , $bytes
}

function Open-Package([byte[]] $Bytes) {
    [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Bytes, $false), [IO.Compression.ZipArchiveMode]::Read)
}

function Read-Entry([IO.Compression.ZipArchiveEntry] $Entry) {
    $source = $Entry.Open()
    $buffer = [IO.MemoryStream]::new()
    try { $source.CopyTo($buffer) } finally { $source.Dispose() }
    , $buffer.ToArray()
}

function Get-Nuspec([IO.Compression.ZipArchive] $Zip) {
    $nuspec = @($Zip.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.Name -like '*.nuspec' })
    if ($nuspec.Count -ne 1) { throw "Expected one root .nuspec, found $($nuspec.Count)." }
    # XmlDocument reads the encoding declaration and byte-order mark itself.
    $document = [xml]::new()
    $stream = [IO.MemoryStream]::new((Read-Entry $nuspec[0]), $false)
    try { $document.Load($stream) } finally { $stream.Dispose() }
    , $document
}

function Get-RepositoryCommit([xml] $Nuspec) {
    $node = $Nuspec.SelectSingleNode("//*[local-name()='repository']")
    if ($null -eq $node) { return '' }
    $node.GetAttribute('commit')
}

# net11.0 -> 1110, netstandard2.1 -> 21; platform-specific TFMs rank -1.
function Get-TfmRank([string] $Tfm) {
    $t = ($Tfm -replace '^\.NETCoreApp', 'net' -replace '^\.NETStandard', 'netstandard').ToLowerInvariant()
    if ($t -match '^net(\d+)\.(\d+)$') { return 1000 + 10 * [int]$Matches[1] + [int]$Matches[2] }
    if ($t -match '^netstandard2\.([01])$') { return 20 + [int]$Matches[1] }
    -1
}

# ---------------------------------------------------------------- graph

$runtimeId = "Microsoft.NETCore.App.Runtime.$Rid"
$runtimeZip = Open-Package (Get-PackageBytes $runtimeId $DotNet)
$runtimeCommit = Get-RepositoryCommit (Get-Nuspec $runtimeZip)
if (-not $runtimeCommit) { throw 'The runtime pack names no repository commit.' }

# A dependency built from the runtime pack's own commit is taken at the
# runtime pack's version; anything else at its nuspec lower bound.
$builtWithRuntime = @{}
function Test-BuiltWithRuntime([string] $Id) {
    if ($builtWithRuntime.ContainsKey($Id)) { return $builtWithRuntime[$Id] }
    $result = $false
    $available = if ($null -ne $pins) { $pinSha512.ContainsKey("$Id $DotNet") }
                 elseif ($Offline) { $false }
                 else { @((Invoke-RestMethod ('{0}{1}/index.json' -f (Get-ServiceAddress 'PackageBaseAddress/3.0.0'), $Id.ToLowerInvariant())).versions) -contains $DotNet }
    if ($available) {
        $zip = Open-Package (Get-PackageBytes $Id $DotNet)
        try { $result = (Get-RepositoryCommit (Get-Nuspec $zip)) -ceq $runtimeCommit } finally { $zip.Dispose() }
    }
    $builtWithRuntime[$Id] = $result
    $result
}

# NuGet version precedence: SemVer 2.0 section 11, with up to four numeric
# release parts and case-insensitive pre-release labels, as NuGet compares.
function Compare-PackageVersion([string] $A, [string] $B) {
    $parse = {
        param([string] $v)
        $core = $v.Split('+')[0]
        $dash = $core.IndexOf('-')
        $release = if ($dash -ge 0) { $core.Substring(0, $dash) } else { $core }
        $pre = if ($dash -ge 0) { $core.Substring($dash + 1) } else { '' }
        $parts = @($release.Split('.') | ForEach-Object {
            if ($_ -notmatch '^\d+$') { throw "Version '$v' has a non-numeric release part." }
            [long]$_ })
        if ($parts.Count -lt 1 -or $parts.Count -gt 4) { throw "Version '$v' has $($parts.Count) release parts." }
        while ($parts.Count -lt 4) { $parts += 0L }
        @{ Parts = $parts; Pre = $pre }
    }
    $x = & $parse $A
    $y = & $parse $B
    for ($i = 0; $i -lt 4; $i++) {
        if ($x.Parts[$i] -ne $y.Parts[$i]) { return [Math]::Sign($x.Parts[$i] - $y.Parts[$i]) }
    }
    if ($x.Pre -eq $y.Pre) { return 0 }
    if (-not $x.Pre) { return 1 }
    if (-not $y.Pre) { return -1 }
    $xi = $x.Pre.Split('.')
    $yi = $y.Pre.Split('.')
    for ($i = 0; $i -lt [Math]::Min($xi.Count, $yi.Count); $i++) {
        $xn = $xi[$i] -match '^\d+$'
        $yn = $yi[$i] -match '^\d+$'
        $c = if ($xn -and $yn) { [Math]::Sign([decimal]$xi[$i] - [decimal]$yi[$i]) }
             elseif ($xn) { -1 } elseif ($yn) { 1 }
             else { [Math]::Sign([string]::Compare($xi[$i], $yi[$i], [StringComparison]::OrdinalIgnoreCase)) }
        if ($c -ne 0) { return $c }
    }
    [Math]::Sign($xi.Count - $yi.Count)
}

# NuGet range syntax: '1.0' (min inclusive), '[1.0]', '[1.0,2.0)', '(,1.0]'.
function ConvertFrom-VersionRange([string] $Range) {
    $r = $Range.Trim()
    if ($r -notmatch '^[\[\(]') { return @{ Text = $r; Min = $r; MinInclusive = $true; Max = $null; MaxInclusive = $false } }
    if ($r -notmatch '^([\[\(])\s*([^,\]\)]*)\s*(?:(,)\s*([^\]\)]*))?\s*([\]\)])$') { throw "Cannot parse version range '$Range'." }
    $open, $low, $comma, $high, $close = $Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5]
    if (-not $comma) {
        if ($open -ne '[' -or $close -ne ']' -or -not $low) { throw "Exact version range '$Range' must be '[version]'." }
        return @{ Text = $r; Min = $low; MinInclusive = $true; Max = $low; MaxInclusive = $true }
    }
    @{ Text = $r; Min = $(if ($low) { $low } else { $null }); MinInclusive = $open -eq '['
       Max = $(if ($high) { $high } else { $null }); MaxInclusive = $close -eq ']' }
}

function Test-VersionInRange([string] $Version, [hashtable] $Range) {
    if ($Range.Min) {
        $c = Compare-PackageVersion $Version $Range.Min
        if ($c -lt 0 -or ($c -eq 0 -and -not $Range.MinInclusive)) { return $false }
    }
    if ($Range.Max) {
        $c = Compare-PackageVersion $Version $Range.Max
        if ($c -gt 0 -or ($c -eq 0 -and -not $Range.MaxInclusive)) { return $false }
    }
    $true
}

# One package's dependencies for the highest dependency group at or below
# the runtime's TFM.
$dependencyCache = @{}
function Get-PackageDependencies([string] $Id, [string] $Version) {
    $key = "$Id $Version"
    if ($dependencyCache.ContainsKey($key)) { return $dependencyCache[$key] }
    $zip = Open-Package (Get-PackageBytes $Id $Version)
    try { $nuspec = Get-Nuspec $zip } finally { $zip.Dispose() }
    $groups = @($nuspec.SelectNodes("//*[local-name()='dependencies']/*[local-name()='group']") |
        Where-Object { $r = Get-TfmRank $_.GetAttribute('targetFramework'); $r -ge 0 -and $r -le $runtimeTfmRank } |
        Sort-Object { Get-TfmRank $_.GetAttribute('targetFramework') } -Descending)
    $deps = @(if ($groups.Count) {
        foreach ($dep in $groups[0].SelectNodes("*[local-name()='dependency']")) {
            @{ Id = $dep.GetAttribute('id'); Range = ConvertFrom-VersionRange $dep.GetAttribute('version') }
        }
    })
    $dependencyCache[$key] = $deps
    $deps
}

# NuGet's rule for a package several packages depend on: the lowest version
# that satisfies every range. A package built from the runtime pack's commit
# is taken at the runtime's version when that satisfies every range. Walk,
# re-choose, and walk again until no choice changes.
$chosen = @{}
foreach ($id in $RootPackages) { $chosen[$id] = $PowerShell }
# Pinned mode starts from the pins; resolution must reproduce them exactly.
if ($null -ne $pins) {
    foreach ($p in $pins.packages) {
        if ($p.id -eq $runtimeId) { continue }
        if ($chosen.ContainsKey($p.id) -and $chosen[$p.id] -cne $p.version) { throw "Pin file gives '$($p.id)' two versions." }
        $chosen[$p.id] = [string]$p.version
    }
}
for ($pass = 1; ; $pass++) {
    if ($pass -gt 20) { throw 'Package resolution did not settle in 20 passes.' }
    $constraints = @{}
    $reached = [Collections.Generic.List[string]]::new()
    $walk = [Collections.Generic.Queue[string]]::new()
    foreach ($id in $RootPackages) { $walk.Enqueue($id) }
    while ($walk.Count) {
        $id = $walk.Dequeue()
        if ($reached.Contains($id)) { continue }
        $reached.Add($id)
        foreach ($dep in @(Get-PackageDependencies $id $chosen[$id])) {
            if (-not $constraints.ContainsKey($dep.Id)) { $constraints[$dep.Id] = [Collections.Generic.List[object]]::new() }
            $constraints[$dep.Id].Add(@{ Range = $dep.Range; From = "$id $($chosen[$id])" })
            if (-not $chosen.ContainsKey($dep.Id)) {
                if (-not $dep.Range.Min) { throw "'$id' depends on '$($dep.Id)' with no lower bound ($($dep.Range.Text))." }
                $chosen[$dep.Id] = $dep.Range.Min
            }
            $walk.Enqueue($dep.Id)
        }
    }

    $changed = $false
    foreach ($id in $constraints.Keys) {
        $ranges = @($constraints[$id])
        if ($id -in $RootPackages) {
            $pick = $chosen[$id]
        }
        else {
            $mins = @($ranges | ForEach-Object { $_.Range.Min } | Where-Object { $_ })
            $pick = $mins[0]
            foreach ($m in $mins) { if ((Compare-PackageVersion $m $pick) -gt 0) { $pick = $m } }
            if ((Test-BuiltWithRuntime $id) -and @($ranges | Where-Object { -not (Test-VersionInRange $DotNet $_.Range) }).Count -eq 0) {
                $pick = $DotNet
            }
        }
        $violated = @($ranges | Where-Object { -not (Test-VersionInRange $pick $_.Range) })
        if ($violated.Count) {
            throw "No version of '$id' satisfies every range: $pick fails $(($violated | ForEach-Object { "$($_.Range.Text) from $($_.From)" }) -join '; ')."
        }
        if ($chosen[$id] -cne $pick) {
            if ($null -ne $pins) { throw "Resolution picks '$id' $pick; the pin file says $($chosen[$id])." }
            $chosen[$id] = $pick
            $changed = $true
        }
    }
    if (-not $changed) { break }
}

$packages = [ordered]@{}
foreach ($id in $reached) {
    $packages[$id] = @{
        Version    = $chosen[$id]
        Zip        = Open-Package (Get-PackageBytes $id $chosen[$id])
        RequiredBy = $(if ($constraints.ContainsKey($id)) { @($constraints[$id] | ForEach-Object { "$($_.From) ($($_.Range.Text))" }) } else { @('(root)') })
    }
}

if ($null -ne $pins) {
    $used = @($packages.Keys | ForEach-Object { "$_ $($packages[$_].Version)" }) + "$runtimeId $DotNet"
    $unused = @($pinSha512.Keys | Where-Object { $_ -notin $used })
    if ($unused.Count) { throw "Pins not used by the resolved graph: $($unused -join ', ')." }
}

# ---------------------------------------------------------------- images

$candidates = @{}
function Add-Candidate([string] $Name, [byte[]] $Bytes, [string] $Source, [int] $Rank) {
    if ($candidates.ContainsKey($Name)) {
        $current = $candidates[$Name]
        if ($current.Rank -eq $Rank) { throw "'$Name' has two sources at the same rank: $($current.Source) and $Source." }
        if ($current.Rank -lt $Rank) { return }
    }
    $candidates[$Name] = @{ Bytes = $Bytes; Source = $Source; Rank = $Rank }
}

$runtimeLib = "runtimes/$Rid/lib/net$($DotNet.Split('.')[0]).0/"
$runtimeImages = @($runtimeZip.Entries | Where-Object { $_.FullName.StartsWith($runtimeLib, [StringComparison]::Ordinal) -and $_.Name -like '*.dll' })
if ($runtimeImages.Count -eq 0) { throw "The runtime pack has no images under '$runtimeLib'." }
foreach ($e in $runtimeImages) { Add-Candidate ([IO.Path]::GetFileNameWithoutExtension($e.Name)) (Read-Entry $e) "$runtimeId/$($e.FullName)" 0 }

foreach ($id in $packages.Keys) {
    $zip = $packages[$id].Zip
    foreach ($layout in @(@{ Prefix = 'runtimes/unix/lib/'; Rank = 1 }, @{ Prefix = 'lib/'; Rank = 2 })) {
        $entries = @($zip.Entries | Where-Object { $_.FullName.StartsWith($layout.Prefix, [StringComparison]::Ordinal) -and $_.Name -like '*.dll' -and
            ($_.FullName.Substring($layout.Prefix.Length) -split '/').Count -eq 2 })
        $tfms = @($entries | ForEach-Object { $_.FullName.Substring($layout.Prefix.Length).Split('/')[0] } | Sort-Object -Unique |
            Where-Object { $r = Get-TfmRank $_; $r -ge 0 -and $r -le $runtimeTfmRank } | Sort-Object { Get-TfmRank $_ } -Descending)
        if ($tfms.Count -eq 0) { continue }
        foreach ($e in $entries | Where-Object { $_.FullName.StartsWith("$($layout.Prefix)$($tfms[0])/", [StringComparison]::Ordinal) }) {
            Add-Candidate ([IO.Path]::GetFileNameWithoutExtension($e.Name)) (Read-Entry $e) "$id $($packages[$id].Version)/$($e.FullName)" $layout.Rank
        }
    }
}

# ---------------------------------------------------------------- closure

function Get-PlatformAttributes($Md) {
    foreach ($h in $Md.GetAssemblyDefinition().GetCustomAttributes()) {
        $ca = $Md.GetCustomAttribute($h)
        if ($ca.Constructor.Kind -ne [Reflection.Metadata.HandleKind]::MemberReference) { continue }
        $parent = $Md.GetMemberReference([Reflection.Metadata.MemberReferenceHandle]$ca.Constructor).Parent
        if ($parent.Kind -ne [Reflection.Metadata.HandleKind]::TypeReference) { continue }
        $name = $Md.GetString($Md.GetTypeReference([Reflection.Metadata.TypeReferenceHandle]$parent).Name)
        if ($name -notin 'SupportedOSPlatformAttribute', 'UnsupportedOSPlatformAttribute') { continue }
        $blob = $Md.GetBlobReader($ca.Value)
        if ($blob.ReadUInt16() -ne 1) { throw 'Custom attribute blob lacks the 0x0001 prolog.' }
        '{0}:{1}' -f ($name -replace 'OSPlatformAttribute$', ''), $blob.ReadSerializedString()
    }
}

$closure = [ordered]@{}
$unresolved = [Collections.Generic.SortedDictionary[string, Collections.Generic.SortedSet[string]]]::new([StringComparer]::Ordinal)
$work = [Collections.Generic.Queue[object]]::new()
foreach ($r in $Roots) { $work.Enqueue(@($r, '(root)')) }
while ($work.Count) {
    $name, $from = $work.Dequeue()
    if ($closure.Contains($name)) { continue }
    if (-not $candidates.ContainsKey($name)) {
        if (-not $unresolved.ContainsKey($name)) { $unresolved[$name] = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal) }
        [void]$unresolved[$name].Add($from)
        continue
    }
    $bytes = [byte[]]$candidates[$name].Bytes
    $pe = [Reflection.PortableExecutable.PEReader]::new([Collections.Immutable.ImmutableArray]::Create($bytes))
    try {
        if (-not $pe.HasMetadata) { throw "'$name' ($($candidates[$name].Source)) has no metadata." }
        $md = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
        $definition = $md.GetAssemblyDefinition()
        $definedName = $md.GetString($definition.Name)
        if ($definedName -cne $name) { throw "File '$name.dll' defines assembly '$definedName'." }
        $refs = @(foreach ($h in $md.AssemblyReferences) { $md.GetString($md.GetAssemblyReference($h).Name) })
        $closure[$name] = [ordered]@{
            name     = $name
            version  = $definition.Version.ToString()
            mvid     = $md.GetGuid($md.GetModuleDefinition().Mvid).ToString()
            sha256   = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            size     = $bytes.Length
            r2r      = $pe.PEHeaders.CorHeader.ManagedNativeHeaderDirectory.Size -gt 0
            platform = @(Get-PlatformAttributes $md)
            source   = $candidates[$name].Source
            refs     = @($refs | Sort-Object -Unique)
        }
    }
    finally { $pe.Dispose() }
    foreach ($r in $refs) { $work.Enqueue(@($r, $name)) }
}
foreach ($row in $closure.Values) {
    $row.referencedBy = @($closure.Values | Where-Object { $_.refs -contains $row.name } | ForEach-Object { $_.name } | Sort-Object)
}

foreach ($p in $packages.Values) { $p.Zip.Dispose() }
$runtimeZip.Dispose()

# ---------------------------------------------------------------- report

$unexpected = @($unresolved.Keys | Where-Object { $_ -notin $AcceptUnresolved })
$report = [ordered]@{
    probe      = [ordered]@{ path = $PSCommandPath; sha256 = $probeSha256; mode = $PSCmdlet.ParameterSetName; offline = [bool]$Offline }
    rid        = $Rid
    dotNet     = $DotNet
    powerShell = $PowerShell
    runtime    = [ordered]@{ id = $runtimeId; version = $DotNet; commit = $runtimeCommit; sha512 = $packageSha512["$runtimeId $DotNet"] }
    roots      = $Roots
    # The resolved graph only; packages fetched to test their commit are not in it.
    packages   = @($packages.Keys | Sort-Object | ForEach-Object {
        [ordered]@{ id = $_; version = $packages[$_].Version; sha512 = $packageSha512["$_ $($packages[$_].Version)"]
                    requiredBy = @($packages[$_].RequiredBy) } })
    closure    = @($closure.Values | Sort-Object { $_.name })
    unresolved = @($unresolved.Keys | ForEach-Object { [ordered]@{ name = $_; referencedBy = @($unresolved[$_]) } })
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'closure.json') -Encoding utf8NoBOM

$md = [Text.StringBuilder]::new()
[void]$md.AppendLine("# Payload closure ($Rid)").AppendLine()
[void]$md.AppendLine("Runtime $runtimeId $DotNet (commit $runtimeCommit); PowerShell $PowerShell; probe SHA-256 $probeSha256.").AppendLine()
[void]$md.AppendLine("$($closure.Count) images, $(@($closure.Values | Where-Object r2r).Count) with R2R code, $($unresolved.Count) unresolved.").AppendLine()
[void]$md.AppendLine('| Assembly | Size | R2R | Platform | Referenced by | Source |')
[void]$md.AppendLine('| --- | ---: | :---: | --- | --- | --- |')
foreach ($row in $report.closure) {
    [void]$md.AppendLine(('| {0} | {1:N0} | {2} | {3} | {4} | {5} |' -f $row.name, $row.size, $(if ($row.r2r) { 'yes' } else { '' }),
        ($row.platform -join ' '), ($row.referencedBy -join ', '), $row.source))
}
if ($unresolved.Count) {
    [void]$md.AppendLine().AppendLine('## Unresolved').AppendLine()
    foreach ($u in $report.unresolved) { [void]$md.AppendLine("- $($u.name), referenced by $($u.referencedBy -join ', ')") }
}
$md.ToString() | Set-Content -LiteralPath (Join-Path $OutputDirectory 'closure.md') -Encoding utf8NoBOM

if ($Discover) {
    [ordered]@{
        note       = 'Candidate pins from NuGet catalog hashes. Review before use.'
        dotNet     = $DotNet
        powerShell = $PowerShell
        packages   = @(@($report.packages | ForEach-Object { [ordered]@{ id = $_.id; version = $_.version; sha512 = $_.sha512 } }) +
            [ordered]@{ id = $runtimeId; version = $DotNet; sha512 = $report.runtime.sha512 } | Sort-Object { $_.id })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'pins.candidate.json') -Encoding utf8NoBOM
}

"$($closure.Count) images; $(@($closure.Values | Where-Object r2r).Count) R2R; unresolved: $(@($unresolved.Keys) -join ', ')"
if ($unexpected.Count) { throw "Unresolved references not accepted: $($unexpected -join ', ')." }
