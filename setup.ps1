#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low', PositionalBinding = $false)]
param(
    [Alias('h')]
    [switch] $Help,

    # One step (5), a range (1-5, 4-5), or a list (2,3). Steps hand data to each
    # other in memory, so a selection also runs whatever its steps depend on.
    [ValidatePattern('^\d{1,2}(-\d{1,2})?(,\d{1,2}(-\d{1,2})?)*$')]
    [string] $Step = '1',

    # Exact NuGet versions. Empty means the version pinned in lib/manifest.json.
    [ValidatePattern('^$|^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $DotNet = '',
    [ValidatePattern('^$|^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $Android = '',
    [ValidatePattern('^$|^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$')]
    [string] $PowerShell = '',

    # Download location. Folder: -CacheDirectory (the user temp folder unless
    # set), reused next run. Memory: never written to disk.
    [ValidateSet('Folder', 'Memory')]
    [string] $Packages = 'Memory',

    # Every location this script writes to is listed in the write plan and
    # confirmed before anything is written. None may be inside this
    # repository. Empty values are filled with per-user suggestions that are
    # shown in the plan, never used silently.
    [string] $CacheDirectory = '',

    [Alias('c', 'Console')]
    [switch] $Headless,

    [switch] $Interactive,

    # arm64: phones. x64: the x86_64 emulator, which runs it natively.
    # arm32: 32-bit ARMv7 devices.
    [ValidateSet('arm64', 'x64', 'arm32')]
    [string] $Architecture = 'arm64',

    # Xamarin: the .NET for Android host (the proven build).
    # NativeActivity: gate 1 of leaving it. The framework NativeActivity loads
    # an emitted libpwsh-host.so that logs one line; no DEX, no runtime.
    [ValidateSet('Xamarin', 'NativeActivity')]
    [string] $Admission = 'Xamarin',


    # Minimal:  Assembly set, IL only, no ReadyToRun (R2R) code.
    # Standard: every runtime assembly the packages ship, R2R code included.
    # SDK:      Standard plus the PowerShell SDK assemblies.
    [ValidateSet('Minimal', 'Standard', 'SDK')]
    [string] $Payload = 'Minimal',

    [string] $OutputDirectory = '',

    # The APK signing identity (PKCS#12). Rebuilds must reuse it: Android
    # refuses to upgrade an installed app whose signer changed.
    [string] $SigningKeyPath = '',

    # Accept the printed write plan without a prompt. Required for unattended
    # runs that do not pass every location explicitly.
    [switch] $AcceptWritePlan,

    # Only the signed APK is written by default; every intermediate artifact
    # stays in memory. This writes them (store, libraries, dex, manifest,
    # unsigned APK, package record) to -OutputDirectory for inspection.
    [switch] $KeepIntermediates,

    # Where the signed APK goes. Default: <package name>.apk next to setup.ps1,
    # the only file the build places in the repository (*.apk is ignored by git).
    [string] $ApkPath = '',

    # Downloaded packages are kept and reused unless this is set. The
    # interactive menu offers the same choice.
    [switch] $DeletePackages,

    # GNU-style spellings (--help, --step 11, --payload=standard). pwsh -File
    # already maps --name to -name; this catches them under & and dot-sourcing.
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $LongArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Debug: write the intermediates and cross-check against a .NET for Android
# reference build.
$Debug = $PSBoundParameters.ContainsKey('Debug')

for ($i = 0; $i -lt $LongArguments.Count; $i++) {
    if ($LongArguments[$i] -notmatch '^--?([A-Za-z][A-Za-z-]*)(?:=(.*))?$') {
        Write-Host "[FAIL] Unrecognized argument '$($LongArguments[$i])'. Run with --help." -ForegroundColor Red
        exit 2
    }
    $name = $Matches[1].Replace('-', '').ToLowerInvariant()
    $inline = $Matches[2]
    $value = {
        if ($null -ne $inline) { return $inline }
        if (++$script:i -ge $LongArguments.Count) { throw "--$name requires a value." }
        $LongArguments[$script:i]
    }
    switch ($name) {
        { $_ -in 'h', 'help' }                  { $Help = $true }
        { $_ -in 'c', 'console', 'headless' }   { $Headless = $true }
        'interactive'                           { $Interactive = $true }
        'deletepackages'                        { $DeletePackages = $true }
        'whatif'                                { $WhatIfPreference = $true }
        'step'                                  { $Step = & $value }
        'dotnet'                                { $DotNet = & $value }
        'android'                               { $Android = & $value }
        'powershell'                            { $PowerShell = & $value }
        'packages'                              { $Packages = (Get-Culture).TextInfo.ToTitleCase((& $value).ToLowerInvariant()) }
        'debug'                                 { $Debug = $true }
        'payload'                               { $Payload = & $value }
        'architecture'                          { $Architecture = & $value }
        'cachedirectory'                        { $CacheDirectory = & $value }
        'outputdirectory'                       { $OutputDirectory = & $value }
        'signingkeypath'                        { $SigningKeyPath = & $value }
        'acceptwriteplan'                       { $AcceptWritePlan = $true }
        'keepintermediates'                     { $KeepIntermediates = $true }
        'apkpath'                               { $ApkPath = & $value }
        default {
            Write-Host "[FAIL] Unrecognized argument '--$name'. Run with --help." -ForegroundColor Red
            exit 2
        }
    }
}

# One literal record per target. The facade name is never used as a path; it
# resolves here into the separate naming domains the platform uses.
$script:Targets = @{
    arm64 = [pscustomobject]@{ Rid = 'android-arm64'; Abi = 'arm64-v8a';   ElfClass = 64; Machine = 'EM_AARCH64'; CompilerDefine = '__aarch64__'; RelativeRelocation = 'R_AARCH64_RELATIVE'; GotRelocation = 'R_AARCH64_GLOB_DAT'; RelocationForm = 'RELA'; Isa = 'A64'; ElfFlags = @() }
    x64   = [pscustomobject]@{ Rid = 'android-x64';   Abi = 'x86_64';      ElfClass = 64; Machine = 'EM_X86_64';  CompilerDefine = '__x86_64__';  RelativeRelocation = 'R_X86_64_RELATIVE';  GotRelocation = 'R_X86_64_GLOB_DAT';  RelocationForm = 'RELA'; Isa = 'X64'; ElfFlags = @() }
    arm32 = [pscustomobject]@{ Rid = 'android-arm';   Abi = 'armeabi-v7a'; ElfClass = 32; Machine = 'EM_ARM';     CompilerDefine = '__arm__';     RelativeRelocation = 'R_ARM_RELATIVE';     GotRelocation = 'R_ARM_GLOB_DAT';     RelocationForm = 'REL';  Isa = 'A32'; ElfFlags = @('EF_ARM_EABI_VER5', 'EF_ARM_ABI_FLOAT_SOFT') }
}
$script:Target = $script:Targets[$Architecture]

$script:StepSelection = [System.Collections.Generic.List[int]]::new()
foreach ($part in $Step -split ',') {
    $bounds = [int[]]($part -split '-')
    foreach ($id in $bounds[0]..$bounds[-1]) {
        if ($id -lt 1 -or $id -gt 11) { throw "Step $id does not exist. Steps are 1-11." }
        if (-not $script:StepSelection.Contains($id)) { $script:StepSelection.Add($id) }
    }
}
Remove-Variable -Name Step -Force -WhatIf:$false
$Step = [int]($script:StepSelection | Measure-Object -Maximum).Maximum

if ($Headless -and $Interactive) {
    throw '-Headless and -Interactive are mutually exclusive.'
}
if ($Debug) { $KeepIntermediates = [switch]$true }
function Show-SetupHelp {
    Get-SetupHelpText | Write-Host
}

function Get-SetupHelpText {
    @'
Pwsh autonomous build pipeline

USAGE
  pwsh -NoProfile -File .\setup.ps1 [options]

OPTIONS
  -h, --help                Show this help and exit.
  -c, -Console, -Headless   Run directly in non-TUI console mode.
  -Interactive              Require the interactive interface.
  -Step <n|a-b|a,b>         Run steps: 5, 1-5, 4-5, or 2,3. Each step runs the
                            steps it depends on first, so -Step 11 is a full
                            build.
                              1  Verify pinned specifications against upstream
                              2  Acquire and hash the pinned NuGet packages
                              3  Inspect and classify every package payload
                              4  Select the assembly set for the target
                              5  Emit and verify the XABA assembly store
                              6  Wrap the store in an ELF64 library for the target
                              7  Emit the binary AndroidManifest.xml
                              8  Emit the Java peer class as Dalvik bytecode
                              9  Emit libxamarin-app.so, the app data library
                             10  Assemble the unsigned APK archive
                             11  Sign the APK with Signature Scheme v2
  -OutputDirectory <path>   Where emitted artifacts are written.
  -SigningKeyPath <path>    The APK signing identity (.pfx). Reused across
                            builds; created there if missing.
  -CacheDirectory <path>    Package and lib-source cache, used with
                            -Packages Folder.
  -AcceptWritePlan          Accept the write plan without a prompt.
  -ApkPath <path>           Where the signed APK goes. Default:
                            dev.mansfieldplumbing.pwsh.apk next to setup.ps1
                            (ignored by git).
  -KeepIntermediates        Also write the intermediate artifacts to
                            -OutputDirectory. By default they stay in memory
                            and only the signed APK is written.

  WRITE PLAN
  Before anything is written, the script lists every location it will write
  to and asks for confirmation. Locations left empty are filled with
  suggestions and shown, not used silently: the signed APK next to this
  script, intermediates (only with -KeepIntermediates) in ..\Build\<repo>,
  side by side with the repository (created if missing; it ignores itself
  for git), the
  signing key and cache in per-user data (LocalApplicationData\Pwsh on
  Windows, the XDG directories elsewhere). No location may be
  inside this repository except the signed APK. Unattended runs stop unless every location is
  given or -AcceptWritePlan is set. -WhatIf prints the plan and writes
  nothing.
  -Architecture <arm64|x64|arm32>
                            Target. arm64 for phones, x64 for the x86_64
                            emulator. arm32 for 32-bit ARMv7 devices.
  -Admission <Xamarin|NativeActivity>
                            Xamarin (default) builds the proven host.
                            NativeActivity builds gate 1: a DEX-free APK whose
                            emitted host library logs one line.
  -Debug                    Write the intermediates and cross-check against a
                            .NET for Android reference build (needs the .NET
                            SDK with the Android workload; built in a temp
                            folder that is deleted afterwards).
  -Payload <Minimal|Standard|SDK>
                            Minimal: lean assembly set, IL only, no
                            ReadyToRun (R2R) code. Standard: every runtime
                            assembly, R2R code included. SDK: Standard plus
                            the PowerShell SDK assemblies. Standard and SDK
                            are not built yet.
  -Packages <Memory|Folder> Download location. Memory (default): never
                            written to disk. Folder: -CacheDirectory,
                            reused next run.
                            In the interface, Enter opens Browse.
  -DotNet <version>         .NET runtime pack for Android.
  -Android <version>        .NET for Android CoreCLR host and bindings.
  -PowerShell <version>     System.Management.Automation and PowerShell SDK.
                            Exact versions only. Omitted, each uses the
                            version pinned in lib/manifest.json.
  -DeletePackages           Delete the downloaded package cache on exit.
                            Without it packages are kept. The interface asks
                            on exit.
  -WhatIf                   Preview filesystem and device mutations.

EXAMPLES
  .\setup.ps1
  .\setup.ps1 -h
  .\setup.ps1 -c -Step 1
  .\setup.ps1 -c -Step 11
  .\setup.ps1 -c -Step 1-5
  .\setup.ps1 -c -Step 11 -PowerShell 7.7.0-preview.3
  .\setup.ps1 -c -Step 11 -DeletePackages
  .\setup.ps1 -Interactive

EXECUTION CONTRACT
  With no mode switch, an attached interactive console opens the setup
  interface. Redirected and unattended sessions run headlessly. The same
  phase functions execute in both modes. Every switch also takes a GNU
  spelling: --help, --console, --step 11, --payload=standard,
  --delete-packages, --output-directory <path>, --signing-key-path <path>,
  --accept-write-plan.
'@
}

function Test-InteractiveConsole {
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
    try {
        $null = [Console]::WindowWidth
        $null = [Console]::WindowHeight
        return $true
    }
    catch {
        return $false
    }
}

# ==============================================================================
# Build graph
#
# Every step is a node. Edges are declared here and nowhere else: a node names
# what it depends on, and the driver resolves the order. Steps no longer call
# each other from inside their own bodies, so the dependency structure is
# readable in one place instead of being spread across eleven function tops.
#
# The graph is also the only list. The interface renders these nodes directly,
# so the menu, the progress view, and the execution order cannot drift apart.
# ==============================================================================
# Indexed by key, never by position: an OrderedDictionary indexed with an [int]
# indexes by position instead of by key, which silently rewires every edge.
# StepIds carries the order a hashtable does not guarantee.
$script:StepIds = @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11)
$script:StepGraph = @{
    1  = @{
        Key = 'Verify'; DependsOn = @()
        Title = 'Verify pinned specifications against upstream'
        Caption = 'Chains every lib/ file back to the root provenance digest.'
        Action = { Invoke-VerifyStep }
    }
    2  = @{
        Key = 'Acquire'; DependsOn = @(1)
        Title = 'Acquire and hash the pinned NuGet packages'
        Caption = 'Downloads the versions pinned in lib/manifest.json and checks catalog SHA-512.'
        Action = { Invoke-AcquisitionStep }
    }
    3  = @{
        Key = 'Inspect'; DependsOn = @(2)
        Title = 'Inspect and classify every package payload'
        Caption = 'Separates IL images, native payloads, and R2R exclusions.'
        Action = { Invoke-InspectionStep }
    }
    4  = @{
        Key = 'Select'; DependsOn = @(3)
        Title = 'Select the assembly set for the target'
        Caption = 'Rejects reference-only images; emits the generated assemblies.'
        Action = { Invoke-SelectionStep }
    }
    5  = @{
        Key = 'Store'; DependsOn = @(4)
        Title = 'Emit and verify the XABA assembly store'
        Caption = 'Verified by the runtime''s own lookup rules, not a second parser.'
        Action = { Invoke-StoreStep }
    }
    6  = @{
        Key = 'Native'; DependsOn = @(5)
        Title = 'Wrap the store in an ELF64 library for the target'
        Caption = 'Resolved through the emitted hash table exactly as dlsym would.'
        Action = { Invoke-NativeStep }
    }
    7  = @{
        Key = 'Manifest'; DependsOn = @(6)
        Title = 'Emit the binary AndroidManifest.xml'
        Caption = 'Binary AXML, chunk-walked and balanced after emission.'
        Action = { Invoke-ManifestStep }
    }
    8  = @{
        Key = 'Dex'; DependsOn = @(7)
        Title = 'Emit the Java peer class as Dalvik bytecode'
        Caption = 'Checksum, SHA-1, and string ordering verified.'
        Action = { Invoke-DexStep }
    }
    9  = @{
        Key = 'AppData'; DependsOn = @(8)
        Title = 'Emit libxamarin-app.so, the application data library'
        Caption = 'application_config, the type map, and the runtime''s undefined symbols.'
        Action = { Invoke-AppDataStep }
    }
    10 = @{
        Key = 'Assemble'; DependsOn = @(9)
        Title = 'Assemble the unsigned APK archive'
        Caption = 'Every entry read back byte-identical by an independent reader.'
        Action = { Invoke-AssembleStep }
    }
    11 = @{
        Key = 'Sign'; DependsOn = @(10)
        Title = 'Sign the APK with Signature Scheme v2'
        Caption = 'Signature re-verified against the recomputed content digest.'
        Action = { Invoke-SignStep }
    }
}

# Nodes that have already run in this process. A node executes at most once, so
# selecting step 6 after step 5 continues from where the run left off instead of
# rebuilding the whole chain.
$script:CompletedNodes = [System.Collections.Generic.HashSet[int]]::new()

function Resolve-StepOrder {
    <#
        Depth-first topological resolve of one target node. Throws on an unknown
        edge or a cycle rather than looping, so a malformed graph fails here and
        not halfway through a build.
    #>
    param([Parameter(Mandatory)][int] $Target)

    $order = [System.Collections.Generic.List[int]]::new()
    $state = @{}

    $visit = {
        param([int] $id)

        if (-not $script:StepGraph.Contains($id)) {
            throw "Build graph references an undefined step: $id."
        }
        if ($state[$id] -eq 'done') { return }
        if ($state[$id] -eq 'open') {
            throw "Build graph contains a cycle through step $id."
        }

        $state[$id] = 'open'
        foreach ($dependency in $script:StepGraph[$id].DependsOn) {
            & $visit $dependency
        }
        $state[$id] = 'done'
        $order.Add($id)
    }

    & $visit $Target
    return $order
}

function Invoke-StepNode {
    <#
        Runs a target node and everything it depends on, in order, skipping
        nodes already completed in this process.
    #>
    param([Parameter(Mandatory)][int] $Target)

    foreach ($id in Resolve-StepOrder -Target $Target) {
        if ($script:CompletedNodes.Contains($id)) { continue }
        $script:RunningStep = $id
        & $script:StepGraph[$id].Action
        [void]$script:CompletedNodes.Add($id)
    }
}

$script:FeedManifest = @(
    [ordered]@{
        Name         = 'NuGet.org'
        ServiceIndex = 'https://api.nuget.org/v3/index.json'
    }
)

# No versions and no hashes are written here. Step 2 resolves them:
#   Channel     packages that ship together. A channel uses the exact version
#               pinned in lib/manifest.json, or the exact version given with
#               -DotNet, -Android, or -PowerShell.
#   Dependency  the version the channel packages' nuspecs ask for, which is
#               the rule NuGet itself applies.
# Each download is checked against the SHA-512 the feed's catalog publishes.
$script:PackageManifest = @(
    [ordered]@{ Id = "Microsoft.NETCore.App.Runtime.$($script:Target.Rid)"; Feed = 'NuGet.org'; Channel = 'DotNet' }
    # The CoreCLR host for Android. Ships libnet-android.release.so, which the
    # APK carries as the runtime's native entry point.
    [ordered]@{ Id = "Microsoft.Android.Runtime.CoreCLR.37.$($script:Target.Rid)"; Feed = 'NuGet.org'; Channel = 'Android' }
    [ordered]@{ Id = 'Microsoft.Android.Runtime.37.android'; Feed = 'NuGet.org'; Channel = 'Android' }
    [ordered]@{ Id = 'System.Management.Automation'; Feed = 'NuGet.org'; Channel = 'PowerShell' }
    [ordered]@{ Id = 'Microsoft.PowerShell.SDK'; Feed = 'NuGet.org'; Channel = 'PowerShell' }
    [ordered]@{ Id = 'Microsoft.ApplicationInsights'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'Microsoft.Management.Infrastructure'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'Microsoft.Management.Infrastructure.Runtime.Unix'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'Newtonsoft.Json'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'System.CodeDom'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'System.Configuration.ConfigurationManager'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'System.Diagnostics.EventLog'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'System.Security.Cryptography.Pkcs'; Feed = 'NuGet.org'; Channel = 'Dependency' }
    [ordered]@{ Id = 'System.Security.Cryptography.ProtectedData'; Feed = 'NuGet.org'; Channel = 'Dependency' }
)
$script:Channels = 'DotNet', 'Android', 'PowerShell'

$script:LibDirectory = Join-Path $PSScriptRoot 'lib'

# ==============================================================================
# Write plan
#
# Every file this script creates goes through Write-BuildFile, which admits a
# path only when it lies under a location the user confirmed and outside this
# repository. The written set is reported with SHA-512 digests at the end.
# ==============================================================================

$script:RepositoryRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$script:ApprovedWriteRoots = [System.Collections.Generic.List[string]]::new()
$script:WrittenFiles = [System.Collections.Generic.List[object]]::new()
$script:LibRestoreDirectory = $null
$script:BuildRoot = $null

function Get-SuggestedUserDirectory {
    # Per-user, non-roaming, not synced, not temp. XDG on Linux, the Library
    # folders on macOS, LocalApplicationData on Windows.
    param([Parameter(Mandatory)][ValidateSet('Data', 'Cache')][string] $Kind)

    if ($IsWindows) {
        return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Pwsh'
    }
    $home_ = [Environment]::GetFolderPath('UserProfile')
    if ($IsMacOS) {
        if ($Kind -eq 'Cache') { return Join-Path $home_ 'Library/Caches/Pwsh' }
        return Join-Path $home_ 'Library/Application Support/Pwsh'
    }
    if ($Kind -eq 'Cache') {
        $base = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $home_ '.cache' }
        return Join-Path $base 'pwsh-apk'
    }
    $base = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $home_ '.local/share' }
    return Join-Path $base 'pwsh-apk'
}

function Test-PathInside {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Root)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $base = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $comparison = if ($IsWindows -or $IsMacOS) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $full.Equals($base, $comparison) -or
        $full.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar, $comparison)
}

function Resolve-WritePlan {
    # Returns the plan and whether every location was given explicitly.
    $explicit = (-not $KeepIntermediates -or -not [string]::IsNullOrWhiteSpace($OutputDirectory)) -and
        -not [string]::IsNullOrWhiteSpace($SigningKeyPath) -and
        ($Packages -eq 'Memory' -or -not [string]::IsNullOrWhiteSpace($CacheDirectory))

    $script:ApkFileName = "$script:PackageName.apk"
    $script:ApkPath = if ([string]::IsNullOrWhiteSpace($ApkPath)) { Join-Path $script:RepositoryRoot $script:ApkFileName }
                      else { [System.IO.Path]::GetFullPath($ApkPath) }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        # <parent>\Build\<repo>, side by side with the repository. The Build
        # folder is created if it does not exist and ignores itself for git.
        $script:BuildRoot = Join-Path (Split-Path -Parent $script:RepositoryRoot) 'Build'
        $script:OutputDirectory = Join-Path $script:BuildRoot (Split-Path -Leaf $script:RepositoryRoot)
    }
    if ([string]::IsNullOrWhiteSpace($SigningKeyPath)) {
        # Earlier builds kept the key directly under the data directory. Reuse
        # it when present: a new key would block upgrades of installed builds.
        $dataRoot = Get-SuggestedUserDirectory -Kind Data
        $existingKey = Join-Path $dataRoot 'pwsh-signing.pfx'
        $script:SigningKeyPath = if (Test-Path -LiteralPath $existingKey -PathType Leaf) { $existingKey }
                                 else { Join-Path (Join-Path $dataRoot 'Keys') 'pwsh-signing.pfx' }
    }
    if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $script:CacheDirectory = Get-SuggestedUserDirectory -Kind Cache
    }
    $script:OutputDirectory = [System.IO.Path]::GetFullPath($script:OutputDirectory)
    $script:SigningKeyPath = [System.IO.Path]::GetFullPath($script:SigningKeyPath)
    $script:CacheDirectory = [System.IO.Path]::GetFullPath($script:CacheDirectory)

    $plan = [ordered]@{
        'APK'           = $script:ApkPath
        'Intermediates' = if ($KeepIntermediates) { $script:OutputDirectory } else { 'none (kept in memory)' }
        'Signing key'   = $script:SigningKeyPath
        'Package cache' = if ($Packages -eq 'Folder') { $script:CacheDirectory } else { 'none (packages stay in memory)' }
    }
    if ($Packages -eq 'Folder') { $plan['lib sources'] = Join-Path $script:CacheDirectory 'lib' }
    if ($Debug) { $plan['Reference'] = (Join-Path ([System.IO.Path]::GetTempPath()) 'pwsh-reference-*') + ' (deleted after the check)' }

    if ((Test-PathInside -Path $script:ApkPath -Root $script:RepositoryRoot) -and
        -not (Test-PathInside -Path $script:ApkPath -Root (Join-Path $script:RepositoryRoot $script:ApkFileName))) {
        throw "The APK may only be placed in the repository as '$(Join-Path $script:RepositoryRoot $script:ApkFileName)'."
    }
    foreach ($entry in @(
            @{ Name = 'Build output'; Path = $script:OutputDirectory },
            @{ Name = 'Signing key'; Path = $script:SigningKeyPath },
            @{ Name = 'Package cache'; Path = $script:CacheDirectory })) {
        if (Test-PathInside -Path $entry.Path -Root $script:RepositoryRoot) {
            throw "$($entry.Name) location '$($entry.Path)' is inside the repository '$script:RepositoryRoot'. Choose a location outside it."
        }
    }
    if (Test-PathInside -Path $script:SigningKeyPath -Root $script:OutputDirectory) {
        throw "The signing key '$script:SigningKeyPath' must not be inside the build output '$script:OutputDirectory'."
    }

    [pscustomobject]@{ Plan = $plan; Explicit = $explicit }
}

function Show-WritePlan {
    param([Parameter(Mandatory)] $Plan)
    Write-Host 'Write plan. This run writes only to these locations:'
    foreach ($key in $Plan.Keys) { Write-Host ('  {0,-14} {1}' -f $key, $Plan[$key]) }
    $repositoryNote = if (Test-PathInside -Path $script:ApkPath -Root $script:RepositoryRoot) { "only $script:ApkFileName is written" } else { 'never written' }
    Write-Host ('  {0,-14} {1}' -f 'Repository', "$script:RepositoryRoot ($repositoryNote)")
}

function Enable-WritePlan {
    $script:ApprovedWriteRoots.Clear()
    if ($KeepIntermediates) { $script:ApprovedWriteRoots.Add($script:OutputDirectory) }
    $script:ApprovedWriteRoots.Add([System.IO.Path]::GetDirectoryName($script:SigningKeyPath))
    if (-not (Test-PathInside -Path $script:ApkPath -Root $script:RepositoryRoot)) {
        $script:ApprovedWriteRoots.Add([System.IO.Path]::GetDirectoryName($script:ApkPath))
    }
    if ($Packages -eq 'Folder') {
        $script:ApprovedWriteRoots.Add($script:CacheDirectory)
        $script:LibRestoreDirectory = Join-Path $script:CacheDirectory 'lib'
    }

    # The shared Build folder ignores itself, so no repository that ever
    # contains it can pick up build output.
    if ($KeepIntermediates -and $script:BuildRoot -and -not $WhatIfPreference) {
        $ignore = Join-Path $script:BuildRoot '.gitignore'
        if (-not (Test-Path -LiteralPath $ignore -PathType Leaf)) {
            $script:ApprovedWriteRoots.Add($script:BuildRoot)
            Write-BuildFile -Path $ignore -Bytes ([System.Text.Encoding]::ASCII.GetBytes("# Build output. Never tracked.`n*`n"))
        }
    }
}

function Assert-ApprovedWritePath {
    param([Parameter(Mandatory)][string] $Path)
    if (Test-PathInside -Path $Path -Root $script:RepositoryRoot) {
        # The single exception: the signed APK beside setup.ps1.
        if (Test-PathInside -Path $Path -Root $script:ApkPath) { return }
        throw "Refusing to write '$Path': it is inside the repository."
    }
    foreach ($root in $script:ApprovedWriteRoots) {
        if (Test-PathInside -Path $Path -Root $root) { return }
    }
    throw "Refusing to write '$Path': it is not under a location in the confirmed write plan."
}

function Write-BuildFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes,
        # Intermediate artifacts are written only with -KeepIntermediates.
        [switch] $Intermediate
    )
    if ($Intermediate -and -not $KeepIntermediates) { return }
    $full = [System.IO.Path]::GetFullPath($Path)
    Assert-ApprovedWritePath -Path $full
    [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($full)) | Out-Null
    [System.IO.File]::WriteAllBytes($full, $Bytes)
    $script:WrittenFiles.Add([pscustomobject]@{
        Path   = $full
        Bytes  = $Bytes.Length
        Sha512 = [Convert]::ToHexString([System.Security.Cryptography.SHA512]::HashData($Bytes))
    })
}

function New-ApprovedDirectory {
    param([Parameter(Mandatory)][string] $Path)
    # Intermediate output directories exist only with -KeepIntermediates.
    if (-not $KeepIntermediates -and (Test-PathInside -Path $Path -Root $script:OutputDirectory)) { return }
    Assert-ApprovedWritePath -Path $Path
    [System.IO.Directory]::CreateDirectory($Path) | Out-Null
}

function Get-RepositorySnapshot {
    # Path, length and last write time of every file in the repository.
    $snapshot = @{}
    foreach ($file in Get-ChildItem -LiteralPath $script:RepositoryRoot -Recurse -File -Force -ErrorAction SilentlyContinue) {
        if ($file.FullName -like "*$([System.IO.Path]::DirectorySeparatorChar).git$([System.IO.Path]::DirectorySeparatorChar)*") { continue }
        if ($script:ApkPath -and (Test-PathInside -Path $file.FullName -Root $script:ApkPath)) { continue }
        $snapshot[$file.FullName] = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
    }
    $snapshot
}

function Compare-RepositorySnapshot {
    param([Parameter(Mandatory)][hashtable] $Before)
    $after = Get-RepositorySnapshot
    $changed = @(
        foreach ($key in $after.Keys) { if (-not $Before.ContainsKey($key) -or $Before[$key] -ne $after[$key]) { $key } }
        foreach ($key in $Before.Keys) { if (-not $after.ContainsKey($key)) { $key } }
    )
    $changed
}

function Invoke-ReferenceCrossCheck {
    # -Debug only. Builds a minimal .NET for Android app with the .NET SDK in a
    # temporary folder, then compares it with what this script derives: the
    # Java peer package name and the pinned lib/classes.dex. The folder is
    # deleted afterwards; the reference APK is kept with the intermediates.
    $dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dotnet) { throw '-Debug needs the .NET SDK (dotnet) with the Android workload for the reference build.' }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('pwsh-reference-' + [Guid]::NewGuid().ToString('N'))
    $script:ApprovedWriteRoots.Add($root)
    try {
        $project = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net11.0-android37.0</TargetFramework>
    <OutputType>Exe</OutputType>
    <RuntimeIdentifier>$(TargetRid)</RuntimeIdentifier>
    <ApplicationId>dev.mansfieldplumbing.terminal.reference</ApplicationId>
    <SupportedOSPlatformVersion>26</SupportedOSPlatformVersion>
    <RunAOTCompilation>false</RunAOTCompilation>
    <AndroidUseAssemblyStore>true</AndroidUseAssemblyStore>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <PublishReadyToRun>false</PublishReadyToRun>
    <Optimize>true</Optimize>
    <DebugSymbols>false</DebugSymbols>
    <EmbedAssembliesIntoApk>true</EmbedAssembliesIntoApk>
    <AndroidUseSharedRuntime>false</AndroidUseSharedRuntime>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="ReferenceActivity.cs" />
    <PackageReference Include="System.Management.Automation" Version="$(PowerShellPackageVersion)" />
    <PackageReference Include="Microsoft.PowerShell.Commands.Management" Version="$(PowerShellPackageVersion)" />
    <PackageReference Include="Microsoft.PowerShell.Commands.Utility" Version="$(PowerShellPackageVersion)" />
    <PackageReference Include="Microsoft.PowerShell.Security" Version="$(PowerShellPackageVersion)" />
    <TrimmerRootAssembly Include="System.Management.Automation" />
    <TrimmerRootAssembly Include="Microsoft.PowerShell.Commands.Management" />
    <TrimmerRootAssembly Include="Microsoft.PowerShell.Commands.Utility" />
    <TrimmerRootAssembly Include="Microsoft.PowerShell.Security" />
  </ItemGroup>
</Project>
'@
        $activity = @'
using Android.App;
using Android.OS;

namespace Terminal.ReferenceBuild;

[Activity(Label = "Terminal Reference Build", MainLauncher = true, Exported = true)]
public sealed class ReferenceActivity : Activity
{
    protected override void OnCreate(Bundle? state)
    {
        base.OnCreate(state);
    }
}
'@
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $projectPath = Join-Path $root 'Terminal.Reference.csproj'
        Write-BuildFile -Path $projectPath -Bytes $utf8.GetBytes($project)
        Write-BuildFile -Path (Join-Path $root 'ReferenceActivity.cs') -Bytes $utf8.GetBytes($activity)

        $sma = @(Get-Variable -Name PackageManifest -Scope Script -ValueOnly -ErrorAction Ignore | Where-Object Id -eq 'System.Management.Automation')
        if ($sma.Count -eq 0) { throw '-Debug needs step 2 or later so the PowerShell version is resolved.' }
        $powerShellVersion = $sma[0].Version
        Write-Host ('[ .. ] Reference build (dotnet publish, PowerShell {0}) in {1}' -f $powerShellVersion, $root) -ForegroundColor DarkCyan
        & $dotnet.Source publish $projectPath -c Release -r $script:Target.Rid -nologo "-p:TargetRid=$($script:Target.Rid)" `
            "-p:PowerShellPackageVersion=$powerShellVersion" `
            "-p:BaseOutputPath=$root\bin\" "-p:BaseIntermediateOutputPath=$root\obj\" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Reference build failed (dotnet exit code $LASTEXITCODE)." }

        # Java peer package name.
        $map = Get-ChildItem -LiteralPath (Join-Path $root 'obj') -Recurse -Filter 'acw-map.txt' | Select-Object -First 1
        if (-not $map) { throw 'Reference build produced no acw-map.txt.' }
        $line = Select-String -LiteralPath $map.FullName -Pattern '^Terminal\.ReferenceBuild\.ReferenceActivity[^;]*;(crc64[0-9a-f]+)\.' | Select-Object -First 1
        if (-not $line) { throw 'acw-map.txt does not map Terminal.ReferenceBuild.ReferenceActivity.' }
        $expected = $line.Matches[0].Groups[1].Value
        $derived = Get-JavaPeerPackage -Namespace 'Terminal.ReferenceBuild' -AssemblyName 'Terminal.Reference'
        if ($derived -cne $expected) { throw "Java peer naming differs: reference $expected, derived $derived." }
        Write-Host ('[PASS] Reference Java peer package matches: {0}' -f $expected) -ForegroundColor Green

        # classes.dex against the pinned copy.
        $apk = Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Recurse -Filter '*-Signed.apk' | Select-Object -First 1
        if (-not $apk) { throw 'Reference build produced no signed APK.' }
        $apkStream = [System.IO.File]::OpenRead($apk.FullName)
        $archive = [System.IO.Compression.ZipArchive]::new($apkStream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            $entry = $archive.GetEntry('classes.dex')
            $buffer = [System.IO.MemoryStream]::new()
            $source = $entry.Open(); try { $source.CopyTo($buffer) } finally { $source.Dispose() }
            $referenceDex = $buffer.ToArray()
        }
        finally { $archive.Dispose() }
        $referenceHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($referenceDex))
        $pinnedHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([byte[]](Import-LibSourceBytes -Path 'classes.dex')))
        if ($referenceHash -ceq $pinnedHash) {
            Write-Host ('[PASS] Reference classes.dex matches the pinned lib/classes.dex: {0}' -f $referenceHash) -ForegroundColor Green
        }
        else {
            Write-Host ('[WARN] Reference classes.dex {0} differs from the pinned lib/classes.dex {1}.' -f $referenceHash, $pinnedHash) -ForegroundColor Yellow
        }

        Write-BuildFile -Intermediate -Path (Join-Path (Join-Path $OutputDirectory 'reference') $apk.Name) -Bytes ([System.IO.File]::ReadAllBytes($apk.FullName))
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        [void]$script:ApprovedWriteRoots.Remove($root)
    }
}

function Show-WrittenFiles {
    if ($script:WrittenFiles.Count -eq 0) { Write-Host 'Files written: none.'; return }
    Write-Host ('Files written: {0}' -f $script:WrittenFiles.Count)
    foreach ($file in $script:WrittenFiles) {
        Write-Host ('  {0,12:N0}  {1}' -f $file.Bytes, $file.Path)
        Write-Host ('                SHA-512 {0}' -f $file.Sha512)
    }
}

# Durable by default. -DeletePackages and the interactive menu both switch this
# to a run that deletes its downloaded packages on the way out.
$script:KeepPackageCache = -not $DeletePackages -and $Packages -eq 'Folder'


# The single trust anchor of the build.
#
# setup.ps1 carries no specification cargo. It holds one constant: the SHA-256
# digest of the root provenance manifest. That manifest lists every file
# imported from lib/ with its own digest and, for upstream files, its
# commit-pinned address. Every address, format constant, and ordered assembly
# name is derived from files that chain back to this digest, so tampering with
# any of them fails verification before a single byte is parsed.
$script:RepositoryLibBaseUrl = 'https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/16c349db8b0941e7ad6b72777592514245d5745b/lib/'
$script:LibRootManifestPath = 'manifest.json'
$script:LibRootManifestSha256 = '6CC98B420B072398B437DD6C9095CB10540F69FE7D504915491D1044F2481314'
$script:LibSourceManifest = $null

function Get-LibFileBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Sha256,
        [string] $Url,
        [string] $Transport = ''
    )

    $bytes = $null

    # The repository's lib/ first, then a confirmed restore cache. Neither is
    # trusted until the bytes hash to the pinned digest.
    $candidates = @(Join-Path $script:LibDirectory $Path)
    if ($script:LibRestoreDirectory) { $candidates += Join-Path $script:LibRestoreDirectory $Path }
    foreach ($fullPath in $candidates) {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $stream = [System.IO.MemoryStream]::new($bytes, $false)
        try { $actual = Get-Sha256Hex -Stream $stream }
        finally { $stream.Dispose() }
        if ($actual -cne $Sha256) {
            throw "lib source '$fullPath' is present but failed integrity verification. Expected $Sha256, computed $actual."
        }
        return $bytes
    }

    # A standalone setup.ps1 restores what it needs. The address is either the
    # source's own pinned upstream address or this repository's pinned copy;
    # either way the bytes are admitted only after they hash to the digest the
    # root manifest declares.
    $address = if ([string]::IsNullOrWhiteSpace($Url)) {
        $script:RepositoryLibBaseUrl + $Path
    }
    else {
        $Url
    }

    Write-Host ('[ .. ] Restoring lib source: {0}' -f $Path) -ForegroundColor DarkCyan
    $bytes = Get-UpstreamSourceBytes -Url $address -Transport $(if ([string]::IsNullOrWhiteSpace($Url)) { '' } else { $Transport })

    $stream = [System.IO.MemoryStream]::new($bytes, $false)
    try { $actual = Get-Sha256Hex -Stream $stream }
    finally { $stream.Dispose() }
    if ($actual -cne $Sha256) {
        throw "lib source '$Path' restored from '$address' hashes to $actual; the pinned digest is $Sha256."
    }

    # Kept on disk only in the confirmed cache; the repository is never written.
    if ($script:LibRestoreDirectory -and -not $WhatIfPreference) {
        Write-BuildFile -Path (Join-Path $script:LibRestoreDirectory $Path) -Bytes $bytes
    }
    return $bytes
}

function Get-PinTransport {
    # The optional 'transport' field of a provenance pin; empty when absent.
    param([Parameter(Mandatory)] $Pin)
    $property = $Pin.PSObject.Properties['transport']
    if ($null -eq $property) { return '' }
    [string]$property.Value
}

function Get-UpstreamSourceBytes {
    # Fetches a pinned address and returns the file's bytes. Gitiles
    # (android.googlesource.com) serves a file at a fixed commit only as base64
    # (?format=TEXT); 'gitiles-base64' decodes that. The pinned digest is always
    # over the decoded file bytes.
    param([Parameter(Mandatory)][string] $Url, [string] $Transport = '')

    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing
    if ([int]$response.StatusCode -ne 200) {
        throw "Upstream source '$Url' returned HTTP $([int]$response.StatusCode)."
    }
    $bytes = $response.RawContentStream.ToArray()
    if ($Transport -ceq 'gitiles-base64') {
        return [Convert]::FromBase64String([System.Text.Encoding]::ASCII.GetString($bytes).Trim())
    }
    if (-not [string]::IsNullOrEmpty($Transport)) { throw "Unknown upstream transport '$Transport'." }
    return $bytes
}

function Get-LibSourceManifest {
    if ($null -ne $script:LibSourceManifest) { return $script:LibSourceManifest }

    $bytes = Get-LibFileBytes -Path $script:LibRootManifestPath -Sha256 $script:LibRootManifestSha256
    $manifest = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -Depth 32
    if ([int]$manifest.schemaVersion -ne 1) {
        throw "Unsupported root provenance manifest schema version $($manifest.schemaVersion)."
    }

    $sources = @($manifest.sources)
    if ($sources.Count -eq 0) {
        throw 'The root provenance manifest declares no sources.'
    }
    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace([string]$source.path)) {
            throw 'The root provenance manifest contains a source without a path.'
        }
        if ([string]$source.sha256 -notmatch '^[0-9A-F]{64}$') {
            throw "Source '$($source.path)' has a malformed SHA-256 digest."
        }
        if ($null -ne $source.url -and -not ([string]$source.url).StartsWith('https://', [StringComparison]::Ordinal)) {
            throw "Source '$($source.path)' declares a non-HTTPS upstream address."
        }
        $transport = Get-PinTransport -Pin $source
        if ($transport -and ($transport -cne 'gitiles-base64' -or -not ([string]$source.url).StartsWith('https://android.googlesource.com/', [StringComparison]::Ordinal))) {
            throw "Source '$($source.path)' declares transport '$transport', which is allowed only as 'gitiles-base64' for android.googlesource.com."
        }
    }
    if (@($sources | Group-Object -Property path | Where-Object Count -ne 1).Count -ne 0) {
        throw 'The root provenance manifest lists a source more than once.'
    }

    # Exact package versions per channel. No floating resolution.
    $versions = $manifest.packageVersions
    if ($null -eq $versions) { throw 'The root provenance manifest declares no packageVersions.' }
    $script:PinnedVersions = @{}
    foreach ($channel in 'DotNet', 'Android', 'PowerShell') {
        $value = [string]$versions.$channel
        if ($value -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
            throw "packageVersions.$channel is not an exact version: '$value'."
        }
        $script:PinnedVersions[$channel] = $value
    }

    $script:LibSourceManifest = $sources
    return $script:LibSourceManifest
}

function Get-PinnedVersion {
    param([Parameter(Mandatory)][ValidateSet('DotNet', 'Android', 'PowerShell')][string] $Channel)
    [void](Get-LibSourceManifest)
    $script:PinnedVersions[$Channel]
}

function Get-LibSourcePin {
    param([Parameter(Mandatory)][string] $Path)

    $pins = @(Get-LibSourceManifest | Where-Object { [string]$_.path -ceq $Path })
    if ($pins.Count -ne 1) {
        throw "lib source '$Path' has $($pins.Count) provenance pins; exactly one is required."
    }
    return $pins[0]
}

function Import-LibSourceBytes {
    param([Parameter(Mandatory)][string] $Path)

    $pin = Get-LibSourcePin -Path $Path
    return Get-LibFileBytes -Path $Path -Sha256 ([string]$pin.sha256) -Url ([string]$pin.url) -Transport (Get-PinTransport -Pin $pin)
}
function Import-LibSourceText {
    param([Parameter(Mandatory)][string] $Path)

    return [System.Text.Encoding]::UTF8.GetString((Import-LibSourceBytes -Path $Path))
}

function Get-LeanAssemblyManifest {
    $text = Import-LibSourceText -Path 'arm64-v8a.lean-assembly-order.txt'
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if (-not $trimmed.EndsWith('.dll', [StringComparison]::Ordinal)) {
            throw "The lean assembly order contains a non-assembly entry: '$trimmed'."
        }
        $names.Add($trimmed)
    }

    # The list is pinned by digest in lib/manifest.json, so its length is the
    # authoritative assembly count; every later check compares against it.
    if ($names.Count -eq 0) {
        throw 'The lean assembly order is empty.'
    }
    if (@($names | Group-Object | Where-Object Count -ne 1).Count -ne 0) {
        throw 'The lean assembly order contains duplicate entries.'
    }
    return $names.ToArray()
}

function Get-AndroidNativeContract {
    $contract = Import-LibSourceText -Path 'android-native-producer.contract.json' |
        ConvertFrom-Json -Depth 32
    if ([int]$contract.schemaVersion -ne 1) {
        throw "Unsupported native producer contract schema version $($contract.schemaVersion)."
    }
    return $contract
}

function Invoke-VerifyStep {
    $remoteCount = 0
    $localCount = 0
    foreach ($pin in (Get-LibSourceManifest)) {
        $bytes = Import-LibSourceBytes -Path ([string]$pin.path)
        $localCount++

        if ($null -eq $pin.url) {
            Write-Host ('[PASS] Local specification: {0} | {1} bytes | SHA-256 {2}' -f
                $pin.path, $bytes.Length, $pin.sha256) -ForegroundColor Green
            continue
        }

        $remoteBytes = Get-UpstreamSourceBytes -Url ([string]$pin.url) -Transport (Get-PinTransport -Pin $pin)
        $remoteStream = [System.IO.MemoryStream]::new($remoteBytes, $false)
        try { $remoteHash = Get-Sha256Hex -Stream $remoteStream }
        finally { $remoteStream.Dispose() }

        if ($remoteHash -cne [string]$pin.sha256) {
            throw "Upstream source '$($pin.url)' hashes to $remoteHash; the pinned digest is $($pin.sha256)."
        }
        $remoteCount++
        Write-Host ('[PASS] Upstream verified: {0} | {1} bytes | SHA-256 {2}' -f
            $pin.path, $remoteBytes.Length, $remoteHash) -ForegroundColor Green
    }

    Test-JavaPeerNaming
    $attributeCount = Test-AndroidAttributeIds
    $names = Get-LeanAssemblyManifest
    $contract = Get-AndroidNativeContract
    Write-Host ('[PASS] Step 1 complete: {0} lib specifications verified locally, {1} byte-identical to their pinned upstream addresses, {2} ordered assembly names, {4} framework attribute ids checked against upstream, and XABA magic 0x{3} imported.' -f
        $localCount,
        $remoteCount,
        $names.Count,
        ([uint32]$contract.xaba.magic).ToString('X8'),
        $attributeCount) -ForegroundColor Green
}

$script:BuildContext = [ordered]@{
    Feeds            = @{}
    PackageBytes     = @{}
    PackageContracts = @{}
    PayloadInventory = $null
    PayloadCandidates = $null
    SelectedAssemblies = $null
    AssemblyStore    = $null
    StoreLibrary     = $null
    PslNative        = $null
    AndroidManifest  = $null
    PeerDex          = $null
    UnsignedApk      = $null
    SignedApk        = $null
    XamarinApp       = $null
}

# Application identity. The activity class is the type emitted into Pwsh.dll.
$script:PackageName = 'dev.mansfieldplumbing.pwsh'
$script:ActivityClassName = 'MainActivity'
$script:ApplicationLabel = 'Pwsh'
$script:ResourceChunkConstants = $null

# The Java peer class Android instantiates for the activity. Derived, not
# chosen: the package is a hash of the managed identity.
$script:AssemblyName = 'Pwsh'
$script:ManagedNamespace = 'Dev.MansfieldPlumbing.Pwsh'

# When an activity declares an explicit Name, .NET Android emits the Java peer
# under that exact name instead of a crc64 package. The manifest, the peer in
# classes2.dex, and the ActivityAttribute must all agree on this one string.
$script:JavaPeerName = 'dev.mansfieldplumbing.pwsh.MainActivity'

function Get-Sha256Hex {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)

    $originalPosition = $Stream.Position
    try {
        $Stream.Position = 0
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            return [Convert]::ToHexString($algorithm.ComputeHash($Stream))
        }
        finally {
            $algorithm.Dispose()
        }
    }
    finally {
        $Stream.Position = $originalPosition
    }
}

function Get-NuGetFeedContract {
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Feed)

    $response = Invoke-WebRequest -Uri $Feed.ServiceIndex -UseBasicParsing
    if ([int]$response.StatusCode -ne 200) {
        throw "Feed '$($Feed.Name)' returned HTTP $([int]$response.StatusCode)."
    }

    $index = $response.Content | ConvertFrom-Json -Depth 16
    $packageBaseResources = @(
        $index.resources | Where-Object {
            $types = @($_.'@type')
            $types -contains 'PackageBaseAddress/3.0.0'
        }
    )

    if ($packageBaseResources.Count -ne 1) {
        throw "Feed '$($Feed.Name)' exposed $($packageBaseResources.Count) PackageBaseAddress/3.0.0 resources; exactly one is required."
    }

    $packageBaseAddress = [string]$packageBaseResources[0].'@id'
    $registration = @($index.resources | Where-Object { @($_.'@type') -contains 'RegistrationsBaseUrl/3.6.0' })
    if ($registration.Count -ne 1) {
        throw "Feed '$($Feed.Name)' exposed $($registration.Count) RegistrationsBaseUrl/3.6.0 resources; exactly one is required."
    }
    if (-not $packageBaseAddress.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Feed '$($Feed.Name)' returned a non-HTTPS package base address."
    }

    [pscustomobject]@{
        Name               = [string]$Feed.Name
        ServiceIndex       = [string]$Feed.ServiceIndex
        PackageBaseAddress = $packageBaseAddress.TrimEnd('/') + '/'
        RegistrationBaseAddress = ([string]$registration[0].'@id').TrimEnd('/') + '/'
    }
}

function Get-PackageAddress {
    param(
        [Parameter(Mandatory)][pscustomobject] $Feed,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Package
    )

    $id = ([string]$Package.Id).ToLowerInvariant()
    $version = ([string]$Package.Version).ToLowerInvariant()
    $escapedId = [Uri]::EscapeDataString($id)
    $escapedVersion = [Uri]::EscapeDataString($version)
    return '{0}{1}/{2}/{1}.{2}.nupkg' -f $Feed.PackageBaseAddress, $escapedId, $escapedVersion
}

function Read-NuspecContract {
    param(
        [Parameter(Mandatory)][byte[]] $PackageBytes,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Package
    )

    $packageStream = [System.IO.MemoryStream]::new($PackageBytes, $false)
    $archive = [System.IO.Compression.ZipArchive]::new(
        $packageStream,
        [System.IO.Compression.ZipArchiveMode]::Read,
        $false
    )

    try {
        $nuspecEntries = @($archive.Entries | Where-Object FullName -like '*.nuspec')
        if ($nuspecEntries.Count -ne 1) {
            throw "Package '$($Package.Id)' contains $($nuspecEntries.Count) nuspec files; exactly one is required."
        }

        $entryStream = $nuspecEntries[0].Open()
        $reader = [System.IO.StreamReader]::new($entryStream, [Text.Encoding]::UTF8, $true)
        try {
            [xml]$document = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
            $entryStream.Dispose()
        }

        $metadata = $document.package.metadata
        if ([string]$metadata.id -cne [string]$Package.Id) {
            throw "Package identity mismatch. Expected '$($Package.Id)', received '$($metadata.id)'."
        }
        if ((ConvertTo-NormalizedVersion ([string]$metadata.version)) -ine (ConvertTo-NormalizedVersion ([string]$Package.Version))) {
            throw "Package version mismatch for '$($Package.Id)'. Expected '$($Package.Version)', received '$($metadata.version)'."
        }

        $dependencies = [System.Collections.Generic.List[object]]::new()
        $dependenciesProperty = $metadata.PSObject.Properties['dependencies']
        if ($null -ne $dependenciesProperty -and $null -ne $dependenciesProperty.Value) {
            $dependencyRoot = $dependenciesProperty.Value
            $directDependencyProperty = $dependencyRoot.PSObject.Properties['dependency']
            if ($null -ne $directDependencyProperty) {
                foreach ($dependency in @($directDependencyProperty.Value)) {
                    if ($null -eq $dependency) { continue }
                    $dependencies.Add([pscustomobject]@{
                        Framework = $null
                        Id        = [string]$dependency.id
                        Range     = [string]$dependency.version
                    })
                }
            }

            $groupProperty = $dependencyRoot.PSObject.Properties['group']
            if ($null -ne $groupProperty) {
                foreach ($group in @($groupProperty.Value)) {
                    if ($null -eq $group) { continue }
                    $groupDependencyProperty = $group.PSObject.Properties['dependency']
                    if ($null -eq $groupDependencyProperty) { continue }
                    foreach ($dependency in @($groupDependencyProperty.Value)) {
                        if ($null -eq $dependency) { continue }
                        $dependencies.Add([pscustomobject]@{
                            Framework = [string]$group.targetFramework
                            Id        = [string]$dependency.id
                            Range     = [string]$dependency.version
                        })
                    }
                }
            }
        }

        [pscustomobject]@{
            Id           = [string]$metadata.id
            Version      = [string]$metadata.version
            EntryCount   = $archive.Entries.Count
            Dependencies = $dependencies.ToArray()
        }
    }
    finally {
        $archive.Dispose()
        $packageStream.Dispose()
    }
}

$script:OfflineMessage = 'Pwsh Setup requires an internet connection.'

function Test-NetworkFailure {
    param([Parameter(Mandatory)][Exception] $Exception)
    for ($e = $Exception; $e; $e = $e.InnerException) {
        if ($e -is [System.Net.Http.HttpRequestException] -or $e -is [System.Net.Sockets.SocketException] -or
            $e -is [System.Net.WebException] -or $e -is [System.Threading.Tasks.TaskCanceledException]) { return $true }
    }
    return $false
}

function Remove-DownloadedPackages {
    # Deletes only the .nupkg files, then the folder if nothing else is in it.
    param([Parameter(Mandatory)][string] $Directory)
    Get-ChildItem -LiteralPath $Directory -Filter '*.nupkg' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
    }
}

function Get-FeedVersions {
    param([Parameter(Mandatory)][string] $PackageBaseAddress, [Parameter(Mandatory)][string] $Id)
    # The flat container lists versions in SemVer order, oldest first.
    $index = Invoke-RestMethod -Uri ('{0}{1}/index.json' -f $PackageBaseAddress, $Id.ToLowerInvariant())
    return @($index.versions)
}

function Get-ChannelVersions {
    <#
        For each channel, the versions published for every one of its packages,
        newest first. Needs only the flat container, so the interface can list
        them before anything is downloaded.
    #>
    param(
        [Parameter(Mandatory)][string] $PackageBaseAddress,
        [Parameter(Mandatory)][object[]] $Manifest,
        [Parameter(Mandatory)][string[]] $Channels
    )

    $result = [ordered]@{}
    foreach ($channel in $Channels) {
        $common = $null
        foreach ($package in @($Manifest | Where-Object { $_.Channel -eq $channel })) {
            $versions = Get-FeedVersions -PackageBaseAddress $PackageBaseAddress -Id $package.Id
            $common = if ($null -eq $common) { $versions } else { @($common | Where-Object { $versions -contains $_ }) }
        }
        if (-not $common) { throw "No version of channel '$channel' is published for all of its packages." }
        [array]::Reverse($common)
        $result[$channel] = @($common)
    }

    # Keep only what can run together on Android. The Android packages carry
    # their API level in the id, and each API level ships with one .NET major
    # (35 = .NET 9, 36 = .NET 10, 37 = .NET 11). Each PowerShell 7.x release is
    # built on one .NET major (7.5 = 9, 7.6 = 10, 7.7 = 11).
    $android = @($Manifest | Where-Object { $_.Channel -eq 'Android' })[0]
    if ($android.Id -notmatch '\.(\d+)\.android') { throw "Cannot read the API level from '$($android.Id)'." }
    $dotnetMajor = [int]$Matches[1] - 26
    $result['DotNet'] = @($result['DotNet'] | Where-Object { $_ -like "$dotnetMajor.*" })
    $result['PowerShell'] = @($result['PowerShell'] | Where-Object { $_ -like "7.$($dotnetMajor - 4).*" })
    foreach ($channel in $Channels) {
        if ($result[$channel].Count -eq 0) { throw "No $channel version on the feed fits Android API $($dotnetMajor + 26) (.NET $dotnetMajor)." }
    }
    return $result
}

function Get-DependencyFloor {
    # NuGet ranges: '1.2', '[1.2, )', '[1.2]', '(1.2, 2.0]'. The resolved
    # version is the lower bound.
    param([Parameter(Mandatory)][string] $Range)
    $lower = ($Range.Trim().TrimStart('[', '(') -split ',')[0].Trim().TrimEnd(']', ')')
    if (-not $lower) { throw "Dependency range '$Range' has no lower bound." }
    return ConvertTo-NormalizedVersion $lower
}

function ConvertTo-NormalizedVersion {
    # NuGet's normalized form, which the feed's addresses use: at least three
    # numeric parts, a fourth only when it is not zero, metadata dropped.
    param([Parameter(Mandatory)][string] $Version)
    $core, $label = ($Version -split '\+')[0] -split '-', 2
    $parts = [System.Collections.Generic.List[string]]@(($core -split '\.') | ForEach-Object { [string][long]$_ })
    while ($parts.Count -lt 3) { $parts.Add('0') }
    if ($parts.Count -eq 4 -and $parts[3] -eq '0') { $parts.RemoveAt(3) }
    return ($parts -join '.') + $(if ($label) { "-$label" } else { '' })
}

function Get-VersionSortKey {
    # Numeric parts compare as numbers; a release sorts after its prereleases.
    param([Parameter(Mandatory)][string] $Version)
    $core, $label = $Version -split '-', 2
    $numbers = @(($core -split '\.') + @('0', '0', '0', '0') | Select-Object -First 4 | ForEach-Object { '{0:D10}' -f [long]$_ })
    return ($numbers -join '.') + $(if ($label) { "-$label" } else { '~' })
}

function Get-CatalogSha512 {
    param(
        [Parameter(Mandatory)][string] $RegistrationBaseAddress,
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Version
    )
    $leaf = Invoke-RestMethod -Uri ('{0}{1}/{2}.json' -f $RegistrationBaseAddress, $Id.ToLowerInvariant(), $Version.ToLowerInvariant())
    $entry = Invoke-RestMethod -Uri ([string]$leaf.catalogEntry)
    if ([string]$entry.packageHashAlgorithm -cne 'SHA512') {
        throw "Catalog for '$Id $Version' publishes a $($entry.packageHashAlgorithm) hash; SHA512 is required."
    }
    return [Convert]::ToHexString([Convert]::FromBase64String([string]$entry.packageHash))
}

function Get-FileSha512 {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [Convert]::ToHexString([System.Security.Cryptography.SHA512]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Get-VerifiedPackageBytes {
    <#
        Returns one resolved package's bytes, checked against the catalog's
        SHA-512. Folder downloads into $CacheDirectory unless a matching
        copy is there; Memory never writes. Returns $null under -WhatIf.
    #>
    param(
        [Parameter(Mandatory)][pscustomobject] $Feed,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Package
    )

    $fileName = '{0}.{1}.nupkg' -f $Package.Id, $Package.Version
    $Package.Sha512 = Get-CatalogSha512 -RegistrationBaseAddress $Feed.RegistrationBaseAddress -Id $Package.Id -Version $Package.Version
    $address = Get-PackageAddress -Feed $Feed -Package $Package

    if ($Packages -eq 'Memory') {
        if (-not $PSCmdlet.ShouldProcess($address, 'Download into memory and verify')) { return $null }
        $bytes = [byte[]](Invoke-WebRequest -Uri $address -UseBasicParsing).Content
        $actual = [Convert]::ToHexString([System.Security.Cryptography.SHA512]::HashData($bytes))
        if ($actual -cne $Package.Sha512) {
            throw "SHA-512 mismatch for '$fileName'. The catalog publishes $($Package.Sha512); the download hashes to $actual."
        }
        return , $bytes
    }

    $destination = Join-Path $CacheDirectory $fileName
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and (Get-FileSha512 -Path $destination) -ceq $Package.Sha512) {
        return , [System.IO.File]::ReadAllBytes($destination)
    }

    $downloadPath = "$destination.download"
    if (-not $PSCmdlet.ShouldProcess($destination, "Download and verify $address")) { return $null }
    Assert-ApprovedWritePath -Path $destination
    try {
        Invoke-WebRequest -Uri $address -OutFile $downloadPath -UseBasicParsing
        $actual = Get-FileSha512 -Path $downloadPath
        if ($actual -cne $Package.Sha512) {
            throw "SHA-512 mismatch for '$fileName'. The catalog publishes $($Package.Sha512); the download hashes to $actual."
        }
        Move-Item -LiteralPath $downloadPath -Destination $destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
    }
    $downloaded = [System.IO.File]::ReadAllBytes($destination)
    $script:WrittenFiles.Add([pscustomobject]@{ Path = $destination; Bytes = $downloaded.Length; Sha512 = $Package.Sha512 })
    return , $downloaded
}

function Invoke-AcquisitionStep {
    if (Skip-ForNativeAdmission -Step 2 -Output 'the NuGet packages') { return }
    if ($Packages -ne 'Memory' -and -not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($CacheDirectory, 'Create package cache directory')) {
            New-ApprovedDirectory -Path $CacheDirectory
        }
    }

    $feeds = @{}
    foreach ($feedDefinition in $script:FeedManifest) {
        $feed = Get-NuGetFeedContract -Feed $feedDefinition
        $feeds[$feed.Name] = $feed
        Write-Host ('[PASS] Feed API: {0} -> {1}' -f $feed.Name, $feed.PackageBaseAddress) -ForegroundColor Green
    }
    $script:BuildContext.Feeds = $feeds

    foreach ($package in $script:PackageManifest) {
        if (-not $feeds.ContainsKey([string]$package.Feed)) {
            throw "Package '$($package.Id)' refers to unknown feed '$($package.Feed)'."
        }
    }

    # Channels first: the version requested, otherwise the one pinned in lib/manifest.json.
    $requested = @{ DotNet = $DotNet; Android = $Android; PowerShell = $PowerShell }
    $channelFeed = $feeds[[string]$script:PackageManifest[0].Feed]
    $available = Get-ChannelVersions -PackageBaseAddress $channelFeed.PackageBaseAddress -Manifest $script:PackageManifest -Channels $script:Channels
    foreach ($channel in $script:Channels) {
        $version = if ($requested[$channel]) { $requested[$channel] } else { Get-PinnedVersion -Channel $channel }
        if ($available[$channel] -notcontains $version) {
            throw "$channel $version is not published for every package in the channel."
        }
        foreach ($package in @($script:PackageManifest | Where-Object { $_.Channel -eq $channel })) { $package.Version = $version }
        Write-Host ('[PASS] {0} {1}' -f $channel, $version) -ForegroundColor Green
    }

    $contracts = [System.Collections.Generic.List[object]]::new()
    $load = {
        param($package)
        $bytes = Get-VerifiedPackageBytes -Feed $feeds[[string]$package.Feed] -Package $package
        if ($null -eq $bytes) {
            Write-Host ('[PLAN] Package not loaded during WhatIf: {0} {1}' -f $package.Id, $package.Version) -ForegroundColor Yellow
            return
        }
        $contract = Read-NuspecContract -PackageBytes $bytes -Package $package
        $script:BuildContext.PackageBytes[[string]$package.Id] = $bytes
        $script:BuildContext.PackageContracts[[string]$package.Id] = $contract
        $contracts.Add($contract)
        Write-Host ('[PASS] Package: {0} {1} | {2} bytes | {3} entries | SHA-512 matches catalog' -f
            $contract.Id, $contract.Version, $bytes.Length, $contract.EntryCount) -ForegroundColor Green
    }

    foreach ($package in @($script:PackageManifest | Where-Object { $_.Channel -ne 'Dependency' })) { . $load $package }

    # Dependencies: the highest floor any loaded package declares. Repeated
    # until nothing changes, so a dependency of a dependency counts, and a
    # higher floor found later replaces a version chosen earlier.
    $dependencies = @($script:PackageManifest | Where-Object { $_.Channel -eq 'Dependency' })
    do {
        $progress = $false
        foreach ($package in $dependencies) {
            $floors = @(foreach ($contract in $contracts) {
                foreach ($dependency in $contract.Dependencies) {
                    if ($dependency.Id -ieq $package.Id -and $dependency.Range) { Get-DependencyFloor -Range $dependency.Range }
                }
            })
            if ($floors.Count -eq 0) { continue }
            $wanted = @($floors | Sort-Object { Get-VersionSortKey $_ })[-1]
            if ($package.Contains('Version') -and $package.Version -eq $wanted) { continue }
            if ($package.Contains('Version')) {
                Write-Host ('[PASS] {0} raised to {1}; a later dependency asks for it.' -f $package.Id, $wanted) -ForegroundColor Green
                $stale = @($contracts | Where-Object { $_.Id -ieq $package.Id })
                foreach ($old in $stale) { [void]$contracts.Remove($old) }
            }
            $package.Version = $wanted
            . $load $package
            $progress = $true
        }
    } while ($progress)

    # System.* packages ship with the runtime; one nothing asks for follows it.
    foreach ($package in @($dependencies | Where-Object { -not $_.Contains('Version') })) {
        if ($package.Id -notlike 'System.*') {
            if ($WhatIfPreference) { continue }
            throw "No loaded package declares a dependency on '$($package.Id)'."
        }
        $package.Version = $script:PackageManifest[0].Version
        Write-Host ('[PASS] {0} follows .NET {1}; no package names a version.' -f $package.Id, $package.Version) -ForegroundColor Green
        . $load $package
    }

    # The record of what this build used.
    $recordDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $recordPath = Join-Path $recordDirectory 'packages.json'
    if ($PSCmdlet.ShouldProcess($recordPath, 'Write package record')) {
        $record = @($script:PackageManifest | ForEach-Object { [ordered]@{ Id = $_.Id; Version = $_.Version; Sha512 = $_.Sha512 } })
        $json = ConvertTo-Json -InputObject $record -Depth 4
        Write-BuildFile -Intermediate -Path $recordPath -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine))
    }

    Write-Host ('[PASS] Step 2 complete: {0} packages, each matching its catalog SHA-512. .NET {1} | Android {2} | PowerShell {3}' -f
        $contracts.Count,
        $script:PackageManifest[0].Version,
        $script:PackageManifest[1].Version,
        $script:PackageManifest[3].Version) -ForegroundColor Green
}

function Test-ReadyToRunImage {
    param([Parameter(Mandatory)][byte[]] $ImageBytes)

    $stream = [System.IO.MemoryStream]::new($ImageBytes, $false)
    $reader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        if (-not $reader.HasMetadata -or $null -eq $reader.PEHeaders.CorHeader) {
            return $false
        }
        return $reader.PEHeaders.CorHeader.ManagedNativeHeaderDirectory.Size -gt 0
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Read-ZipEntryBytes {
    param([Parameter(Mandatory)][System.IO.Compression.ZipArchiveEntry] $Entry)

    $source = $Entry.Open()
    $destination = [System.IO.MemoryStream]::new()
    try {
        $source.CopyTo($destination)
        return $destination.ToArray()
    }
    finally {
        $destination.Dispose()
        $source.Dispose()
    }
}

function Invoke-InspectionStep {
    if (Skip-ForNativeAdmission -Step 3 -Output 'package inspection') { return }

    $managedCount = 0
    $nativeCount = 0
    $r2rCount = 0
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $script:PackageManifest) {
        if (-not $script:BuildContext.PackageBytes.ContainsKey([string]$package.Id)) {
            Write-Host ('[PLAN] Inspection deferred until package is available: {0}' -f $package.Id) -ForegroundColor Yellow
            continue
        }
        $packageBytes = $script:BuildContext.PackageBytes[[string]$package.Id]
        $packageStream = [System.IO.MemoryStream]::new($packageBytes, $false)
        $archive = [System.IO.Compression.ZipArchive]::new(
            $packageStream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )

        $packageManaged = 0
        $packageNative = 0
        $packageR2r = 0
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith('.so', [StringComparison]::OrdinalIgnoreCase)) {
                    $packageNative++
                    continue
                }
                if (-not $entry.FullName.EndsWith('.dll', [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }

                $imageBytes = Read-ZipEntryBytes -Entry $entry
                $isReadyToRun = Test-ReadyToRunImage -ImageBytes $imageBytes
                if ($isReadyToRun) {
                    $packageR2r++
                }
                else {
                    $packageManaged++
                }
                $segments = $entry.FullName -split '/'
                $referenceOnly = $segments -contains 'ref'
                $candidates.Add([pscustomobject]@{
                    Name          = [System.IO.Path]::GetFileName($entry.FullName)
                    PackageId     = [string]$package.Id
                    PackagePath   = $entry.FullName
                    ReferenceOnly = $referenceOnly
                    IsReadyToRun  = $isReadyToRun
                    Bytes         = $imageBytes
                })
            }
        }
        finally {
            $archive.Dispose()
            $packageStream.Dispose()
        }

        $managedCount += $packageManaged
        $nativeCount += $packageNative
        $r2rCount += $packageR2r
        Write-Host ('[PASS] Inventory: {0} | IL={1} | native={2} | R2R excluded={3}' -f
            $package.Id,
            $packageManaged,
            $packageNative,
            $packageR2r) -ForegroundColor Green
    }

    Write-Host ('[PASS] Step 3 complete: {0} IL images, {1} native payloads, and {2} R2R images classified in memory.' -f
        $managedCount,
        $nativeCount,
        $r2rCount) -ForegroundColor Green

    $script:BuildContext.PayloadInventory = [pscustomobject]@{
        IlImageCount      = $managedCount
        NativeImageCount  = $nativeCount
        ExcludedR2rCount  = $r2rCount
    }
    $script:BuildContext.PayloadCandidates = $candidates
}

function Get-PayloadCandidateRank {
    param([Parameter(Mandatory)][pscustomobject] $Candidate)

    $path = $Candidate.PackagePath
    if ($path.StartsWith('generated/', [StringComparison]::OrdinalIgnoreCase)) { return -1 }
    if ($path.StartsWith("runtimes/$($script:Target.Rid)/lib/", [StringComparison]::OrdinalIgnoreCase)) { return 0 }
    if ($path.StartsWith('runtimes/android/lib/', [StringComparison]::OrdinalIgnoreCase)) { return 1 }
    if ($path -match '^runtimes/unix/lib/net11\.0/') { return 2 }
    if ($path.StartsWith('runtimes/unix/lib/', [StringComparison]::OrdinalIgnoreCase)) { return 3 }
    if ($path -match '^lib/net11\.0/') { return 10 }
    if ($path -match '^lib/net10\.0/') { return 11 }
    if ($path -match '^lib/net9\.0/') { return 12 }
    if ($path -match '^lib/net8\.0/') { return 13 }
    if ($path -match '^lib/netstandard2\.1/') { return 20 }
    if ($path -match '^lib/netstandard2\.0/') { return 21 }
    if ($path.StartsWith('lib/', [StringComparison]::OrdinalIgnoreCase)) { return 50 }
    return 100
}

function Set-DeterministicMvid {
    # PersistedAssemblyBuilder stamps every emitted assembly with a fresh GUID
    # and the current time, so two builds of identical input differ. That
    # matters twice over: reproducibility, and the fact that the type map is
    # keyed by MVID, so a random one is a value that must be read back rather
    # than known.
    #
    # Both are normalised here. The timestamp is cleared first, because the
    # module id is then derived from the assembly's own remaining content and
    # would otherwise inherit the clock. No compiler is involved in this build;
    # this is the same idea a deterministic compiler applies, done to bytes we
    # emitted ourselves.
    param([Parameter(Mandatory)][byte[]] $Assembly)

    # COFF header: e_lfanew at 0x3C, then the PE signature, then Machine and
    # NumberOfSections, putting TimeDateStamp eight bytes in.
    $peOffset = [BitConverter]::ToInt32($Assembly, 0x3C)
    if ([BitConverter]::ToUInt32($Assembly, $peOffset) -ne 0x00004550) {
        throw 'The emitted assembly does not carry a PE signature where its DOS header points.'
    }
    $timestampOffset = $peOffset + 8
    for ($i = 0; $i -lt 4; $i++) { $Assembly[$timestampOffset + $i] = 0 }

    $stream = [System.IO.MemoryStream]::new($Assembly, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $current = $reader.GetGuid($reader.GetModuleDefinition().Mvid).ToByteArray()
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    # The GUID appears once, in the #GUID heap. Locate it rather than assuming
    # an offset, and refuse to guess if it is not unique.
    $matches = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le ($Assembly.Length - 16); $i++) {
        if ($Assembly[$i] -ne $current[0]) { continue }
        $same = $true
        for ($j = 1; $j -lt 16; $j++) {
            if ($Assembly[$i + $j] -ne $current[$j]) { $same = $false; break }
        }
        if ($same) { $matches.Add($i) }
    }
    if ($matches.Count -ne 1) {
        throw "The module version id appears $($matches.Count) times in the emitted assembly; exactly one occurrence is required."
    }
    $offset = $matches[0]

    # Digest the assembly with the existing id blanked, so the result depends on
    # content alone and not on whatever GUID happened to be generated.
    $blanked = [byte[]]$Assembly.Clone()
    for ($j = 0; $j -lt 16; $j++) { $blanked[$offset + $j] = 0 }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $digest = $sha256.ComputeHash($blanked) }
    finally { $sha256.Dispose() }

    $mvid = New-Object byte[] 16
    [System.Array]::Copy($digest, 0, $mvid, 0, 16)
    # Mark it as an RFC 4122 version 4 variant 1 value, as deterministic
    # compilers do, so it is a well formed GUID rather than raw hash bytes.
    $mvid[7] = [byte](($mvid[7] -band 0x0F) -bor 0x40)
    $mvid[8] = [byte](($mvid[8] -band 0x3F) -bor 0x80)

    $result = [byte[]]$Assembly.Clone()
    [System.Array]::Copy($mvid, 0, $result, $offset, 16)
    return ,$result
}

function New-EmptyManagedAssemblyBytes {
    param(
        [Parameter(Mandatory)][string] $AssemblyName,
        [Parameter(Mandatory)][string] $TypeName
    )

    $identity = [Reflection.AssemblyName]::new($AssemblyName)
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
    $module = $builder.DefineDynamicModule("$AssemblyName.dll")
    $type = $module.DefineType($TypeName, [Reflection.TypeAttributes]'Public,Class,Sealed')
    $type.DefineDefaultConstructor([Reflection.MethodAttributes]'Public') | Out-Null
    $type.CreateType() | Out-Null
    $stream = [IO.MemoryStream]::new()
    try {
        $builder.Save($stream)
        return ,(Set-DeterministicMvid -Assembly $stream.ToArray())
    }
    finally {
        $stream.Dispose()
    }
}

# Methods compiled from expression trees during this build.
$script:PersistedMethods = [System.Collections.Generic.List[object]]::new()

# ==============================================================================
# Expression kit
#
# Methods are described as System.Linq.Expressions trees and handed to the
# framework's own LambdaCompiler, which writes the IL. Nothing here emits an
# opcode: valid IL is the compiler's guarantee, not ours.
#
# Ported from the pre-migration tree, where this produced the whole recovery
# screen as roughly thirty compiled methods.
# ==============================================================================
$script:AndroidAssembly = $null
$script:ExpressionFactories = $null

function Initialize-ExpressionKit {
    param([Parameter(Mandatory)][Reflection.Assembly] $AndroidAssembly)

    $script:AndroidAssembly = $AndroidAssembly

    # Expression.New/Call/Block/Lambda/Invoke are heavily overloaded. Bind the
    # exact overload once by signature rather than letting PowerShell's method
    # resolution pick per call site.
    $expressionType = [Linq.Expressions.Expression]
    $expressionArray = [Linq.Expressions.Expression[]]
    $parameterArray = [Linq.Expressions.ParameterExpression[]]

    $factories = @{
        New = $expressionType.GetMethod('New', [Type[]]@([Reflection.ConstructorInfo], $expressionArray))
        Call = $expressionType.GetMethod('Call', [Type[]]@($expressionType, [Reflection.MethodInfo], $expressionArray))
        Block = $expressionType.GetMethod('Block', [Type[]]@(
            [Collections.Generic.IEnumerable[Linq.Expressions.ParameterExpression]], $expressionArray))
        Lambda = $expressionType.GetMethod('Lambda', [Type[]]@([Type], $expressionType, $parameterArray))
        Invoke = $expressionType.GetMethod('Invoke', [Type[]]@($expressionType, $expressionArray))
    }
    foreach ($name in $factories.Keys) {
        if ($null -eq $factories[$name]) {
            throw "The System.Linq.Expressions.$name factory overload was not found."
        }
    }
    $script:ExpressionFactories = $factories
}

function Get-AndroidType {
    param([Parameter(Mandatory)][string] $Name)

    $type = $script:AndroidAssembly.GetType($Name, $false)
    if ($null -eq $type) { throw "Android type not found: $Name" }
    $type
}

# Exact member binding. Every lookup names the full signature and throws with it
# when the member is absent, so an overload can never be silently mis-chosen.
function Get-ExactConstructor {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter()][AllowEmptyCollection()][Type[]] $ParameterTypes = @()
    )

    $constructor = $Type.GetConstructor($ParameterTypes)
    if ($null -eq $constructor) {
        throw "Constructor not found: $($Type.FullName)($($ParameterTypes.FullName -join ', '))"
    }
    $constructor
}

function Get-ExactMethod {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][string] $Name,
        [Parameter()][AllowEmptyCollection()][Type[]] $ParameterTypes = @(),
        [Reflection.BindingFlags] $Flags = [Reflection.BindingFlags]'Public,Instance,Static'
    )

    $method = $Type.GetMethod($Name, $Flags, $null, $ParameterTypes, $null)
    if ($null -eq $method) {
        throw "Method not found: $($Type.FullName).$Name($($ParameterTypes.FullName -join ', '))"
    }
    $method
}

function Get-ExactProperty {
    param(
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][string] $Name,
        [Reflection.BindingFlags] $Flags = [Reflection.BindingFlags]'Public,Instance,Static'
    )

    $property = $Type.GetProperty($Name, $Flags)
    if ($null -eq $property) { throw "Property not found: $($Type.FullName).$Name" }
    $property
}

function New-ClrNew {
    param(
        [Parameter(Mandatory)][Reflection.ConstructorInfo] $Constructor,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.Expression[]] $Arguments = @()
    )
    $script:ExpressionFactories.New.Invoke($null, [object[]]@(
        $Constructor, [Linq.Expressions.Expression[]]$Arguments))
}

function New-ClrCall {
    param(
        [AllowNull()][Linq.Expressions.Expression] $Instance,
        [Parameter(Mandatory)][Reflection.MethodInfo] $Method,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.Expression[]] $Arguments = @()
    )
    $script:ExpressionFactories.Call.Invoke($null, [object[]]@(
        $Instance, $Method, [Linq.Expressions.Expression[]]$Arguments))
}

function New-ClrAssign {
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right
    )
    [Linq.Expressions.Expression]::Assign($Left, $Right)
}

function New-ClrProperty {
    param(
        [AllowNull()][Linq.Expressions.Expression] $Instance,
        [Parameter(Mandatory)][Reflection.PropertyInfo] $Property
    )
    [Linq.Expressions.Expression]::Property($Instance, $Property)
}

function New-ClrField {
    param(
        [AllowNull()][Linq.Expressions.Expression] $Instance,
        [Parameter(Mandatory)][Reflection.FieldInfo] $Field
    )
    [Linq.Expressions.Expression]::Field($Instance, $Field)
}

function New-ClrConstant {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory)][Type] $Type
    )
    [Linq.Expressions.Expression]::Constant($Value, $Type)
}

function New-ClrBlock {
    param(
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.ParameterExpression[]] $Variables = @(),
        [Parameter(Mandatory)][Linq.Expressions.Expression[]] $Expressions
    )
    $script:ExpressionFactories.Block.Invoke($null, [object[]]@(
        [Linq.Expressions.ParameterExpression[]]$Variables,
        [Linq.Expressions.Expression[]]$Expressions))
}

function New-ClrLambda {
    param(
        [Parameter(Mandatory)][Type] $DelegateType,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Body,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.ParameterExpression[]] $Parameters = @()
    )
    $script:ExpressionFactories.Lambda.Invoke($null, [object[]]@(
        $DelegateType, $Body, [Linq.Expressions.ParameterExpression[]]$Parameters))
}

function Write-MicrosoftLambdaToMethodBuilder {
    <#
        Drives System.Linq.Expressions' own LambdaCompiler and points its
        ILGenerator at the supplied MethodBuilder, so the framework emits the
        method body. This is the reason the build needs no C# compiler and no
        hand-written opcodes.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.LambdaExpression] $Lambda,
        [Parameter(Mandatory)][Reflection.Emit.MethodBuilder] $MethodBuilder,
        [switch] $ExplicitThis
    )

    $instanceFlags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
    $staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'

    $expressionAssembly = [Linq.Expressions.Expression].Assembly
    $compilerType = $expressionAssembly.GetType('System.Linq.Expressions.Compiler.LambdaCompiler', $true)

    $analyze = $compilerType.GetMethods($staticFlags) |
        Where-Object { $_.Name -ceq 'AnalyzeLambda' -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    if ($null -eq $analyze) { throw 'LambdaCompiler.AnalyzeLambda was not found.' }

    [object[]] $analyzeArguments = @($Lambda)
    $tree = $analyze.Invoke($null, $analyzeArguments)
    $lowered = [Linq.Expressions.LambdaExpression]$analyzeArguments[0]

    $constructor = $compilerType.GetConstructors($instanceFlags) |
        Where-Object {
            $parameters = $_.GetParameters()
            $parameters.Count -eq 2 -and
            $parameters[1].ParameterType -eq [Linq.Expressions.LambdaExpression]
        } |
        Select-Object -First 1
    if ($null -eq $constructor) { throw 'The LambdaCompiler constructor was not found.' }

    $compiler = $constructor.Invoke([object[]]@($tree, $lowered))

    $methodField = $compilerType.GetField('_method', $instanceFlags)
    $ilField = $compilerType.GetField('_ilg', $instanceFlags)
    $closureField = $compilerType.GetField('_hasClosureArgument', $instanceFlags)
    $typeBuilderField = $compilerType.GetField('_typeBuilder', $instanceFlags)
    foreach ($field in @($methodField, $ilField, $closureField)) {
        if ($null -eq $field) { throw 'A required LambdaCompiler field was not found.' }
    }

    $methodIdentity = $MethodBuilder
    if ($ExplicitThis) {
        # LambdaCompiler reserves arg0 for an instance method and maps lambda
        # parameters from arg1. A lambda that carries CLR self explicitly needs a
        # static signature descriptor, while still writing into the real
        # instance MethodBuilder's ILGenerator.
        $methodIdentity = [Reflection.Emit.DynamicMethod]::new(
            "__PersistedSignature_$($MethodBuilder.Name)",
            $Lambda.ReturnType,
            [Type[]]@($Lambda.Parameters | ForEach-Object Type),
            $true)
    }

    $methodField.SetValue($compiler, $methodIdentity)
    $ilField.SetValue($compiler, $MethodBuilder.GetILGenerator())
    $closureField.SetValue($compiler, $false)
    if ($typeBuilderField) { $typeBuilderField.SetValue($compiler, $MethodBuilder.DeclaringType) }

    $emit = $compilerType.GetMethods($instanceFlags) |
        Where-Object { $_.Name -ceq 'EmitLambdaBody' -and $_.GetParameters().Count -eq 0 } |
        Select-Object -First 1
    if ($null -eq $emit) { throw 'LambdaCompiler.EmitLambdaBody was not found.' }

    $null = $emit.Invoke($compiler, @())

    [pscustomobject]@{
        LoweredLambda  = $lowered
        AnalyzedTree   = $tree
        TypeBuilderSet = [bool]$typeBuilderField
    }
}

# ==============================================================================
# Expression graph verification
#
# The build fails if a dynamic call site survives into an emitted method. This
# is asserted on the in-memory tree before any IL is written, so there is no
# second parser to disagree with the first.
# ==============================================================================
function Test-CallSiteType {
    param([AllowNull()][Type] $Type)

    if ($null -eq $Type) { return $false }
    if ($Type.IsArray -or $Type.IsByRef -or $Type.IsPointer) {
        return Test-CallSiteType $Type.GetElementType()
    }
    if ($Type.IsGenericType -and
        $Type.GetGenericTypeDefinition().FullName -eq 'System.Runtime.CompilerServices.CallSite`1') {
        return $true
    }
    foreach ($argument in $Type.GetGenericArguments()) {
        if (Test-CallSiteType $argument) { return $true }
    }
    $false
}

function Test-ExpressionGraph {
    param([Parameter(Mandatory)][Linq.Expressions.Expression] $Expression)

    $visited = [Collections.Generic.HashSet[object]]::new(
        [Collections.Generic.ReferenceEqualityComparer]::Instance)
    $report = [pscustomobject]@{
        DynamicNodes       = 0
        CallSiteReferences = 0
        CallSiteConstants  = 0
        NodesVisited       = 0
    }

    $visit = {
        param([AllowNull()] $Node)

        if ($null -eq $Node -or -not $visited.Add($Node)) { return }

        if ($Node -is [Linq.Expressions.Expression]) {
            $report.NodesVisited++
            $nodeTypeName = $Node.GetType().Name
            if ($Node -is [Linq.Expressions.DynamicExpression] -or
                $nodeTypeName -like 'TypedDynamicExpression*') {
                $report.DynamicNodes++
            }
            if (Test-CallSiteType $Node.Type) { $report.CallSiteReferences++ }
            if ($Node -is [Linq.Expressions.ConstantExpression] -and $null -ne $Node.Value) {
                if (Test-CallSiteType $Node.Value.GetType()) { $report.CallSiteConstants++ }
            }
            if ($Node -is [Linq.Expressions.MethodCallExpression]) {
                if ((Test-CallSiteType $Node.Method.DeclaringType) -or
                    (Test-CallSiteType $Node.Method.ReturnType)) {
                    $report.CallSiteReferences++
                }
                foreach ($parameter in $Node.Method.GetParameters()) {
                    if (Test-CallSiteType $parameter.ParameterType) { $report.CallSiteReferences++ }
                }
            }
        }

        if ($Node.GetType().Namespace -ne 'System.Linq.Expressions') { return }

        foreach ($property in $Node.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance')) {
            if ($property.GetIndexParameters().Length -ne 0) { continue }
            try { $value = $property.GetValue($Node) } catch { continue }
            if ($null -eq $value -or $value -is [string] -or $value -is [Type] -or
                $value -is [Reflection.MemberInfo]) { continue }
            if ($value -is [Linq.Expressions.Expression] -or
                $value.GetType().Namespace -eq 'System.Linq.Expressions') {
                & $visit $value
                continue
            }
            if ($value -is [Collections.IEnumerable]) {
                foreach ($item in $value) {
                    if ($null -ne $item -and
                        ($item -is [Linq.Expressions.Expression] -or
                         $item.GetType().Namespace -eq 'System.Linq.Expressions')) {
                        & $visit $item
                    }
                }
            }
        }
    }

    & $visit $Expression
    $report
}

function Add-PersistedMethod {
    <#
        Defines a method and compiles its expression tree into it. The tree is
        verified before emission, so a surviving dynamic call site fails the
        build here rather than on the device.
    #>
    param(
        [Parameter(Mandatory)][Reflection.Emit.TypeBuilder] $Owner,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][Reflection.MethodAttributes] $Attributes,
        [Parameter(Mandatory)][Type] $ReturnType,
        [Parameter()][AllowEmptyCollection()][Type[]] $ParameterTypes = @(),
        [Parameter(Mandatory)][Type] $DelegateType,
        [Parameter()][AllowEmptyCollection()][Linq.Expressions.ParameterExpression[]] $LambdaParameters = @(),
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Body
    )

    $report = Test-ExpressionGraph -Expression $Body
    if ($report.DynamicNodes -or $report.CallSiteReferences -or $report.CallSiteConstants) {
        throw ("$($Owner.FullName).$Name is not fully persisted: " +
            "$($report.DynamicNodes) dynamic node(s), " +
            "$($report.CallSiteReferences) call-site reference(s), " +
            "$($report.CallSiteConstants) call-site constant(s).")
    }

    $method = $Owner.DefineMethod($Name, $Attributes, $ReturnType, $ParameterTypes)
    $lambda = New-ClrLambda $DelegateType $Body $LambdaParameters
    try {
        $null = Write-MicrosoftLambdaToMethodBuilder -Lambda $lambda -MethodBuilder $method
    }
    catch {
        $inner = $_.Exception.GetBaseException()
        throw "LambdaCompiler failed for $($Owner.FullName).$Name ($($Body.NodeType)): $($inner.GetType().FullName): $($inner.Message)"
    }

    $script:PersistedMethods.Add([pscustomobject]@{
        Name = $Name; Method = $method; Nodes = $report.NodesVisited })
    $method
}

function New-StaticCall {
    param([Reflection.MethodInfo] $Method, [Linq.Expressions.Expression[]] $Arguments = @())
    New-ClrCall $null $Method $Arguments
}

function New-If {
    param([Linq.Expressions.Expression] $Test, [Linq.Expressions.Expression] $Then, [Linq.Expressions.Expression] $Else)
    [Linq.Expressions.Expression]::IfThenElse($Test, $Then, $Else)
}

function New-ReturnBlock {
    param([Type] $Type, [Linq.Expressions.Expression[]] $Expressions)
    [Linq.Expressions.Expression]::Block($Type, [Linq.Expressions.Expression[]]$Expressions)
}

function New-HomePath([Linq.Expressions.Expression] $Path, [Reflection.MethodInfo] $Concat, [Reflection.MethodInfo] $GetFileName) {
    # HOME/<file name>: the form the recovery screen shows for a path.
    New-StaticCall $Concat @((New-ClrConstant 'HOME/' ([string])), (New-StaticCall $GetFileName @($Path)))
}

function Add-AndroidHostDeclarations {
    # Resolves the Android and runtime members the host methods bind to, and declares the RecoveryProgram type and its static fields.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $Android = $State['Android']
    $Main = $State['Main']
    $Module = $State['Module']

    Initialize-ExpressionKit -AndroidAssembly $Android


    $activityType = Get-AndroidType 'Android.App.Activity'
    $buttonType = Get-AndroidType 'Android.Widget.Button'
    $clipDataType = Get-AndroidType 'Android.Content.ClipData'
    $clipboardManagerType = Get-AndroidType 'Android.Content.ClipboardManager'
    $complexUnitType = Get-AndroidType 'Android.Util.ComplexUnitType'
    $contextType = Get-AndroidType 'Android.Content.Context'
    $displayMetricsType = Get-AndroidType 'Android.Util.DisplayMetrics'
    $intentType = Get-AndroidType 'Android.Content.Intent'
    $javaFileType = Get-AndroidType 'Java.IO.File'
    $javaObjectType = Get-AndroidType 'Java.Lang.Object'
    $linearLayoutType = Get-AndroidType 'Android.Widget.LinearLayout'
    $layoutParamsType = Get-AndroidType 'Android.Widget.LinearLayout+LayoutParams'
    $orientationType = Get-AndroidType 'Android.Widget.Orientation'
    $resourcesType = Get-AndroidType 'Android.Content.Res.Resources'
    $scrollViewType = Get-AndroidType 'Android.Widget.ScrollView'
    $textViewType = Get-AndroidType 'Android.Widget.TextView'
    $typedValueType = Get-AndroidType 'Android.Util.TypedValue'
    $viewType = Get-AndroidType 'Android.Views.View'
    $viewGroupLayoutParamsType = Get-AndroidType 'Android.Views.ViewGroup+LayoutParams'
    $colorType = Get-AndroidType 'Android.Graphics.Color'

    $eventHandlerType = [EventHandler]

    $linearLayoutConstructor = Get-ExactConstructor $linearLayoutType @($contextType)
    $textViewConstructor = Get-ExactConstructor $textViewType @($contextType)
    $scrollViewConstructor = Get-ExactConstructor $scrollViewType @($contextType)
    $buttonConstructor = Get-ExactConstructor $buttonType @($contextType)
    $layoutParamsConstructor = Get-ExactConstructor $layoutParamsType @([int], [int], [single])
    $buttonLayoutParamsConstructor = Get-ExactConstructor $layoutParamsType @([int], [int])
    $intentConstructor = Get-ExactConstructor $intentType @([string])

    $orientationProperty = Get-ExactProperty $linearLayoutType 'Orientation'
    $textViewTextProperty = Get-ExactProperty $textViewType 'Text'
    $buttonTextProperty = Get-ExactProperty $buttonType 'Text'
    $topMarginProperty = Get-ExactProperty $layoutParamsType 'TopMargin'
    $bottomMarginProperty = Get-ExactProperty $layoutParamsType 'BottomMargin'
    $filesDirProperty = Get-ExactProperty $contextType 'FilesDir'
    $absolutePathProperty = Get-ExactProperty $javaFileType 'AbsolutePath'
    $resourcesProperty = Get-ExactProperty $contextType 'Resources'
    $displayMetricsProperty = Get-ExactProperty $resourcesType 'DisplayMetrics'
    $primaryClipProperty = Get-ExactProperty $clipboardManagerType 'PrimaryClip'
    $actionOpenDocumentField = $intentType.GetField('ActionOpenDocument', [Reflection.BindingFlags]'Public,Static')
    $categoryOpenableField = $intentType.GetField('CategoryOpenable', [Reflection.BindingFlags]'Public,Static')
    $whiteProperty = Get-ExactProperty $colorType 'White' ([Reflection.BindingFlags]'Public,Static')
    $matchParentField = $viewGroupLayoutParamsType.GetField('MatchParent', [Reflection.BindingFlags]'Public,Static')
    $wrapContentField = $viewGroupLayoutParamsType.GetField('WrapContent', [Reflection.BindingFlags]'Public,Static')
    if ($null -eq $actionOpenDocumentField -or $null -eq $categoryOpenableField -or
        $null -eq $matchParentField -or $null -eq $wrapContentField) {
        throw 'Required Android constant fields were not found.'
    }

    $setBackgroundColor = Get-ExactMethod $viewType 'SetBackgroundColor' @($colorType)
    $setPadding = Get-ExactMethod $viewType 'SetPadding' @([int], [int], [int], [int])
    $setTextColor = Get-ExactMethod $textViewType 'SetTextColor' @($colorType)
    $setTextSize = Get-ExactMethod $textViewType 'SetTextSize' @($complexUnitType, [single])
    $setTextIsSelectable = Get-ExactMethod $textViewType 'SetTextIsSelectable' @([bool])
    $addView = Get-ExactMethod $linearLayoutType 'AddView' @($viewType)
    $addViewWithParams = Get-ExactMethod $linearLayoutType 'AddView' @($viewType, $viewGroupLayoutParamsType)
    $scrollAddView = Get-ExactMethod $scrollViewType 'AddView' @($viewType)
    $buttonAddClick = Get-ExactMethod $buttonType 'add_Click' @($eventHandlerType)
    $rgb = Get-ExactMethod $colorType 'Rgb' @([int], [int], [int]) ([Reflection.BindingFlags]'Public,Static')
    $applyDimension = Get-ExactMethod $typedValueType 'ApplyDimension' @($complexUnitType, [single], $displayMetricsType) ([Reflection.BindingFlags]'Public,Static')
    $setContentView = Get-ExactMethod $activityType 'SetContentView' @($viewType)
    $getSystemService = Get-ExactMethod $contextType 'GetSystemService' @([string])
    $newPlainText = Get-ExactMethod $clipDataType 'NewPlainText' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
    $addCategory = Get-ExactMethod $intentType 'AddCategory' @([string])
    $setType = Get-ExactMethod $intentType 'SetType' @([string])
    $startActivityForResult = Get-ExactMethod $activityType 'StartActivityForResult' @($intentType, [int])
    $pathCombine = Get-ExactMethod ([IO.Path]) 'Combine' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
    $readAllText = Get-ExactMethod ([IO.File]) 'ReadAllText' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $getFileSystemEntries = Get-ExactMethod ([IO.Directory]) 'GetFileSystemEntries' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $stringConcat3 = Get-ExactMethod ([string]) 'Concat' @([string], [string], [string]) ([Reflection.BindingFlags]'Public,Static')

    $stringBuilderType = [Text.StringBuilder]
    $stringBuilderConstructor = Get-ExactConstructor $stringBuilderType @()
    $appendString = Get-ExactMethod $stringBuilderType 'Append' @([string])
    $appendLineString = Get-ExactMethod $stringBuilderType 'AppendLine' @([string])
    $builderToString = Get-ExactMethod $stringBuilderType 'ToString' @()
    $currentDomainProperty = Get-ExactProperty ([AppDomain]) 'CurrentDomain' ([Reflection.BindingFlags]'Public,Static')
    $getAssemblies = Get-ExactMethod ([AppDomain]) 'GetAssemblies' @()
    $assemblyFullNameProperty = Get-ExactProperty ([Reflection.Assembly]) 'FullName'
    $assemblyLocationProperty = Get-ExactProperty ([Reflection.Assembly]) 'Location'
    $packageNameProperty = Get-ExactProperty $contextType 'PackageName'
    $manufacturerProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'Manufacturer' ([Reflection.BindingFlags]'Public,Static')
    $modelProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'Model' ([Reflection.BindingFlags]'Public,Static')
    $androidReleaseProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build+VERSION') 'Release' ([Reflection.BindingFlags]'Public,Static')
    $androidSdkProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build+VERSION') 'SdkInt' ([Reflection.BindingFlags]'Public,Static')
    $supportedAbisProperty = Get-ExactProperty (Get-AndroidType 'Android.OS.Build') 'SupportedAbis' ([Reflection.BindingFlags]'Public,Static')
    $frameworkDescriptionProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'FrameworkDescription' ([Reflection.BindingFlags]'Public,Static')
    $processArchitectureProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'ProcessArchitecture' ([Reflection.BindingFlags]'Public,Static')
    $osArchitectureProperty = Get-ExactProperty ([Runtime.InteropServices.RuntimeInformation]) 'OSArchitecture' ([Reflection.BindingFlags]'Public,Static')
    $joinStrings = Get-ExactMethod ([string]) 'Join' @(
        [string], [Collections.Generic.IEnumerable[string]]) ([Reflection.BindingFlags]'Public,Static')

    $programType = $Module.DefineType(
        'Dev.MansfieldPlumbing.Pwsh.RecoveryProgram',
        [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
    $mainType = $Main
    $runspaceType = [Management.Automation.Runspaces.Runspace]
    $runspaceField = $programType.DefineField(
        's_runspace', $runspaceType,
        [Reflection.FieldAttributes]'Private,Static')
    $powerShellLoadContextInitializedField = $programType.DefineField(
        's_powerShellLoadContextInitialized', [bool],
        [Reflection.FieldAttributes]'Private,Static')
    $animationCallbackField = $programType.DefineField(
        's_animationCallback', [Action],
        [Reflection.FieldAttributes]'Private,Static')

    $emitted = [Collections.Generic.List[object]]::new()
    $publicStatic = [Reflection.MethodAttributes]'Public,Static,HideBySig'
    $privateStatic = [Reflection.MethodAttributes]'Private,Static,HideBySig'

    $State['absolutePathProperty'] = $absolutePathProperty
    $State['actionOpenDocumentField'] = $actionOpenDocumentField
    $State['activityType'] = $activityType
    $State['addCategory'] = $addCategory
    $State['addView'] = $addView
    $State['addViewWithParams'] = $addViewWithParams
    $State['androidReleaseProperty'] = $androidReleaseProperty
    $State['androidSdkProperty'] = $androidSdkProperty
    $State['animationCallbackField'] = $animationCallbackField
    $State['applyDimension'] = $applyDimension
    $State['assemblyFullNameProperty'] = $assemblyFullNameProperty
    $State['bottomMarginProperty'] = $bottomMarginProperty
    $State['buttonAddClick'] = $buttonAddClick
    $State['buttonConstructor'] = $buttonConstructor
    $State['buttonLayoutParamsConstructor'] = $buttonLayoutParamsConstructor
    $State['buttonTextProperty'] = $buttonTextProperty
    $State['buttonType'] = $buttonType
    $State['categoryOpenableField'] = $categoryOpenableField
    $State['clipboardManagerType'] = $clipboardManagerType
    $State['complexUnitType'] = $complexUnitType
    $State['contextType'] = $contextType
    $State['displayMetricsProperty'] = $displayMetricsProperty
    $State['emitted'] = $emitted
    $State['filesDirProperty'] = $filesDirProperty
    $State['frameworkDescriptionProperty'] = $frameworkDescriptionProperty
    $State['getFileSystemEntries'] = $getFileSystemEntries
    $State['getSystemService'] = $getSystemService
    $State['intentConstructor'] = $intentConstructor
    $State['intentType'] = $intentType
    $State['layoutParamsConstructor'] = $layoutParamsConstructor
    $State['layoutParamsType'] = $layoutParamsType
    $State['linearLayoutConstructor'] = $linearLayoutConstructor
    $State['linearLayoutType'] = $linearLayoutType
    $State['mainType'] = $mainType
    $State['manufacturerProperty'] = $manufacturerProperty
    $State['matchParentField'] = $matchParentField
    $State['modelProperty'] = $modelProperty
    $State['newPlainText'] = $newPlainText
    $State['orientationProperty'] = $orientationProperty
    $State['orientationType'] = $orientationType
    $State['packageNameProperty'] = $packageNameProperty
    $State['pathCombine'] = $pathCombine
    $State['powerShellLoadContextInitializedField'] = $powerShellLoadContextInitializedField
    $State['primaryClipProperty'] = $primaryClipProperty
    $State['privateStatic'] = $privateStatic
    $State['programType'] = $programType
    $State['publicStatic'] = $publicStatic
    $State['readAllText'] = $readAllText
    $State['resourcesProperty'] = $resourcesProperty
    $State['rgb'] = $rgb
    $State['runspaceField'] = $runspaceField
    $State['runspaceType'] = $runspaceType
    $State['scrollAddView'] = $scrollAddView
    $State['scrollViewConstructor'] = $scrollViewConstructor
    $State['scrollViewType'] = $scrollViewType
    $State['setBackgroundColor'] = $setBackgroundColor
    $State['setContentView'] = $setContentView
    $State['setPadding'] = $setPadding
    $State['setTextColor'] = $setTextColor
    $State['setTextIsSelectable'] = $setTextIsSelectable
    $State['setTextSize'] = $setTextSize
    $State['setType'] = $setType
    $State['startActivityForResult'] = $startActivityForResult
    $State['textViewConstructor'] = $textViewConstructor
    $State['textViewTextProperty'] = $textViewTextProperty
    $State['textViewType'] = $textViewType
    $State['topMarginProperty'] = $topMarginProperty
    $State['viewType'] = $viewType
    $State['whiteProperty'] = $whiteProperty
    $State['wrapContentField'] = $wrapContentField
}

function Add-RecoveryScreenMethods {
    # The recovery screen: layout factories and ShowRecovery.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $activityType = $State['activityType']
    $addView = $State['addView']
    $addViewWithParams = $State['addViewWithParams']
    $applyDimension = $State['applyDimension']
    $bottomMarginProperty = $State['bottomMarginProperty']
    $buttonAddClick = $State['buttonAddClick']
    $buttonConstructor = $State['buttonConstructor']
    $buttonLayoutParamsConstructor = $State['buttonLayoutParamsConstructor']
    $buttonTextProperty = $State['buttonTextProperty']
    $buttonType = $State['buttonType']
    $complexUnitType = $State['complexUnitType']
    $displayMetricsProperty = $State['displayMetricsProperty']
    $layoutParamsConstructor = $State['layoutParamsConstructor']
    $layoutParamsType = $State['layoutParamsType']
    $linearLayoutConstructor = $State['linearLayoutConstructor']
    $linearLayoutType = $State['linearLayoutType']
    $matchParentField = $State['matchParentField']
    $orientationProperty = $State['orientationProperty']
    $orientationType = $State['orientationType']
    $privateStatic = $State['privateStatic']
    $programType = $State['programType']
    $publicStatic = $State['publicStatic']
    $resourcesProperty = $State['resourcesProperty']
    $rgb = $State['rgb']
    $scrollAddView = $State['scrollAddView']
    $scrollViewConstructor = $State['scrollViewConstructor']
    $scrollViewType = $State['scrollViewType']
    $setBackgroundColor = $State['setBackgroundColor']
    $setContentView = $State['setContentView']
    $setPadding = $State['setPadding']
    $setTextColor = $State['setTextColor']
    $setTextIsSelectable = $State['setTextIsSelectable']
    $setTextSize = $State['setTextSize']
    $textViewConstructor = $State['textViewConstructor']
    $textViewTextProperty = $State['textViewTextProperty']
    $textViewType = $State['textViewType']
    $topMarginProperty = $State['topMarginProperty']
    $viewType = $State['viewType']
    $whiteProperty = $State['whiteProperty']
    $wrapContentField = $State['wrapContentField']

    # Small factories keep every persisted method closure-free.
    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $v = [Linq.Expressions.Expression]::Parameter([int], 'value')
    $dpBody = [Linq.Expressions.Expression]::Convert(
        (New-ClrCall $null $applyDimension @(
            (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Dip')) $complexUnitType),
            ([Linq.Expressions.Expression]::Convert($v, [single])),
            (New-ClrProperty (New-ClrProperty $a $resourcesProperty) $displayMetricsProperty))),
        [int])
    $dpMethod = Add-PersistedMethod $programType 'Dp' $privateStatic ([int]) @($activityType, [int]) `
        ([Func``3].MakeGenericType($activityType, [int], [int])) @($a, $v) $dpBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $parameters = [Linq.Expressions.Expression]::Parameter($layoutParamsType, 'parameters')
    $margin = New-StaticCall $dpMethod @($a, (New-ClrConstant 8 ([int])))
    $buttonParamsBody = New-ReturnBlock $layoutParamsType @(
        (New-ClrAssign (New-ClrProperty $parameters $topMarginProperty) $margin),
        $parameters)
    $buttonParamsMethod = Add-PersistedMethod $programType 'ConfigureButtonParameters' $privateStatic $layoutParamsType `
        @($activityType, $layoutParamsType) `
        ([Func``3].MakeGenericType($activityType, $layoutParamsType, $layoutParamsType)) `
        @($a, $parameters) $buttonParamsBody

    $typeGetType = Get-ExactMethod ([Type]) 'GetType' @([string], [bool]) ([Reflection.BindingFlags]'Public,Static')
    $typeGetMethod = Get-ExactMethod ([Type]) 'GetMethod' @([string], [Reflection.BindingFlags])
    $createDelegate = Get-ExactMethod ([Delegate]) 'CreateDelegate' @([Type], [Reflection.MethodInfo]) ([Reflection.BindingFlags]'Public,Static')
    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
    $recoveryProgramRuntimeType = New-StaticCall $typeGetType @(
        (New-ClrConstant 'Dev.MansfieldPlumbing.Pwsh.RecoveryProgram, Pwsh' ([string])),
        (New-ClrConstant $true ([bool])))
    $eventHandlerRuntimeType = New-StaticCall $typeGetType @(
        (New-ClrConstant 'System.EventHandler' ([string])),
        (New-ClrConstant $true ([bool])))
    $handlerMethodInfo = New-ClrCall $recoveryProgramRuntimeType $typeGetMethod @(
        $handlerName,
        (New-ClrConstant ([Reflection.BindingFlags]'Public,Static') ([Reflection.BindingFlags])))
    $handlerBody = [Linq.Expressions.Expression]::Convert(
        (New-StaticCall $createDelegate @($eventHandlerRuntimeType, $handlerMethodInfo)),
        [EventHandler])
    $createHandlerMethod = Add-PersistedMethod $programType 'CreateHandler' $privateStatic ([EventHandler]) `
        @($activityType, [string]) ([Func``3].MakeGenericType($activityType, [string], [EventHandler])) `
        @($a, $handlerName) $handlerBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $parent = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'parent')
    $buttonText = [Linq.Expressions.Expression]::Parameter([string], 'text')
    $handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
    $buttonDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $button = [Linq.Expressions.Expression]::Parameter($buttonType, 'button')
    $contentDescriptionProperty = Get-ExactProperty $viewType 'ContentDescription'
    $focusableProperty = Get-ExactProperty $viewType 'Focusable'
    $focusableInTouchModeProperty = Get-ExactProperty $viewType 'FocusableInTouchMode'
    $configureButtonBody = New-ReturnBlock ([void]) @(
        (New-ClrAssign (New-ClrProperty $button $buttonTextProperty) $buttonText),
        (New-ClrAssign (New-ClrProperty $button $contentDescriptionProperty) $buttonDetails),
        (New-ClrAssign (New-ClrProperty $button $focusableProperty) (New-ClrConstant $true ([bool]))),
        (New-ClrCall $button $buttonAddClick @(
            (New-StaticCall $createHandlerMethod @($a, $handlerName)))),
        (New-ClrCall $parent $addViewWithParams @(
            $button,
            (New-StaticCall $buttonParamsMethod @(
                $a,
                (New-ClrNew $buttonLayoutParamsConstructor @(
                    ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
                    ([Linq.Expressions.Expression]::Field($null, $wrapContentField)))))))),
        [Linq.Expressions.Expression]::Empty())
    $configureButtonMethod = Add-PersistedMethod $programType 'ConfigureButton' $privateStatic ([void]) `
        @($activityType, $linearLayoutType, [string], [string], [string], $buttonType) `
        ([Action``6].MakeGenericType($activityType, $linearLayoutType, [string], [string], [string], $buttonType)) `
        @($a, $parent, $buttonText, $handlerName, $buttonDetails, $button) $configureButtonBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $parent = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'parent')
    $buttonText = [Linq.Expressions.Expression]::Parameter([string], 'text')
    $handlerName = [Linq.Expressions.Expression]::Parameter([string], 'handlerName')
    $buttonDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $addButtonBody = New-StaticCall $configureButtonMethod @(
        $a, $parent, $buttonText, $handlerName, $buttonDetails, (New-ClrNew $buttonConstructor @($a)))
    $addButtonMethod = Add-PersistedMethod $programType 'AddButton' $privateStatic ([void]) `
        @($activityType, $linearLayoutType, [string], [string], [string]) `
        ([Action``5].MakeGenericType($activityType, $linearLayoutType, [string], [string], [string])) `
        @($a, $parent, $buttonText, $handlerName, $buttonDetails) $addButtonBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $headingText = [Linq.Expressions.Expression]::Parameter([string], 'text')
    $heading = [Linq.Expressions.Expression]::Parameter($textViewType, 'heading')
    $headingBody = New-ReturnBlock $textViewType @(
        (New-ClrAssign (New-ClrProperty $heading $textViewTextProperty) $headingText),
        (New-ClrCall $heading $setTextColor @((New-ClrProperty $null $whiteProperty))),
        (New-ClrCall $heading $setTextSize @(
            (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
            (New-ClrConstant ([single]64) ([single])))),
        $heading)
    $headingMethod = Add-PersistedMethod $programType 'ConfigureHeading' $privateStatic $textViewType `
        @($activityType, [string], $textViewType) `
        ([Func``4].MakeGenericType($activityType, [string], $textViewType, $textViewType)) `
        @($a, $headingText, $heading) $headingBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $messageText = [Linq.Expressions.Expression]::Parameter([string], 'text')
    $message = [Linq.Expressions.Expression]::Parameter($textViewType, 'message')
    $messageBody = New-ReturnBlock $textViewType @(
        (New-ClrAssign (New-ClrProperty $message $textViewTextProperty) $messageText),
        (New-ClrCall $message $setTextIsSelectable @((New-ClrConstant $true ([bool])))),
        (New-ClrCall $message $setTextColor @((New-ClrProperty $null $whiteProperty))),
        (New-ClrCall $message $setTextSize @(
            (New-ClrConstant ([Enum]::Parse($complexUnitType, 'Sp')) $complexUnitType),
            (New-ClrConstant ([single]15) ([single])))),
        $message)
    $messageMethod = Add-PersistedMethod $programType 'ConfigureMessage' $privateStatic $textViewType `
        @($activityType, [string], $textViewType) `
        ([Func``4].MakeGenericType($activityType, [string], $textViewType, $textViewType)) `
        @($a, $messageText, $message) $messageBody

    $scroll = [Linq.Expressions.Expression]::Parameter($scrollViewType, 'scroll')
    $message = [Linq.Expressions.Expression]::Parameter($textViewType, 'message')
    $scrollBody = New-ReturnBlock $scrollViewType @(
        (New-ClrCall $scroll $scrollAddView @($message)),
        $scroll)
    $scrollMethod = Add-PersistedMethod $programType 'ConfigureScroll' $privateStatic $scrollViewType `
        @($scrollViewType, $textViewType) `
        ([Func``3].MakeGenericType($scrollViewType, $textViewType, $scrollViewType)) `
        @($scroll, $message) $scrollBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $messageParameters = [Linq.Expressions.Expression]::Parameter($layoutParamsType, 'parameters')
    $dp16 = New-StaticCall $dpMethod @($a, (New-ClrConstant 16 ([int])))
    $messageParamsBody = New-ReturnBlock $layoutParamsType @(
        (New-ClrAssign (New-ClrProperty $messageParameters $topMarginProperty) $dp16),
        (New-ClrAssign (New-ClrProperty $messageParameters $bottomMarginProperty) $dp16),
        $messageParameters)
    $messageParamsMethod = Add-PersistedMethod $programType 'ConfigureMessageParameters' $privateStatic $layoutParamsType `
        @($activityType, $layoutParamsType) `
        ([Func``3].MakeGenericType($activityType, $layoutParamsType, $layoutParamsType)) `
        @($a, $messageParameters) $messageParamsBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $layoutTitle = [Linq.Expressions.Expression]::Parameter([string], 'title')
    $layoutDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $layout = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'layout')
    $padding24 = New-StaticCall $dpMethod @($a, (New-ClrConstant 24 ([int])))
    $newHeading = New-StaticCall $headingMethod @($a, $layoutTitle, (New-ClrNew $textViewConstructor @($a)))
    $newMessage = New-StaticCall $messageMethod @($a, $layoutDetails, (New-ClrNew $textViewConstructor @($a)))
    $newScroll = New-StaticCall $scrollMethod @(
        (New-ClrNew $scrollViewConstructor @($a)), $newMessage)
    $messageParametersValue = New-StaticCall $messageParamsMethod @(
        $a,
        (New-ClrNew $layoutParamsConstructor @(
            ([Linq.Expressions.Expression]::Field($null, $matchParentField)),
            (New-ClrConstant 0 ([int])),
            (New-ClrConstant ([single]1) ([single])))))
    $copyCondition = New-If `
        ([Linq.Expressions.Expression]::Equal($layoutTitle, (New-ClrConstant ':(' ([string])))) `
        (New-StaticCall $addButtonMethod @(
            $a, $layout,
            (New-ClrConstant 'COPY TO CLIPBOARD' ([string])),
            (New-ClrConstant 'CopyClick' ([string])),
            $layoutDetails)) `
        ([Linq.Expressions.Expression]::Empty())
    $layoutBody = New-ReturnBlock $linearLayoutType @(
        (New-ClrAssign `
            (New-ClrProperty $layout $orientationProperty) `
            (New-ClrConstant ([Enum]::Parse($orientationType, 'Vertical')) $orientationType)),
        (New-ClrCall $layout $setBackgroundColor @(
            (New-StaticCall $rgb @(
                (New-ClrConstant 11 ([int])),
                (New-ClrConstant 61 ([int])),
                (New-ClrConstant 46 ([int])))))),
        (New-ClrCall $layout $setPadding @($padding24, $padding24, $padding24, $padding24)),
        (New-ClrCall $layout $addView @($newHeading)),
        (New-ClrCall $layout $addViewWithParams @($newScroll, $messageParametersValue)),
        $copyCondition,
        (New-StaticCall $addButtonMethod @(
            $a, $layout,
            (New-ClrConstant 'IMPORT FILE' ([string])),
            (New-ClrConstant 'ImportClick' ([string])),
            $layoutDetails)),
        (New-StaticCall $addButtonMethod @(
            $a, $layout,
            (New-ClrConstant 'RETRY' ([string])),
            (New-ClrConstant 'RetryClick' ([string])),
            $layoutDetails)),
        $layout)
    $buildLayoutMethod = Add-PersistedMethod $programType 'BuildRecoveryLayout' $privateStatic $linearLayoutType `
        @($activityType, [string], [string], $linearLayoutType) `
        ([Func``5].MakeGenericType($activityType, [string], [string], $linearLayoutType, $linearLayoutType)) `
        @($a, $layoutTitle, $layoutDetails, $layout) $layoutBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $showTitle = [Linq.Expressions.Expression]::Parameter([string], 'title')
    $showDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $shownLayout = [Linq.Expressions.Expression]::Parameter($linearLayoutType, 'layout')
    $getChildAt = Get-ExactMethod $linearLayoutType 'GetChildAt' @([int])
    $requestFocus = Get-ExactMethod $viewType 'RequestFocus' @()
    $showBody = New-ClrBlock @($shownLayout) @(
        (New-ClrAssign $shownLayout (New-StaticCall $buildLayoutMethod @(
            $a, $showTitle, $showDetails, (New-ClrNew $linearLayoutConstructor @($a))))),
        (New-ClrCall $a $setContentView @($shownLayout)),
        [Linq.Expressions.Expression]::Empty())
    $showRecoveryMethod = Add-PersistedMethod $programType 'ShowRecovery' $publicStatic ([void]) `
        @($activityType, [string], [string]) `
        ([Action``3].MakeGenericType($activityType, [string], [string])) `
        @($a, $showTitle, $showDetails) $showBody

    $State['a'] = $a
    $State['contentDescriptionProperty'] = $contentDescriptionProperty
    $State['showRecoveryMethod'] = $showRecoveryMethod
}

function Add-RecoverySupportMethods {
    # The distress beacon, the case-insensitive Profile.ps1 lookup, and toasts.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $a = $State['a']
    $absolutePathProperty = $State['absolutePathProperty']
    $activityType = $State['activityType']
    $contextType = $State['contextType']
    $filesDirProperty = $State['filesDirProperty']
    $pathCombine = $State['pathCombine']
    $privateStatic = $State['privateStatic']
    $programType = $State['programType']

    # The emitted recovery floor owns its own distress beacon. This remains usable
    # when SMA can load but the application runspace or Profile.ps1 cannot start.
    $androidLogType = Get-AndroidType 'Android.Util.Log'
    $androidLogError = Get-ExactMethod $androidLogType 'Error' @([string], [string]) `
        ([Reflection.BindingFlags]'Public,Static')
    $distressMessage = [Linq.Expressions.Expression]::Parameter([string], 'message')
    $writeDistressBody = New-ClrBlock @() @(
        (New-StaticCall $androidLogError @(
            (New-ClrConstant 'Pwsh' ([string])),
            $distressMessage)),
        [Linq.Expressions.Expression]::Empty())
    $writeDistressMethod = Add-PersistedMethod $programType 'WriteDistress' $privateStatic ([void]) `
        @([string]) ([Action``1].MakeGenericType([string])) @($distressMessage) $writeDistressBody

    # Profile.ps1 is found whatever its letter case. PowerShell does not care
    # about case and neither does this menu; only Android's filesystem does.
    $getFiles = Get-ExactMethod ([IO.Directory]) 'GetFiles' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $getFileName = Get-ExactMethod ([IO.Path]) 'GetFileName' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $ignoreCaseEquals = Get-ExactMethod ([string]) 'Equals' @([string], [string], [StringComparison]) ([Reflection.BindingFlags]'Public,Static')
    $candidateFiles = [Linq.Expressions.Expression]::Parameter([string[]], 'files')
    $candidateIndex = [Linq.Expressions.Expression]::Parameter([int], 'index')
    $candidateFallback = [Linq.Expressions.Expression]::Parameter([string], 'fallback')
    $findProfileMethod = $programType.DefineMethod(
        'FindProfile', $privateStatic, [string], [Type[]]@([string[]], [int], [string]))
    $candidate = [Linq.Expressions.Expression]::ArrayIndex($candidateFiles, $candidateIndex)
    $findProfileBody = [Linq.Expressions.Expression]::Condition(
        ([Linq.Expressions.Expression]::GreaterThanOrEqual(
            $candidateIndex, [Linq.Expressions.Expression]::ArrayLength($candidateFiles))),
        $candidateFallback,
        ([Linq.Expressions.Expression]::Condition(
            (New-StaticCall $ignoreCaseEquals @(
                (New-StaticCall $getFileName @($candidate)),
                (New-ClrConstant 'Profile.ps1' ([string])),
                (New-ClrConstant ([StringComparison]::OrdinalIgnoreCase) ([StringComparison])))),
            $candidate,
            (New-StaticCall $findProfileMethod @(
                $candidateFiles,
                ([Linq.Expressions.Expression]::Add($candidateIndex, (New-ClrConstant 1 ([int])))),
                $candidateFallback)))))
    $null = Write-MicrosoftLambdaToMethodBuilder `
        (New-ClrLambda ([Func``4].MakeGenericType([string[]], [int], [string], [string])) `
            $findProfileBody @($candidateFiles, $candidateIndex, $candidateFallback)) `
        $findProfileMethod

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $homeRoot = New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty
    $resolveProfileBody = New-StaticCall $findProfileMethod @(
        (New-StaticCall $getFiles @($homeRoot)),
        (New-ClrConstant 0 ([int])),
        (New-StaticCall $pathCombine @($homeRoot, (New-ClrConstant 'Profile.ps1' ([string])))))
    $resolveProfileMethod = Add-PersistedMethod $programType 'ResolveProfilePath' $privateStatic ([string]) `
        @($activityType) ([Func``2].MakeGenericType($activityType, [string])) @($a) $resolveProfileBody

    # Every action says what it did. A toast is enough to tell a retry that
    # changed nothing apart from a tap that did nothing.
    $toastType = Get-AndroidType 'Android.Widget.Toast'
    $toastLengthType = Get-AndroidType 'Android.Widget.ToastLength'
    $makeText = Get-ExactMethod $toastType 'MakeText' @($contextType, [string], $toastLengthType) ([Reflection.BindingFlags]'Public,Static')
    $toastShow = Get-ExactMethod $toastType 'Show' @()
    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $toastText = [Linq.Expressions.Expression]::Parameter([string], 'text')
    $showToastBody = New-ClrBlock @() @(
        (New-ClrCall (New-StaticCall $makeText @(
            $a, $toastText,
            (New-ClrConstant ([Enum]::Parse($toastLengthType, 'Short')) $toastLengthType))) $toastShow @()),
        [Linq.Expressions.Expression]::Empty())
    $showToastMethod = Add-PersistedMethod $programType 'ShowToast' $privateStatic ([void]) `
        @($activityType, [string]) ([Action``2].MakeGenericType($activityType, [string])) @($a, $toastText) $showToastBody

    $retryCountField = $programType.DefineField('s_retryCount', [int], [Reflection.FieldAttributes]'Private,Static')
    $nowProperty = Get-ExactProperty ([DateTime]) 'Now' ([Reflection.BindingFlags]'Public,Static')
    $dateToString = Get-ExactMethod ([DateTime]) 'ToString' @([string])
    $objectToString = Get-ExactMethod ([Convert]) 'ToString' @([object]) ([Reflection.BindingFlags]'Public,Static')
    $fileInfoCtor = Get-ExactConstructor ([IO.FileInfo]) @([string])
    $fileLengthProperty = Get-ExactProperty ([IO.FileInfo]) 'Length'

    $State['a'] = $a
    $State['dateToString'] = $dateToString
    $State['fileInfoCtor'] = $fileInfoCtor
    $State['fileLengthProperty'] = $fileLengthProperty
    $State['getFileName'] = $getFileName
    $State['nowProperty'] = $nowProperty
    $State['objectToString'] = $objectToString
    $State['resolveProfileMethod'] = $resolveProfileMethod
    $State['retryCountField'] = $retryCountField
    $State['showToastMethod'] = $showToastMethod
    $State['writeDistressMethod'] = $writeDistressMethod
}

function Add-ProfileRuntimeMethods {
    # The Profile.ps1 runtime: runspace creation, the animation callback, ExecuteProfile and StartProfile.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $a = $State['a']
    $absolutePathProperty = $State['absolutePathProperty']
    $activityType = $State['activityType']
    $animationCallbackField = $State['animationCallbackField']
    $filesDirProperty = $State['filesDirProperty']
    $getFileName = $State['getFileName']
    $privateStatic = $State['privateStatic']
    $programType = $State['programType']
    $publicStatic = $State['publicStatic']
    $resolveProfileMethod = $State['resolveProfileMethod']
    $runspaceField = $State['runspaceField']
    $runspaceType = $State['runspaceType']
    $showRecoveryMethod = $State['showRecoveryMethod']
    $writeDistressMethod = $State['writeDistressMethod']

    # Profile.ps1 runtime. The runspace remains alive after successful startup so
    # event handlers and application state created by the Start script remain usable.
    $defaultRunspaceProperty = Get-ExactProperty $runspaceType 'DefaultRunspace' ([Reflection.BindingFlags]'Public,Static')
    $runspaceDispose = Get-ExactMethod $runspaceType 'Dispose' @()
    $runspaceOpen = Get-ExactMethod $runspaceType 'Open' @()
    $runspaceSessionState = Get-ExactProperty $runspaceType 'SessionStateProxy'
    $sessionStateType = [Management.Automation.Runspaces.SessionStateProxy]
    $setVariable = Get-ExactMethod $sessionStateType 'SetVariable' @([string], [object])
    $initialStateType = [Management.Automation.Runspaces.InitialSessionState]
    $createInitialState = Get-ExactMethod $initialStateType 'CreateDefault2' @() ([Reflection.BindingFlags]'Public,Static')
    $languageModeProperty = Get-ExactProperty $initialStateType 'LanguageMode'
    $threadOptionsProperty = Get-ExactProperty $initialStateType 'ThreadOptions'
    $createRunspace = Get-ExactMethod ([Management.Automation.Runspaces.RunspaceFactory]) 'CreateRunspace' @($initialStateType) ([Reflection.BindingFlags]'Public,Static')
    $powerShellType = [Management.Automation.PowerShell]
    $createPowerShell = Get-ExactMethod $powerShellType 'Create' @() ([Reflection.BindingFlags]'Public,Static')
    $powerShellRunspace = Get-ExactProperty $powerShellType 'Runspace'
    $commandInfoType = [Management.Automation.CommandInfo]
    $commandTypesType = [Management.Automation.CommandTypes]
    $invokeCommandProperty = Get-ExactProperty $sessionStateType 'InvokeCommand'
    $getCommand = Get-ExactMethod ([Management.Automation.CommandInvocationIntrinsics]) 'GetCommand' `
        @([string], $commandTypesType)
    $powerShellAddCommand = Get-ExactMethod $powerShellType 'AddCommand' @($commandInfoType)
    $powerShellAddParameter = Get-ExactMethod $powerShellType 'AddParameter' @([string], [object])
    $powerShellInvoke = $powerShellType.GetMethods([Reflection.BindingFlags]'Public,Instance') |
        Where-Object { $_.Name -eq 'Invoke' -and -not $_.IsGenericMethod -and $_.GetParameters().Count -eq 0 } |
        Select-Object -First 1
    if (-not $powerShellInvoke) { throw 'PowerShell.Invoke() could not be resolved.' }
    $powerShellHadErrors = Get-ExactProperty $powerShellType 'HadErrors'
    $powerShellStreams = Get-ExactProperty $powerShellType 'Streams'
    $errorStreamProperty = Get-ExactProperty ([Management.Automation.PSDataStreams]) 'Error'
    $errorCollectionType = $errorStreamProperty.PropertyType
    $errorCountProperty = Get-ExactProperty $errorCollectionType 'Count'
    $errorItemProperty = $errorCollectionType.GetProperty('Item', [type[]]@([int]))
    $errorRecordToString = Get-ExactMethod ([Management.Automation.ErrorRecord]) 'ToString' @()
    $powerShellDispose = Get-ExactMethod $powerShellType 'Dispose' @()
    $invalidOperationCtor = Get-ExactConstructor ([InvalidOperationException]) @([string])
    $exceptionToString = Get-ExactMethod ([Exception]) 'ToString' @()
    $concat2 = Get-ExactMethod ([string]) 'Concat' @([string], [string]) ([Reflection.BindingFlags]'Public,Static')
    $concat3 = Get-ExactMethod ([string]) 'Concat' @([string], [string], [string]) ([Reflection.BindingFlags]'Public,Static')
    $fileExists = Get-ExactMethod ([IO.File]) 'Exists' @([string]) ([Reflection.BindingFlags]'Public,Static')

    $runspaceFieldExpression = [Linq.Expressions.Expression]::Field($null, $runspaceField)
    $nullRunspace = [Linq.Expressions.Expression]::Constant($null, $runspaceType)
    $resetBody = New-ClrBlock @() @(
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::NotEqual(
                $runspaceFieldExpression,
                $nullRunspace)),
            (New-ClrCall $runspaceFieldExpression $runspaceDispose @()))),
        (New-ClrAssign $runspaceFieldExpression $nullRunspace),
        (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $nullRunspace),
        [Linq.Expressions.Expression]::Empty())
    $resetRuntimeMethod = Add-PersistedMethod $programType 'ResetRuntime' $privateStatic ([void]) @() `
        ([Action]) @() $resetBody

    $callback = [Linq.Expressions.Expression]::Parameter([Action], 'callback')
    $animationCallbackFieldExpression = [Linq.Expressions.Expression]::Field($null, $animationCallbackField)
    $setAnimationCallbackMethod = Add-PersistedMethod $programType 'SetAnimationCallback' $publicStatic ([void]) `
        @([Action]) ([Action``1].MakeGenericType([Action])) @($callback) `
        (New-ClrAssign $animationCallbackFieldExpression $callback)

    $actionInvoke = Get-ExactMethod ([Action]) 'Invoke' @()
    $runAnimationBody = New-ClrBlock @() @(
        (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $runspaceFieldExpression),
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::NotEqual(
                $animationCallbackFieldExpression,
                ([Linq.Expressions.Expression]::Constant($null, [Action])))),
            (New-ClrCall $animationCallbackFieldExpression $actionInvoke @()))),
        [Linq.Expressions.Expression]::Empty())
    $runAnimationCallbackMethod = Add-PersistedMethod $programType 'RunAnimationCallback' $publicStatic ([void]) `
        @() ([Action]) @() $runAnimationBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $profilePath = [Linq.Expressions.Expression]::Parameter([string], 'profilePath')
    $initialState = [Linq.Expressions.Expression]::Parameter($initialStateType, 'initialState')
    $shell = [Linq.Expressions.Expression]::Parameter($powerShellType, 'shell')
    $startCommand = [Linq.Expressions.Expression]::Parameter($commandInfoType, 'startCommand')
    $createRunspaceBlock = New-ClrBlock @($initialState) @(
        (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_CREATEDEFAULT2_BEGIN' ([string])))),
        (New-ClrAssign $initialState (New-StaticCall $createInitialState @())),
        (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_CREATEDEFAULT2_END' ([string])))),
        (New-ClrAssign (New-ClrProperty $initialState $languageModeProperty) `
            (New-ClrConstant ([Management.Automation.PSLanguageMode]::FullLanguage) ([Management.Automation.PSLanguageMode]))),
        (New-ClrAssign (New-ClrProperty $initialState $threadOptionsProperty) `
            (New-ClrConstant ([Management.Automation.Runspaces.PSThreadOptions]::UseCurrentThread) ([Management.Automation.Runspaces.PSThreadOptions]))),
        (New-ClrAssign $runspaceFieldExpression (New-StaticCall $createRunspace @($initialState))),
        (New-ClrCall $runspaceFieldExpression $runspaceOpen @()),
        (New-StaticCall $writeDistressMethod @((New-ClrConstant 'HOST_RUNSPACE_OPEN' ([string])))))
    $profileErrors = New-ClrProperty (New-ClrProperty $shell $powerShellStreams) $errorStreamProperty
    $firstProfileError = [Linq.Expressions.Expression]::MakeIndex(
        $profileErrors, $errorItemProperty,
        [Linq.Expressions.Expression[]]@((New-ClrConstant 0 ([int]))))
    $profileErrorMessage = [Linq.Expressions.Expression]::Condition(
        ([Linq.Expressions.Expression]::GreaterThan(
            (New-ClrProperty $profileErrors $errorCountProperty),
            (New-ClrConstant 0 ([int])))),
        (New-ClrCall $firstProfileError $errorRecordToString @()),
        (New-ClrConstant 'Profile.ps1 reported one or more PowerShell errors.' ([string])))
    $hadErrorsException = New-ClrNew $invalidOperationCtor @($profileErrorMessage)
    $throwHadErrors = [Linq.Expressions.Expression]::Throw($hadErrorsException)
    $throwOnErrors = [Linq.Expressions.Expression]::IfThen(
        (New-ClrProperty $shell $powerShellHadErrors),
        $throwHadErrors)
    $resolveStartCommand = New-ClrCall `
        (New-ClrProperty (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $invokeCommandProperty) `
        $getCommand @(
            $profilePath,
            (New-ClrConstant ([Management.Automation.CommandTypes]::ExternalScript) $commandTypesType))
    $executeShellBody = New-ClrBlock @($startCommand) @(
        (New-ClrAssign (New-ClrProperty $shell $powerShellRunspace) $runspaceFieldExpression),
        (New-ClrCall (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $setVariable @(
            (New-ClrConstant 'Activity' ([string])), [Linq.Expressions.Expression]::Convert($a, [object]))),
        (New-ClrCall (New-ClrProperty $runspaceFieldExpression $runspaceSessionState) $setVariable @(
            (New-ClrConstant 'PSScriptRoot' ([string])),
            [Linq.Expressions.Expression]::Convert((New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty), [object]))),
        (New-ClrAssign $startCommand $resolveStartCommand),
        (New-ClrCall $shell $powerShellAddCommand @($startCommand)),
        (New-ClrCall $shell $powerShellAddParameter @(
            (New-ClrConstant 'Activity' ([string])),
            [Linq.Expressions.Expression]::Convert($a, [object]))),
        (New-StaticCall $writeDistressMethod @((New-ClrConstant 'START_INVOKE_BEGIN' ([string])))),
        (New-ClrCall $shell $powerShellInvoke @()),
        (New-StaticCall $writeDistressMethod @((New-ClrConstant 'START_INVOKE_END' ([string])))),
        $throwOnErrors,
        (New-StaticCall $runAnimationCallbackMethod @()),
        [Linq.Expressions.Expression]::Empty())
    $executeProfileBody = New-ClrBlock @($shell) @(
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::Equal(
                $runspaceFieldExpression,
                $nullRunspace)),
            $createRunspaceBlock)),
        (New-ClrAssign (New-ClrProperty $null $defaultRunspaceProperty) $runspaceFieldExpression),
        (New-ClrAssign $shell (New-StaticCall $createPowerShell @())),
        ([Linq.Expressions.Expression]::TryFinally(
            $executeShellBody,
            (New-ClrCall $shell $powerShellDispose @()))),
        [Linq.Expressions.Expression]::Empty())
    $executeProfileMethod = Add-PersistedMethod $programType 'ExecuteProfile' $privateStatic ([void]) `
        @($activityType, [string]) ([Action``2].MakeGenericType($activityType, [string])) `
        @($a, $profilePath) $executeProfileBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $profilePath = [Linq.Expressions.Expression]::Parameter([string], 'profilePath')
    $startupError = [Linq.Expressions.Expression]::Parameter([Exception], 'error')
    $profilePathValue = New-StaticCall $resolveProfileMethod @($a)
    $missingDetails = New-StaticCall $concat2 @(
        (New-ClrConstant "message: Profile.ps1 is missing.`nsource: " ([string])),
        (New-HomePath $profilePath $concat2 $getFileName))
    $failedStartup = New-ClrBlock @() @(
        (New-StaticCall $writeDistressMethod @(
            (New-StaticCall $concat2 @(
                (New-ClrConstant 'START_FAILURE ' ([string])),
                (New-ClrCall $startupError $exceptionToString @()))))),
        (New-StaticCall $resetRuntimeMethod @()),
        (New-StaticCall $showRecoveryMethod @(
            $a,
            (New-ClrConstant ':(' ([string])),
            (New-ClrCall $startupError $exceptionToString @()))))
    $executeOrRecover = [Linq.Expressions.Expression]::TryCatch(
        (New-StaticCall $executeProfileMethod @($a, $profilePath)),
        ([Linq.Expressions.Expression]::Catch($startupError, $failedStartup)))
    $missingRecovery = New-StaticCall $showRecoveryMethod @(
        $a,
        (New-ClrConstant ':(' ([string])),
        $missingDetails)
    $missingRecovery = New-ClrBlock @() @(
        (New-StaticCall $writeDistressMethod @(
            (New-StaticCall $concat2 @(
                (New-ClrConstant 'START_MISSING ' ([string])),
                $missingDetails)))),
        $missingRecovery,
        [Linq.Expressions.Expression]::Empty())
    $startupChoice = [Linq.Expressions.Expression]::IfThenElse(
        (New-StaticCall $fileExists @($profilePath)),
        $executeOrRecover,
        $missingRecovery)
    $startProfileBody = New-ClrBlock @($profilePath) @(
        (New-ClrAssign $profilePath $profilePathValue),
        $startupChoice,
        [Linq.Expressions.Expression]::Empty())
    $startProfileMethod = Add-PersistedMethod $programType 'StartProfile' $publicStatic ([void]) `
        @($activityType) ([Action``1].MakeGenericType($activityType)) @($a) $startProfileBody

    $State['a'] = $a
    $State['concat2'] = $concat2
    $State['concat3'] = $concat3
    $State['exceptionToString'] = $exceptionToString
    $State['fileExists'] = $fileExists
    $State['profilePathValue'] = $profilePathValue
    $State['resetRuntimeMethod'] = $resetRuntimeMethod
    $State['startProfileMethod'] = $startProfileMethod
}

function Add-ActivityAdmissionMethod {
    # AdmitActivity, the Android-to-PowerShell admission OnCreate delegates to.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $a = $State['a']
    $absolutePathProperty = $State['absolutePathProperty']
    $activityType = $State['activityType']
    $filesDirProperty = $State['filesDirProperty']
    $powerShellLoadContextInitializedField = $State['powerShellLoadContextInitializedField']
    $programType = $State['programType']
    $publicStatic = $State['publicStatic']
    $startProfileMethod = $State['startProfileMethod']

    # Irreducible Android-to-PowerShell admission. The Activity override performs
    # only the nonvirtual CLR base call, then enters this persisted expression body.
    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $setPowerShellAssemblyLoadContext =
        [Management.Automation.PowerShellAssemblyLoadContextInitializer].GetMethod(
            'SetPowerShellAssemblyLoadContext',
            [Reflection.BindingFlags]'Public,Static', $null, [type[]]@([string]), $null)
    $setAppContextData = Get-ExactMethod ([AppContext]) 'SetData' @([string], [object]) `
        ([Reflection.BindingFlags]'Public,Static')
    $applicationBase = New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty
    $powerShellLoadContextInitialized = [Linq.Expressions.Expression]::Field(
        $null, $powerShellLoadContextInitializedField)
    $initializePowerShellLoadContext = New-StaticCall $setPowerShellAssemblyLoadContext @(
        $applicationBase)
    # libpsl-native carries SMA's Unix P/Invoke surface. The host waits for a
    # Java-side load of libraries it has no cache entry for, so load it here
    # before the runspace opens. This goes away with the .NET for Android host.
    $loadLibrary = Get-ExactMethod (Get-AndroidType 'Java.Lang.JavaSystem') 'LoadLibrary' @([string]) `
        ([Reflection.BindingFlags]'Public,Static')
    $admitActivityBody = New-ClrBlock @() @(
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::IsFalse($powerShellLoadContextInitialized)),
            (New-ClrBlock @() @(
                (New-StaticCall $loadLibrary @((New-ClrConstant 'psl-native' ([string])))),
                (New-StaticCall $setAppContextData @(
                    (New-ClrConstant 'APP_CONTEXT_BASE_DIRECTORY' ([string])),
                    ([Linq.Expressions.Expression]::Convert($applicationBase, [object])))),
                $initializePowerShellLoadContext,
                (New-ClrAssign $powerShellLoadContextInitialized (New-ClrConstant $true ([bool]))),
                [Linq.Expressions.Expression]::Empty())))),
        (New-StaticCall $startProfileMethod @($a)),
        [Linq.Expressions.Expression]::Empty())
    $admitActivityMethod = Add-PersistedMethod $programType 'AdmitActivity' $publicStatic ([void]) `
        @($activityType) ([Action``1].MakeGenericType($activityType)) @($a) $admitActivityBody

    $State['a'] = $a
    $State['admitActivityMethod'] = $admitActivityMethod
}

function Add-DocumentImportMethods {
    # Document import from the file picker: display names, ImportDocument and HandleActivityResult.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $a = $State['a']
    $absolutePathProperty = $State['absolutePathProperty']
    $activityType = $State['activityType']
    $concat2 = $State['concat2']
    $concat3 = $State['concat3']
    $exceptionToString = $State['exceptionToString']
    $fileInfoCtor = $State['fileInfoCtor']
    $fileLengthProperty = $State['fileLengthProperty']
    $filesDirProperty = $State['filesDirProperty']
    $getFileName = $State['getFileName']
    $intentType = $State['intentType']
    $objectToString = $State['objectToString']
    $pathCombine = $State['pathCombine']
    $privateStatic = $State['privateStatic']
    $programType = $State['programType']
    $publicStatic = $State['publicStatic']
    $resetRuntimeMethod = $State['resetRuntimeMethod']
    $resolveProfileMethod = $State['resolveProfileMethod']
    $showRecoveryMethod = $State['showRecoveryMethod']
    $showToastMethod = $State['showToastMethod']
    $startProfileMethod = $State['startProfileMethod']

    # File-picker completion. Selected documents retain their display name in the
    # private app directory; Profile.ps1 is restarted immediately after import.
    $intentType = Get-AndroidType 'Android.Content.Intent'
    $uriType = Get-AndroidType 'Android.Net.Uri'
    $contentResolverType = Get-AndroidType 'Android.Content.ContentResolver'
    $cursorType = Get-AndroidType 'Android.Database.ICursor'
    $resultType = Get-AndroidType 'Android.App.Result'
    $contentResolverProperty = Get-ExactProperty $activityType 'ContentResolver'
    $intentDataProperty = Get-ExactProperty $intentType 'Data'
    $queryMethod = Get-ExactMethod $contentResolverType 'Query' @(
        $uriType, [string[]], [string], [string[]], [string])
    $openInputStream = Get-ExactMethod $contentResolverType 'OpenInputStream' @($uriType)
    $moveToFirst = Get-ExactMethod $cursorType 'MoveToFirst' @()
    $getColumnIndex = Get-ExactMethod $cursorType 'GetColumnIndex' @([string])
    $cursorGetString = Get-ExactMethod $cursorType 'GetString' @([int])
    $disposeMethod = Get-ExactMethod ([IDisposable]) 'Dispose' @()
    $displayNameField = (Get-AndroidType 'Android.Provider.IOpenableColumns').GetField(
        'DisplayName', [Reflection.BindingFlags]'Public,Static')
    $ioExceptionCtor = Get-ExactConstructor ([IO.IOException]) @([string])
    $isNullOrWhiteSpace = Get-ExactMethod ([string]) 'IsNullOrWhiteSpace' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $stringEqualsComparison = Get-ExactMethod ([string]) 'Equals' @([string], [string], [StringComparison]) ([Reflection.BindingFlags]'Public,Static')
    $stringContainsChar = Get-ExactMethod ([string]) 'Contains' @([char])
    $fileStreamCtor = Get-ExactConstructor ([IO.FileStream]) @([string], [IO.FileMode], [IO.FileAccess], [IO.FileShare])
    $streamCopyTo = Get-ExactMethod ([IO.Stream]) 'CopyTo' @([IO.Stream])
    $fileStreamFlushDisk = Get-ExactMethod ([IO.FileStream]) 'Flush' @([bool])
    $fileMoveOverwrite = Get-ExactMethod ([IO.File]) 'Move' @([string], [string], [bool]) ([Reflection.BindingFlags]'Public,Static')
    $fileDelete = Get-ExactMethod ([IO.File]) 'Delete' @([string]) ([Reflection.BindingFlags]'Public,Static')

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $uri = [Linq.Expressions.Expression]::Parameter($uriType, 'uri')
    $cursor = [Linq.Expressions.Expression]::Parameter($cursorType, 'cursor')
    $column = [Linq.Expressions.Expression]::Parameter([int], 'column')
    $displayName = [Linq.Expressions.Expression]::Parameter([string], 'displayName')
    $nullCursor = [Linq.Expressions.Expression]::Constant($null, $cursorType)
    $noDisplayName = New-ClrNew $ioExceptionCtor @(
        (New-ClrConstant 'The selected document has no display name.' ([string])))
    $queryCursor = New-ClrCall (New-ClrProperty $a $contentResolverProperty) $queryMethod @(
        $uri,
        ([Linq.Expressions.Expression]::NewArrayInit([string], @(
            (New-ClrConstant ([string]$displayNameField.GetValue($null)) ([string]))))),
        [Linq.Expressions.Expression]::Constant($null, [string]),
        [Linq.Expressions.Expression]::Constant($null, [string[]]),
        [Linq.Expressions.Expression]::Constant($null, [string]))
    $readDisplayName = New-ReturnBlock ([string]) @(
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::OrElse(
                ([Linq.Expressions.Expression]::Equal($cursor, $nullCursor)),
                ([Linq.Expressions.Expression]::Not((New-ClrCall $cursor $moveToFirst @()))))),
            ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
        (New-ClrAssign $column (New-ClrCall $cursor $getColumnIndex @(
            (New-ClrConstant ([string]$displayNameField.GetValue($null)) ([string]))))),
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::LessThan($column, (New-ClrConstant 0 ([int])))),
            ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
        (New-ClrAssign $displayName (New-ClrCall $cursor $cursorGetString @($column))),
        ([Linq.Expressions.Expression]::IfThen(
            (New-StaticCall $isNullOrWhiteSpace @($displayName)),
            ([Linq.Expressions.Expression]::Throw($noDisplayName)))),
        $displayName)
    $closeCursor = [Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::NotEqual($cursor, $nullCursor)),
        (New-ClrCall ([Linq.Expressions.Expression]::Convert($cursor, [IDisposable])) $disposeMethod @()))
    $getDisplayNameBody = New-ClrBlock @($cursor, $column, $displayName) @(
        (New-ClrAssign $cursor $queryCursor),
        ([Linq.Expressions.Expression]::TryFinally($readDisplayName, $closeCursor)))
    $getDisplayNameMethod = Add-PersistedMethod $programType 'GetDisplayName' $privateStatic ([string]) `
        @($activityType, $uriType) ([Func``3].MakeGenericType($activityType, $uriType, [string])) `
        @($a, $uri) $getDisplayNameBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $intent = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
    $uri = [Linq.Expressions.Expression]::Parameter($uriType, 'uri')
    $displayName = [Linq.Expressions.Expression]::Parameter([string], 'displayName')
    $destination = [Linq.Expressions.Expression]::Parameter([string], 'destination')
    $incoming = [Linq.Expressions.Expression]::Parameter([string], 'incoming')
    $source = [Linq.Expressions.Expression]::Parameter([IO.Stream], 'source')
    $target = [Linq.Expressions.Expression]::Parameter([IO.FileStream], 'target')
    $importError = [Linq.Expressions.Expression]::Parameter([Exception], 'error')
    $invalidDotName = [Linq.Expressions.Expression]::OrElse(
        ([Linq.Expressions.Expression]::Equal($displayName, (New-ClrConstant '.' ([string])))),
        ([Linq.Expressions.Expression]::Equal($displayName, (New-ClrConstant '..' ([string])))))
    $slashCharacter = New-ClrConstant ([char]47) ([char])
    $backslashCharacter = New-ClrConstant ([char]92) ([char])
    $hasSlash = New-ClrCall $displayName $stringContainsChar @($slashCharacter)
    $hasBackslash = New-ClrCall $displayName $stringContainsChar @($backslashCharacter)
    $invalidSeparator = [Linq.Expressions.Expression]::OrElse($hasSlash, $hasBackslash)
    $invalidName = [Linq.Expressions.Expression]::OrElse(
        (New-StaticCall $isNullOrWhiteSpace @($displayName)),
        ([Linq.Expressions.Expression]::OrElse($invalidDotName, $invalidSeparator)))
    $invalidNameThrow = [Linq.Expressions.Expression]::Throw(
        (New-ClrNew $ioExceptionCtor @(
            (New-ClrConstant 'The selected document name is invalid.' ([string])))))
    $isProfile = New-StaticCall $stringEqualsComparison @(
        $displayName,
        (New-ClrConstant 'Profile.ps1' ([string])),
        (New-ClrConstant ([StringComparison]::OrdinalIgnoreCase) ([StringComparison])))
    $copyFileBody = New-ClrBlock @() @(
        (New-ClrCall $source $streamCopyTo @($target)),
        (New-ClrCall $target $fileStreamFlushDisk @((New-ClrConstant $true ([bool])))),
        [Linq.Expressions.Expression]::Empty())
    $disposeTarget = New-ClrCall ([Linq.Expressions.Expression]::Convert($target, [IDisposable])) $disposeMethod @()
    $disposeSource = New-ClrCall ([Linq.Expressions.Expression]::Convert($source, [IDisposable])) $disposeMethod @()
    $restartAfterImport = New-ClrBlock @() @(
        (New-StaticCall $resetRuntimeMethod @()),
        (New-StaticCall $startProfileMethod @($a)))
    $importedTitle = New-StaticCall $concat2 @(
        (New-ClrConstant 'IMPORTED: ' ([string])), $displayName)
    $importedDetails = New-StaticCall $concat2 @(
        (New-ClrConstant 'source: ' ([string])), (New-HomePath $destination $concat2 $getFileName))
    $showImported = New-StaticCall $showRecoveryMethod @(
        $a, $importedTitle, $importedDetails)
    $afterImport = [Linq.Expressions.Expression]::IfThenElse(
        $isProfile, $restartAfterImport, $showImported)
    $importSuccess = New-ClrBlock @() @(
        (New-ClrAssign $uri (New-ClrProperty $intent $intentDataProperty)),
        (New-ClrAssign $displayName (New-StaticCall $getDisplayNameMethod @($a, $uri))),
        ([Linq.Expressions.Expression]::IfThen($invalidName, $invalidNameThrow)),
        ([Linq.Expressions.Expression]::IfThen(
            $isProfile,
            (New-ClrAssign $displayName (New-ClrConstant 'Profile.ps1' ([string]))))),
        (New-ClrAssign $destination ([Linq.Expressions.Expression]::Condition(
            $isProfile,
            (New-StaticCall $resolveProfileMethod @($a)),
            (New-StaticCall $pathCombine @(
                (New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty),
                $displayName))))),
        (New-ClrAssign $incoming (New-StaticCall $concat2 @(
            $destination, (New-ClrConstant '.incoming' ([string]))))),
        (New-ClrAssign $source (New-ClrCall (New-ClrProperty $a $contentResolverProperty) $openInputStream @($uri))),
        (New-ClrAssign $target (New-ClrNew $fileStreamCtor @(
            $incoming,
            (New-ClrConstant ([IO.FileMode]::Create) ([IO.FileMode])),
            (New-ClrConstant ([IO.FileAccess]::Write) ([IO.FileAccess])),
            (New-ClrConstant ([IO.FileShare]::None) ([IO.FileShare]))))),
        ([Linq.Expressions.Expression]::TryFinally(
            ([Linq.Expressions.Expression]::TryFinally($copyFileBody, $disposeTarget)),
            $disposeSource)),
        (New-StaticCall $fileMoveOverwrite @(
            $incoming, $destination, (New-ClrConstant $true ([bool])))),
        (New-StaticCall $showToastMethod @(
            $a,
            (New-StaticCall $concat3 @(
                (New-ClrConstant 'Imported ' ([string])),
                (New-HomePath $destination $concat2 $getFileName),
                (New-StaticCall $concat3 @(
                    (New-ClrConstant ' (' ([string])),
                    (New-StaticCall $objectToString @(
                        [Linq.Expressions.Expression]::Convert(
                            (New-ClrProperty (New-ClrNew $fileInfoCtor @($destination)) $fileLengthProperty),
                            [object]))),
                    (New-ClrConstant ' bytes)' ([string])))))))),
        $afterImport,
        [Linq.Expressions.Expression]::Empty())
    $importFailure = New-ClrBlock @() @(
        ([Linq.Expressions.Expression]::IfThen(
            ([Linq.Expressions.Expression]::NotEqual(
                $incoming, ([Linq.Expressions.Expression]::Constant($null, [string])))),
            (New-StaticCall $fileDelete @($incoming)))),
        (New-StaticCall $showRecoveryMethod @(
            $a,
            (New-ClrConstant ':(' ([string])),
            (New-ClrCall $importError $exceptionToString @()))))
    $importDocumentBody = New-ClrBlock @($uri, $displayName, $destination, $incoming, $source, $target) @(
        (New-ClrAssign $incoming ([Linq.Expressions.Expression]::Constant($null, [string]))),
        ([Linq.Expressions.Expression]::TryCatch(
            $importSuccess,
            ([Linq.Expressions.Expression]::Catch($importError, $importFailure)))),
        [Linq.Expressions.Expression]::Empty())
    $importDocumentMethod = Add-PersistedMethod $programType 'ImportDocument' $privateStatic ([void]) `
        @($activityType, $intentType) ([Action``2].MakeGenericType($activityType, $intentType)) `
        @($a, $intent) $importDocumentBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $requestCode = [Linq.Expressions.Expression]::Parameter([int], 'requestCode')
    $resultCode = [Linq.Expressions.Expression]::Parameter($resultType, 'resultCode')
    $intent = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
    $requestMatches = [Linq.Expressions.Expression]::Equal(
        $requestCode, (New-ClrConstant 1001 ([int])))
    $resultMatches = [Linq.Expressions.Expression]::Equal(
        $resultCode,
        (New-ClrConstant ([Enum]::Parse($resultType, 'Ok')) $resultType))
    $hasIntent = [Linq.Expressions.Expression]::NotEqual(
        $intent, ([Linq.Expressions.Expression]::Constant($null, $intentType)))
    $hasUri = [Linq.Expressions.Expression]::NotEqual(
        (New-ClrProperty $intent $intentDataProperty),
        ([Linq.Expressions.Expression]::Constant($null, $uriType)))
    $hasIntentAndUri = [Linq.Expressions.Expression]::AndAlso($hasIntent, $hasUri)
    $resultAndDataMatch = [Linq.Expressions.Expression]::AndAlso($resultMatches, $hasIntentAndUri)
    $validResult = [Linq.Expressions.Expression]::AndAlso($requestMatches, $resultAndDataMatch)
    $handleResultBody = New-ClrBlock @() @(
        ([Linq.Expressions.Expression]::IfThen(
            $validResult,
            (New-StaticCall $importDocumentMethod @($a, $intent)))),
        [Linq.Expressions.Expression]::Empty())
    $handleResultMethod = Add-PersistedMethod $programType 'HandleActivityResult' $publicStatic ([void]) `
        @($activityType, [int], $resultType, $intentType) `
        ([Action``4].MakeGenericType($activityType, [int], $resultType, $intentType)) `
        @($a, $requestCode, $resultCode, $intent) $handleResultBody

    $State['a'] = $a
    $State['handleResultMethod'] = $handleResultMethod
    $State['intentType'] = $intentType
    $State['resultType'] = $resultType
}

function Add-RecoveryActionMethods {
    # The recovery screen actions: the clipboard payload, CopyClick, ImportClick and RetryClick.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $a = $State['a']
    $absolutePathProperty = $State['absolutePathProperty']
    $actionOpenDocumentField = $State['actionOpenDocumentField']
    $activityType = $State['activityType']
    $addCategory = $State['addCategory']
    $androidReleaseProperty = $State['androidReleaseProperty']
    $androidSdkProperty = $State['androidSdkProperty']
    $assemblyFullNameProperty = $State['assemblyFullNameProperty']
    $buttonType = $State['buttonType']
    $categoryOpenableField = $State['categoryOpenableField']
    $clipboardManagerType = $State['clipboardManagerType']
    $concat2 = $State['concat2']
    $concat3 = $State['concat3']
    $contentDescriptionProperty = $State['contentDescriptionProperty']
    $contextType = $State['contextType']
    $dateToString = $State['dateToString']
    $emitted = $State['emitted']
    $fileExists = $State['fileExists']
    $filesDirProperty = $State['filesDirProperty']
    $frameworkDescriptionProperty = $State['frameworkDescriptionProperty']
    $getFileSystemEntries = $State['getFileSystemEntries']
    $getSystemService = $State['getSystemService']
    $handleResultMethod = $State['handleResultMethod']
    $intentConstructor = $State['intentConstructor']
    $intentType = $State['intentType']
    $manufacturerProperty = $State['manufacturerProperty']
    $modelProperty = $State['modelProperty']
    $newPlainText = $State['newPlainText']
    $nowProperty = $State['nowProperty']
    $objectToString = $State['objectToString']
    $packageNameProperty = $State['packageNameProperty']
    $primaryClipProperty = $State['primaryClipProperty']
    $privateStatic = $State['privateStatic']
    $profilePathValue = $State['profilePathValue']
    $programType = $State['programType']
    $publicStatic = $State['publicStatic']
    $readAllText = $State['readAllText']
    $resetRuntimeMethod = $State['resetRuntimeMethod']
    $resolveProfileMethod = $State['resolveProfileMethod']
    $resultType = $State['resultType']
    $retryCountField = $State['retryCountField']
    $setType = $State['setType']
    $showToastMethod = $State['showToastMethod']
    $startActivityForResult = $State['startActivityForResult']
    $startProfileMethod = $State['startProfileMethod']
    $viewType = $State['viewType']

    # Clipboard payload: recursive helpers avoid persisted local variables while
    # retaining a complete inventory of assemblies, files, runtime, and Profile.ps1.
    $builderType = [Text.StringBuilder]
    $appendLine = Get-ExactMethod $builderType 'AppendLine' @([string])
    $append = Get-ExactMethod $builderType 'Append' @([string])
    $builderToStringMethod = Get-ExactMethod $builderType 'ToString' @()
    $builderCtor = Get-ExactConstructor $builderType @()
    $assembliesType = [Reflection.Assembly[]]
    $getAssembliesMethod = Get-ExactMethod ([AppDomain]) 'GetAssemblies' @()
    $currentDomain = Get-ExactProperty ([AppDomain]) 'CurrentDomain' ([Reflection.BindingFlags]'Public,Static')
    $index = [Linq.Expressions.Expression]::Parameter([int], 'index')
    $builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
    $assemblies = [Linq.Expressions.Expression]::Parameter($assembliesType, 'assemblies')
    $appendAssembliesMethod = $programType.DefineMethod(
        'AppendAssemblies', $privateStatic, [void], [Type[]]@($builderType, $assembliesType, [int]))
    $assemblyAtIndex = [Linq.Expressions.Expression]::ArrayIndex($assemblies, $index)
    $nextAssemblyIndex = [Linq.Expressions.Expression]::Add($index, (New-ClrConstant 1 ([int])))
    $appendNextAssembly = New-StaticCall $appendAssembliesMethod @(
        $builder, $assemblies, $nextAssemblyIndex)
    $appendAssemblyStep = New-ClrBlock @() @(
        (New-ClrCall $builder $appendLine @((New-ClrProperty $assemblyAtIndex $assemblyFullNameProperty))),
        $appendNextAssembly)
    $appendAssembliesBody = [Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($assemblies))),
        $appendAssemblyStep)
    $appendAssembliesLambda = New-ClrLambda `
        ([Action``3].MakeGenericType($builderType, $assembliesType, [int])) `
        $appendAssembliesBody @($builder, $assemblies, $index)
    $null = Write-MicrosoftLambdaToMethodBuilder $appendAssembliesLambda $appendAssembliesMethod
    $emitted.Add([pscustomobject]@{ Name = 'AppendAssemblies'; Method = $appendAssembliesMethod; Success = $true })

    $files = [Linq.Expressions.Expression]::Parameter([string[]], 'files')
    $index = [Linq.Expressions.Expression]::Parameter([int], 'index')
    $builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
    $appendFilesMethod = $programType.DefineMethod(
        'AppendFiles', $privateStatic, [void], [Type[]]@($builderType, [string[]], [int]))
    $nextFileIndex = [Linq.Expressions.Expression]::Add($index, (New-ClrConstant 1 ([int])))
    $appendNextFile = New-StaticCall $appendFilesMethod @($builder, $files, $nextFileIndex)
    $appendFileStep = New-ClrBlock @() @(
        (New-ClrCall $builder $appendLine @([Linq.Expressions.Expression]::ArrayIndex($files, $index))),
        $appendNextFile)
    $appendFilesBody = [Linq.Expressions.Expression]::IfThen(
        ([Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($files))),
        $appendFileStep)
    $appendFilesLambda = New-ClrLambda ([Action``3].MakeGenericType($builderType, [string[]], [int])) `
        $appendFilesBody @($builder, $files, $index)
    $null = Write-MicrosoftLambdaToMethodBuilder $appendFilesLambda $appendFilesMethod
    $emitted.Add([pscustomobject]@{ Name = 'AppendFiles'; Method = $appendFilesMethod; Success = $true })

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $profilePathValue = New-StaticCall $resolveProfileMethod @($a)
    $fileExists = Get-ExactMethod ([IO.File]) 'Exists' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $readProfileBody = [Linq.Expressions.Expression]::Condition(
        (New-StaticCall $fileExists @($profilePathValue)),
        (New-StaticCall $readAllText @($profilePathValue)),
        (New-ClrConstant 'Profile.ps1: unavailable' ([string])))
    $readProfileMethod = Add-PersistedMethod $programType 'ReadProfileOrUnavailable' $privateStatic ([string]) `
        @($activityType) ([Func``2].MakeGenericType($activityType, [string])) @($a) $readProfileBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $payloadDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $builder = [Linq.Expressions.Expression]::Parameter($builderType, 'builder')
    $convertObjectToString = Get-ExactMethod ([Convert]) 'ToString' @([object]) ([Reflection.BindingFlags]'Public,Static')
    function New-AppendLiteral([string] $Text) {
        New-ClrCall $builder $appendLine @((New-ClrConstant $Text ([string])))
    }
    function New-AppendFact([string] $Label, [Linq.Expressions.Expression] $Value) {
        New-ClrBlock @() @(
            (New-ClrCall $builder $append @((New-ClrConstant $Label ([string])))),
            (New-ClrCall $builder $appendLine @($Value)))
    }
    $privateRootValue = New-ClrProperty (New-ClrProperty $a $filesDirProperty) $absolutePathProperty
    $payloadBody = New-ReturnBlock ([string]) @(
        (New-AppendLiteral 'PWSH RECOVERY REPORT'),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'REQUEST TO OUTSIDE MODEL'),
        (New-AppendLiteral 'Diagnose this startup failure and return a complete replacement Profile.ps1.'),
        (New-AppendLiteral 'Use only assemblies and files actually listed in this report.'),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'RUNTIME CONTRACT'),
        (New-AppendLiteral 'Profile.ps1 runs in-process in a PowerShell runspace.'),
        (New-AppendLiteral '$Activity is the live Android.App.Activity.'),
        (New-AppendLiteral '$PSScriptRoot is the private app-files directory.'),
        (New-AppendLiteral 'IMPORT FILE copies a selected document there; RETRY starts Profile.ps1 again.'),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'FAILURE DETAILS'),
        (New-ClrCall $builder $appendLine @($payloadDetails)),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'ENVIRONMENT'),
        (New-AppendFact 'privateRoot: ' $privateRootValue),
        (New-AppendFact 'package: ' (New-ClrProperty $a $packageNameProperty)),
        (New-AppendFact 'manufacturer: ' (New-ClrProperty $null $manufacturerProperty)),
        (New-AppendFact 'model: ' (New-ClrProperty $null $modelProperty)),
        (New-AppendFact 'android: ' (New-ClrProperty $null $androidReleaseProperty)),
        (New-AppendFact 'api: ' (New-StaticCall $convertObjectToString @(
            [Linq.Expressions.Expression]::Convert((New-ClrProperty $null $androidSdkProperty), [object])))),
        (New-AppendFact 'dotnet: ' (New-ClrProperty $null $frameworkDescriptionProperty)),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'LOADED ASSEMBLIES'),
        (New-StaticCall $appendAssembliesMethod @(
            $builder,
            (New-ClrCall (New-ClrProperty $null $currentDomain) $getAssembliesMethod @()),
            (New-ClrConstant 0 ([int])))),
        (New-AppendLiteral ''),
        (New-AppendLiteral 'PRIVATE FILES'),
        (New-StaticCall $appendFilesMethod @(
            $builder,
            (New-StaticCall $getFileSystemEntries @($privateRootValue)),
            (New-ClrConstant 0 ([int])))),
        (New-AppendLiteral ''),
        (New-AppendLiteral '--- Profile.ps1 BEGIN ---'),
        (New-ClrCall $builder $appendLine @((New-StaticCall $readProfileMethod @($a)))),
        (New-AppendLiteral '--- Profile.ps1 END ---'),
        (New-ClrCall $builder $builderToStringMethod @()))
    $buildPayloadCoreMethod = Add-PersistedMethod $programType 'BuildClipboardPayloadCore' $privateStatic ([string]) `
        @($activityType, [string], $builderType) `
        ([Func``4].MakeGenericType($activityType, [string], $builderType, [string])) `
        @($a, $payloadDetails, $builder) $payloadBody

    $a = [Linq.Expressions.Expression]::Parameter($activityType, 'activity')
    $payloadDetails = [Linq.Expressions.Expression]::Parameter([string], 'details')
    $buildPayloadBody = New-StaticCall $buildPayloadCoreMethod @(
        $a, $payloadDetails, (New-ClrNew $builderCtor @()))
    $buildPayloadMethod = Add-PersistedMethod $programType 'BuildClipboardPayload' $publicStatic ([string]) `
        @($activityType, [string]) ([Func``3].MakeGenericType($activityType, [string], [string])) `
        @($a, $payloadDetails) $buildPayloadBody

    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    $senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
    $senderActivity = [Linq.Expressions.Expression]::Convert(
        (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
    $clipboard = [Linq.Expressions.Expression]::Convert(
        (New-ClrCall $senderActivity $getSystemService @(
            (New-ClrConstant ([string]$contextType.GetField('ClipboardService').GetValue($null)) ([string])))),
        $clipboardManagerType)
    $copyBody = New-ClrAssign (New-ClrProperty $clipboard $primaryClipProperty) `
        (New-StaticCall $newPlainText @(
            (New-ClrConstant 'Pwsh recovery report' ([string])),
            (New-StaticCall $buildPayloadMethod @(
                $senderActivity, (New-ClrProperty $senderButton $contentDescriptionProperty)))))
    $null = Add-PersistedMethod $programType 'CopyClick' $publicStatic ([void]) @([object], [EventArgs]) `
        ([EventHandler]) @($sender, $eventArgs) $copyBody

    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    $senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
    $senderActivity = [Linq.Expressions.Expression]::Convert(
        (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
    $picker = New-ClrNew $intentConstructor @(
        (New-ClrConstant ([string]$actionOpenDocumentField.GetValue($null)) ([string])))
    $pickConfiguredMethod = $programType.DefineMethod(
        'ConfigurePicker', $privateStatic, $intentType, [Type[]]@($intentType))
    $pickerParameter = [Linq.Expressions.Expression]::Parameter($intentType, 'picker')
    $pickerBody = New-ReturnBlock $intentType @(
        (New-ClrCall $pickerParameter $addCategory @(
            (New-ClrConstant ([string]$categoryOpenableField.GetValue($null)) ([string])))),
        (New-ClrCall $pickerParameter $setType @((New-ClrConstant '*/*' ([string])))),
        $pickerParameter)
    $pickerLambda = New-ClrLambda ([Func``2].MakeGenericType($intentType, $intentType)) $pickerBody @($pickerParameter)
    $null = Write-MicrosoftLambdaToMethodBuilder $pickerLambda $pickConfiguredMethod
    $emitted.Add([pscustomobject]@{ Name = 'ConfigurePicker'; Method = $pickConfiguredMethod; Success = $true })
    $importBody = New-ClrCall $senderActivity $startActivityForResult @(
        (New-StaticCall $pickConfiguredMethod @($picker)), (New-ClrConstant 1001 ([int])))
    $null = Add-PersistedMethod $programType 'ImportClick' $publicStatic ([void]) @([object], [EventArgs]) `
        ([EventHandler]) @($sender, $eventArgs) $importBody

    $sender = [Linq.Expressions.Expression]::Parameter([object], 'sender')
    $eventArgs = [Linq.Expressions.Expression]::Parameter([EventArgs], 'args')
    $senderButton = [Linq.Expressions.Expression]::Convert($sender, $buttonType)
    $senderActivity = [Linq.Expressions.Expression]::Convert(
        (New-ClrProperty $senderButton (Get-ExactProperty $viewType 'Context')), $activityType)
    $retryCount = New-ClrField $null $retryCountField
    $retryBody = New-ClrBlock @() @(
        (New-ClrAssign $retryCount ([Linq.Expressions.Expression]::Add($retryCount, (New-ClrConstant 1 ([int]))))),
        (New-StaticCall $resetRuntimeMethod @()),
        (New-StaticCall $startProfileMethod @($senderActivity)),
        (New-StaticCall $showToastMethod @(
            $senderActivity,
            (New-StaticCall $concat3 @(
                (New-ClrConstant 'RETRY #' ([string])),
                (New-StaticCall $objectToString @([Linq.Expressions.Expression]::Convert($retryCount, [object]))),
                (New-StaticCall $concat2 @(
                    (New-ClrConstant ' at ' ([string])),
                    (New-ClrCall (New-ClrProperty $null $nowProperty) $dateToString @(
                        (New-ClrConstant 'HH:mm:ss' ([string])))))))))),
        [Linq.Expressions.Expression]::Empty())
    $null = Add-PersistedMethod $programType 'RetryClick' $publicStatic ([void]) @([object], [EventArgs]) `
        ([EventHandler]) @($sender, $eventArgs) $retryBody

    $resultType = Get-AndroidType 'Android.App.Result'
    $resultSelf = [Linq.Expressions.Expression]::Parameter($activityType, 'self')
    $resultRequest = [Linq.Expressions.Expression]::Parameter([int], 'requestCode')
    $resultCodeParameter = [Linq.Expressions.Expression]::Parameter($resultType, 'resultCode')
    $resultData = [Linq.Expressions.Expression]::Parameter($intentType, 'data')
    $onActivityResultBody = New-StaticCall $handleResultMethod @(
        $resultSelf, $resultRequest, $resultCodeParameter, $resultData)
    $onActivityResultDelegate = [Action``4].MakeGenericType(
        $activityType, [int], $resultType, $intentType)
    $onActivityResultLambda = New-ClrLambda $onActivityResultDelegate $onActivityResultBody @(
        $resultSelf, $resultRequest, $resultCodeParameter, $resultData)

    $State['onActivityResultLambda'] = $onActivityResultLambda
    $State['resultType'] = $resultType
}

function Complete-AndroidHostTypes {
    # The OnActivityResult override on the activity, then the finished RecoveryProgram type.
    # Part of New-AndroidHostTypes; the statements keep their emission order.
    param([Parameter(Mandatory)][hashtable] $State)

    $activityType = $State['activityType']
    $admitActivityMethod = $State['admitActivityMethod']
    $emitted = $State['emitted']
    $intentType = $State['intentType']
    $mainType = $State['mainType']
    $onActivityResultLambda = $State['onActivityResultLambda']
    $programType = $State['programType']
    $resultType = $State['resultType']

    $onActivityResultMethod = $mainType.DefineMethod(
        'OnActivityResult',
        [Reflection.MethodAttributes]'Family,Virtual,HideBySig',
        [void],
        [type[]]@([int], $resultType, $intentType))
    $null = Write-MicrosoftLambdaToMethodBuilder `
        -Lambda $onActivityResultLambda `
        -MethodBuilder $onActivityResultMethod `
        -ExplicitThis
    $baseOnActivityResult = $activityType.GetMethod(
        'OnActivityResult', [Reflection.BindingFlags]'Instance,NonPublic', $null,
        [type[]]@([int], $resultType, $intentType), $null)
    $mainType.DefineMethodOverride($onActivityResultMethod, $baseOnActivityResult)
    $emitted.Add([pscustomobject]@{
        Name = 'OnActivityResult'
        Method = $onActivityResultMethod
        Success = $true
    })
    $programType.CreateType() | Out-Null

    [pscustomobject]@{
        ProgramType  = $programType
        AdmitMethod  = $admitActivityMethod
        ActivityType = $activityType
        MethodCount  = $script:PersistedMethods.Count + $emitted.Count
    }
}

function New-AndroidHostTypes {
    <#
        Builds the Android host as compiled methods on RecoveryProgram: the
        Profile.ps1 runtime, AdmitActivity, the recovery screen it falls back to
        (COPY TO CLIPBOARD, IMPORT FILE, RETRY), the document importer, and the
        OnActivityResult override. Every body is an expression tree compiled by
        the framework's LambdaCompiler. OnCreate is the one method this does not
        build: it needs a non-virtual base call, which has no expression-tree
        form, so the caller emits it as a six-opcode shim that delegates to
        AdmitActivity. The phases below run in emission order.

        Ported from the predecessor appliance's emitter.
    #>
    param(
        [Parameter(Mandatory)][Reflection.Emit.ModuleBuilder] $Module,
        [Parameter(Mandatory)][Reflection.Emit.TypeBuilder] $Main,
        [Parameter(Mandatory)][Reflection.Assembly] $Android
    )

    $state = @{ Module = $Module; Main = $Main; Android = $Android }
    # Each phase takes the state it needs from $state and puts back what later
    # phases read. A phase writes nothing to the pipeline.
    foreach ($phase in 'Add-AndroidHostDeclarations',
            'Add-RecoveryScreenMethods',
            'Add-RecoverySupportMethods',
            'Add-ProfileRuntimeMethods',
            'Add-ActivityAdmissionMethod',
            'Add-DocumentImportMethods',
            'Add-RecoveryActionMethods') {
        $output = @(& $phase -State $state)
        if ($output.Count -ne 0) { throw "Host phase $phase wrote $($output.Count) objects to the pipeline." }
    }
    Complete-AndroidHostTypes -State $state
}

function New-PwshActivityAssemblyBytes {
    param([Parameter(Mandatory)][System.Collections.Generic.List[object]] $Candidates)

    $loadNames = 'Java.Interop.dll', 'Mono.Android.Runtime.dll', 'Mono.Android.dll', 'System.Management.Automation.dll'
    $imageMap = @{}
    foreach ($name in $loadNames) {
        $candidate = $Candidates |
            Where-Object { -not $_.ReferenceOnly -and $_.Name -ceq $name } |
            Sort-Object @{ Expression = { Get-PayloadCandidateRank -Candidate $_ } } |
            Select-Object -First 1
        if ($null -eq $candidate) { throw "Cannot emit Pwsh.dll without '$name'." }
        $imageMap[[IO.Path]::GetFileNameWithoutExtension($name)] = $candidate.Bytes
    }

    $context = [Runtime.Loader.AssemblyLoadContext]::new('Pwsh.Target.Android', $true)
    $resolver = [Func[Runtime.Loader.AssemblyLoadContext, Reflection.AssemblyName, Reflection.Assembly]] {
        param($loadContext, $requestedName)
        if (-not $imageMap.ContainsKey($requestedName.Name)) { return $null }
        $dependencyStream = [IO.MemoryStream]::new([byte[]]$imageMap[$requestedName.Name], $false)
        try { return $loadContext.LoadFromStream($dependencyStream) }
        finally { $dependencyStream.Dispose() }
    }
    $context.add_Resolving($resolver)

    try {
        $monoStream = [IO.MemoryStream]::new([byte[]]$imageMap['Mono.Android'], $false)
        try { $android = $context.LoadFromStream($monoStream) }
        finally { $monoStream.Dispose() }

        $activityAttributeType = $android.GetType('Android.App.ActivityAttribute', $true)

        $identity = [Reflection.AssemblyName]::new('Pwsh')
        $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
        $module = $builder.DefineDynamicModule('Pwsh.dll')

        $activityType = $android.GetType('Android.App.Activity', $true)
        $main = $module.DefineType(
            'Dev.MansfieldPlumbing.Pwsh.MainActivity',
            [Reflection.TypeAttributes]'Public,Class,Sealed,BeforeFieldInit',
            $activityType)

        # The recovery menu, as compiled methods. This also gives the activity
        # its OnActivityResult override, which needs no hand-written IL.
        $screen = New-AndroidHostTypes -Module $module -Main $main -Android $android
        $main.DefineDefaultConstructor(
            [Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName') | Out-Null

        $attributeConstructor = Get-ExactConstructor $activityAttributeType @()
        $attributeProperties = [Reflection.PropertyInfo[]]@(
            (Get-ExactProperty $activityAttributeType 'Name'),
            (Get-ExactProperty $activityAttributeType 'Label'),
            (Get-ExactProperty $activityAttributeType 'MainLauncher'),
            (Get-ExactProperty $activityAttributeType 'Exported'))
        $attributeValues = [object[]]@(
            'dev.mansfieldplumbing.pwsh.MainActivity',
            'Pwsh',
            $true,
            $true)
        $main.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new(
            $attributeConstructor,
            [object[]]@(),
            $attributeProperties,
            $attributeValues))

        $bundleType = $android.GetType('Android.OS.Bundle', $true)
        $baseOnCreate = $activityType.GetMethod(
            'OnCreate',
            [Reflection.BindingFlags]'Instance,NonPublic',
            $null,
            [Type[]]@($bundleType),
            $null)
        if ($null -eq $baseOnCreate -or $baseOnCreate.DeclaringType -ne $activityType) {
            throw 'Android.App.Activity.OnCreate(Bundle) could not be identified unambiguously.'
        }

        $onCreate = $main.DefineMethod(
            'OnCreate',
            [Reflection.MethodAttributes]'Family,Virtual,HideBySig',
            [void],
            [Type[]]@($bundleType))

        # The only hand-written IL in the build, and it carries no behaviour.
        # base.OnCreate is a non-virtual call to a virtual method, which has no
        # expression-tree form: Expression.Call on a virtual method emits
        # callvirt, which would dispatch straight back into this override. So
        # the shim performs the base call and delegates. Everything the screen
        # actually does lives in AdmitActivity, which was compiled from a tree.
        #
        #   base.OnCreate (bundle);
        #   RecoveryProgram.AdmitActivity (this);
        $il = $onCreate.GetILGenerator()
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
        $il.Emit([Reflection.Emit.OpCodes]::Call, $baseOnCreate)
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([Reflection.Emit.OpCodes]::Call, $screen.AdmitMethod)
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        $main.DefineMethodOverride($onCreate, $baseOnCreate)
        $main.CreateType() | Out-Null

        Write-Host ('[PASS] Screen: {0} methods compiled from expression trees; 6 hand-written opcodes in the OnCreate shim.' -f
            $screen.MethodCount) -ForegroundColor Green

        $stream = [IO.MemoryStream]::new()
        try {
            $builder.Save($stream)
            return ,(Set-DeterministicMvid -Assembly $stream.ToArray())
        }
        finally { $stream.Dispose() }
    }
    finally {
        $context.remove_Resolving($resolver)
        $context.Unload()
    }
}

function Add-GeneratedAssemblyCandidates {
    $generated = [ordered]@{
        '_Microsoft.Android.Resource.Designer.dll' = New-EmptyManagedAssemblyBytes `
            -AssemblyName '_Microsoft.Android.Resource.Designer' `
            -TypeName '_Microsoft.Android.Resource.Designer.Resource'
        'Probe.dll' = New-EmptyManagedAssemblyBytes -AssemblyName 'Probe' -TypeName 'Pwsh.Probe'
        'Pwsh.dll' = New-PwshActivityAssemblyBytes -Candidates $script:BuildContext.PayloadCandidates
    }
    foreach ($item in $generated.GetEnumerator()) {
        $script:BuildContext.PayloadCandidates.Add([pscustomobject]@{
            Name = $item.Key
            PackageId = 'setup.ps1'
            PackagePath = "generated/$($item.Key)"
            ReferenceOnly = $false
            IsReadyToRun = $false
            Bytes = [byte[]]$item.Value
        })
        $hashStream = [IO.MemoryStream]::new([byte[]]$item.Value, $false)
        try { $hash = Get-Sha256Hex -Stream $hashStream }
        finally { $hashStream.Dispose() }
        Write-Host ('[PASS] Generated: {0} | {1} bytes | SHA-256 {2}' -f $item.Key, $item.Value.Length, $hash) -ForegroundColor Green
    }
}

function Invoke-SelectionStep {
    if (Skip-ForNativeAdmission -Step 4 -Output 'the assembly set') { return }
    if ($Payload -ne 'Minimal') {
        throw "Payload '$Payload' is not built yet. Only Minimal is."
    }
    $manifest = Get-LeanAssemblyManifest
    Add-GeneratedAssemblyCandidates

    $selected = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $manifest) {
        $matches = @(
            $script:BuildContext.PayloadCandidates |
                Where-Object { -not $_.ReferenceOnly -and $_.Name -ceq $name } |
                Sort-Object @{ Expression = { Get-PayloadCandidateRank -Candidate $_ } }, PackageId, PackagePath
        )
        if ($matches.Count -eq 0) {
            $missing.Add($name)
            continue
        }

        $bestRank = Get-PayloadCandidateRank -Candidate $matches[0]
        $best = @($matches | Where-Object { (Get-PayloadCandidateRank -Candidate $_) -eq $bestRank })
        if ($best.Count -ne 1) {
            throw "Assembly '$name' has $($best.Count) equally ranked runtime sources."
        }
        $selected[$name] = $best[0]
    }

    if ($missing.Count -ne 0) {
        throw ('The pinned root packages do not supply {0} required runtime assemblies: {1}' -f
            $missing.Count,
            ($missing -join ', '))
    }
    if ($selected.Count -ne $manifest.Count) {
        throw "Lean assembly selection produced $($selected.Count) entries; the pinned list names $($manifest.Count)."
    }

    $script:BuildContext.SelectedAssemblies = $selected
    Write-Host "[PASS] Step 4 complete: $($selected.Count) ordered runtime assemblies selected in memory; reference-only images and Probe.r2r.dll rejected." -ForegroundColor Green
}

$script:Crc32Table = $null

function Get-Crc32Table {
    if ($null -ne $script:Crc32Table) { return $script:Crc32Table }

    $table = New-Object uint32[] 256
    for ($i = 0; $i -lt 256; $i++) {
        [uint64] $value = $i
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($value -band 1) -ne 0) {
                $value = (0xEDB88320L -bxor ($value -shr 1)) -band 0xFFFFFFFFL
            }
            else {
                $value = ($value -shr 1) -band 0xFFFFFFFFL
            }
        }
        $table[$i] = [uint32]$value
    }
    $script:Crc32Table = $table
    return $script:Crc32Table
}

function Get-Crc32 {
    param([Parameter(Mandatory)][byte[]] $Data)

    $table = Get-Crc32Table
    [uint64] $value = 0xFFFFFFFFL
    foreach ($byte in $Data) {
        $value = ([uint64]$table[[int](($value -bxor $byte) -band 0xFF)] -bxor ($value -shr 8)) -band 0xFFFFFFFFL
    }
    return [uint32](($value -bxor 0xFFFFFFFFL) -band 0xFFFFFFFFL)
}

function Get-ContractStructureSize {
    param(
        [Parameter(Mandatory)][pscustomobject] $Contract,
        [Parameter(Mandatory)][string] $StructureName
    )

    $widths = @{
        'uint8_t'                  = 1
        'uint32_t'                 = 4
        'uint64_t'                 = 8
        'xamarin::android::hash_t' = 4
    }

    $structure = $Contract.xaba.structures.PSObject.Properties[$StructureName]
    if ($null -eq $structure) {
        throw "The native producer contract does not declare structure '$StructureName'."
    }

    $size = 0
    foreach ($field in @($structure.Value)) {
        $type = [string]$field.type
        if (-not $widths.ContainsKey($type)) {
            throw "Structure '$StructureName' declares unsupported field type '$type'."
        }
        $size += $widths[$type]
    }
    return $size
}

function New-AssemblyStoreBytes {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $SelectedAssemblies,
        [Parameter(Mandatory)][pscustomobject] $Contract
    )

    $headerSize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreHeader'
    $indexEntrySize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreIndexEntry'
    $descriptorSize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreEntryDescriptor'

    $magic = [uint32]$Contract.xaba.magic
    $version = [uint32]([uint32]$Contract.xaba.formatVersion -bor
        (Get-Store64BitFlag -Contract $Contract) -bor
        (Get-StoreAbiFlag))

    $entryCount = [uint32]$SelectedAssemblies.Count
    $names = [System.Collections.Generic.List[byte[]]]::new()
    $namesSize = 0
    foreach ($name in $SelectedAssemblies.Keys) {
        $nameBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$name)
        $names.Add($nameBytes)
        $namesSize += 4 + $nameBytes.Length
    }

    $indexEntryCount = $entryCount * 2
    $indexSize = $indexEntryCount * $indexEntrySize
    $dataStart = $headerSize + $indexSize + ($entryCount * $descriptorSize) + $namesSize

    # Descriptors, in the same order as the lean assembly manifest. The index is
    # built alongside them and sorted by name hash afterwards, exactly as the
    # runtime's binary search over the index requires.
    $descriptors = [System.Collections.Generic.List[object]]::new()
    $indexEntries = [System.Collections.Generic.List[object]]::new()
    $payloads = [System.Collections.Generic.List[byte[]]]::new()
    $cursor = [uint32]$dataStart
    $descriptorIndex = [uint32]0

    foreach ($name in $SelectedAssemblies.Keys) {
        $candidate = $SelectedAssemblies[$name]
        $bytes = [byte[]]$candidate.Bytes
        $payloads.Add($bytes)

        $descriptors.Add([pscustomobject]@{
            MappingIndex     = $descriptorIndex
            DataOffset       = $cursor
            DataSize         = [uint32]$bytes.Length
            DebugDataOffset  = [uint32]0
            DebugDataSize    = [uint32]0
            ConfigDataOffset = [uint32]0
            ConfigDataSize   = [uint32]0
        })

        $withExtension = [string]$name
        $withoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($withExtension)
        foreach ($lookupName in @($withExtension, $withoutExtension)) {
            $indexEntries.Add([pscustomobject]@{
                NameHash        = Get-Crc32 -Data ([System.Text.Encoding]::UTF8.GetBytes($lookupName))
                DescriptorIndex = $descriptorIndex
                Ignore          = [byte]0
                LookupName      = $lookupName
            })
        }

        $cursor = [uint32]($cursor + $bytes.Length)
        $descriptorIndex++
    }

    $sortedIndex = @($indexEntries | Sort-Object -Property NameHash, DescriptorIndex)

    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream, [System.Text.Encoding]::UTF8, $true)
    try {
        # HEADER. content_id is the upstream deterministic payload hash; the
        # runtime never reads it, and it is written as zero until the optional
        # hashing phase exists.
        $writer.Write([uint32]$magic)
        $writer.Write([uint32]$version)
        $writer.Write([uint32]$entryCount)
        $writer.Write([uint32]$indexEntryCount)
        $writer.Write([uint32]$indexSize)
        $writer.Write([uint64]0)

        # INDEX
        foreach ($entry in $sortedIndex) {
            $writer.Write([uint32]$entry.NameHash)
            $writer.Write([uint32]$entry.DescriptorIndex)
            $writer.Write([byte]$entry.Ignore)
        }

        # ASSEMBLY_DESCRIPTORS
        foreach ($descriptor in $descriptors) {
            $writer.Write([uint32]$descriptor.MappingIndex)
            $writer.Write([uint32]$descriptor.DataOffset)
            $writer.Write([uint32]$descriptor.DataSize)
            $writer.Write([uint32]$descriptor.DebugDataOffset)
            $writer.Write([uint32]$descriptor.DebugDataSize)
            $writer.Write([uint32]$descriptor.ConfigDataOffset)
            $writer.Write([uint32]$descriptor.ConfigDataSize)
        }

        # ASSEMBLY_NAMES
        foreach ($nameBytes in $names) {
            $writer.Write([uint32]$nameBytes.Length)
            Write-ByteSpan -Writer $writer -Bytes $nameBytes
        }

        $writer.Flush()
        if ($stream.Position -ne $dataStart) {
            throw "Assembly store metadata ended at $($stream.Position); the descriptors declare data starting at $dataStart."
        }

        # ASSEMBLY DATA
        foreach ($payload in $payloads) {
            Write-ByteSpan -Writer $writer -Bytes $payload
        }
        $writer.Flush()
        return $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Test-AssemblyStoreBytes {
    param(
        [Parameter(Mandatory)][byte[]] $StoreBytes,
        [Parameter(Mandatory)][System.Collections.IDictionary] $SelectedAssemblies,
        [Parameter(Mandatory)][pscustomobject] $Contract
    )

    $headerSize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreHeader'
    $indexEntrySize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreIndexEntry'
    $descriptorSize = Get-ContractStructureSize -Contract $Contract -StructureName 'AssemblyStoreEntryDescriptor'

    $magic = [BitConverter]::ToUInt32($StoreBytes, 0)
    if ($magic -ne [uint32]$Contract.xaba.magic) {
        throw ('The emitted store carries magic 0x{0:X8}.' -f $magic)
    }
    $expectedVersion = [uint32]([uint32]$Contract.xaba.formatVersion -bor
        (Get-Store64BitFlag -Contract $Contract) -bor
        (Get-StoreAbiFlag))
    $version = [BitConverter]::ToUInt32($StoreBytes, 4)
    if ($version -ne $expectedVersion) {
        throw ('The emitted store declares format version 0x{0:X8}; the runtime requires 0x{1:X8}.' -f $version, $expectedVersion)
    }

    $entryCount = [int][BitConverter]::ToUInt32($StoreBytes, 8)
    $indexEntryCount = [int][BitConverter]::ToUInt32($StoreBytes, 12)
    $indexSize = [int][BitConverter]::ToUInt32($StoreBytes, 16)
    if ($entryCount -ne $SelectedAssemblies.Count) {
        throw "The emitted store declares $entryCount entries; $($SelectedAssemblies.Count) were selected."
    }
    if ($indexEntryCount -ne $entryCount * 2) {
        throw "The emitted store declares $indexEntryCount index entries; $($entryCount * 2) are required."
    }
    if ($indexSize -ne $indexEntryCount * $indexEntrySize) {
        throw "The emitted store declares an index of $indexSize bytes; $($indexEntryCount * $indexEntrySize) are required."
    }

    $descriptorStart = $headerSize + $indexSize
    $namesStart = $descriptorStart + ($entryCount * $descriptorSize)

    # Names, read exactly the way the runtime reads them.
    $cursor = $namesStart
    $names = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $entryCount; $i++) {
        $length = [int][BitConverter]::ToUInt32($StoreBytes, $cursor)
        $cursor += 4
        $names.Add([System.Text.Encoding]::UTF8.GetString($StoreBytes, $cursor, $length))
        $cursor += $length
    }
    $expectedNames = @($SelectedAssemblies.Keys)
    for ($i = 0; $i -lt $entryCount; $i++) {
        if ($names[$i] -cne [string]$expectedNames[$i]) {
            throw "Store name $i is '$($names[$i])'; the manifest declares '$($expectedNames[$i])'."
        }
    }

    # The index must be sorted, because the runtime binary-searches it.
    $previousHash = [uint32]0
    $seen = @{}
    for ($i = 0; $i -lt $indexEntryCount; $i++) {
        $offset = $headerSize + ($i * $indexEntrySize)
        $hash = [BitConverter]::ToUInt32($StoreBytes, $offset)
        $descriptorIndex = [int][BitConverter]::ToUInt32($StoreBytes, $offset + 4)
        if ($i -gt 0 -and $hash -lt $previousHash) {
            throw "The emitted index is not sorted by name hash at entry $i."
        }
        if ($descriptorIndex -lt 0 -or $descriptorIndex -ge $entryCount) {
            throw "Index entry $i points at descriptor $descriptorIndex, which is out of range."
        }
        $previousHash = $hash
        $seen[$hash] = $descriptorIndex
    }

    # Every assembly must resolve by both of the names the runtime may ask for,
    # and its payload must be byte-identical to the selected image.
    foreach ($name in $SelectedAssemblies.Keys) {
        $expectedBytes = [byte[]]$SelectedAssemblies[$name].Bytes
        foreach ($lookupName in @([string]$name, [System.IO.Path]::GetFileNameWithoutExtension([string]$name))) {
            $hash = Get-Crc32 -Data ([System.Text.Encoding]::UTF8.GetBytes($lookupName))
            if (-not $seen.ContainsKey($hash)) {
                throw "Assembly '$lookupName' does not resolve in the emitted index."
            }
            $descriptorIndex = $seen[$hash]
            if ($names[$descriptorIndex] -cne [string]$name) {
                throw "Assembly '$lookupName' resolves to '$($names[$descriptorIndex])'."
            }

            $descriptorOffset = $descriptorStart + ($descriptorIndex * $descriptorSize)
            $dataOffset = [int][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 4)
            $dataSize = [int][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 8)
            if ($dataSize -ne $expectedBytes.Length) {
                throw "Assembly '$name' is stored as $dataSize bytes; the selected image is $($expectedBytes.Length) bytes."
            }
            if ($dataOffset + $dataSize -gt $StoreBytes.Length) {
                throw "Assembly '$name' data runs past the end of the store."
            }
        }
    }

    # Byte-for-byte payload comparison. Comparing 116 MB one element at a time
    # from PowerShell costs minutes per build, so both sides are fed through an
    # incremental hash instead: the same guarantee, at native speed.
    $expectedDigest = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $storedDigest = [System.Security.Cryptography.IncrementalHash]::CreateHash(
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $index = 0
        foreach ($name in $SelectedAssemblies.Keys) {
            $expectedBytes = [byte[]]$SelectedAssemblies[$name].Bytes
            $descriptorOffset = $descriptorStart + ($index * $descriptorSize)
            $dataOffset = [int][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 4)
            $dataSize = [int][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 8)
            $mappingIndex = [int][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset)
            if ($mappingIndex -ne $index) {
                throw "Descriptor $index declares mapping index $mappingIndex."
            }
            $expectedDigest.AppendData($expectedBytes, 0, $expectedBytes.Length)
            $storedDigest.AppendData($StoreBytes, $dataOffset, $dataSize)
            $index++
        }

        $expectedHash = [Convert]::ToHexString($expectedDigest.GetHashAndReset())
        $storedHash = [Convert]::ToHexString($storedDigest.GetHashAndReset())
        if ($expectedHash -cne $storedHash) {
            throw "The stored payloads digest to $storedHash; the selected images digest to $expectedHash."
        }
    }
    finally {
        $expectedDigest.Dispose()
        $storedDigest.Dispose()
    }

    return [pscustomobject]@{
        EntryCount      = $entryCount
        IndexEntryCount = $indexEntryCount
        MetadataSize    = $cursor
        TotalSize       = $StoreBytes.Length
    }
}

function Invoke-StoreStep {
    if (Skip-ForNativeAdmission -Step 5 -Output 'the XABA store') { return }

    $contract = Get-AndroidNativeContract
    $selected = $script:BuildContext.SelectedAssemblies
    $storeBytes = New-AssemblyStoreBytes -SelectedAssemblies $selected -Contract $contract
    $report = Test-AssemblyStoreBytes -StoreBytes $storeBytes -SelectedAssemblies $selected -Contract $contract

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($outputDirectory, 'Create assembly store output directory')) {
            New-ApprovedDirectory -Path $outputDirectory
        }
    }
    $storePath = Join-Path $outputDirectory 'assembly-store.so'
    if ($PSCmdlet.ShouldProcess($storePath, 'Write assembly store')) {
        Write-BuildFile -Intermediate -Path $storePath -Bytes $storeBytes
    }

    $storeStream = [System.IO.MemoryStream]::new($storeBytes, $false)
    try { $storeHash = Get-Sha256Hex -Stream $storeStream }
    finally { $storeStream.Dispose() }

    $script:BuildContext.AssemblyStore = [pscustomobject]@{
        Path   = $storePath
        Bytes  = $storeBytes
        Sha256 = $storeHash
    }

    Write-Host ('[PASS] Step 5 complete: {0} assemblies emitted into a {1}-byte XABA store ({2} index entries, {3} bytes of metadata), verified by the runtime''s own lookup rules. SHA-256 {4}' -f
        $report.EntryCount,
        $report.TotalSize,
        $report.IndexEntryCount,
        $report.MetadataSize,
        $storeHash) -ForegroundColor Green
}

$script:ElfConstants = $null

function Get-ElfConstants {
    if ($null -ne $script:ElfConstants) { return $script:ElfConstants }

    # Values are read out of the pinned LLVM headers. ELF.h declares the file,
    # machine, segment, and symbol constants as C++ enumerators; the dynamic
    # tags live in DynamicTags.def, which ELF.h includes rather than defines.
    $constants = @{}

    $elfText = Import-LibSourceText -Path 'ELF.h'
    $parseNumber = {
        param([string] $Text)
        if ($Text.StartsWith('0x')) { return [Convert]::ToUInt64($Text.Substring(2), 16) }
        return [uint64]$Text
    }

    $wanted = @(
        'ET_DYN', 'EM_AARCH64', 'EM_X86_64', 'EM_ARM', 'ELFCLASS64', 'ELFCLASS32', 'ELFDATA2LSB',
        'EV_CURRENT', 'PT_LOAD', 'PT_DYNAMIC', 'PT_PHDR', 'PT_GNU_STACK',
        'PF_R', 'PF_W', 'PF_X', 'STB_GLOBAL', 'STT_OBJECT', 'STT_FUNC',
        'DF_BIND_NOW', 'EF_ARM_EABI_VER5', 'EF_ARM_ABI_FLOAT_SOFT',
        'SHT_STRTAB', 'SHT_DYNAMIC', 'SHF_ALLOC', 'SHF_WRITE'
    )
    foreach ($name in $wanted) {
        $match = [regex]::Match($elfText, "\b$name\s*=\s*(0x[0-9a-fA-F]+|\d+)")
        if (-not $match.Success) {
            throw "ELF.h does not declare '$name'."
        }
        $constants[$name] = [uint32](& $parseNumber $match.Groups[1].Value)
    }

    $tagText = Import-LibSourceText -Path 'DynamicTags.def'
    foreach ($tag in @('NULL', 'NEEDED', 'HASH', 'STRTAB', 'SYMTAB', 'RELA', 'RELASZ', 'RELAENT', 'RELACOUNT', 'REL', 'RELSZ', 'RELENT', 'STRSZ', 'SYMENT', 'SONAME', 'FLAGS')) {
        $match = [regex]::Match($tagText, "DYNAMIC_TAG\($tag,\s*(0x[0-9a-fA-F]+|\d+)\)")
        if (-not $match.Success) {
            throw "DynamicTags.def does not declare 'DT_$tag'."
        }
        $constants["DT_$tag"] = [uint64](& $parseNumber $match.Groups[1].Value)
    }

    foreach ($source in @(
            @{ Path = 'AArch64.def'; Names = @('R_AARCH64_GLOB_DAT', 'R_AARCH64_RELATIVE') },
            @{ Path = 'x86_64.def'; Names = @('R_X86_64_GLOB_DAT', 'R_X86_64_RELATIVE') },
            @{ Path = 'ARM.def'; Names = @('R_ARM_GLOB_DAT', 'R_ARM_RELATIVE') })) {
        $relocText = Import-LibSourceText -Path $source.Path
        foreach ($reloc in $source.Names) {
            $match = [regex]::Match($relocText, "ELF_RELOC\($reloc,\s*(0x[0-9a-fA-F]+|\d+)\)")
            if (-not $match.Success) {
                throw "$($source.Path) does not declare '$reloc'."
            }
            $constants[$reloc] = [uint32](& $parseNumber $match.Groups[1].Value)
        }
    }

    $script:ElfConstants = $constants
    return $script:ElfConstants
}

function Get-Store64BitFlag {
    # xamarin-app.hh sets ASSEMBLY_STORE_64BIT_FLAG only when
    # INTPTR_MAX == INT64_MAX, and 0 otherwise. The contract records the 64-bit
    # value; a 32-bit target's store carries no flag, or the host rejects it.
    param([Parameter(Mandatory)][pscustomobject] $Contract)
    if ($script:Target.ElfClass -eq 64) { return [uint32]$Contract.xaba.bit64Flag }
    [uint32]0
}

function Get-StoreAbiFlag {
    # The assembly store version word carries the target ABI. The values are
    # read from the pinned xamarin-app.hh, selected by the compiler define that
    # identifies the target there.
    $text = Import-LibSourceText -Path 'xamarin-app.hh'
    $define = [regex]::Escape($script:Target.CompilerDefine)
    $match = [regex]::Match($text, "defined\($define\)\s*\r?\n\s*static constexpr uint32_t ASSEMBLY_STORE_ABI\s*=\s*(0x[0-9a-fA-F]+)")
    if (-not $match.Success) {
        throw "xamarin-app.hh declares no ASSEMBLY_STORE_ABI for $($script:Target.CompilerDefine)."
    }
    [Convert]::ToUInt32($match.Groups[1].Value.Substring(2), 16)
}

function Get-ElfHashTableBytes {
    param([Parameter(Mandatory)][string[]] $Symbols)

    # SysV hash table. One bucket is correct for a table this small: the chain
    # walk still terminates, and bionic accepts it.
    $elfHash = {
        param([string] $Name)
        [uint32] $h = 0
        foreach ($char in [System.Text.Encoding]::ASCII.GetBytes($Name)) {
            $h = [uint32](((($h * 16) + $char) -band 0xFFFFFFFFL))
            $g = [uint32]($h -band 0xF0000000)
            if ($g -ne 0) { $h = [uint32]($h -bxor ($g -shr 24)) }
            $h = [uint32]($h -band (-bnot $g))
        }
        return $h
    }

    $chainCount = $Symbols.Count + 1
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        $writer.Write([uint32]1)
        $writer.Write([uint32]$chainCount)
        $writer.Write([uint32]1)
        for ($i = 0; $i -lt $chainCount; $i++) {
            if ($i -eq 0 -or $i -eq ($chainCount - 1)) { $writer.Write([uint32]0) }
            else { $writer.Write([uint32]($i + 1)) }
        }
        $writer.Flush()
        return $stream.ToArray()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

function Write-ByteSpan {
    # BinaryWriter.Write($array) can bind an overload that emits a single
    # element, which truncates silently. The three-argument form is
    # unambiguous, so every array write in this script goes through here.
    param(
        [Parameter(Mandatory)][System.IO.BinaryWriter] $Writer,
        [Parameter(Mandatory)][byte[]] $Bytes
    )

    if ($Bytes.Length -eq 0) { return }
    $before = $Writer.BaseStream.Position
    $Writer.Write($Bytes, 0, $Bytes.Length)
    $Writer.Flush()
    $written = $Writer.BaseStream.Position - $before
    if ($written -ne $Bytes.Length) {
        throw "A $($Bytes.Length)-byte write advanced the stream by $written bytes."
    }
}

# ==============================================================================
# ELF container
#
# One writer and one reader for every target. The record layouts are the
# Elf32_* and Elf64_* structures lib/ELF.h declares, and the sizes in
# Get-ElfLayout are those structures' sizes. File offsets equal virtual
# addresses throughout. This section knows nothing about instructions: the
# per-target sections supply encoders and decoders through Get-InstructionSet.
# ==============================================================================

function Get-ElfLayout {
    # Record sizes for one ELF class: Elf{32,64}_Ehdr, _Phdr, _Shdr, _Sym, _Dyn,
    # _Rel and _Rela. Word is the size of an address or offset (ElfN_Addr,
    # ElfN_Off), which is also the alignment of every metadata table.
    param([Parameter(Mandatory)][ValidateSet(32, 64)][int] $Class)
    if ($Class -eq 64) {
        return [pscustomobject]@{ Class = 64; Word = 8; Header = 64; ProgramHeader = 56; SectionHeader = 64; Symbol = 24; Dynamic = 16; Rel = 16; Rela = 24 }
    }
    [pscustomobject]@{ Class = 32; Word = 4; Header = 52; ProgramHeader = 32; SectionHeader = 40; Symbol = 16; Dynamic = 8; Rel = 8; Rela = 12 }
}

function Get-ElfHeaderFlags {
    # e_flags: the OR of the ELF.h constants the target table names. The table
    # holds the reasons; this writer holds no target knowledge.
    $elf = Get-ElfConstants
    $flags = [uint32]0
    foreach ($name in @($script:Target.ElfFlags)) { $flags = $flags -bor [uint32]$elf[$name] }
    $flags
}

function Get-ElfRelocationEntrySize {
    param([Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][ValidateSet('REL', 'RELA')][string] $Form)
    if ($Form -eq 'RELA') { return $Layout.Rela }
    $Layout.Rel
}

function Get-ElfRelocationTags {
    # The dynamic tags that locate a relocation table of the given form.
    param([Parameter(Mandatory)][ValidateSet('REL', 'RELA')][string] $Form)
    $elf = Get-ElfConstants
    [pscustomobject]@{
        Table = $elf["DT_$Form"]
        Size  = $elf["DT_${Form}SZ"]
        Entry = $elf["DT_${Form}ENT"]
    }
}

function Get-AlignedOffset {
    param([Parameter(Mandatory)][long] $Value, [Parameter(Mandatory)][long] $Alignment)
    [long](($Value + $Alignment - 1) -band (-bnot ($Alignment - 1)))
}

function Set-ElfField {
    # Writes an unsigned little-endian value of Width bytes at Offset.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Offset,
          [Parameter(Mandatory)][ValidateSet(1, 2, 4, 8)][int] $Width, [Parameter(Mandatory)][uint64] $Value)
    [System.Array]::Copy([BitConverter]::GetBytes($Value), 0, $Image, $Offset, $Width)
}

function New-ElfStringTable {
    # A string table: a leading NUL, then each distinct string NUL-terminated in
    # first-use order. Returns the bytes and each string's offset.
    param([Parameter(Mandatory)][string[]] $Strings)
    $stream = [System.IO.MemoryStream]::new()
    $stream.WriteByte(0)
    $offsets = @{}
    foreach ($text in $Strings) {
        if ($offsets.ContainsKey($text)) { continue }
        $offsets[$text] = [uint32]$stream.Position
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.WriteByte(0)
    }
    $result = [pscustomobject]@{ Bytes = $stream.ToArray(); Offset = $offsets }
    $stream.Dispose()
    $result
}

function Write-ElfHeader {
    # e_ident, e_type, e_machine, e_version, e_phoff and the record sizes.
    # e_shoff, e_shnum and e_shstrndx are set by Add-ElfSectionTable.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][int] $ProgramHeaderCount)
    $elf = Get-ElfConstants
    $w = $Layout.Word
    [System.Array]::Copy([byte[]]@(0x7F, 0x45, 0x4C, 0x46, $elf["ELFCLASS$($Layout.Class)"], $elf['ELFDATA2LSB'], $elf['EV_CURRENT']), 0, $Image, 0, 7)
    Set-ElfField $Image 16 2 $elf['ET_DYN']
    Set-ElfField $Image 18 2 $elf[$script:Target.Machine]
    Set-ElfField $Image 20 4 $elf['EV_CURRENT']
    Set-ElfField $Image (24 + $w) $w $Layout.Header             # e_phoff; e_entry stays 0
    $at = 24 + 3 * $w
    Set-ElfField $Image $at 4 (Get-ElfHeaderFlags)              # e_flags
    Set-ElfField $Image ($at + 4) 2 $Layout.Header              # e_ehsize
    Set-ElfField $Image ($at + 6) 2 $Layout.ProgramHeader       # e_phentsize
    Set-ElfField $Image ($at + 8) 2 $ProgramHeaderCount         # e_phnum
    Set-ElfField $Image ($at + 10) 2 $Layout.SectionHeader      # e_shentsize
}

function Write-ElfProgramHeader {
    # One program header. Identity mapping: p_offset = p_vaddr = p_paddr.
    # Elf64_Phdr places p_flags second; Elf32_Phdr places it after p_memsz.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][long] $At,
          [uint32] $Type, [uint32] $Flags, [long] $Offset, [long] $FileSize, [long] $MemorySize, [long] $Align)
    $w = $Layout.Word
    Set-ElfField $Image $At 4 $Type
    $fields = $At + 4
    if ($Layout.Class -eq 64) { Set-ElfField $Image $fields 4 $Flags; $fields += 4 }
    foreach ($i in 0, 1, 2) { Set-ElfField $Image ($fields + $i * $w) $w $Offset }
    Set-ElfField $Image ($fields + 3 * $w) $w $FileSize
    Set-ElfField $Image ($fields + 4 * $w) $w $MemorySize
    if ($Layout.Class -eq 32) { Set-ElfField $Image ($fields + 5 * $w) 4 $Flags; $fields += 4 }
    Set-ElfField $Image ($fields + 5 * $w) $w $Align
}

function Write-ElfSymbol {
    # One symbol. Elf64_Sym: name, info, other, shndx, value, size.
    # Elf32_Sym: name, value, size, info, other, shndx.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][long] $At,
          [uint32] $Name, [uint64] $Value, [uint64] $Size, [byte] $Info, [uint16] $Section)
    Set-ElfField $Image $At 4 $Name
    if ($Layout.Class -eq 64) {
        $Image[$At + 4] = $Info
        Set-ElfField $Image ($At + 6) 2 $Section
        Set-ElfField $Image ($At + 8) 8 $Value
        Set-ElfField $Image ($At + 16) 8 $Size
    }
    else {
        Set-ElfField $Image ($At + 4) 4 $Value
        Set-ElfField $Image ($At + 8) 4 $Size
        $Image[$At + 12] = $Info
        Set-ElfField $Image ($At + 14) 2 $Section
    }
}

function Write-ElfDynamicTable {
    # Writes (tag, value) pairs, each field one word wide.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][long] $At,
          [Parameter(Mandatory)][object[]] $Entries)
    $w = $Layout.Word
    foreach ($entry in $Entries) {
        Set-ElfField $Image $At $w ([uint64]$entry[0])
        Set-ElfField $Image ($At + $w) $w ([uint64]$entry[1])
        $At += $Layout.Dynamic
    }
}

function Write-ElfRelocation {
    # One relocation. r_info is (symbol << 32 | type) for ELF64 and
    # (symbol << 8 | type) for ELF32. RELA carries the addend in the entry; REL
    # carries it in place, in the word being relocated, so the caller must have
    # written the image content at Offset before calling this.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)] $Layout, [Parameter(Mandatory)][long] $At,
          [Parameter(Mandatory)][ValidateSet('REL', 'RELA')][string] $Form,
          [long] $Offset, [uint32] $Symbol, [uint32] $Type, [long] $Addend)
    $w = $Layout.Word
    $info = if ($Layout.Class -eq 64) { ([uint64]$Symbol -shl 32) -bor $Type } else { ([uint64]$Symbol -shl 8) -bor $Type }
    Set-ElfField $Image $At $w $Offset
    Set-ElfField $Image ($At + $w) $w $info
    if ($Form -eq 'RELA') { Set-ElfField $Image ($At + 2 * $w) $w ([uint64]$Addend) }
    else { Set-ElfField $Image $Offset $w ([uint64]$Addend) }
}

function Add-ElfSectionTable {
    # Bionic does not merely tolerate section headers, it reads them: it looks
    # for an SHT_DYNAMIC section, follows its sh_link to a string table, and
    # rejects the library if either is missing. A phdr-only file loads on some
    # releases and fails on current ones, so the table is built properly:
    # a null entry, .dynstr, .dynamic linked to it, and .shstrtab.
    param(
        [Parameter(Mandatory)][byte[]] $Image,
        [Parameter(Mandatory)] $Layout,
        [Parameter(Mandatory)][long] $DynstrOffset,
        [Parameter(Mandatory)][long] $DynstrSize,
        [Parameter(Mandatory)][long] $DynamicOffset,
        [Parameter(Mandatory)][long] $DynamicSize
    )

    $elf = Get-ElfConstants
    $w = $Layout.Word
    $names = New-ElfStringTable -Strings @('.dynstr', '.dynamic', '.shstrtab')
    $stringsOffset = Get-AlignedOffset $Image.Length $w
    $tableOffset = Get-AlignedOffset ($stringsOffset + $names.Bytes.Length) $w
    $sectionCount = 4

    $result = New-Object byte[] ($tableOffset + $Layout.SectionHeader * $sectionCount)
    [System.Array]::Copy($Image, 0, $result, 0, $Image.Length)
    [System.Array]::Copy($names.Bytes, 0, $result, $stringsOffset, $names.Bytes.Length)

    # Elf{32,64}_Shdr: name, type, flags, addr, offset, size, link, info,
    # addralign, entsize. flags, addr, offset, size, addralign and entsize are
    # one word wide.
    $writeSection = {
        param([int] $Index, [string] $Name, [uint32] $Type, [uint64] $Flags, [long] $Address, [long] $Offset,
              [long] $Size, [uint32] $Link, [long] $AddressAlign, [long] $EntrySize)
        $at = $tableOffset + $Index * $Layout.SectionHeader
        Set-ElfField $result $at 4 $names.Offset[$Name]
        Set-ElfField $result ($at + 4) 4 $Type
        Set-ElfField $result ($at + 8) $w $Flags
        Set-ElfField $result ($at + 8 + $w) $w $Address
        Set-ElfField $result ($at + 8 + 2 * $w) $w $Offset
        Set-ElfField $result ($at + 8 + 3 * $w) $w $Size
        Set-ElfField $result ($at + 8 + 4 * $w) 4 $Link
        Set-ElfField $result ($at + 16 + 4 * $w) $w $AddressAlign
        Set-ElfField $result ($at + 16 + 5 * $w) $w $EntrySize
    }

    & $writeSection 1 '.dynstr' $elf['SHT_STRTAB'] $elf['SHF_ALLOC'] $DynstrOffset $DynstrOffset $DynstrSize 0 1 0
    & $writeSection 2 '.dynamic' $elf['SHT_DYNAMIC'] ($elf['SHF_ALLOC'] -bor $elf['SHF_WRITE']) $DynamicOffset $DynamicOffset $DynamicSize 1 $w $Layout.Dynamic
    & $writeSection 3 '.shstrtab' $elf['SHT_STRTAB'] 0 0 $stringsOffset $names.Bytes.Length 0 1 0

    $at = 24 + 3 * $w
    Set-ElfField $result (24 + 2 * $w) $w $tableOffset               # e_shoff
    Set-ElfField $result ($at + 10) 2 $Layout.SectionHeader          # e_shentsize
    Set-ElfField $result ($at + 12) 2 $sectionCount                  # e_shnum
    Set-ElfField $result ($at + 14) 2 3                              # e_shstrndx: .shstrtab
    return , $result
}

function New-ElfPayloadLibrary {
    # A library that carries one byte payload under one exported object symbol.
    # Segments: PHDR, one read-only LOAD covering the whole file, DYNAMIC.
    param(
        [Parameter(Mandatory)][string] $Soname,
        [Parameter(Mandatory)][string] $SymbolName,
        [Parameter(Mandatory)][byte[]] $Payload,
        [int] $PageSize = 16384
    )

    $elf = Get-ElfConstants
    $L = Get-ElfLayout -Class $script:Target.ElfClass
    $w = $L.Word
    $programHeaderCount = 3

    $strings = New-ElfStringTable -Strings @($Soname, $SymbolName)
    $hashBytes = Get-ElfHashTableBytes -Symbols @($SymbolName)

    $dynstrOffset = $L.Header + $L.ProgramHeader * $programHeaderCount
    $dynsymOffset = Get-AlignedOffset ($dynstrOffset + $strings.Bytes.Length) $w
    $hashOffset = $dynsymOffset + 2 * $L.Symbol
    $dynamicOffset = Get-AlignedOffset ($hashOffset + $hashBytes.Length) $w
    # Seven entries. The ELF64 writer has always reserved room for eight and the
    # ELF32 writer for seven; both are kept so this writer reproduces the bytes
    # already proven on hardware. Making them agree is a separate change.
    $dynamicSize = $L.Dynamic * $(if ($L.Class -eq 64) { 8 } else { 7 })
    $payloadOffset = [long]([Math]::Ceiling(($dynamicOffset + $dynamicSize) / $PageSize)) * $PageSize
    $imageSize = $payloadOffset + $Payload.Length
    if ($L.Class -eq 32 -and $imageSize -gt [uint32]::MaxValue) {
        throw "A $imageSize-byte image does not fit the 32-bit address fields."
    }

    $image = New-Object byte[] $imageSize
    Write-ElfHeader $image $L $programHeaderCount
    $ph = $L.Header
    foreach ($s in @(
            @($elf['PT_PHDR'], $elf['PF_R'], $L.Header, ($L.ProgramHeader * $programHeaderCount), $w),
            @($elf['PT_LOAD'], $elf['PF_R'], 0, $imageSize, $PageSize),
            @($elf['PT_DYNAMIC'], $elf['PF_R'], $dynamicOffset, $dynamicSize, $w))) {
        Write-ElfProgramHeader $image $L $ph $s[0] $s[1] $s[2] $s[3] $s[3] $s[4]
        $ph += $L.ProgramHeader
    }

    [System.Array]::Copy($strings.Bytes, 0, $image, $dynstrOffset, $strings.Bytes.Length)
    Write-ElfSymbol $image $L ($dynsymOffset + $L.Symbol) $strings.Offset[$SymbolName] $payloadOffset $Payload.Length `
        ([byte](([uint32]$elf['STB_GLOBAL'] -shl 4) -bor [uint32]$elf['STT_OBJECT'])) 1
    [System.Array]::Copy($hashBytes, 0, $image, $hashOffset, $hashBytes.Length)

    Write-ElfDynamicTable $image $L $dynamicOffset @(
        @($elf['DT_SONAME'], $strings.Offset[$Soname]),
        @($elf['DT_HASH'], $hashOffset),
        @($elf['DT_STRTAB'], $dynstrOffset),
        @($elf['DT_SYMTAB'], $dynsymOffset),
        @($elf['DT_STRSZ'], $strings.Bytes.Length),
        @($elf['DT_SYMENT'], $L.Symbol),
        @($elf['DT_NULL'], 0))

    [System.Array]::Copy($Payload, 0, $image, $payloadOffset, $Payload.Length)

    $image = Add-ElfSectionTable -Image $image -Layout $L -DynstrOffset $dynstrOffset -DynstrSize $strings.Bytes.Length -DynamicOffset $dynamicOffset -DynamicSize $dynamicSize

    [pscustomobject]@{
        Bytes         = $image
        PayloadOffset = $payloadOffset
        SymbolName    = $SymbolName
        Soname        = $Soname
    }
}

function New-ElfCodeLibrary {
    <#
        A library with exported functions and imported functions reached through
        a GOT. Each function is a list of steps in the target's instruction set
        (Get-InstructionSet); a 'tail' step jumps through its import's GOT slot
        and an 'adr-data' step addresses a Data label. Each GOT slot is
        relocated with the target's GLOB_DAT type under DT_FLAGS BIND_NOW, so
        there is no PLT and no lazy binding. Segments: R (metadata), RX (code,
        data), RW (GOT), and a non-executable stack.
    #>
    param(
        [Parameter(Mandatory)][string] $Soname,
        [Parameter(Mandatory)][string[]] $Needed,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Functions,
        [System.Collections.IDictionary] $Data = @{},
        [int] $PageSize = 16384
    )

    $elf = Get-ElfConstants
    $L = Get-ElfLayout -Class $script:Target.ElfClass
    $w = $L.Word
    $isa = Get-InstructionSet
    $form = $script:Target.RelocationForm
    $relocationEntry = Get-ElfRelocationEntrySize -Layout $L -Form $form
    $relocationTags = Get-ElfRelocationTags -Form $form

    # Imports, in first-use order.
    $imports = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Functions.Keys) {
        foreach ($step in $Functions[$name]) {
            if ($step.Op -eq 'tail' -and -not $imports.Contains($step.Import)) { $imports.Add($step.Import) }
        }
    }
    $exports = @($Functions.Keys)
    $symbols = @($imports) + $exports

    $strings = New-ElfStringTable -Strings (@($Soname) + @($Needed) + $symbols)
    $hashBytes = Get-ElfHashTableBytes -Symbols $symbols

    $programHeaderCount = 6
    $dynstrOffset = $L.Header + $L.ProgramHeader * $programHeaderCount
    $dynsymOffset = Get-AlignedOffset ($dynstrOffset + $strings.Bytes.Length) $w
    $dynsymSize = $L.Symbol * ($symbols.Count + 1)
    $hashOffset = Get-AlignedOffset ($dynsymOffset + $dynsymSize) $w
    $relocationOffset = Get-AlignedOffset ($hashOffset + $hashBytes.Length) $w
    $relocationSize = $relocationEntry * $imports.Count
    $dynamicOffset = Get-AlignedOffset ($relocationOffset + $relocationSize) $w
    $dynamicSize = $L.Dynamic * (11 + $Needed.Count)
    $metaEnd = $dynamicOffset + $dynamicSize

    $textOffset = Get-AlignedOffset $metaEnd $PageSize
    $functionOffset = [ordered]@{}
    $functionSize = @{}
    $cursor = $textOffset
    foreach ($name in $exports) {
        $functionOffset[$name] = $cursor
        $size = 0
        foreach ($step in $Functions[$name]) { $size += & $isa.Length -Step $step }
        $functionSize[$name] = $size
        $cursor += $size
    }
    $dataOffset = [ordered]@{}
    foreach ($label in $Data.Keys) {
        $dataOffset[$label] = $cursor
        $cursor += $Data[$label].Length
    }
    $textEnd = $cursor
    $gotOffset = Get-AlignedOffset $textEnd $PageSize
    $gotSize = $w * [Math]::Max(1, $imports.Count)
    $imageSize = $gotOffset + $gotSize

    $image = New-Object byte[] $imageSize
    Write-ElfHeader $image $L $programHeaderCount
    $ph = $L.Header
    foreach ($s in @(
            @($elf['PT_PHDR'], $elf['PF_R'], $L.Header, ($L.ProgramHeader * $programHeaderCount), $w),
            @($elf['PT_LOAD'], $elf['PF_R'], 0, $metaEnd, $PageSize),
            @($elf['PT_LOAD'], ($elf['PF_R'] -bor $elf['PF_X']), $textOffset, ($textEnd - $textOffset), $PageSize),
            @($elf['PT_LOAD'], ($elf['PF_R'] -bor $elf['PF_W']), $gotOffset, $gotSize, $PageSize),
            @($elf['PT_DYNAMIC'], $elf['PF_R'], $dynamicOffset, $dynamicSize, $w),
            @($elf['PT_GNU_STACK'], ($elf['PF_R'] -bor $elf['PF_W']), 0, 0, 16))) {
        Write-ElfProgramHeader $image $L $ph $s[0] $s[1] $s[2] $s[3] $s[3] $s[4]
        $ph += $L.ProgramHeader
    }

    [System.Array]::Copy($strings.Bytes, 0, $image, $dynstrOffset, $strings.Bytes.Length)

    # Symbols: null, imports (undefined), exports (defined functions).
    $functionInfo = [byte](([uint32]$elf['STB_GLOBAL'] -shl 4) -bor [uint32]$elf['STT_FUNC'])
    $symbolIndex = @{}
    $index = 1
    foreach ($name in $imports) {
        Write-ElfSymbol $image $L ($dynsymOffset + $L.Symbol * $index) $strings.Offset[$name] 0 0 $functionInfo 0
        $symbolIndex[$name] = $index++
    }
    foreach ($name in $exports) {
        Write-ElfSymbol $image $L ($dynsymOffset + $L.Symbol * $index) $strings.Offset[$name] $functionOffset[$name] $functionSize[$name] $functionInfo 1
        $symbolIndex[$name] = $index++
    }
    [System.Array]::Copy($hashBytes, 0, $image, $hashOffset, $hashBytes.Length)

    # GOT slots start at zero; with REL that zero is the in-place addend.
    $gotSlot = @{}
    for ($i = 0; $i -lt $imports.Count; $i++) {
        $slot = $gotOffset + $w * $i
        $gotSlot[$imports[$i]] = $slot
        Write-ElfRelocation $image $L ($relocationOffset + $relocationEntry * $i) $form $slot $symbolIndex[$imports[$i]] $elf[$script:Target.GotRelocation] 0
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($lib in $Needed) { $entries.Add(@($elf['DT_NEEDED'], $strings.Offset[$lib])) }
    foreach ($e in @(
            @($elf['DT_SONAME'], $strings.Offset[$Soname]),
            @($elf['DT_HASH'], $hashOffset),
            @($elf['DT_STRTAB'], $dynstrOffset),
            @($elf['DT_SYMTAB'], $dynsymOffset),
            @($elf['DT_STRSZ'], $strings.Bytes.Length),
            @($elf['DT_SYMENT'], $L.Symbol),
            @($relocationTags.Table, $relocationOffset),
            @($relocationTags.Size, $relocationSize),
            @($relocationTags.Entry, $relocationEntry),
            @($elf['DT_FLAGS'], $elf['DF_BIND_NOW']),
            @($elf['DT_NULL'], 0))) { $entries.Add($e) }
    Write-ElfDynamicTable $image $L $dynamicOffset $entries.ToArray()

    foreach ($name in $exports) {
        $pc = [long]$functionOffset[$name]
        foreach ($step in $Functions[$name]) {
            $length = & $isa.Length -Step $step
            $target = switch ($step.Op) {
                'tail' { $gotSlot[$step.Import] }
                { $_ -in 'adr-data', 'lea-data' } { $dataOffset[$step.Data] }
                default { 0 }
            }
            $bytes = [byte[]]@(& $isa.Encode -Step $step -Pc $pc -Target $target)
            if ($bytes.Length -ne $length) { throw "$($isa.Name) step '$($step.Op)' encoded to $($bytes.Length) bytes, expected $length." }
            [System.Array]::Copy($bytes, 0, $image, $pc, $length)
            $pc += $length
        }
    }
    foreach ($label in $Data.Keys) {
        [System.Array]::Copy([byte[]]$Data[$label], 0, $image, $dataOffset[$label], $Data[$label].Length)
    }

    $image = Add-ElfSectionTable -Image $image -Layout $L -DynstrOffset $dynstrOffset -DynstrSize $strings.Bytes.Length -DynamicOffset $dynamicOffset -DynamicSize $dynamicSize

    [pscustomobject]@{
        Bytes     = $image
        Soname    = $Soname
        Exports   = $functionOffset
        Imports   = @($imports)
        GotSlots  = $gotSlot
        DataAt    = $dataOffset
        Functions = $Functions
    }
}

function New-ElfDataLibrary {
    # A shared object that exports data. Two loadable segments: a read and
    # execute region holding the metadata and the one code stub, and a read and
    # write region holding the data the host mutates, extended past the end of
    # the file by a .bss tail. Pointers inside the data are supplied by the
    # target's RELATIVE relocations, because a position independent object
    # cannot know its own load address.
    param(
        [Parameter(Mandatory)][string] $Soname,
        [Parameter(Mandatory)][byte[]] $Payload,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]] $Symbols,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]] $Relocations,
        [Parameter(Mandatory)][string] $BssSymbolName,
        [int] $BssSize = 8,
        [int] $PageSize = 16384
    )

    $elf = Get-ElfConstants
    $L = Get-ElfLayout -Class $script:Target.ElfClass
    $w = $L.Word
    $form = $script:Target.RelocationForm
    $relocationEntry = Get-ElfRelocationEntrySize -Layout $L -Form $form
    $relocationTags = Get-ElfRelocationTags -Form $form
    $programHeaderCount = 3

    $exported = [System.Collections.Generic.List[object]]::new()
    foreach ($symbol in $Symbols) { $exported.Add($symbol) }
    $exported.Add([pscustomobject]@{ Name = $BssSymbolName; Offset = $Payload.Length; Size = $BssSize; Kind = 'OBJECT' })

    $strings = New-ElfStringTable -Strings (@($Soname) + @($exported | ForEach-Object { [string]$_.Name }))
    $hashBytes = Get-ElfHashTableBytes -Symbols @($exported | ForEach-Object { [string]$_.Name })

    # DT_RELACOUNT has been emitted with RELA since the first device run; the
    # REL images have never carried DT_RELCOUNT.
    $dynamic = [System.Collections.Generic.List[object]]::new()
    $dynstrOffset = $L.Header + $L.ProgramHeader * $programHeaderCount
    $dynsymOffset = Get-AlignedOffset ($dynstrOffset + $strings.Bytes.Length) $w
    $hashOffset = $dynsymOffset + $L.Symbol * ($exported.Count + 1)
    $relocationOffset = Get-AlignedOffset ($hashOffset + $hashBytes.Length) $w
    $relocationSize = $relocationEntry * $Relocations.Count
    $dynamicOffset = Get-AlignedOffset ($relocationOffset + $relocationSize) $w
    foreach ($e in @(
            @($elf['DT_SONAME'], $strings.Offset[$Soname]),
            @($elf['DT_HASH'], $hashOffset),
            @($elf['DT_STRTAB'], $dynstrOffset),
            @($elf['DT_SYMTAB'], $dynsymOffset),
            @($elf['DT_STRSZ'], $strings.Bytes.Length),
            @($elf['DT_SYMENT'], $L.Symbol),
            @($relocationTags.Table, $relocationOffset),
            @($relocationTags.Size, $relocationSize),
            @($relocationTags.Entry, $relocationEntry))) { $dynamic.Add($e) }
    if ($form -eq 'RELA') { $dynamic.Add(@($elf['DT_RELACOUNT'], $Relocations.Count)) }
    $dynamic.Add(@($elf['DT_NULL'], 0))
    $dynamic.Add(@($elf['DT_NULL'], 0))
    $dynamicSize = $L.Dynamic * $dynamic.Count

    $codeOffset = Get-AlignedOffset ($dynamicOffset + $dynamicSize) 4
    $readExecuteEnd = $codeOffset + 4
    $payloadOffset = [long]([Math]::Ceiling(($readExecuteEnd + 1) / $PageSize)) * $PageSize
    $imageSize = $payloadOffset + $Payload.Length

    $symbolAddress = {
        param([object] $Symbol)
        if ([string]$Symbol.Kind -ceq 'FUNC') { return $codeOffset }
        return $payloadOffset + [int]$Symbol.Offset
    }

    $image = New-Object byte[] $imageSize
    Write-ElfHeader $image $L $programHeaderCount
    $readExecute = [uint32]($elf['PF_R'] -bor $elf['PF_X'])
    $readWrite = [uint32]($elf['PF_R'] -bor $elf['PF_W'])
    Write-ElfProgramHeader $image $L $L.Header $elf['PT_LOAD'] $readExecute 0 $readExecuteEnd $readExecuteEnd $PageSize
    Write-ElfProgramHeader $image $L ($L.Header + $L.ProgramHeader) $elf['PT_LOAD'] $readWrite $payloadOffset $Payload.Length ($Payload.Length + $BssSize) $PageSize
    Write-ElfProgramHeader $image $L ($L.Header + 2 * $L.ProgramHeader) $elf['PT_DYNAMIC'] $readWrite $dynamicOffset $dynamicSize $dynamicSize $w

    [System.Array]::Copy($strings.Bytes, 0, $image, $dynstrOffset, $strings.Bytes.Length)
    $at = $dynsymOffset + $L.Symbol
    foreach ($symbol in $exported) {
        $type = if ([string]$symbol.Kind -ceq 'FUNC') { [uint32]$elf['STT_FUNC'] } else { [uint32]$elf['STT_OBJECT'] }
        Write-ElfSymbol $image $L $at $strings.Offset[[string]$symbol.Name] (& $symbolAddress $symbol) ([int]$symbol.Size) `
            ([byte](([uint32]$elf['STB_GLOBAL'] -shl 4) -bor $type)) 1
        $at += $L.Symbol
    }
    [System.Array]::Copy($hashBytes, 0, $image, $hashOffset, $hashBytes.Length)
    Write-ElfDynamicTable $image $L $dynamicOffset $dynamic.ToArray()

    $stub = [byte[]](Get-ReturnStubBytes)
    [System.Array]::Copy($stub, 0, $image, $codeOffset, $stub.Length)
    [System.Array]::Copy($Payload, 0, $image, $payloadOffset, $Payload.Length)

    # After the payload copy, because REL writes each addend into the payload.
    $at = $relocationOffset
    foreach ($relocation in $Relocations) {
        Write-ElfRelocation $image $L $at $form ($payloadOffset + [int]$relocation.Offset) 0 $elf[$script:Target.RelativeRelocation] ($payloadOffset + [int]$relocation.Target)
        $at += $relocationEntry
    }

    $image = Add-ElfSectionTable -Image $image -Layout $L -DynstrOffset $dynstrOffset -DynstrSize $strings.Bytes.Length -DynamicOffset $dynamicOffset -DynamicSize $dynamicSize

    [pscustomobject]@{
        Bytes           = $image
        PayloadOffset   = $payloadOffset
        SymbolCount     = $exported.Count
        RelocationCount = $Relocations.Count
        BssSize         = $BssSize
    }
}

function Read-ElfImage {
    <#
        An ELF reader that takes nothing from the writers but the bytes. The
        class, the record layout and every table address come from the image,
        the way bionic reads it; symbols are resolved through the SysV hash
        table with this function's own hash, the way dlsym resolves them.
    #>
    param([Parameter(Mandatory)][byte[]] $Image)

    $elf = Get-ElfConstants
    if ($Image.Length -lt 52 -or $Image[0] -ne 0x7F -or $Image[1] -ne 0x45 -or $Image[2] -ne 0x4C -or $Image[3] -ne 0x46) {
        throw 'The image does not begin with the ELF magic.'
    }
    $class = if ($Image[4] -eq $elf['ELFCLASS32']) { 32 } elseif ($Image[4] -eq $elf['ELFCLASS64']) { 64 } else { throw "Unknown ELF class $($Image[4])." }
    $L = Get-ElfLayout -Class $class
    $w = $L.Word
    $u = {
        param([long] $At, [int] $Width)
        switch ($Width) {
            2 { [uint64][BitConverter]::ToUInt16($Image, $At) }
            4 { [uint64][BitConverter]::ToUInt32($Image, $At) }
            8 { [BitConverter]::ToUInt64($Image, $At) }
        }
    }
    $cstring = {
        param([long] $At)
        $end = $At
        while ($Image[$end] -ne 0) { $end++ }
        [System.Text.Encoding]::ASCII.GetString($Image, $At, $end - $At)
    }

    $f = 24 + 3 * $w
    $header = [pscustomobject]@{
        Class = $class; Data = $Image[5]; IdentVersion = $Image[6]
        Type = & $u 16 2; Machine = & $u 18 2; Version = & $u 20 4
        ProgramHeaderOffset = & $u (24 + $w) $w; SectionHeaderOffset = & $u (24 + 2 * $w) $w
        Flags = & $u $f 4; HeaderSize = & $u ($f + 4) 2; ProgramHeaderSize = & $u ($f + 6) 2
        ProgramHeaderCount = & $u ($f + 8) 2; SectionHeaderSize = & $u ($f + 10) 2
        SectionHeaderCount = & $u ($f + 12) 2; SectionNameIndex = & $u ($f + 14) 2
    }

    $segments = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $header.ProgramHeaderCount; $i++) {
        $p = [long]$header.ProgramHeaderOffset + $i * [long]$header.ProgramHeaderSize
        if ($class -eq 64) {
            $segments.Add([pscustomobject]@{ Type = & $u $p 4; Flags = & $u ($p + 4) 4; Offset = & $u ($p + 8) 8; Address = & $u ($p + 16) 8
                                             FileSize = & $u ($p + 32) 8; MemorySize = & $u ($p + 40) 8; Align = & $u ($p + 48) 8 })
        }
        else {
            $segments.Add([pscustomobject]@{ Type = & $u $p 4; Offset = & $u ($p + 4) 4; Address = & $u ($p + 8) 4; FileSize = & $u ($p + 16) 4
                                             MemorySize = & $u ($p + 20) 4; Flags = & $u ($p + 24) 4; Align = & $u ($p + 28) 4 })
        }
    }

    $tags = @{}
    $needed = [System.Collections.Generic.List[uint64]]::new()
    $dynamicSegment = @($segments | Where-Object { $_.Type -eq $elf['PT_DYNAMIC'] })
    if ($dynamicSegment.Count -eq 1) {
        for ($at = [long]$dynamicSegment[0].Offset; ; $at += $L.Dynamic) {
            $tag = & $u $at $w
            if ($tag -eq $elf['DT_NULL']) { break }
            $value = & $u ($at + $w) $w
            if ($tag -eq $elf['DT_NEEDED']) { $needed.Add($value) } else { $tags[[uint64]$tag] = $value }
        }
    }

    $strtab = [long]$tags[[uint64]$elf['DT_STRTAB']]
    $symtab = [long]$tags[[uint64]$elf['DT_SYMTAB']]
    $syment = [long]$tags[[uint64]$elf['DT_SYMENT']]
    $readSymbol = {
        param([long] $Index)
        $at = $symtab + $Index * $syment
        if ($class -eq 64) {
            $info = $Image[$at + 4]; $section = & $u ($at + 6) 2; $value = & $u ($at + 8) 8; $size = & $u ($at + 16) 8
        }
        else {
            $value = & $u ($at + 4) 4; $size = & $u ($at + 8) 4; $info = $Image[$at + 12]; $section = & $u ($at + 14) 2
        }
        [pscustomobject]@{ Index = $Index; Name = & $cstring ($strtab + (& $u $at 4)); Value = $value; Size = $size
                           Binding = $info -shr 4; Type = $info -band 0xF; Section = $section }
    }

    # SysV ELF hash, computed here rather than borrowed from the writer.
    $elfHash = {
        param([string] $Name)
        [uint64] $h = 0
        foreach ($c in [System.Text.Encoding]::ASCII.GetBytes($Name)) {
            $h = (($h -shl 4) + $c) -band 0xFFFFFFFFL
            $g = $h -band 0xF0000000L
            if ($g -ne 0) { $h = $h -bxor ($g -shr 24) }
            $h = $h -band (-bnot $g) -band 0xFFFFFFFFL
        }
        $h
    }
    $resolved = @{}
    $symbolsByIndex = [System.Collections.Generic.List[object]]::new()
    if ($tags.ContainsKey([uint64]$elf['DT_HASH'])) {
        $hash = [long]$tags[[uint64]$elf['DT_HASH']]
        $bucketCount = [long](& $u $hash 4)
        $chainCount = [long](& $u ($hash + 4) 4)
        for ($i = 1; $i -lt $chainCount; $i++) { $symbolsByIndex.Add((& $readSymbol $i)) }
        foreach ($symbol in $symbolsByIndex) {
            $index = & $u ($hash + 8 + 4 * ((& $elfHash $symbol.Name) % $bucketCount)) 4
            while ($index -ne 0) {
                $candidate = & $readSymbol $index
                if ($candidate.Name -ceq $symbol.Name) { $resolved[$symbol.Name] = $candidate; break }
                $index = & $u ($hash + 8 + 4 * $bucketCount + 4 * $index) 4
            }
        }
    }

    $relocations = [System.Collections.Generic.List[object]]::new()
    $form = $null
    foreach ($candidate in 'RELA', 'REL') {
        $t = Get-ElfRelocationTags -Form $candidate
        if (-not $tags.ContainsKey([uint64]$t.Table)) { continue }
        if ($null -ne $form) { throw 'The image declares both REL and RELA tables.' }
        $form = $candidate
        $table = [long]$tags[[uint64]$t.Table]
        $entry = [long]$tags[[uint64]$t.Entry]
        for ($at = $table; $at -lt $table + [long]$tags[[uint64]$t.Size]; $at += $entry) {
            $offset = [long](& $u $at $w)
            $info = & $u ($at + $w) $w
            $symbolIndex = if ($class -eq 64) { $info -shr 32 } else { $info -shr 8 }
            $type = if ($class -eq 64) { $info -band 0xFFFFFFFFL } else { $info -band 0xFF }
            $addend = if ($candidate -eq 'RELA') {
                if ($class -eq 64) { [BitConverter]::ToInt64($Image, $at + 2 * $w) } else { [BitConverter]::ToInt32($Image, $at + 2 * $w) }
            }
            elseif ($offset + $w -le $Image.Length) {
                if ($class -eq 64) { [BitConverter]::ToInt64($Image, $offset) } else { [long][BitConverter]::ToUInt32($Image, $offset) }
            }
            else { $null }
            $name = if ($symbolIndex -ne 0) { (& $readSymbol $symbolIndex).Name } else { $null }
            $relocations.Add([pscustomobject]@{ Offset = $offset; Symbol = $symbolIndex; SymbolName = $name; Type = $type; Addend = $addend })
        }
    }

    [pscustomobject]@{
        Layout         = $L
        Header         = $header
        Segments       = $segments
        Tags           = $tags
        Needed         = @($needed | ForEach-Object { & $cstring ($strtab + $_) })
        Symbols        = $symbolsByIndex
        Resolved       = $resolved
        RelocationForm = $form
        Relocations    = $relocations
    }
}

function Read-ElfString {
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Offset)
    $end = $Offset
    while ($Image[$end] -ne 0) { $end++ }
    [System.Text.Encoding]::UTF8.GetString($Image, $Offset, $end - $Offset)
}

function Assert-ElfTargetHeader {
    # The header fields bionic's VerifyElfHeader checks (lib/linker_phdr.cpp),
    # plus e_flags and the record sizes, against the selected target.
    param([Parameter(Mandatory)] $Parsed, [Parameter(Mandatory)][string] $Name)
    $elf = Get-ElfConstants
    $h = $Parsed.Header
    if ($h.Class -ne $script:Target.ElfClass) { throw "$Name is ELFCLASS$($h.Class); the target is ELFCLASS$($script:Target.ElfClass)." }
    if ($h.Data -ne $elf['ELFDATA2LSB']) { throw "$Name is not little-endian." }
    if ($h.Type -ne $elf['ET_DYN']) { throw "$Name is not ET_DYN." }
    if ($h.Version -ne $elf['EV_CURRENT']) { throw "$Name e_version is not EV_CURRENT." }
    if ($h.Machine -ne $elf[$script:Target.Machine]) { throw "$Name is not $($script:Target.Machine)." }
    if ($h.Flags -ne (Get-ElfHeaderFlags)) { throw ('{0} e_flags is 0x{1:X8}, expected 0x{2:X8}.' -f $Name, $h.Flags, (Get-ElfHeaderFlags)) }
    if ($h.HeaderSize -ne $Parsed.Layout.Header -or $h.ProgramHeaderSize -ne $Parsed.Layout.ProgramHeader) { throw "$Name declares the wrong header record sizes." }
    if ($h.SectionHeaderSize -ne $Parsed.Layout.SectionHeader) { throw "$Name e_shentsize is not the section header size." }
    if ($h.SectionNameIndex -eq 0) { throw "$Name e_shstrndx is 0." }
    foreach ($segment in $Parsed.Segments) {
        if ($segment.Offset -ne $segment.Address) { throw "$Name maps file offset $($segment.Offset) at address $($segment.Address); the writers use identity mapping." }
        if ($segment.Type -eq $elf['PT_LOAD'] -and ($segment.Flags -band $elf['PF_W']) -and ($segment.Flags -band $elf['PF_X'])) {
            throw "$Name has a writable and executable segment."
        }
    }
}

function Test-ElfPayloadLibrary {
    param(
        [Parameter(Mandatory)][pscustomobject] $Library,
        [Parameter(Mandatory)][byte[]] $Payload
    )

    $elf = Get-ElfConstants
    $bytes = [byte[]]$Library.Bytes
    $image = Read-ElfImage -Image $bytes
    Assert-ElfTargetHeader -Parsed $image -Name $Library.Soname

    $loads = @($image.Segments | Where-Object { $_.Type -eq $elf['PT_LOAD'] })
    if ($loads.Count -eq 0) { throw 'The emitted library declares no PT_LOAD segment.' }
    foreach ($load in $loads) {
        if ($load.Align -gt 0 -and (($load.Address - $load.Offset) % $load.Align) -ne 0) { throw 'A PT_LOAD segment is not congruent modulo its alignment.' }
    }
    $isMapped = {
        param([uint64] $Start, [uint64] $Length)
        foreach ($load in $loads) { if ($Start -ge $load.Offset -and ($Start + $Length) -le ($load.Offset + $load.FileSize)) { return $true } }
        $false
    }
    foreach ($required in 'DT_HASH', 'DT_STRTAB', 'DT_SYMTAB', 'DT_STRSZ', 'DT_SYMENT', 'DT_SONAME') {
        if (-not $image.Tags.ContainsKey([uint64]$elf[$required])) { throw "The emitted dynamic table is missing $required." }
    }
    if ($image.Tags[[uint64]$elf['DT_SYMENT']] -ne $image.Layout.Symbol) { throw 'DT_SYMENT is not the symbol record size.' }
    if (-not (& $isMapped $image.Tags[[uint64]$elf['DT_STRTAB']] $image.Tags[[uint64]$elf['DT_STRSZ']])) { throw '.dynstr is not inside a PT_LOAD segment.' }

    $symbol = $image.Resolved[$Library.SymbolName]
    if ($null -eq $symbol) { throw "'$($Library.SymbolName)' does not resolve through the emitted hash table." }
    if ($symbol.Binding -ne $elf['STB_GLOBAL'] -or $symbol.Type -ne $elf['STT_OBJECT'] -or $symbol.Section -eq 0) {
        throw "'$($symbol.Name)' is not a defined global object symbol."
    }
    if ($symbol.Size -ne $Payload.Length) { throw "'$($symbol.Name)' declares $($symbol.Size) bytes; the payload is $($Payload.Length) bytes." }
    if (-not (& $isMapped $symbol.Value $symbol.Size)) { throw "'$($symbol.Name)' points outside every PT_LOAD segment." }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $carried = $sha.ComputeHash($bytes, [int]$symbol.Value, $Payload.Length)
        $expected = $sha.ComputeHash($Payload)
    }
    finally { $sha.Dispose() }
    if ([Convert]::ToHexString($carried) -ne [Convert]::ToHexString($expected)) { throw 'The carried payload differs from the store.' }

    [pscustomobject]@{
        ImageSize     = $bytes.Length
        PayloadOffset = $Library.PayloadOffset
        Overhead      = $bytes.Length - $Payload.Length
    }
}

function Test-ElfCodeLibrary {
    # Reads the image back: header fields against the target, one executable
    # segment, every export resolves through the hash table to its address,
    # every instruction decodes to the intended one through the target's own
    # decoder, and every GOT reference lands on a slot whose relocation names
    # the intended import.
    param([Parameter(Mandatory)] $Library)

    $elf = Get-ElfConstants
    $bytes = [byte[]]$Library.Bytes
    $image = Read-ElfImage -Image $bytes
    Assert-ElfTargetHeader -Parsed $image -Name $Library.Soname
    $isa = Get-InstructionSet

    $executable = @($image.Segments | Where-Object { $_.Type -eq $elf['PT_LOAD'] -and ($_.Flags -band $elf['PF_X']) })
    if ($executable.Count -ne 1) { throw "$($Library.Soname) must have exactly one executable segment." }
    if ($executable[0].Align -lt 16384) { throw "$($Library.Soname) is not 16 KB aligned." }
    if (-not ($image.Tags[[uint64]$elf['DT_FLAGS']] -band $elf['DF_BIND_NOW'])) { throw 'DT_FLAGS lacks BIND_NOW.' }
    if ($image.RelocationForm -ne $script:Target.RelocationForm) { throw "$($Library.Soname) uses $($image.RelocationForm); the target uses $($script:Target.RelocationForm)." }
    $tags = Get-ElfRelocationTags -Form $image.RelocationForm
    if ($image.Tags[[uint64]$tags.Entry] -ne (Get-ElfRelocationEntrySize -Layout $image.Layout -Form $image.RelocationForm)) { throw 'The relocation entry size is wrong.' }

    $slotImport = @{}
    foreach ($relocation in $image.Relocations) {
        if ($relocation.Type -ne $elf[$script:Target.GotRelocation]) { throw "Relocation at $($relocation.Offset) is not $($script:Target.GotRelocation)." }
        if ($relocation.Addend -ne 0) { throw "GOT slot $($relocation.Offset) carries a nonzero addend." }
        $slotImport[[long]$relocation.Offset] = $relocation.SymbolName
    }

    $steps = 0
    foreach ($name in $Library.Exports.Keys) {
        $symbol = $image.Resolved[$name]
        if (-not $symbol -or $symbol.Section -eq 0) { throw "Export '$name' does not resolve." }
        if ($symbol.Value -ne $Library.Exports[$name]) { throw "Export '$name' resolves to $($symbol.Value), expected $($Library.Exports[$name])." }
        if ($symbol.Value % $isa.Alignment) { throw "Export '$name' is not aligned to a $($isa.Name) instruction." }
        $pc = [long]$symbol.Value
        foreach ($step in $Library.Functions[$name]) {
            $pc += & $isa.Verify -Image $bytes -Pc $pc -Step $step -DataAt $Library.DataAt -SlotImport $slotImport -Name $name
            $steps++
        }
    }

    [pscustomobject]@{
        ImageSize = $bytes.Length
        Exports   = $Library.Exports.Count
        Imports   = $Library.Imports.Count
        Needed    = $image.Needed.Count
        Steps     = $steps
    }
}

function Test-XamarinAppLibrary {
    param(
        [Parameter(Mandatory)][pscustomobject] $Library,
        [Parameter(Mandatory)][string[]] $RequiredSymbols,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][int] $AssemblyCount
    )

    $elf = Get-ElfConstants
    $bytes = [byte[]]$Library.Bytes
    $image = Read-ElfImage -Image $bytes
    Assert-ElfTargetHeader -Parsed $image -Name 'libxamarin-app.so'
    $w = $image.Layout.Word

    if (-not @($image.Segments | Where-Object { $_.Type -eq $elf['PT_LOAD'] -and $_.MemorySize -gt $_.FileSize })) {
        throw 'No segment reserves memory past the end of the file for the assemblies buffer.'
    }
    if (-not @($image.Segments | Where-Object { $_.Type -eq $elf['PT_DYNAMIC'] })) { throw 'The emitted library declares no PT_DYNAMIC segment.' }
    foreach ($required in 'DT_HASH', 'DT_STRTAB', 'DT_SYMTAB') {
        if (-not $image.Tags.ContainsKey([uint64]$elf[$required])) { throw "The dynamic table is missing $required." }
    }
    if ($image.RelocationForm -ne $script:Target.RelocationForm) { throw "libxamarin-app.so uses $($image.RelocationForm); the target uses $($script:Target.RelocationForm)." }
    $tags = Get-ElfRelocationTags -Form $image.RelocationForm
    if ($image.Tags[[uint64]$tags.Entry] -ne (Get-ElfRelocationEntrySize -Layout $image.Layout -Form $image.RelocationForm)) { throw 'The relocation entry size is wrong.' }

    $addendAt = @{}
    foreach ($relocation in $image.Relocations) {
        if ($relocation.Type -ne $elf[$script:Target.RelativeRelocation]) { throw "Relocation at $($relocation.Offset) is not $($script:Target.RelativeRelocation)." }
        if ($relocation.Offset + $w -gt $bytes.Length) { throw "Relocation at $($relocation.Offset) writes outside the image." }
        if ($relocation.Addend -lt 0 -or $relocation.Addend -ge $bytes.Length) { throw "Relocation at $($relocation.Offset) points outside the image." }
        $addendAt[[long]$relocation.Offset] = [long]$relocation.Addend
    }

    $missing = @($RequiredSymbols | Where-Object { -not $image.Resolved.ContainsKey($_) })
    if ($missing.Count -ne 0) { throw "The emitted library does not export: $($missing -join ', ')" }

    # ApplicationConfig: four bools, thirteen uint32_t, the package-name pointer
    # at 56, then have_assembly_store (lib/xamarin-app.hh).
    $config = [long]$image.Resolved['application_config'].Value
    if ([BitConverter]::ToUInt32($bytes, $config + 20) -ne $AssemblyCount) { throw "application_config does not declare $AssemblyCount assemblies." }
    if ($bytes[$config + 56 + $w] -ne 1) { throw 'application_config does not set have_assembly_store.' }
    if (-not $addendAt.ContainsKey($config + 56) -or (Read-ElfString -Image $bytes -Offset $addendAt[$config + 56]) -cne $PackageName) {
        throw 'application_config.android_package_name does not address the package name.'
    }

    [pscustomobject]@{
        Size            = $bytes.Length
        SymbolCount     = $Library.SymbolCount
        RelocationCount = $Library.RelocationCount
        Verified        = $RequiredSymbols.Count
    }
}

function Get-InstructionSet {
    # The selected target's instruction set, as the operations the shared ELF
    # code-library writer and reader call. Everything machine-specific stays in
    # that instruction set's own section.
    switch ($script:Target.Isa) {
        'A64' { return [pscustomobject]@{ Name = 'A64'; Alignment = 4; Length = ${function:Get-A64StepLength}; Encode = ${function:New-A64Step}; Verify = ${function:Test-A64Step} } }
        'X64' { return [pscustomobject]@{ Name = 'x86-64'; Alignment = 1; Length = ${function:Get-X64StepLength}; Encode = ${function:New-X64Step}; Verify = ${function:Test-X64Step} } }
        'A32' { return [pscustomobject]@{ Name = 'A32'; Alignment = 4; Length = ${function:Get-A32StepLength}; Encode = ${function:New-A32Step}; Verify = ${function:Test-A32Step} } }
        default { throw "No instruction set for target $Architecture." }
    }
}

# ==============================================================================
# AArch64 machine code
#
# Named encoders for the few A64 instructions the emitted shims use, and an
# independent decoder that reads every emitted word back. Field layouts follow
# the Arm A-profile architecture reference (A64 base instructions).
# ==============================================================================

function New-A64MovWide {
    # MOVZ / MOVN: sf opc 100101 hw imm16 Rd
    param([ValidateSet('movz', 'movn')][string] $Op, [ValidateRange(0, 31)][int] $Rd,
          [ValidateRange(0, 65535)][int] $Imm16, [bool] $Is64 = $true)
    $opc = if ($Op -eq 'movz') { 2 } else { 0 }
    [uint32]((([uint32]$Is64) -shl 31) -bor ($opc -shl 29) -bor (0x25 -shl 23) -bor ($Imm16 -shl 5) -bor $Rd)
}

function New-A64MovRegister {
    # MOV Rd, Rm is ORR Rd, ZR, Rm: sf 01 01010 00 0 Rm 000000 11111 Rd
    param([ValidateRange(0, 30)][int] $Rd, [ValidateRange(0, 30)][int] $Rm, [bool] $Is64 = $true)
    [uint32]((([uint32]$Is64) -shl 31) -bor (0x2A000000) -bor ($Rm -shl 16) -bor (31 -shl 5) -bor $Rd)
}

function New-A64Adr {
    # ADR / ADRP: op immlo 10000 immhi Rd, signed 21-bit immediate
    param([ValidateSet('adr', 'adrp')][string] $Op, [ValidateRange(0, 30)][int] $Rd, [long] $Imm21)
    if ($Imm21 -lt -1048576 -or $Imm21 -gt 1048575) { throw "$Op immediate $Imm21 is out of range." }
    $value = [uint32]($Imm21 -band 0x1FFFFF)
    $opBit = if ($Op -eq 'adrp') { 1 } else { 0 }
    [uint32](($opBit -shl 31) -bor (($value -band 3) -shl 29) -bor (0x10 -shl 24) -bor ((($value -shr 2) -band 0x7FFFF) -shl 5) -bor $Rd)
}

function New-A64LdrUnsigned {
    # LDR Xt, [Xn, #imm]: 11 111 0 01 01 imm12 Rn Rt, imm12 = offset / 8
    param([ValidateRange(0, 30)][int] $Rt, [ValidateRange(0, 31)][int] $Rn, [ValidateRange(0, 32760)][int] $Offset)
    if ($Offset % 8) { throw "LDR offset $Offset is not a multiple of 8." }
    [uint32](0xF9400000u -bor (($Offset / 8) -shl 10) -bor ($Rn -shl 5) -bor $Rt)
}

function New-A64BranchRegister {
    # BR / RET: 1101011 0 0 opc 11111 000000 Rn 00000
    param([ValidateSet('br', 'ret')][string] $Op, [ValidateRange(0, 30)][int] $Rn = 30)
    $opc = if ($Op -eq 'ret') { 2 } else { 0 }
    [uint32](0xD61F0000u -bor ($opc -shl 21) -bor ($Rn -shl 5))
}

function Read-A64Instruction {
    # Independent decode: classifies by the fixed opcode bits and extracts the
    # fields, without calling any encoder.
    param([Parameter(Mandatory)][uint32] $Word)

    if (($Word -band 0x7F800000) -eq 0x52800000) {
        return [pscustomobject]@{ Op = 'movz'; Is64 = [bool]($Word -shr 31); Hw = ($Word -shr 21) -band 3; Imm = ($Word -shr 5) -band 0xFFFF; Rd = $Word -band 31 }
    }
    if (($Word -band 0x7F800000) -eq 0x12800000) {
        return [pscustomobject]@{ Op = 'movn'; Is64 = [bool]($Word -shr 31); Hw = ($Word -shr 21) -band 3; Imm = ($Word -shr 5) -band 0xFFFF; Rd = $Word -band 31 }
    }
    if (($Word -band 0x7FE0FFE0) -eq 0x2A0003E0) {
        return [pscustomobject]@{ Op = 'mov'; Is64 = [bool]($Word -shr 31); Rm = ($Word -shr 16) -band 31; Rd = $Word -band 31 }
    }
    if (($Word -band 0x1F000000) -eq 0x10000000) {
        $raw = ((($Word -shr 5) -band 0x7FFFF) -shl 2) -bor (($Word -shr 29) -band 3)
        $imm = if ($raw -band 0x100000) { [long]$raw - 0x200000 } else { [long]$raw }
        return [pscustomobject]@{ Op = $(if ($Word -band 0x80000000u) { 'adrp' } else { 'adr' }); Imm = $imm; Rd = $Word -band 31 }
    }
    if (($Word -band 0xFFC00000u) -eq 0xF9400000u) {
        return [pscustomobject]@{ Op = 'ldr'; Offset = (($Word -shr 10) -band 0xFFF) * 8; Rn = ($Word -shr 5) -band 31; Rt = $Word -band 31 }
    }
    if (($Word -band 0xFFFFFC1Fu) -eq 0xD61F0000u) {
        return [pscustomobject]@{ Op = 'br'; Rn = ($Word -shr 5) -band 31 }
    }
    if (($Word -band 0xFFFFFC1Fu) -eq 0xD65F0000u) {
        return [pscustomobject]@{ Op = 'ret'; Rn = ($Word -shr 5) -band 31 }
    }
    throw ('Unrecognized A64 instruction 0x{0:X8}.' -f $Word)
}

function Get-A64StepLength {
    param([Parameter(Mandatory)] $Step)
    switch ($Step.Op) {
        'tail' { 12 }
        { $_ -in 'movz', 'movn', 'mov', 'ret', 'adr-data' } { 4 }
        default { throw "Unknown A64 step '$($Step.Op)'." }
    }
}

function New-A64Step {
    # Bytes for one step at Pc. Target is the GOT slot for 'tail' and the data
    # address for 'adr-data'. 'tail' is ADRP x16, LDR x16, BR x16.
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $words = switch ($Step.Op) {
        { $_ -in 'movz', 'movn' } { , [uint32[]]@(New-A64MovWide -Op $Step.Op -Rd $Step.Rd -Imm16 $Step.Imm -Is64 ([bool]$Step.Is64)) }
        'mov' { , [uint32[]]@(New-A64MovRegister -Rd $Step.Rd -Rm $Step.Rm -Is64 ([bool]$Step.Is64)) }
        'ret' { , [uint32[]]@(New-A64BranchRegister -Op ret) }
        'adr-data' { , [uint32[]]@(New-A64Adr -Op adr -Rd $Step.Rd -Imm21 ($Target - $Pc)) }
        'tail' {
            $pages = ([long]($Target -band -4096) - [long]($Pc -band -4096)) -shr 12
            , [uint32[]]@(
                (New-A64Adr -Op adrp -Rd 16 -Imm21 $pages),
                (New-A64LdrUnsigned -Rt 16 -Rn 16 -Offset ($Target -band 0xFFF)),
                (New-A64BranchRegister -Op br -Rn 16))
        }
        default { throw "Unknown A64 step '$($Step.Op)'." }
    }
    [byte[]]@($words | ForEach-Object { [BitConverter]::GetBytes([uint32]$_) } | ForEach-Object { $_ })
}

function Test-A64Step {
    # Decodes the step at Pc with Read-A64Instruction and checks it against the
    # intended step. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [string] $Name)
    $word = Read-A64Instruction -Word ([BitConverter]::ToUInt32($Image, [int]$Pc))
    $ok = switch ($Step.Op) {
        { $_ -in 'movz', 'movn' } { $word.Op -eq $Step.Op -and $word.Rd -eq $Step.Rd -and $word.Imm -eq $Step.Imm -and $word.Hw -eq 0 -and $word.Is64 -eq [bool]$Step.Is64 }
        'mov' { $word.Op -eq 'mov' -and $word.Rd -eq $Step.Rd -and $word.Rm -eq $Step.Rm -and $word.Is64 -eq [bool]$Step.Is64 }
        'ret' { $word.Op -eq 'ret' -and $word.Rn -eq 30 }
        'adr-data' { $word.Op -eq 'adr' -and $word.Rd -eq $Step.Rd -and ($Pc + $word.Imm) -eq $DataAt[$Step.Data] }
        'tail' {
            $w2 = Read-A64Instruction -Word ([BitConverter]::ToUInt32($Image, [int]$Pc + 4))
            $w3 = Read-A64Instruction -Word ([BitConverter]::ToUInt32($Image, [int]$Pc + 8))
            $slot = (($Pc -band -4096) + ($word.Imm -shl 12)) + $w2.Offset
            $word.Op -eq 'adrp' -and $word.Rd -eq 16 -and $w2.Op -eq 'ldr' -and $w2.Rn -eq 16 -and $w2.Rt -eq 16 -and
            $w3.Op -eq 'br' -and $w3.Rn -eq 16 -and $SlotImport[[long]$slot] -ceq $Step.Import
        }
    }
    if (-not $ok) { throw "$Name at ${Pc}: expected $($Step.Op), decoded $($word.Op)." }
    Get-A64StepLength -Step $Step
}

function New-PslNativeLibrary {
    # libpsl-native for Android. SMA's syslog provider calls the three
    # Native_*Log exports during startup; they forward to bionic, which routes
    # syslog to logcat. The remaining exports exist so every P/Invoke resolves;
    # they report failure until they are implemented. Export list: SMA
    # v7.7.0-preview.4 CorePsPlatform.cs, SysLogProvider.cs and
    # RunspaceConnectionInfo.cs.
    param([int] $PageSize = 16384)

    $ret0 = @(@{ Op = 'movz'; Rd = 0; Imm = 0; Is64 = $true }, @{ Op = 'ret' })
    $retMinus1 = @(@{ Op = 'movn'; Rd = 0; Imm = 0; Is64 = $true }, @{ Op = 'ret' })

    $functions = [ordered]@{
        # openlog(ident, LOG_NDELAY | LOG_PID, facility): LOG_PID 0x01, LOG_NDELAY 0x08.
        'Native_OpenLog'  = @(@{ Op = 'mov'; Rd = 2; Rm = 1; Is64 = $false }, @{ Op = 'movz'; Rd = 1; Imm = 0x9; Is64 = $false }, @{ Op = 'tail'; Import = 'openlog' })
        # syslog(priority, "%s", message)
        'Native_SysLog'   = @(@{ Op = 'mov'; Rd = 2; Rm = 1; Is64 = $true }, @{ Op = 'adr-data'; Rd = 1; Data = 'format' }, @{ Op = 'tail'; Import = 'syslog' })
        'Native_CloseLog' = @(@{ Op = 'tail'; Import = 'closelog' })
        'GetCurrentThreadId' = @(@{ Op = 'tail'; Import = 'gettid' })
        'GetErrorCategory'   = $ret0
        'GetPPid'            = $ret0
        'GetLinkCount'       = $retMinus1
        'IsExecutable'       = $ret0
        'KillProcess'        = $ret0
        'WaitPid'            = $retMinus1
        'SetDate'            = $retMinus1
        'CreateSymLink'      = $retMinus1
        'CreateHardLink'     = $retMinus1
        'GetUserFromPid'     = $ret0
        'IsSameFileSystemItem' = $ret0
        'GetInodeData'       = $retMinus1
        'GetCommonLStat'     = $retMinus1
        'GetCommonStat'      = $retMinus1
        'GetPwUid'           = $ret0
        'GetGrGid'           = $ret0
        'ForkAndExecProcess' = $retMinus1
    }
    $data = [ordered]@{ format = [System.Text.Encoding]::ASCII.GetBytes("%s`0") }

    $library = New-ElfCodeLibrary -Soname 'libpsl-native.so' -Needed @('libc.so') -Functions $functions -Data $data -PageSize $PageSize
    $report = Test-ElfCodeLibrary -Library $library
    [pscustomobject]@{ Library = $library; Report = $report }
}

# ==============================================================================
# x86-64 machine code
#
# The x86-64 section, kept separate from the AArch64 one. Named encoders for the
# few instructions the shims use, an independent decoder, and the step encoder and
# verifier the shared ELF writer and reader call. Register numbers: eax 0, ecx 1, edx 2,
# ebx 3, esp 4, ebp 5, esi 6, edi 7. System V AMD64 arguments: rdi, rsi, rdx,
# rcx, r8, r9; return in rax; al holds the vector-argument count for varargs.
# ==============================================================================

function Get-X64ModRm {
    param([ValidateRange(0, 3)][int] $Mod, [ValidateRange(0, 7)][int] $Reg, [ValidateRange(0, 7)][int] $Rm)
    [byte](($Mod -shl 6) -bor ($Reg -shl 3) -bor $Rm)
}

function New-X64Instruction {
    # Returns the bytes for one step. RIP-relative forms take the distance from
    # the end of the instruction.
    param([Parameter(Mandatory)] $Step, [long] $RipDisplacement = 0)
    $imm32 = { param([long] $v) [BitConverter]::GetBytes([int32]$v) }
    switch ($Step.Op) {
        'mov32'     { return [byte[]]@(0x89, (Get-X64ModRm 3 $Step.Src $Step.Dst)) }
        'mov64'     { return [byte[]]@(0x48, 0x89, (Get-X64ModRm 3 $Step.Src $Step.Dst)) }
        'movimm32'  { return [byte[]](@([byte](0xB8 + $Step.Dst)) + (& $imm32 $Step.Imm)) }
        'movimm64s' { return [byte[]](@(0x48, 0xC7, (Get-X64ModRm 3 0 $Step.Dst)) + (& $imm32 $Step.Imm)) }
        'xor32'     { return [byte[]]@(0x31, (Get-X64ModRm 3 $Step.Dst $Step.Dst)) }
        'lea-data'  { return [byte[]](@(0x48, 0x8D, (Get-X64ModRm 0 $Step.Dst 5)) + (& $imm32 $RipDisplacement)) }
        'ret'       { return [byte[]]@(0xC3) }
        'tail'      { return [byte[]](@(0xFF, (Get-X64ModRm 0 4 5)) + (& $imm32 $RipDisplacement)) }
        default     { throw "Unknown x86-64 step '$($Step.Op)'." }
    }
}

function Get-X64StepLength {
    param([Parameter(Mandatory)] $Step)
    switch ($Step.Op) {
        'mov32' { 2 } 'mov64' { 3 } 'movimm32' { 5 } 'movimm64s' { 7 }
        'xor32' { 2 } 'lea-data' { 7 } 'ret' { 1 } 'tail' { 6 }
        default { throw "Unknown x86-64 step '$($Step.Op)'." }
    }
}

function Read-X64Instruction {
    # Independent decode of the forms above, from the opcode and ModRM bytes.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $At)
    $b0 = $Image[$At]
    $disp = { param([long] $o) [BitConverter]::ToInt32($Image, [int]$o) }
    $modrm = { param([byte] $m) [pscustomobject]@{ Mod = $m -shr 6; Reg = ($m -shr 3) -band 7; Rm = $m -band 7 } }
    if ($b0 -eq 0x48) {
        $b1 = $Image[$At + 1]; $m = & $modrm $Image[$At + 2]
        if ($b1 -eq 0x89 -and $m.Mod -eq 3) { return [pscustomobject]@{ Op = 'mov64'; Dst = $m.Rm; Src = $m.Reg; Length = 3 } }
        if ($b1 -eq 0xC7 -and $m.Mod -eq 3 -and $m.Reg -eq 0) { return [pscustomobject]@{ Op = 'movimm64s'; Dst = $m.Rm; Imm = (& $disp ($At + 3)); Length = 7 } }
        if ($b1 -eq 0x8D -and $m.Mod -eq 0 -and $m.Rm -eq 5) { return [pscustomobject]@{ Op = 'lea-rip'; Dst = $m.Reg; Disp = (& $disp ($At + 3)); Length = 7 } }
    }
    if ($b0 -eq 0x89) { $m = & $modrm $Image[$At + 1]; if ($m.Mod -eq 3) { return [pscustomobject]@{ Op = 'mov32'; Dst = $m.Rm; Src = $m.Reg; Length = 2 } } }
    if ($b0 -ge 0xB8 -and $b0 -le 0xBF) { return [pscustomobject]@{ Op = 'movimm32'; Dst = $b0 - 0xB8; Imm = (& $disp ($At + 1)); Length = 5 } }
    if ($b0 -eq 0x31) { $m = & $modrm $Image[$At + 1]; if ($m.Mod -eq 3) { return [pscustomobject]@{ Op = 'xor32'; Dst = $m.Rm; Src = $m.Reg; Length = 2 } } }
    if ($b0 -eq 0xC3) { return [pscustomobject]@{ Op = 'ret'; Length = 1 } }
    if ($b0 -eq 0xFF) { $m = & $modrm $Image[$At + 1]; if ($m.Mod -eq 0 -and $m.Reg -eq 4 -and $m.Rm -eq 5) { return [pscustomobject]@{ Op = 'jmp-rip'; Disp = (& $disp ($At + 2)); Length = 6 } } }
    throw ('Unrecognized x86-64 instruction at {0}: 0x{1:X2}.' -f $At, $b0)
}

function New-X64Step {
    # Bytes for one step at Pc. RIP-relative forms take the distance from the
    # end of the instruction to Target.
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $next = $Pc + (Get-X64StepLength -Step $Step)
    $displacement = if ($Step.Op -in 'tail', 'lea-data') { $Target - $next } else { 0 }
    # @() keeps a one-byte instruction an array; PowerShell unrolls it otherwise.
    [byte[]]@(New-X64Instruction -Step $Step -RipDisplacement $displacement)
}

function Test-X64Step {
    # Decodes the step at Pc with Read-X64Instruction and checks it against the
    # intended step. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [string] $Name)
    $d = Read-X64Instruction -Image $Image -At $Pc
    $next = $Pc + $d.Length
    $ok = switch ($Step.Op) {
        'mov32'     { $d.Op -eq 'mov32' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Src }
        'mov64'     { $d.Op -eq 'mov64' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Src }
        'movimm32'  { $d.Op -eq 'movimm32' -and $d.Dst -eq $Step.Dst -and $d.Imm -eq $Step.Imm }
        'movimm64s' { $d.Op -eq 'movimm64s' -and $d.Dst -eq $Step.Dst -and $d.Imm -eq $Step.Imm }
        'xor32'     { $d.Op -eq 'xor32' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Dst }
        'lea-data'  { $d.Op -eq 'lea-rip' -and $d.Dst -eq $Step.Dst -and ($next + $d.Disp) -eq $DataAt[$Step.Data] }
        'ret'       { $d.Op -eq 'ret' }
        'tail'      { $d.Op -eq 'jmp-rip' -and $SlotImport[[long]($next + $d.Disp)] -ceq $Step.Import }
    }
    if (-not $ok) { throw "$Name at ${Pc}: expected $($Step.Op), decoded $($d.Op)." }
    $d.Length
}

function New-PslNativeLibraryX64 {
    # The x86-64 libpsl-native. Same export set and behavior as the AArch64 one.
    # Native_SysLog passes a fixed "%s" so '%' in messages is data, and sets
    # al = 0 because syslog is variadic.
    param([int] $PageSize = 16384)

    $eax = 0; $edx = 2; $esi = 6
    $ret0 = @(@{ Op = 'xor32'; Dst = $eax }, @{ Op = 'ret' })
    $retMinus1 = @(@{ Op = 'movimm64s'; Dst = $eax; Imm = -1 }, @{ Op = 'ret' })

    $functions = [ordered]@{
        # openlog(ident, LOG_NDELAY | LOG_PID, facility): rdi stays, esi = 0x9, edx = facility.
        'Native_OpenLog'  = @(@{ Op = 'mov32'; Dst = $edx; Src = $esi }, @{ Op = 'movimm32'; Dst = $esi; Imm = 0x9 }, @{ Op = 'tail'; Import = 'openlog' })
        # syslog(priority, "%s", message): edi stays, rdx = message, rsi = &"%s", al = 0.
        'Native_SysLog'   = @(@{ Op = 'mov64'; Dst = $edx; Src = $esi }, @{ Op = 'lea-data'; Dst = $esi; Data = 'format' }, @{ Op = 'xor32'; Dst = $eax }, @{ Op = 'tail'; Import = 'syslog' })
        'Native_CloseLog' = @(@{ Op = 'tail'; Import = 'closelog' })
        'GetCurrentThreadId' = @(@{ Op = 'tail'; Import = 'gettid' })
        'GetErrorCategory'   = $ret0
        'GetPPid'            = $ret0
        'GetLinkCount'       = $retMinus1
        'IsExecutable'       = $ret0
        'KillProcess'        = $ret0
        'WaitPid'            = $retMinus1
        'SetDate'            = $retMinus1
        'CreateSymLink'      = $retMinus1
        'CreateHardLink'     = $retMinus1
        'GetUserFromPid'     = $ret0
        'IsSameFileSystemItem' = $ret0
        'GetInodeData'       = $retMinus1
        'GetCommonLStat'     = $retMinus1
        'GetCommonStat'      = $retMinus1
        'GetPwUid'           = $ret0
        'GetGrGid'           = $ret0
        'ForkAndExecProcess' = $retMinus1
    }
    $data = [ordered]@{ format = [System.Text.Encoding]::ASCII.GetBytes("%s`0") }

    $library = New-ElfCodeLibrary -Soname 'libpsl-native.so' -Needed @('libc.so') -Functions $functions -Data $data -PageSize $PageSize
    $report = Test-ElfCodeLibrary -Library $library
    [pscustomobject]@{ Library = $library; Report = $report }
}

# ==============================================================================
# ARM32 machine code
#
# The ARM32 section, kept separate from the AArch64 and x86-64 ones. A32
# (ARM-state) encodings for the few instructions the shims use, an independent
# decoder, and the step encoder and verifier the shared ELF writer and reader call. Every instruction
# carries condition AL (0xE). Field layouts follow the Arm A-profile
# architecture reference (A32 data-processing, load/store and branch). The
# working predecessor libpsl-native, built by NDK clang, uses the same
# encodings for bx lr (E12FFF1E) and for loads into pc.
#
# Calling convention: AAPCS with soft-float argument passing (lib/ARM.cpp,
# arm::getDefaultFloatABI returns SoftFP for Android). Arguments r0-r3, return
# in r0, lr holds the return address, ip (r12) is free to clobber in a veneer.
# Variadic calls such as syslog take no extra setup.
# ==============================================================================

function Get-A32ModifiedImmediate {
    # An A32 data-processing immediate is imm8 rotated right by 2 * rot. Returns
    # the 12-bit field (rot << 8 | imm8), or throws if the value has no encoding.
    param([Parameter(Mandatory)][uint32] $Value)
    for ($rot = 0; $rot -lt 16; $rot++) {
        $shift = 2 * $rot
        $rolled = if ($shift -eq 0) { [uint64]$Value } else { (([uint64]$Value -shl $shift) -bor ([uint64]$Value -shr (32 - $shift))) -band 0xFFFFFFFFL }
        if ($rolled -le 0xFF) { return [uint32](($rot -shl 8) -bor $rolled) }
    }
    throw ('0x{0:X8} has no A32 modified-immediate encoding.' -f $Value)
}

function Get-A32ImmediateValue {
    param([Parameter(Mandatory)][uint32] $Field)
    $imm8 = [uint64]($Field -band 0xFF)
    $shift = 2 * (($Field -shr 8) -band 0xF)
    if ($shift -eq 0) { return [uint32]$imm8 }
    [uint32]((($imm8 -shr $shift) -bor ($imm8 -shl (32 - $shift))) -band 0xFFFFFFFFL)
}

function New-A32Instruction {
    # Returns the words for one step. 'tail' is a four-word position-independent
    # jump through a GOT slot: ldr ip, [pc, #4]; add ip, pc, ip; ldr pc, [ip];
    # then a literal holding the slot's distance from the add's pc (add + 8).
    # A load into pc interworks on ARMv7, so the import may be Thumb code.
    # PcRelative is the target minus the value pc reads as for the step.
    param([Parameter(Mandatory)] $Step, [long] $PcRelative = 0)
    $al = 0xE0000000u
    switch ($Step.Op) {
        'mov'     { return [uint32[]]@($al -bor 0x01A00000 -bor ($Step.Rd -shl 12) -bor $Step.Rm) }
        'movimm'  { return [uint32[]]@($al -bor 0x03A00000 -bor ($Step.Rd -shl 12) -bor (Get-A32ModifiedImmediate $Step.Imm)) }
        'mvnimm'  { return [uint32[]]@($al -bor 0x03E00000 -bor ($Step.Rd -shl 12) -bor (Get-A32ModifiedImmediate $Step.Imm)) }
        'adr-data' {
            if ($PcRelative -ge 0) { return [uint32[]]@($al -bor 0x028F0000 -bor ($Step.Rd -shl 12) -bor (Get-A32ModifiedImmediate ([uint32]$PcRelative))) }
            return [uint32[]]@($al -bor 0x024F0000 -bor ($Step.Rd -shl 12) -bor (Get-A32ModifiedImmediate ([uint32](-$PcRelative))))
        }
        'bx'      { return [uint32[]]@($al -bor 0x012FFF10 -bor $Step.Rm) }
        'tail'    {
            if ($PcRelative -lt [int32]::MinValue -or $PcRelative -gt [int32]::MaxValue) { throw 'GOT slot out of 32-bit range.' }
            return [uint32[]]@(
                ($al -bor 0x059FC004),                         # ldr ip, [pc, #4]
                ($al -bor 0x008FC00C),                         # add ip, pc, ip
                ($al -bor 0x059CF000),                         # ldr pc, [ip]
                [uint32]([int32]$PcRelative -band 0xFFFFFFFFL)) # literal
        }
        default   { throw "Unknown ARM32 step '$($Step.Op)'." }
    }
}

function Get-A32StepLength {
    param([Parameter(Mandatory)] $Step)
    switch ($Step.Op) {
        'tail' { 16 }
        { $_ -in 'mov', 'movimm', 'mvnimm', 'adr-data', 'bx' } { 4 }
        default { throw "Unknown ARM32 step '$($Step.Op)'." }
    }
}

function Get-A32PcBias {
    # Where the pc-relative distance is measured from, relative to the step's
    # first word: pc reads as the instruction address plus 8. For 'tail' the
    # pc-relative instruction is the add, the second word.
    param([Parameter(Mandatory)] $Step)
    if ($Step.Op -eq 'tail') { return 12 }
    8
}

function Read-A32Instruction {
    # Independent decode of the forms above, from the fixed opcode bits.
    param([Parameter(Mandatory)][uint32] $Word)
    if (($Word -shr 28) -ne 0xE) { throw ('A32 word 0x{0:X8} is not condition AL.' -f $Word) }
    $rd = ($Word -shr 12) -band 0xF
    if (($Word -band 0x0FFF0FF0) -eq 0x01A00000) { return [pscustomobject]@{ Op = 'mov'; Rd = $rd; Rm = $Word -band 0xF } }
    if (($Word -band 0x0FFF0000) -eq 0x03A00000) { return [pscustomobject]@{ Op = 'movimm'; Rd = $rd; Imm = (Get-A32ImmediateValue ($Word -band 0xFFF)) } }
    if (($Word -band 0x0FFF0000) -eq 0x03E00000) { return [pscustomobject]@{ Op = 'mvnimm'; Rd = $rd; Imm = (Get-A32ImmediateValue ($Word -band 0xFFF)) } }
    if (($Word -band 0x0FFF0000) -eq 0x028F0000) { return [pscustomobject]@{ Op = 'adr'; Rd = $rd; Offset = [long](Get-A32ImmediateValue ($Word -band 0xFFF)) } }
    if (($Word -band 0x0FFF0000) -eq 0x024F0000) { return [pscustomobject]@{ Op = 'adr'; Rd = $rd; Offset = -[long](Get-A32ImmediateValue ($Word -band 0xFFF)) } }
    if (($Word -band 0x0FFFFFF0) -eq 0x012FFF10) { return [pscustomobject]@{ Op = 'bx'; Rm = $Word -band 0xF } }
    if (($Word -band 0x0FF00FF0) -eq 0x00800000) { return [pscustomobject]@{ Op = 'add'; Rd = $rd; Rn = ($Word -shr 16) -band 0xF; Rm = $Word -band 0xF } }
    if (($Word -band 0x0FF00000) -eq 0x05900000) { return [pscustomobject]@{ Op = 'ldr'; Rt = $rd; Rn = ($Word -shr 16) -band 0xF; Offset = $Word -band 0xFFF } }
    throw ('Unrecognized A32 instruction 0x{0:X8}.' -f $Word)
}

function New-A32Step {
    # Bytes for one step at Pc. The pc-relative distance is measured from the
    # value pc reads as (Get-A32PcBias).
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $relative = if ($Step.Op -in 'tail', 'adr-data') { $Target - ($Pc + (Get-A32PcBias -Step $Step)) } else { 0 }
    $words = [uint32[]]@(New-A32Instruction -Step $Step -PcRelative $relative)
    [byte[]]@($words | ForEach-Object { [BitConverter]::GetBytes([uint32]$_) } | ForEach-Object { $_ })
}

function Test-A32Step {
    # Decodes the step at Pc with Read-A32Instruction and checks it against the
    # intended step. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [string] $Name)
    $u32 = { param([long] $At) [BitConverter]::ToUInt32($Image, [int]$At) }
    $d = Read-A32Instruction -Word (& $u32 $Pc)
    $ok = switch ($Step.Op) {
        'mov'      { $d.Op -eq 'mov' -and $d.Rd -eq $Step.Rd -and $d.Rm -eq $Step.Rm }
        'movimm'   { $d.Op -eq 'movimm' -and $d.Rd -eq $Step.Rd -and $d.Imm -eq [uint32]$Step.Imm }
        'mvnimm'   { $d.Op -eq 'mvnimm' -and $d.Rd -eq $Step.Rd -and $d.Imm -eq [uint32]$Step.Imm }
        'adr-data' { $d.Op -eq 'adr' -and $d.Rd -eq $Step.Rd -and ($Pc + 8 + $d.Offset) -eq $DataAt[$Step.Data] }
        'bx'       { $d.Op -eq 'bx' -and $d.Rm -eq $Step.Rm }
        'tail'     {
            $add = Read-A32Instruction -Word (& $u32 ($Pc + 4))
            $jump = Read-A32Instruction -Word (& $u32 ($Pc + 8))
            $literalAt = $Pc + 8 + $d.Offset
            $slot = ($Pc + 4 + 8) + [long][BitConverter]::ToInt32($Image, [int]$literalAt)
            $d.Op -eq 'ldr' -and $d.Rt -eq 12 -and $d.Rn -eq 15 -and $literalAt -eq ($Pc + 12) -and
            $add.Op -eq 'add' -and $add.Rd -eq 12 -and $add.Rn -eq 15 -and $add.Rm -eq 12 -and
            $jump.Op -eq 'ldr' -and $jump.Rt -eq 15 -and $jump.Rn -eq 12 -and $jump.Offset -eq 0 -and
            $SlotImport[[long]$slot] -ceq $Step.Import
        }
    }
    if (-not $ok) { throw "$Name at ${Pc}: expected $($Step.Op), decoded $($d.Op)." }
    Get-A32StepLength -Step $Step
}

function New-PslNativeLibraryArm32 {
    # The ARM32 libpsl-native. Same export set and behavior as the AArch64 and
    # x86-64 ones. Native_SysLog passes a fixed "%s" so '%' in messages is data.
    param([int] $PageSize = 16384)

    $r0 = 0; $r1 = 1; $r2 = 2; $lr = 14
    $ret0 = @(@{ Op = 'movimm'; Rd = $r0; Imm = 0 }, @{ Op = 'bx'; Rm = $lr })
    $retMinus1 = @(@{ Op = 'mvnimm'; Rd = $r0; Imm = 0 }, @{ Op = 'bx'; Rm = $lr })

    $functions = [ordered]@{
        # openlog(ident, LOG_NDELAY | LOG_PID, facility): r0 stays, r2 = facility, r1 = 0x9.
        'Native_OpenLog'  = @(@{ Op = 'mov'; Rd = $r2; Rm = $r1 }, @{ Op = 'movimm'; Rd = $r1; Imm = 0x9 }, @{ Op = 'tail'; Import = 'openlog' })
        # syslog(priority, "%s", message): r0 stays, r2 = message, r1 = &"%s".
        'Native_SysLog'   = @(@{ Op = 'mov'; Rd = $r2; Rm = $r1 }, @{ Op = 'adr-data'; Rd = $r1; Data = 'format' }, @{ Op = 'tail'; Import = 'syslog' })
        'Native_CloseLog' = @(@{ Op = 'tail'; Import = 'closelog' })
        'GetCurrentThreadId' = @(@{ Op = 'tail'; Import = 'gettid' })
        'GetErrorCategory'   = $ret0
        'GetPPid'            = $ret0
        'GetLinkCount'       = $retMinus1
        'IsExecutable'       = $ret0
        'KillProcess'        = $ret0
        'WaitPid'            = $retMinus1
        'SetDate'            = $retMinus1
        'CreateSymLink'      = $retMinus1
        'CreateHardLink'     = $retMinus1
        'GetUserFromPid'     = $ret0
        'IsSameFileSystemItem' = $ret0
        'GetInodeData'       = $retMinus1
        'GetCommonLStat'     = $retMinus1
        'GetCommonStat'      = $retMinus1
        'GetPwUid'           = $ret0
        'GetGrGid'           = $ret0
        'ForkAndExecProcess' = $retMinus1
    }
    $data = [ordered]@{ format = [System.Text.Encoding]::ASCII.GetBytes("%s`0") }

    $library = New-ElfCodeLibrary -Soname 'libpsl-native.so' -Needed @('libc.so') -Functions $functions -Data $data -PageSize $PageSize
    $report = Test-ElfCodeLibrary -Library $library
    [pscustomobject]@{ Library = $library; Report = $report }
}

function Skip-ForNativeAdmission {
    # True when the NativeActivity admission build does not use this step's
    # output. The step still runs in its place in the graph and says so.
    param([Parameter(Mandatory)][int] $Step, [Parameter(Mandatory)][string] $Output)
    if ($Admission -ne 'NativeActivity') { return $false }
    Write-Host ('[PASS] Step {0} skipped: {1} is not part of NativeActivity admission.' -f $Step, $Output) -ForegroundColor Green
    $true
}

function Get-AndroidLogPriority {
    # A value of the android_LogPriority enum in lib/log.h. The enumerators are
    # implicit, so apply C's rule: each is the previous value plus one, unless
    # it is assigned.
    param([Parameter(Mandatory)][string] $Name)
    $text = Import-LibSourceText -Path 'log.h'
    $match = [regex]::Match($text, 'typedef enum android_LogPriority \{(.*?)\}', 'Singleline')
    if (-not $match.Success) { throw 'log.h does not declare android_LogPriority.' }
    $body = [regex]::Replace($match.Groups[1].Value, '/\*.*?\*/', '', 'Singleline')
    $next = 0
    foreach ($entry in ($body -split ',')) {
        $item = $entry.Trim()
        if (-not $item) { continue }
        $parts = $item -split '\s*=\s*'
        $value = if ($parts.Count -gt 1) { [int]$parts[1] } else { $next }
        if ($parts[0] -ceq $Name) { return $value }
        $next = $value + 1
    }
    throw "log.h declares no $Name."
}

function New-NativeHostLibrary {
    # Gate 1: libpwsh-host.so. ANativeActivity_onCreate (lib/native_activity.h)
    # makes one __android_log_write(ANDROID_LOG_INFO, tag, text) call
    # (lib/log.h) as a tail call and returns. The activity argument is unused.
    param([int] $PageSize = 16384)

    $info = Get-AndroidLogPriority -Name 'ANDROID_LOG_INFO'
    $steps = switch ($Architecture) {
        'arm64' { @(@{ Op = 'movz'; Rd = 0; Imm = $info; Is64 = $false }, @{ Op = 'adr-data'; Rd = 1; Data = 'tag' }, @{ Op = 'adr-data'; Rd = 2; Data = 'text' }, @{ Op = 'tail'; Import = '__android_log_write' }) }
        'x64'   { @(@{ Op = 'movimm32'; Dst = 7; Imm = $info }, @{ Op = 'lea-data'; Dst = 6; Data = 'tag' }, @{ Op = 'lea-data'; Dst = 2; Data = 'text' }, @{ Op = 'tail'; Import = '__android_log_write' }) }
        'arm32' { @(@{ Op = 'movimm'; Rd = 0; Imm = $info }, @{ Op = 'adr-data'; Rd = 1; Data = 'tag' }, @{ Op = 'adr-data'; Rd = 2; Data = 'text' }, @{ Op = 'tail'; Import = '__android_log_write' }) }
        default { throw "No native host section for $Architecture." }
    }
    $functions = [ordered]@{ 'ANativeActivity_onCreate' = $steps }
    $data = [ordered]@{
        tag  = [System.Text.Encoding]::ASCII.GetBytes("Pwsh`0")
        text = [System.Text.Encoding]::ASCII.GetBytes("GATE1 ANativeActivity_onCreate`0")
    }
    $library = New-ElfCodeLibrary -Soname 'libpwsh-host.so' -Needed @('liblog.so') -Functions $functions -Data $data -PageSize $PageSize
    $report = Test-ElfCodeLibrary -Library $library
    [pscustomobject]@{ Library = $library; Report = $report }
}

function Assert-NativeAdmissionApk {
    # Gate 1 proves absence as well as success, from parsed structures: the
    # archive's own entry names, the manifest's elements and string pool, and
    # the host library's dynamic section.
    param([Parameter(Mandatory)][string[]] $EntryNames)

    $abi = $script:Target.Abi
    $forbidden = @($EntryNames | Where-Object { $_ -like '*.dex' -or $_ -like '*/libmonodroid.so' -or $_ -like '*/libxamarin-app.so' -or $_ -like '*/libassembly-store.so' })
    if ($forbidden.Count) { throw "The NativeActivity APK carries Xamarin or DEX entries: $($forbidden -join ', ')" }
    if ("lib/$abi/libpwsh-host.so" -notin $EntryNames) { throw "The NativeActivity APK lacks lib/$abi/libpwsh-host.so." }

    $manifest = Test-BinaryAxml -Document ([byte[]]$script:BuildContext.AndroidManifest.Bytes)
    if (@($manifest.Elements | Where-Object Name -eq 'provider').Count) { throw 'The NativeActivity manifest declares a provider.' }
    if (@($manifest.Strings | Where-Object { $_ -like '*MonoRuntimeProvider*' }).Count) { throw 'The NativeActivity manifest string pool names MonoRuntimeProvider.' }
    $application = @($manifest.Elements | Where-Object Name -eq 'application')[0]
    if ($application.Attributes['hasCode'] -ne 0) { throw 'The NativeActivity manifest does not set android:hasCode="false".' }
    $activity = @($manifest.Elements | Where-Object Name -eq 'activity')
    if ($activity.Count -ne 1 -or $activity[0].Attributes['name'] -cne 'android.app.NativeActivity') { throw 'The manifest activity is not android.app.NativeActivity.' }
    $libName = @($manifest.Elements | Where-Object { $_.Name -eq 'meta-data' -and $_.Attributes['name'] -ceq 'android.app.lib_name' })
    if ($libName.Count -ne 1 -or $libName[0].Attributes['value'] -cne 'pwsh-host') { throw 'The manifest does not name pwsh-host as android.app.lib_name.' }

    $library = Read-ElfImage -Image ([byte[]]$script:BuildContext.NativeHost.Bytes)
    if ((@($library.Needed) -join ',') -cne 'liblog.so') { throw "libpwsh-host.so needs $(@($library.Needed) -join ', '); only liblog.so is allowed." }
    if (-not $library.Resolved.ContainsKey('ANativeActivity_onCreate')) { throw 'libpwsh-host.so does not export ANativeActivity_onCreate.' }

    Write-Host ('[PASS] NativeActivity admission: {0} entries, none DEX or Xamarin; manifest has no provider, hasCode=false, android.app.NativeActivity with lib_name pwsh-host; libpwsh-host.so needs only liblog.so.' -f
        $EntryNames.Count) -ForegroundColor Green
}

function Invoke-NativeStep {

    if ($Admission -eq 'NativeActivity') {
        $pageSize = [int](Get-AndroidNativeContract).elf.maxPageSize
        $nativeHost = New-NativeHostLibrary -PageSize $pageSize
        $hostPath = Join-Path (Join-Path $OutputDirectory $script:Target.Abi) 'libpwsh-host.so'
        if ($PSCmdlet.ShouldProcess($hostPath, 'Write libpwsh-host')) {
            Write-BuildFile -Intermediate -Path $hostPath -Bytes $nativeHost.Library.Bytes
        }
        $script:BuildContext.NativeHost = [pscustomobject]@{ Path = $hostPath; Bytes = $nativeHost.Library.Bytes }
        Write-Host ('[PASS] Step 6 complete: libpwsh-host.so emitted as {0} bytes exporting ANativeActivity_onCreate, one liblog import through a BIND_NOW GOT, {1} instructions decoded back and checked.' -f
            $nativeHost.Report.ImageSize, $nativeHost.Report.Steps) -ForegroundColor Green
        return
    }

    $contract = Get-AndroidNativeContract
    $storeBytes = [byte[]]$script:BuildContext.AssemblyStore.Bytes
    $soname = [string]$contract.elf.storeLibraryName
    $symbol = [string]$contract.elf.payloadSymbol
    $pageSize = [int]$contract.elf.maxPageSize

    $expectedMachine = [uint32]$contract.elf.machine
    # The contract describes the arm64 producer; other targets take their machine from ELF.h.
    if ($Architecture -eq 'arm64' -and (Get-ElfConstants)['EM_AARCH64'] -ne $expectedMachine) {
        throw "The contract targets machine $expectedMachine; ELF.h declares EM_AARCH64 as $((Get-ElfConstants)['EM_AARCH64'])."
    }

    $library = New-ElfPayloadLibrary -Soname $soname -SymbolName $symbol -Payload $storeBytes -PageSize $pageSize
    $report = Test-ElfPayloadLibrary -Library $library -Payload $storeBytes

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($outputDirectory, 'Create native output directory')) {
            New-ApprovedDirectory -Path $outputDirectory
        }
    }
    $libraryPath = Join-Path $outputDirectory $soname
    if ($PSCmdlet.ShouldProcess($libraryPath, 'Write assembly store library')) {
        Write-BuildFile -Intermediate -Path $libraryPath -Bytes $library.Bytes
    }

    $libraryStream = [System.IO.MemoryStream]::new([byte[]]$library.Bytes, $false)
    try { $libraryHash = Get-Sha256Hex -Stream $libraryStream }
    finally { $libraryStream.Dispose() }

    $script:BuildContext.StoreLibrary = [pscustomobject]@{
        Path   = $libraryPath
        Bytes  = $library.Bytes
        Sha256 = $libraryHash
    }

    # libpsl-native: SMA resolves it by name during startup logging.
    $psl = switch ($Architecture) {
        'arm64' { New-PslNativeLibrary -PageSize $pageSize }
        'x64'   { New-PslNativeLibraryX64 -PageSize $pageSize }
        'arm32' { New-PslNativeLibraryArm32 -PageSize $pageSize }
        default { throw "No libpsl-native section for $Architecture." }
    }
    $pslPath = Join-Path $outputDirectory 'libpsl-native.so'
    if ($PSCmdlet.ShouldProcess($pslPath, 'Write libpsl-native')) {
        Write-BuildFile -Intermediate -Path $pslPath -Bytes $psl.Library.Bytes
    }
    $script:BuildContext.PslNative = [pscustomobject]@{ Path = $pslPath; Bytes = $psl.Library.Bytes }
    Write-Host ('[PASS] libpsl-native.so emitted: {0} bytes, {1} exports, {2} libc imports through a BIND_NOW GOT, {3} instructions decoded back and checked.' -f
        $psl.Report.ImageSize, $psl.Report.Exports, $psl.Report.Imports, $psl.Report.Steps) -ForegroundColor Green

    Write-Host (('[PASS] Step 6 complete: {0} emitted as an ' + $script:Target.Machine + ' ET_DYN image of {1} bytes, carrying the store at offset {2} under the ''{3}'' symbol with {4} bytes of ELF overhead. Resolved through the emitted hash table exactly as dlsym would. SHA-256 {5}') -f
        $soname,
        $report.ImageSize,
        $report.PayloadOffset,
        $symbol,
        $report.Overhead,
        $libraryHash) -ForegroundColor Green
}

$script:Crc64JonesTable = $null

function Get-Crc64JonesTable {
    if ($null -ne $script:Crc64JonesTable) { return $script:Crc64JonesTable }

    # CRC-64/Jones, reflected. The polynomial is the reversed form of
    # 0xad93d23594c935a9, which is the constant dotnet/java-interop documents.
    $polynomial = [Convert]::ToUInt64('95AC9329AC4BC9B5', 16)
    $table = New-Object uint64[] 256
    for ($i = 0; $i -lt 256; $i++) {
        [uint64] $value = $i
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($value -band 1UL) -ne 0UL) { $value = ($value -shr 1) -bxor $polynomial }
            else { $value = $value -shr 1 }
        }
        $table[$i] = $value
    }
    $script:Crc64JonesTable = $table
    return $script:Crc64JonesTable
}

function Get-JavaPeerPackage {
    # .NET Android names a generated Java peer's package
    # "crc64" + hex(Crc64.Compute(namespace + ":" + assemblyName)), where
    # Crc64 starts at ulong.MaxValue and exclusive-ors the byte count into the
    # final value before taking its little-endian bytes. Reproduced from
    # Crc64.cs and JavaNativeTypeManager.cs, and checked against a known
    # mapping emitted by a real build:
    #
    #   Terminal.ReferenceBuild:Terminal.Reference -> crc649e75029c1a6609a5
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Namespace,
        [Parameter(Mandatory)][string] $AssemblyName
    )

    $table = Get-Crc64JonesTable
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("${Namespace}:${AssemblyName}")
    [uint64] $crc = [uint64]::MaxValue
    foreach ($byte in $bytes) {
        $crc = $table[[int](($crc -bxor $byte) -band 0xFF)] -bxor ($crc -shr 8)
    }
    $crc = $crc -bxor ([uint64]$bytes.Length)
    return 'crc64' + ([Convert]::ToHexString([BitConverter]::GetBytes($crc))).ToLowerInvariant()
}

function Test-AndroidAttributeIds {
    # The binary XML emitter carries a table of android: attribute names and the
    # resource ids they resolve to. Those ids are declarations in the framework's
    # public-final.xml, so rather than trusting the table, check it. A wrong id
    # produces a manifest that installs and then behaves incorrectly, which is
    # worse than one that fails to build.
    $text = Import-LibSourceText -Path 'public-final.xml'
    $expected = [ordered]@{
        'theme' = 0x01010000; 'label' = 0x01010001; 'icon' = 0x01010002
        'name' = 0x01010003; 'hasCode' = 0x0101000C; 'exported' = 0x01010010; 'authorities' = 0x01010018
        'initOrder' = 0x0101001A; 'launchMode' = 0x0101001D; 'value' = 0x01010024
        'resource' = 0x01010025; 'drawable' = 0x01010199; 'minSdkVersion' = 0x0101020C
        'versionCode' = 0x0101021B; 'versionName' = 0x0101021C
        'targetSdkVersion' = 0x01010270; 'allowBackup' = 0x01010280
        'required' = 0x0101028E; 'inset' = 0x010104B5; 'extractNativeLibs' = 0x010104EA
        'roundIcon' = 0x0101052C; 'compileSdkVersion' = 0x01010572
        'compileSdkVersionCodename' = 0x01010573
    }

    foreach ($name in $expected.Keys) {
        $match = [regex]::Match($text, "<public type=`"attr`" name=`"$name`" id=`"0x([0-9a-fA-F]+)`"")
        if (-not $match.Success) {
            throw "public-final.xml does not declare the attribute 'android:$name'."
        }
        $declared = [Convert]::ToUInt32($match.Groups[1].Value, 16)
        if ($declared -ne [uint32]$expected[$name]) {
            throw ('android:{0} is 0x{1:X8} upstream but this build uses 0x{2:X8}.' -f $name, $declared, $expected[$name])
        }
    }
    return $expected.Count
}
function Test-JavaPeerNaming {
    # The derivation above is only trustworthy because this agrees with the
    # acw-map.txt a real .NET Android build produced.
    $known = Get-JavaPeerPackage -Namespace 'Terminal.ReferenceBuild' -AssemblyName 'Terminal.Reference'
    if ($known -cne 'crc649e75029c1a6609a5') {
        throw "Java peer naming is wrong: 'Terminal.ReferenceBuild:Terminal.Reference' produced '$known'."
    }
}

function Write-Uleb128 {
    param(
        [Parameter(Mandatory)][System.IO.MemoryStream] $Stream,
        [Parameter(Mandatory)][int] $Value
    )

    $remaining = [uint32]$Value
    while ($true) {
        $byte = [byte]($remaining -band 0x7F)
        $remaining = $remaining -shr 7
        if ($remaining -ne 0) { $Stream.WriteByte([byte]($byte -bor 0x80)) }
        else { $Stream.WriteByte($byte); break }
    }
}

function Get-Adler32 {
    param([Parameter(Mandatory)][byte[]] $Bytes, [int] $Offset, [int] $Count)

    [uint32] $a = 1
    [uint32] $b = 0
    for ($i = 0; $i -lt $Count; $i++) {
        $a = ($a + $Bytes[$Offset + $i]) % 65521
        $b = ($b + $a) % 65521
    }
    return [uint32](($b -shl 16) -bor $a)
}

function New-JavaPeerDex {
    # Emits a DEX containing exactly one class: the Java peer Android
    # instantiates for the managed activity. Everything it calls into —
    # mono.android.Runtime, TypeManager, IGCUserPeer — lives in the acquired
    # classes.dex, so this file only has to carry the binding.
    #
    # The class shape and instruction sequences are taken from the peer in a
    # shipping .NET Android APK, read out of its dex rather than assumed.
    param(
        [Parameter(Mandatory)][string] $PeerPackage,
        [Parameter(Mandatory)][string] $ClassName,
        [Parameter(Mandatory)][string] $ManagedTypeName,
        [Parameter(Mandatory)][string] $MethodDeclarations
    )

    $selfDescriptor = "L$PeerPackage/$ClassName;"

    # --- interned pools -------------------------------------------------
    $strings = [System.Collections.Generic.List[string]]::new()
    $addString = {
        param([string] $Value)
        if (-not $strings.Contains($Value)) { [void]$strings.Add($Value) }
    }

    $typeDescriptors = @(
        $selfDescriptor,
        'I',
        'Landroid/app/Activity;',
        'Landroid/content/Intent;',
        'Landroid/os/Bundle;',
        'Ljava/lang/Class;',
        'Ljava/lang/Object;',
        'Ljava/lang/String;',
        'Ljava/util/ArrayList;',
        'Lmono/android/IGCUserPeer;',
        'Lmono/android/Runtime;',
        'Lmono/android/TypeManager;',
        '[Ljava/lang/Object;',
        'V',
        'Z'
    )
    foreach ($descriptor in $typeDescriptors) { & $addString $descriptor }

    $literals = @(
        '', '<clinit>', '<init>', 'Activate', 'add', 'clear', 'monodroidAddReference',
        'monodroidClearReferences', 'n_onActivityResult', 'n_onCreate', 'onActivityResult',
        'onCreate', 'refList', 'register',
        $ManagedTypeName, $MethodDeclarations,
        'V', 'VIIL', 'VL', 'VLLL', 'VLLLL', 'ZL'
    )
    foreach ($literal in $literals) { & $addString $literal }

    # DEX requires string_ids sorted by string content and type_ids sorted by
    # the index of their descriptor, so sort once and index afterwards.
    $sortedStrings = [string[]]@($strings)
    [System.Array]::Sort($sortedStrings, [System.StringComparer]::Ordinal)
    $stringIndex = @{}
    for ($i = 0; $i -lt $sortedStrings.Length; $i++) { $stringIndex[$sortedStrings[$i]] = $i }

    $sortedTypes = [string[]]@($typeDescriptors | Sort-Object { $stringIndex[$_] })
    $typeIndex = @{}
    for ($i = 0; $i -lt $sortedTypes.Length; $i++) { $typeIndex[$sortedTypes[$i]] = $i }

    # --- prototypes -----------------------------------------------------
    $protos = @(
        @{ Shorty = 'V';     Return = 'V'; Parameters = @() },
        @{ Shorty = 'VIIL';  Return = 'V'; Parameters = @('I', 'I', 'Landroid/content/Intent;') },
        @{ Shorty = 'VL';    Return = 'V'; Parameters = @('Landroid/os/Bundle;') },
        @{ Shorty = 'VL';    Return = 'V'; Parameters = @('Ljava/lang/Object;') },
        @{ Shorty = 'VLLL';  Return = 'V'; Parameters = @('Ljava/lang/String;', 'Ljava/lang/Class;', 'Ljava/lang/String;') },
        @{ Shorty = 'VLLLL'; Return = 'V'; Parameters = @('Ljava/lang/String;', 'Ljava/lang/String;', 'Ljava/lang/Object;', '[Ljava/lang/Object;') },
        @{ Shorty = 'ZL';    Return = 'Z'; Parameters = @('Ljava/lang/Object;') }
    )
    $sortedProtos = @($protos | Sort-Object `
        @{ Expression = { $typeIndex[$_.Return] } },
        @{ Expression = { ($_.Parameters | ForEach-Object { '{0:D6}' -f $typeIndex[$_] }) -join '' } })
    $protoIndex = @{}
    for ($i = 0; $i -lt $sortedProtos.Count; $i++) {
        $key = $sortedProtos[$i].Return + '(' + (($sortedProtos[$i].Parameters) -join ',') + ')'
        $protoIndex[$key] = $i
    }
    $protoKey = {
        param([string] $Return, [string[]] $Parameters)
        return $Return + '(' + ($Parameters -join ',') + ')'
    }

    # --- fields and methods ---------------------------------------------
    $fields = @(
        @{ Class = $selfDescriptor; Name = 'refList'; Type = 'Ljava/util/ArrayList;' }
    )
    $sortedFields = @($fields | Sort-Object `
        @{ Expression = { $typeIndex[$_.Class] } },
        @{ Expression = { $stringIndex[$_.Name] } },
        @{ Expression = { $typeIndex[$_.Type] } })
    $fieldIndex = @{}
    for ($i = 0; $i -lt $sortedFields.Count; $i++) {
        $fieldIndex[$sortedFields[$i].Class + '->' + $sortedFields[$i].Name] = $i
    }

    $methods = @(
        @{ Class = 'Landroid/app/Activity;';   Name = '<init>';                   Return = 'V'; Parameters = @() },
        @{ Class = $selfDescriptor;            Name = '<clinit>';                  Return = 'V'; Parameters = @() },
        @{ Class = $selfDescriptor;            Name = '<init>';                    Return = 'V'; Parameters = @() },
        @{ Class = $selfDescriptor;            Name = 'monodroidAddReference';     Return = 'V'; Parameters = @('Ljava/lang/Object;') },
        @{ Class = $selfDescriptor;            Name = 'monodroidClearReferences';  Return = 'V'; Parameters = @() },
        @{ Class = $selfDescriptor;            Name = 'n_onActivityResult';        Return = 'V'; Parameters = @('I', 'I', 'Landroid/content/Intent;') },
        @{ Class = $selfDescriptor;            Name = 'n_onCreate';                Return = 'V'; Parameters = @('Landroid/os/Bundle;') },
        @{ Class = $selfDescriptor;            Name = 'onActivityResult';          Return = 'V'; Parameters = @('I', 'I', 'Landroid/content/Intent;') },
        @{ Class = $selfDescriptor;            Name = 'onCreate';                  Return = 'V'; Parameters = @('Landroid/os/Bundle;') },
        @{ Class = 'Ljava/util/ArrayList;';    Name = '<init>';                    Return = 'V'; Parameters = @() },
        @{ Class = 'Ljava/util/ArrayList;';    Name = 'add';                       Return = 'Z'; Parameters = @('Ljava/lang/Object;') },
        @{ Class = 'Ljava/util/ArrayList;';    Name = 'clear';                     Return = 'V'; Parameters = @() },
        @{ Class = 'Lmono/android/Runtime;';   Name = 'register';                  Return = 'V'; Parameters = @('Ljava/lang/String;', 'Ljava/lang/Class;', 'Ljava/lang/String;') },
        @{ Class = 'Lmono/android/TypeManager;'; Name = 'Activate';                Return = 'V'; Parameters = @('Ljava/lang/String;', 'Ljava/lang/String;', 'Ljava/lang/Object;', '[Ljava/lang/Object;') }
    )
    $sortedMethods = @($methods | Sort-Object `
        @{ Expression = { $typeIndex[$_.Class] } },
        @{ Expression = { $stringIndex[$_.Name] } },
        @{ Expression = { $protoIndex[(& $protoKey $_.Return $_.Parameters)] } })
    $methodIndex = @{}
    for ($i = 0; $i -lt $sortedMethods.Count; $i++) {
        $m = $sortedMethods[$i]
        $methodIndex[$m.Class + '->' + $m.Name + (& $protoKey $m.Return $m.Parameters)] = $i
    }
    $methodRef = {
        param([string] $Class, [string] $Name, [string] $Return, [string[]] $Parameters)
        $key = $Class + '->' + $Name + (& $protoKey $Return $Parameters)
        if (-not $methodIndex.ContainsKey($key)) { throw "Unknown method reference '$key'." }
        return [uint16]$methodIndex[$key]
    }

    # --- bytecode --------------------------------------------------------
    $u16 = { param([int] $Value) [byte[]]@([byte]($Value -band 0xFF), [byte](($Value -shr 8) -band 0xFF)) }

    $selfType = [uint16]$typeIndex[$selfDescriptor]
    $objectArrayType = [uint16]$typeIndex['[Ljava/lang/Object;']
    $arrayListType = [uint16]$typeIndex['Ljava/util/ArrayList;']
    $refListField = [uint16]$fieldIndex[$selfDescriptor + '->refList']

    # <clinit>: Runtime.register(managedType, class, methodDeclarations)
    $clinit = [System.Collections.Generic.List[byte]]::new()
    $clinit.AddRange([byte[]]@(0x1A, 0x00)); $clinit.AddRange([byte[]](& $u16 $stringIndex[$ManagedTypeName]))
    $clinit.AddRange([byte[]]@(0x1C, 0x01)); $clinit.AddRange([byte[]](& $u16 $selfType))
    $clinit.AddRange([byte[]]@(0x1A, 0x02)); $clinit.AddRange([byte[]](& $u16 $stringIndex[$MethodDeclarations]))
    $clinit.AddRange([byte[]]@(0x71, 0x30)); $clinit.AddRange([byte[]](& $u16 (& $methodRef 'Lmono/android/Runtime;' 'register' 'V' @('Ljava/lang/String;','Ljava/lang/Class;','Ljava/lang/String;'))))
    $clinit.AddRange([byte[]]@(0x10, 0x02))
    $clinit.AddRange([byte[]]@(0x0E, 0x00))

    # <init>: super(), refList = new ArrayList(), TypeManager.Activate(...)
    $init = [System.Collections.Generic.List[byte]]::new()
    $init.AddRange([byte[]]@(0x70, 0x10)); $init.AddRange([byte[]](& $u16 (& $methodRef 'Landroid/app/Activity;' '<init>' 'V' @()))); $init.AddRange([byte[]]@(0x04, 0x00))
    $init.AddRange([byte[]]@(0x22, 0x00)); $init.AddRange([byte[]](& $u16 $arrayListType))
    $init.AddRange([byte[]]@(0x70, 0x10)); $init.AddRange([byte[]](& $u16 (& $methodRef 'Ljava/util/ArrayList;' '<init>' 'V' @()))); $init.AddRange([byte[]]@(0x00, 0x00))
    $init.AddRange([byte[]]@(0x5B, 0x40)); $init.AddRange([byte[]](& $u16 $refListField))
    $init.AddRange([byte[]]@(0x12, 0x01))
    $init.AddRange([byte[]]@(0x23, 0x11)); $init.AddRange([byte[]](& $u16 $objectArrayType))
    $init.AddRange([byte[]]@(0x1A, 0x02)); $init.AddRange([byte[]](& $u16 $stringIndex[$ManagedTypeName]))
    $init.AddRange([byte[]]@(0x1A, 0x03)); $init.AddRange([byte[]](& $u16 $stringIndex['']))
    $init.AddRange([byte[]]@(0x71, 0x40)); $init.AddRange([byte[]](& $u16 (& $methodRef 'Lmono/android/TypeManager;' 'Activate' 'V' @('Ljava/lang/String;','Ljava/lang/String;','Ljava/lang/Object;','[Ljava/lang/Object;')))); $init.AddRange([byte[]]@(0x32, 0x14))
    $init.AddRange([byte[]]@(0x0E, 0x00))

    # onCreate(Bundle): n_onCreate(bundle)
    $onCreate = [System.Collections.Generic.List[byte]]::new()
    $onCreate.AddRange([byte[]]@(0x70, 0x20)); $onCreate.AddRange([byte[]](& $u16 (& $methodRef $selfDescriptor 'n_onCreate' 'V' @('Landroid/os/Bundle;')))); $onCreate.AddRange([byte[]]@(0x10, 0x00))
    $onCreate.AddRange([byte[]]@(0x0E, 0x00))

    # onActivityResult(int, int, Intent): n_onActivityResult(requestCode, resultCode, data)
    # Without this override Android delivers picker results to the stock
    # Activity implementation and the managed OnActivityResult never runs.
    # invoke-direct/range-free form: four arguments v0 (this), v1, v2, v3.
    $onActivityResult = [System.Collections.Generic.List[byte]]::new()
    $onActivityResult.AddRange([byte[]]@(0x70, 0x40)); $onActivityResult.AddRange([byte[]](& $u16 (& $methodRef $selfDescriptor 'n_onActivityResult' 'V' @('I', 'I', 'Landroid/content/Intent;')))); $onActivityResult.AddRange([byte[]]@(0x10, 0x32))
    $onActivityResult.AddRange([byte[]]@(0x0E, 0x00))

    # monodroidAddReference(Object): refList.add(obj)
    $addReference = [System.Collections.Generic.List[byte]]::new()
    $addReference.AddRange([byte[]]@(0x54, 0x10)); $addReference.AddRange([byte[]](& $u16 $refListField))
    $addReference.AddRange([byte[]]@(0x6E, 0x20)); $addReference.AddRange([byte[]](& $u16 (& $methodRef 'Ljava/util/ArrayList;' 'add' 'Z' @('Ljava/lang/Object;')))); $addReference.AddRange([byte[]]@(0x20, 0x00))
    $addReference.AddRange([byte[]]@(0x0E, 0x00))

    # monodroidClearReferences(): refList.clear()
    $clearReferences = [System.Collections.Generic.List[byte]]::new()
    $clearReferences.AddRange([byte[]]@(0x54, 0x10)); $clearReferences.AddRange([byte[]](& $u16 $refListField))
    $clearReferences.AddRange([byte[]]@(0x6E, 0x10)); $clearReferences.AddRange([byte[]](& $u16 (& $methodRef 'Ljava/util/ArrayList;' 'clear' 'V' @()))); $clearReferences.AddRange([byte[]]@(0x00, 0x00))
    $clearReferences.AddRange([byte[]]@(0x0E, 0x00))

    $codeBodies = [ordered]@{
        '<clinit>'                 = @{ Registers = 3; Ins = 0; Outs = 3; Insns = $clinit.ToArray() }
        '<init>'                   = @{ Registers = 5; Ins = 1; Outs = 4; Insns = $init.ToArray() }
        'monodroidAddReference'    = @{ Registers = 3; Ins = 2; Outs = 2; Insns = $addReference.ToArray() }
        'monodroidClearReferences' = @{ Registers = 2; Ins = 1; Outs = 1; Insns = $clearReferences.ToArray() }
        'onCreate'                 = @{ Registers = 2; Ins = 2; Outs = 2; Insns = $onCreate.ToArray() }
        'onActivityResult'         = @{ Registers = 4; Ins = 4; Outs = 4; Insns = $onActivityResult.ToArray() }
    }

    return [pscustomobject]@{
        SelfDescriptor = $selfDescriptor
        SortedStrings  = $sortedStrings
        StringIndex    = $stringIndex
        SortedTypes    = $sortedTypes
        TypeIndex      = $typeIndex
        SortedProtos   = $sortedProtos
        ProtoIndex     = $protoIndex
        ProtoKey       = $protoKey
        SortedFields   = $sortedFields
        FieldIndex     = $fieldIndex
        SortedMethods  = $sortedMethods
        MethodIndex    = $methodIndex
        CodeBodies     = $codeBodies
    }
}

function ConvertTo-DexImage {
    param([Parameter(Mandatory)][pscustomobject] $Plan)

    $NO_INDEX = [uint32]::MaxValue
    $stringCount = $Plan.SortedStrings.Length
    $typeCount = $Plan.SortedTypes.Length
    $protoCount = $Plan.SortedProtos.Count
    $fieldCount = $Plan.SortedFields.Count
    $methodCount = $Plan.SortedMethods.Count

    $headerSize = 112
    $stringIdsOff = $headerSize
    $typeIdsOff   = $stringIdsOff + (4 * $stringCount)
    $protoIdsOff  = $typeIdsOff + (4 * $typeCount)
    $fieldIdsOff  = $protoIdsOff + (12 * $protoCount)
    $methodIdsOff = $fieldIdsOff + (8 * $fieldCount)
    $classDefsOff = $methodIdsOff + (8 * $methodCount)
    $dataOff      = $classDefsOff + 32

    $data = [System.IO.MemoryStream]::new()
    $align = {
        param([int] $Boundary)
        while ((($dataOff + $data.Position) % $Boundary) -ne 0) { $data.WriteByte(0) }
        return [int]($dataOff + $data.Position)
    }
    $writeU16 = { param([int] $v) $data.WriteByte([byte]($v -band 0xFF)); $data.WriteByte([byte](($v -shr 8) -band 0xFF)) }
    $writeU32 = {
        param([int64] $v)
        for ($i = 0; $i -lt 4; $i++) { $data.WriteByte([byte](($v -shr ($i * 8)) -band 0xFF)) }
    }

    # --- type lists: proto parameters, then the interface list -----------
    $typeListOffsets = @{}
    foreach ($proto in $Plan.SortedProtos) {
        if ($proto.Parameters.Count -eq 0) { continue }
        $key = ($proto.Parameters -join ',')
        if ($typeListOffsets.ContainsKey($key)) { continue }
        $offset = & $align 4
        & $writeU32 $proto.Parameters.Count
        foreach ($parameter in $proto.Parameters) { & $writeU16 $Plan.TypeIndex[$parameter] }
        $typeListOffsets[$key] = $offset
    }
    $interfacesOffset = & $align 4
    & $writeU32 1
    & $writeU16 $Plan.TypeIndex['Lmono/android/IGCUserPeer;']

    # --- string data ------------------------------------------------------
    $stringDataOffsets = New-Object int[] $stringCount
    for ($i = 0; $i -lt $stringCount; $i++) {
        $value = $Plan.SortedStrings[$i]
        $stringDataOffsets[$i] = [int]($dataOff + $data.Position)
        Write-Uleb128 -Stream $data -Value $value.Length
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
        if ($bytes.Length -gt 0) { $data.Write($bytes, 0, $bytes.Length) }
        $data.WriteByte(0)
    }

    # --- code items -------------------------------------------------------
    $codeOffsets = @{}
    foreach ($name in $Plan.CodeBodies.Keys) {
        $body = $Plan.CodeBodies[$name]
        $offset = & $align 4
        & $writeU16 $body.Registers
        & $writeU16 $body.Ins
        & $writeU16 $body.Outs
        & $writeU16 0                       # tries_size
        & $writeU32 0                       # debug_info_off
        & $writeU32 ($body.Insns.Length / 2)
        $data.Write($body.Insns, 0, $body.Insns.Length)
        $codeOffsets[$name] = $offset
    }

    # --- class data -------------------------------------------------------
    $selfMethods = @($Plan.SortedMethods | Where-Object { $_.Class -ceq $Plan.SelfDescriptor })
    $direct = @('<clinit>', '<init>', 'n_onActivityResult', 'n_onCreate')
    $directMethods = @($selfMethods | Where-Object { $direct -contains $_.Name } |
        Sort-Object { $Plan.MethodIndex[$_.Class + '->' + $_.Name + (& $Plan.ProtoKey $_.Return $_.Parameters)] })
    $virtualMethods = @($selfMethods | Where-Object { $direct -notcontains $_.Name } |
        Sort-Object { $Plan.MethodIndex[$_.Class + '->' + $_.Name + (& $Plan.ProtoKey $_.Return $_.Parameters)] })

    $accessFlags = @{
        '<clinit>'                 = 0x10008   # static | constructor
        '<init>'                   = 0x10001   # public | constructor
        'n_onCreate'               = 0x0102    # private | native
        'n_onActivityResult'       = 0x0102    # private | native
        'monodroidAddReference'    = 0x0001
        'monodroidClearReferences' = 0x0001
        'onCreate'                 = 0x0001
        'onActivityResult'         = 0x0001
    }

    $classDataOffset = [int]($dataOff + $data.Position)
    Write-Uleb128 -Stream $data -Value 0                        # static_fields_size
    Write-Uleb128 -Stream $data -Value $Plan.SortedFields.Count  # instance_fields_size
    Write-Uleb128 -Stream $data -Value $directMethods.Count
    Write-Uleb128 -Stream $data -Value $virtualMethods.Count

    $previous = 0
    for ($i = 0; $i -lt $Plan.SortedFields.Count; $i++) {
        $field = $Plan.SortedFields[$i]
        $index = $Plan.FieldIndex[$field.Class + '->' + $field.Name]
        Write-Uleb128 -Stream $data -Value ($index - $previous)
        $previous = $index
        Write-Uleb128 -Stream $data -Value 0x2                   # private
    }

    foreach ($group in @($directMethods, $virtualMethods)) {
        $previous = 0
        foreach ($method in $group) {
            $key = $method.Class + '->' + $method.Name + (& $Plan.ProtoKey $method.Return $method.Parameters)
            $index = $Plan.MethodIndex[$key]
            Write-Uleb128 -Stream $data -Value ($index - $previous)
            $previous = $index
            Write-Uleb128 -Stream $data -Value $accessFlags[$method.Name]
            $codeOffset = if ($Plan.CodeBodies.Contains($method.Name)) { $codeOffsets[$method.Name] } else { 0 }
            Write-Uleb128 -Stream $data -Value $codeOffset
        }
    }

    # --- map list ---------------------------------------------------------
    $mapOffset = & $align 4
    $mapEntries = @(
        @{ Type = 0x0000; Size = 1;            Offset = 0 },
        @{ Type = 0x0001; Size = $stringCount; Offset = $stringIdsOff },
        @{ Type = 0x0002; Size = $typeCount;   Offset = $typeIdsOff },
        @{ Type = 0x0003; Size = $protoCount;  Offset = $protoIdsOff },
        @{ Type = 0x0004; Size = $fieldCount;  Offset = $fieldIdsOff },
        @{ Type = 0x0005; Size = $methodCount; Offset = $methodIdsOff },
        @{ Type = 0x0006; Size = 1;            Offset = $classDefsOff },
        @{ Type = 0x1001; Size = ($typeListOffsets.Count + 1); Offset = ($typeListOffsets.Values + @($interfacesOffset) | Measure-Object -Minimum).Minimum },
        @{ Type = 0x2002; Size = $stringCount; Offset = $stringDataOffsets[0] },
        @{ Type = 0x2001; Size = $codeOffsets.Count; Offset = ($codeOffsets.Values | Measure-Object -Minimum).Minimum },
        @{ Type = 0x2000; Size = 1;            Offset = $classDataOffset },
        @{ Type = 0x1000; Size = 1;            Offset = $mapOffset }
    )
    $mapEntries = @($mapEntries | Sort-Object { $_.Offset })
    & $writeU32 $mapEntries.Count
    foreach ($entry in $mapEntries) {
        & $writeU16 $entry.Type
        & $writeU16 0
        & $writeU32 $entry.Size
        & $writeU32 $entry.Offset
    }

    $dataBytes = $data.ToArray()
    $data.Dispose()
    $fileSize = $dataOff + $dataBytes.Length

    # --- assemble ---------------------------------------------------------
    $image = New-Object byte[] $fileSize
    $stream = [System.IO.MemoryStream]::new($image, 0, $image.Length, $true)
    $writer = [System.IO.BinaryWriter]::new($stream)
    try {
        Write-ByteSpan -Writer $writer -Bytes ([byte[]]@(0x64, 0x65, 0x78, 0x0A, 0x30, 0x33, 0x39, 0x00))
        $writer.Write([uint32]0)                     # checksum, filled in below
        Write-ByteSpan -Writer $writer -Bytes (New-Object byte[] 20)   # signature
        $writer.Write([uint32]$fileSize)
        $writer.Write([uint32]$headerSize)
        $writer.Write([uint32]0x12345678)
        $writer.Write([uint32]0); $writer.Write([uint32]0)             # link
        $writer.Write([uint32]$mapOffset)
        $writer.Write([uint32]$stringCount); $writer.Write([uint32]$stringIdsOff)
        $writer.Write([uint32]$typeCount);   $writer.Write([uint32]$typeIdsOff)
        $writer.Write([uint32]$protoCount);  $writer.Write([uint32]$protoIdsOff)
        $writer.Write([uint32]$fieldCount);  $writer.Write([uint32]$fieldIdsOff)
        $writer.Write([uint32]$methodCount); $writer.Write([uint32]$methodIdsOff)
        $writer.Write([uint32]1);            $writer.Write([uint32]$classDefsOff)
        $writer.Write([uint32]$dataBytes.Length); $writer.Write([uint32]$dataOff)

        foreach ($offset in $stringDataOffsets) { $writer.Write([uint32]$offset) }
        foreach ($descriptor in $Plan.SortedTypes) { $writer.Write([uint32]$Plan.StringIndex[$descriptor]) }
        foreach ($proto in $Plan.SortedProtos) {
            $writer.Write([uint32]$Plan.StringIndex[$proto.Shorty])
            $writer.Write([uint32]$Plan.TypeIndex[$proto.Return])
            $key = ($proto.Parameters -join ',')
            $writer.Write([uint32]$(if ($proto.Parameters.Count -eq 0) { 0 } else { $typeListOffsets[$key] }))
        }
        foreach ($field in $Plan.SortedFields) {
            $writer.Write([uint16]$Plan.TypeIndex[$field.Class])
            $writer.Write([uint16]$Plan.TypeIndex[$field.Type])
            $writer.Write([uint32]$Plan.StringIndex[$field.Name])
        }
        foreach ($method in $Plan.SortedMethods) {
            $writer.Write([uint16]$Plan.TypeIndex[$method.Class])
            $writer.Write([uint16]$Plan.ProtoIndex[(& $Plan.ProtoKey $method.Return $method.Parameters)])
            $writer.Write([uint32]$Plan.StringIndex[$method.Name])
        }

        $writer.Write([uint32]$Plan.TypeIndex[$Plan.SelfDescriptor])
        $writer.Write([uint32]0x0001)                                  # public
        $writer.Write([uint32]$Plan.TypeIndex['Landroid/app/Activity;'])
        $writer.Write([uint32]$interfacesOffset)
        $writer.Write($NO_INDEX)                                       # source_file_idx
        $writer.Write([uint32]0)                                       # annotations_off
        $writer.Write([uint32]$classDataOffset)
        $writer.Write([uint32]0)                                       # static_values_off

        Write-ByteSpan -Writer $writer -Bytes $dataBytes
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    # SHA-1 over everything after the signature field, then Adler-32 over
    # everything after the checksum field. Order matters: the checksum covers
    # the signature.
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $signature = $sha1.ComputeHash($image, 32, $image.Length - 32) }
    finally { $sha1.Dispose() }
    [System.Array]::Copy($signature, 0, $image, 12, 20)

    $checksum = Get-Adler32 -Bytes $image -Offset 12 -Count ($image.Length - 12)
    [System.Array]::Copy([BitConverter]::GetBytes([uint32]$checksum), 0, $image, 8, 4)

    return $image
}

function Test-JavaPeerDex {
    param(
        [Parameter(Mandatory)][byte[]] $Dex,
        [Parameter(Mandatory)][string] $ExpectedDescriptor
    )

    if ([System.Text.Encoding]::ASCII.GetString($Dex, 0, 4) -cne "dex`n") {
        throw 'The emitted dex does not begin with the dex magic.'
    }

    # Both integrity fields are recomputed and compared, so a malformed image
    # fails here rather than on the device.
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try { $signature = $sha1.ComputeHash($Dex, 32, $Dex.Length - 32) }
    finally { $sha1.Dispose() }
    for ($i = 0; $i -lt 20; $i++) {
        if ($Dex[12 + $i] -ne $signature[$i]) { throw 'The emitted dex signature does not cover its own contents.' }
    }
    $checksum = Get-Adler32 -Bytes $Dex -Offset 12 -Count ($Dex.Length - 12)
    if ([BitConverter]::ToUInt32($Dex, 8) -ne $checksum) { throw 'The emitted dex checksum is wrong.' }
    if ([int][BitConverter]::ToUInt32($Dex, 32) -ne $Dex.Length) { throw 'The emitted dex declares the wrong file size.' }
    if ([BitConverter]::ToUInt32($Dex, 40) -ne 0x12345678) { throw 'The emitted dex declares the wrong endian tag.' }

    $stringIdsOff = [int][BitConverter]::ToUInt32($Dex, 60)
    $typeIdsOff   = [int][BitConverter]::ToUInt32($Dex, 68)
    $methodIdsOff = [int][BitConverter]::ToUInt32($Dex, 92)
    $protoIdsOff  = [int][BitConverter]::ToUInt32($Dex, 76)
    $classDefsOff = [int][BitConverter]::ToUInt32($Dex, 100)
    $stringCount  = [int][BitConverter]::ToUInt32($Dex, 56)

    $readUleb = {
        param([int] $Offset)
        $shift = 0; $result = 0; $cursor = $Offset
        while ($true) {
            $b = $Dex[$cursor]; $cursor++
            $result = $result -bor (($b -band 0x7F) -shl $shift)
            if (($b -band 0x80) -eq 0) { break }
            $shift += 7
        }
        return @($result, $cursor)
    }
    $getString = {
        param([int] $Index)
        $offset = [int][BitConverter]::ToUInt32($Dex, $stringIdsOff + ($Index * 4))
        $decoded = & $readUleb $offset
        $start = $decoded[1]; $end = $start
        while ($Dex[$end] -ne 0) { $end++ }
        return [System.Text.Encoding]::UTF8.GetString($Dex, $start, $end - $start)
    }
    $getType = { param([int] $Index) & $getString ([int][BitConverter]::ToUInt32($Dex, $typeIdsOff + ($Index * 4))) }

    # string_ids must be sorted, or the platform's binary search misses.
    for ($i = 1; $i -lt $stringCount; $i++) {
        $previous = & $getString ($i - 1)
        $current = & $getString $i
        if ([string]::CompareOrdinal($previous, $current) -ge 0) {
            throw "The emitted dex string table is not in ordinal order at index $i ('$previous' then '$current')."
        }
    }

    $descriptor = & $getType ([int][BitConverter]::ToUInt32($Dex, $classDefsOff))
    if ($descriptor -cne $ExpectedDescriptor) {
        throw "The emitted dex defines '$descriptor'; the manifest names '$ExpectedDescriptor'."
    }
    $superclass = & $getType ([int][BitConverter]::ToUInt32($Dex, $classDefsOff + 8))
    if ($superclass -cne 'Landroid/app/Activity;') {
        throw "The emitted peer extends '$superclass'."
    }
    $interfacesOff = [int][BitConverter]::ToUInt32($Dex, $classDefsOff + 12)
    if ($interfacesOff -eq 0) { throw 'The emitted peer implements no interfaces.' }
    $interface = & $getType ([int][BitConverter]::ToUInt16($Dex, $interfacesOff + 4))
    if ($interface -cne 'Lmono/android/IGCUserPeer;') {
        throw "The emitted peer implements '$interface' instead of mono.android.IGCUserPeer."
    }

    $classDataOff = [int][BitConverter]::ToUInt32($Dex, $classDefsOff + 24)
    $cursor = $classDataOff
    $counts = @()
    for ($i = 0; $i -lt 4; $i++) {
        $decoded = & $readUleb $cursor
        $counts += $decoded[0]
        $cursor = $decoded[1]
    }
    if ($counts[2] -ne 4 -or $counts[3] -ne 4) {
        throw "The emitted peer declares $($counts[2]) direct and $($counts[3]) virtual methods; 4 and 4 are required."
    }

    return [pscustomobject]@{
        FileSize     = $Dex.Length
        StringCount  = $stringCount
        Descriptor   = $descriptor
        MethodCounts = "$($counts[2]) direct, $($counts[3]) virtual"
    }
}

function Invoke-DexStep {
    if (Skip-ForNativeAdmission -Step 8 -Output 'the Java peer DEX') { return }

    $peerPackage = ($script:JavaPeerName -replace '\.[^.]+$', '') -replace '\.', '/'
    $managedType = "$($script:ManagedNamespace).$($script:ActivityClassName), $($script:AssemblyName)"
    $declarations = "n_onCreate:(Landroid/os/Bundle;)V:GetOnCreate_Landroid_os_Bundle_Handler`n" +
        "n_onActivityResult:(IILandroid/content/Intent;)V:GetOnActivityResult_IILandroid_content_Intent_Handler`n"

    $plan = New-JavaPeerDex `
        -PeerPackage $peerPackage `
        -ClassName $script:ActivityClassName `
        -ManagedTypeName $managedType `
        -MethodDeclarations $declarations
    $dexBytes = ConvertTo-DexImage -Plan $plan
    $report = Test-JavaPeerDex -Dex $dexBytes -ExpectedDescriptor $plan.SelfDescriptor

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $dexPath = Join-Path $outputDirectory 'classes2.dex'
    if ($PSCmdlet.ShouldProcess($dexPath, 'Write Java peer dex')) {
        Write-BuildFile -Intermediate -Path $dexPath -Bytes $dexBytes
    }

    $dexStream = [System.IO.MemoryStream]::new([byte[]]$dexBytes, $false)
    try { $dexHash = Get-Sha256Hex -Stream $dexStream }
    finally { $dexStream.Dispose() }

    $script:BuildContext.PeerDex = [pscustomobject]@{
        Path        = $dexPath
        Bytes       = $dexBytes
        Sha256      = $dexHash
        Descriptor  = $plan.SelfDescriptor
        ManagedType = $managedType
    }

    Write-Host ('[PASS] Step 8 complete: {0} emitted as {1} bytes of Dalvik bytecode defining {2} ({3}), binding {4}. Checksum, SHA-1, and string ordering verified. SHA-256 {5}' -f
        'classes2.dex',
        $report.FileSize,
        $report.Descriptor,
        $report.MethodCounts,
        $managedType,
        $dexHash) -ForegroundColor Green
}
function Get-NativePayload {
    param(
        [Parameter(Mandatory)][string] $PackageId,
        [Parameter(Mandatory)][string] $EntryPath
    )

    $bytes = $script:BuildContext.PackageBytes[$PackageId]
    if ($null -eq $bytes) { throw "Package '$PackageId' was not acquired." }

    $stream = [System.IO.MemoryStream]::new([byte[]]$bytes, $false)
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $entry = $archive.GetEntry($EntryPath)
        if ($null -eq $entry) { throw "Package '$PackageId' does not contain '$EntryPath'." }
        return Read-ZipEntryBytes -Entry $entry
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Get-DeflatedBytes {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    $output = [System.IO.MemoryStream]::new()
    $deflate = [System.IO.Compression.DeflateStream]::new($output, [System.IO.Compression.CompressionLevel]::Optimal, $true)
    try { $deflate.Write($Bytes, 0, $Bytes.Length) }
    finally { $deflate.Dispose() }
    $result = $output.ToArray()
    $output.Dispose()
    return $result
}

function New-ApkArchive {
    # A ZIP, written directly. Entries that Android maps at runtime must start
    # at an aligned offset, which is achieved by padding the local header's
    # extra field rather than by inserting bytes between entries.
    param(
        [Parameter(Mandatory)][System.Collections.Generic.List[object]] $Entries
    )

    $output = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($output, [System.Text.Encoding]::UTF8, $true)
    $directory = [System.Collections.Generic.List[object]]::new()

    # A fixed timestamp keeps the archive reproducible. 1981-01-01 00:00:00 in
    # MS-DOS form, the same date this repository stamps on emitted artifacts.
    $dosTime = [uint16]0
    $dosDate = [uint16]0x0021

    try {
        foreach ($entry in $Entries) {
            $nameBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$entry.Name)
            $raw = [byte[]]$entry.Bytes
            $crc = Get-Crc32 -Data $raw
            $stored = [bool]$entry.Stored
            $payload = if ($stored) { $raw } else { Get-DeflatedBytes -Bytes $raw }
            $method = [uint16]$(if ($stored) { 0 } else { 8 })

            $localOffset = [int]$output.Position
            $extra = [byte[]]@()
            $alignment = [int]$entry.Alignment
            if ($alignment -gt 1) {
                $payloadOffset = $localOffset + 30 + $nameBytes.Length
                $remainder = $payloadOffset % $alignment
                if ($remainder -ne 0) {
                    $padding = $alignment - $remainder
                    if ($padding -lt 4) { $padding += $alignment }
                    $extraStream = [System.IO.MemoryStream]::new()
                    $extraWriter = [System.IO.BinaryWriter]::new($extraStream)
                    try {
                        $extraWriter.Write([uint16]0xD935)
                        $extraWriter.Write([uint16]($padding - 4))
                        $extraWriter.Write((New-Object byte[] ($padding - 4)), 0, ($padding - 4))
                        $extraWriter.Flush()
                        $extra = $extraStream.ToArray()
                    }
                    finally { $extraWriter.Dispose(); $extraStream.Dispose() }
                }
            }

            $writer.Write([uint32]0x04034B50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0)
            $writer.Write($method)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write([uint32]$crc)
            $writer.Write([uint32]$payload.Length)
            $writer.Write([uint32]$raw.Length)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]$extra.Length)
            Write-ByteSpan -Writer $writer -Bytes $nameBytes
            if ($extra.Length -gt 0) { Write-ByteSpan -Writer $writer -Bytes $extra }

            if ($alignment -gt 1 -and (($output.Position % $alignment) -ne 0)) {
                throw "Entry '$($entry.Name)' starts at $($output.Position), which is not a multiple of $alignment."
            }
            Write-ByteSpan -Writer $writer -Bytes $payload

            $directory.Add([pscustomobject]@{
                NameBytes      = $nameBytes
                Method         = $method
                Crc            = $crc
                CompressedSize = $payload.Length
                Size           = $raw.Length
                LocalOffset    = $localOffset
            })
        }

        $directoryOffset = [int]$output.Position
        foreach ($record in $directory) {
            $writer.Write([uint32]0x02014B50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0)
            $writer.Write($record.Method)
            $writer.Write($dosTime)
            $writer.Write($dosDate)
            $writer.Write([uint32]$record.Crc)
            $writer.Write([uint32]$record.CompressedSize)
            $writer.Write([uint32]$record.Size)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.LocalOffset)
            Write-ByteSpan -Writer $writer -Bytes $record.NameBytes
        }
        $directorySize = [int]$output.Position - $directoryOffset

        $writer.Write([uint32]0x06054B50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write([uint16]$directory.Count)
        $writer.Write([uint16]$directory.Count)
        $writer.Write([uint32]$directorySize)
        $writer.Write([uint32]$directoryOffset)
        $writer.Write([uint16]0)
        $writer.Flush()

        return $output.ToArray()
    }
    finally {
        $writer.Dispose()
        $output.Dispose()
    }
}

function Test-ApkArchive {
    param(
        [Parameter(Mandatory)][byte[]] $Apk,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]] $Entries
    )

    # Read the archive back with a reader that knows nothing about how it was
    # written, and require every entry to round-trip byte for byte.
    $stream = [System.IO.MemoryStream]::new($Apk, $false)
    $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $names = @($archive.Entries | ForEach-Object FullName)
        if ($archive.Entries.Count -ne $Entries.Count) {
            throw "The archive holds $($archive.Entries.Count) entries; $($Entries.Count) were written."
        }
        foreach ($entry in $Entries) {
            $found = $archive.GetEntry([string]$entry.Name)
            if ($null -eq $found) { throw "Entry '$($entry.Name)' is not readable in the archive." }
            $actual = Read-ZipEntryBytes -Entry $found
            $expected = [byte[]]$entry.Bytes
            if ($actual.Length -ne $expected.Length) {
                throw "Entry '$($entry.Name)' read back as $($actual.Length) bytes instead of $($expected.Length)."
            }
            for ($i = 0; $i -lt $expected.Length; $i++) {
                if ($actual[$i] -ne $expected[$i]) { throw "Entry '$($entry.Name)' differs at byte $i." }
            }
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }

    return [pscustomobject]@{
        EntryCount = $Entries.Count
        Size       = $Apk.Length
        Names      = $names
    }
}

function Invoke-AssembleStep {

    $abi = $script:Target.Abi
    $runtimePack = "Microsoft.NETCore.App.Runtime.$($script:Target.Rid)"
    $hostPack = "Microsoft.Android.Runtime.CoreCLR.37.$($script:Target.Rid)"

    $entries = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $Name, [byte[]] $Bytes, [bool] $Stored = $false, [int] $Alignment = 0)
        $entries.Add([pscustomobject]@{ Name = $Name; Bytes = $Bytes; Stored = $Stored; Alignment = $Alignment })
    }

    if ($Admission -eq 'NativeActivity') {
        & $add 'AndroidManifest.xml' ([byte[]]$script:BuildContext.AndroidManifest.Bytes) $false 0
        & $add 'resources.arsc' (New-ResourceTable -PackageName $script:PackageName -IconPath 'res/mipmap/ic_launcher.png') $true 4
        & $add 'res/mipmap/ic_launcher.png' (Import-LibSourceBytes -Path 'ic_launcher.png') $true 4
        & $add "lib/$abi/libpwsh-host.so" ([byte[]]$script:BuildContext.NativeHost.Bytes) $false 0
    }
    else {
        & $add 'AndroidManifest.xml' ([byte[]]$script:BuildContext.AndroidManifest.Bytes) $false 0
        & $add 'classes.dex' (Import-LibSourceBytes -Path 'classes.dex') $false 0
        & $add 'classes2.dex' ([byte[]]$script:BuildContext.PeerDex.Bytes) $false 0
        # The launcher icon. Android requires resources.arsc stored and 4-byte
        # aligned; the PNG is already compressed, so it is stored too.
        & $add 'resources.arsc' (New-ResourceTable -PackageName $script:PackageName -IconPath 'res/mipmap/ic_launcher.png') $true 4
        & $add 'res/mipmap/ic_launcher.png' (Import-LibSourceBytes -Path 'ic_launcher.png') $true 4
        & $add "lib/$abi/libassembly-store.so" ([byte[]]$script:BuildContext.StoreLibrary.Bytes) $false 0
        & $add "lib/$abi/libxamarin-app.so" ([byte[]]$script:BuildContext.XamarinApp.Bytes) $false 0
        & $add "lib/$abi/libpsl-native.so" ([byte[]]$script:BuildContext.PslNative.Bytes) $false 0

        # The .NET runtime's native components, taken from the verified packages.
        $natives = [ordered]@{
            'libcoreclr.so'                                = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libcoreclr.so" }
            'libclrjit.so'                                 = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libclrjit.so" }
            'libSystem.Native.so'                          = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libSystem.Native.so" }
            'libSystem.Globalization.Native.so'            = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libSystem.Globalization.Native.so" }
            'libSystem.IO.Compression.Native.so'           = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libSystem.IO.Compression.Native.so" }
            'libSystem.Security.Cryptography.Native.Android.so' = @{ Package = $runtimePack; Path = "runtimes/$($script:Target.Rid)/native/libSystem.Security.Cryptography.Native.Android.so" }
            # The Android host itself. Packaged under the name the runtime loads.
            'libmonodroid.so'                              = @{ Package = $hostPack; Path = "runtimes/$($script:Target.Rid)/native/libnet-android.release.so" }
        }
        foreach ($name in $natives.Keys) {
            $source = $natives[$name]
            & $add "lib/$abi/$name" (Get-NativePayload -PackageId $source.Package -EntryPath $source.Path) $false 0
        }
    }

    $apkBytes = New-ApkArchive -Entries $entries
    $report = Test-ApkArchive -Apk $apkBytes -Entries $entries
    if ($Admission -eq 'NativeActivity') { Assert-NativeAdmissionApk -EntryNames $report.Names }

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $apkPath = Join-Path $outputDirectory 'Pwsh-unsigned.apk'
    if ($PSCmdlet.ShouldProcess($apkPath, 'Write unsigned APK')) {
        Write-BuildFile -Intermediate -Path $apkPath -Bytes $apkBytes
    }

    $apkStream = [System.IO.MemoryStream]::new([byte[]]$apkBytes, $false)
    try { $apkHash = Get-Sha256Hex -Stream $apkStream }
    finally { $apkStream.Dispose() }

    $script:BuildContext.UnsignedApk = [pscustomobject]@{
        Path   = $apkPath
        Bytes  = $apkBytes
        Sha256 = $apkHash
    }

    Write-Host ('[PASS] Step 10 complete: Pwsh-unsigned.apk assembled from {0} entries into {1} bytes, every entry read back byte-identical by an independent reader. SHA-256 {2}' -f
        $report.EntryCount,
        $report.Size,
        $apkHash) -ForegroundColor Green
}

function Get-LengthPrefixed {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes)

    $result = New-Object byte[] (4 + $Bytes.Length)
    [System.Array]::Copy([BitConverter]::GetBytes([uint32]$Bytes.Length), 0, $result, 0, 4)
    if ($Bytes.Length -gt 0) { [System.Array]::Copy($Bytes, 0, $result, 4, $Bytes.Length) }
    return ,$result
}

function Get-SigningCertificate {
    # A signing identity, created in process. No keytool, no keystore utility.
    # It is persisted so that rebuilds keep the same identity: Android refuses
    # to upgrade an installed app whose signer changed.
    param([Parameter(Mandatory)][string] $Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = [System.Security.Cryptography.X509Certificates.X509CertificateLoader]::LoadPkcs12(
            [System.IO.File]::ReadAllBytes($Path),
            'android',
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        return $existing
    }

    $key = [System.Security.Cryptography.RSA]::Create(2048)
    $request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=Pwsh, O=MansfieldPlumbing, C=US',
        $key,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add(
        [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($false, $false, 0, $true))

    # Android requires the certificate to outlive the app.
    $notBefore = [DateTimeOffset]::new([DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
    $notAfter = [DateTimeOffset]::new([DateTime]::new(2070, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
    $certificate = $request.CreateSelfSigned($notBefore, $notAfter)

    $exported = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, 'android')
    Write-BuildFile -Path $Path -Bytes $exported
    if (-not $IsWindows) {
        # Owner-only access to the private key (SC-12).
        [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]'UserRead, UserWrite')
    }
    return $certificate
}

function Get-ApkContentDigest {
    # APK Signature Scheme v2 digest: every section is split into 1 MB chunks,
    # each chunk digested with a 0xa5 prefix, and the concatenated chunk
    # digests digested again with a 0x5a prefix.
    param([Parameter(Mandatory)][object[]] $Sections)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $chunkSize = 1048576
        $chunkDigests = [System.Collections.Generic.List[byte]]::new()
        $chunkCount = 0
        foreach ($section in $Sections) {
            $bytes = [byte[]]$section
            $offset = 0
            while ($offset -lt $bytes.Length) {
                $length = [Math]::Min($chunkSize, $bytes.Length - $offset)
                $chunk = New-Object byte[] (5 + $length)
                $chunk[0] = 0xA5
                [System.Array]::Copy([BitConverter]::GetBytes([uint32]$length), 0, $chunk, 1, 4)
                [System.Buffer]::BlockCopy($bytes, $offset, $chunk, 5, $length)
                $chunkDigests.AddRange($sha256.ComputeHash($chunk))
                $chunkCount++
                $offset += $length
            }
        }

        $top = New-Object byte[] (5 + $chunkDigests.Count)
        $top[0] = 0x5A
        [System.Array]::Copy([BitConverter]::GetBytes([uint32]$chunkCount), 0, $top, 1, 4)
        $chunkDigests.CopyTo($top, 5)
        return ,$sha256.ComputeHash($top)
    }
    finally { $sha256.Dispose() }
}

function New-SignedApk {
    param(
        [Parameter(Mandatory)][byte[]] $Apk,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    # Locate the end of central directory record by scanning back for its
    # signature, then read the three sections the scheme digests.
    $eocdOffset = -1
    for ($i = $Apk.Length - 22; $i -ge 0; $i--) {
        if ([BitConverter]::ToUInt32($Apk, $i) -eq 0x06054B50) { $eocdOffset = $i; break }
    }
    if ($eocdOffset -lt 0) { throw 'The archive has no end of central directory record.' }

    $directorySize = [int][BitConverter]::ToUInt32($Apk, $eocdOffset + 12)
    $directoryOffset = [int][BitConverter]::ToUInt32($Apk, $eocdOffset + 16)

    $contents = New-Object byte[] $directoryOffset
    [System.Array]::Copy($Apk, 0, $contents, 0, $directoryOffset)
    $directory = New-Object byte[] $directorySize
    [System.Array]::Copy($Apk, $directoryOffset, $directory, 0, $directorySize)
    $eocd = New-Object byte[] ($Apk.Length - $eocdOffset)
    [System.Array]::Copy($Apk, $eocdOffset, $eocd, 0, $eocd.Length)

    $digest = Get-ApkContentDigest -Sections @($contents, $directory, $eocd)

    $algorithmId = [uint32]0x0103    # SHA256 with RSA, PKCS#1 v1.5
    $digestEntry = [System.Collections.Generic.List[byte]]::new()
    $digestEntry.AddRange([BitConverter]::GetBytes($algorithmId))
    $digestEntry.AddRange([BitConverter]::GetBytes([uint32]$digest.Length))
    $digestEntry.AddRange($digest)

    $digests = Get-LengthPrefixed (Get-LengthPrefixed $digestEntry.ToArray())
    $certificates = Get-LengthPrefixed (Get-LengthPrefixed $Certificate.RawData)
    $attributes = Get-LengthPrefixed (New-Object byte[] 0)

    $signedDataPayload = [System.Collections.Generic.List[byte]]::new()
    $signedDataPayload.AddRange($digests)
    $signedDataPayload.AddRange($certificates)
    $signedDataPayload.AddRange($attributes)
    $signedDataBytes = $signedDataPayload.ToArray()

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if ($null -eq $rsa) { throw 'The signing certificate carries no RSA private key.' }
    $signature = $rsa.SignData(
        $signedDataBytes,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)

    $signatureEntry = [System.Collections.Generic.List[byte]]::new()
    $signatureEntry.AddRange([BitConverter]::GetBytes($algorithmId))
    $signatureEntry.AddRange([BitConverter]::GetBytes([uint32]$signature.Length))
    $signatureEntry.AddRange($signature)

    $signer = [System.Collections.Generic.List[byte]]::new()
    $signer.AddRange((Get-LengthPrefixed $signedDataBytes))
    $signer.AddRange((Get-LengthPrefixed (Get-LengthPrefixed $signatureEntry.ToArray())))
    $signer.AddRange((Get-LengthPrefixed $Certificate.PublicKey.ExportSubjectPublicKeyInfo()))
    $signers = Get-LengthPrefixed (Get-LengthPrefixed $signer.ToArray())

    $pair = [System.Collections.Generic.List[byte]]::new()
    $pair.AddRange([BitConverter]::GetBytes([uint64](4 + $signers.Length)))
    $pair.AddRange([BitConverter]::GetBytes([uint32]0x7109871A))
    $pair.AddRange($signers)
    $pairBytes = $pair.ToArray()

    $blockSize = [uint64]($pairBytes.Length + 24)
    $block = [System.Collections.Generic.List[byte]]::new()
    $block.AddRange([BitConverter]::GetBytes($blockSize))
    $block.AddRange($pairBytes)
    $block.AddRange([BitConverter]::GetBytes($blockSize))
    $block.AddRange([System.Text.Encoding]::ASCII.GetBytes('APK Sig Block 42'))
    $blockBytes = $block.ToArray()

    # The central directory moves by exactly the block length, and the end of
    # central directory record has to say so.
    $patchedEocd = [byte[]]$eocd.Clone()
    [System.Array]::Copy([BitConverter]::GetBytes([uint32]($directoryOffset + $blockBytes.Length)), 0, $patchedEocd, 16, 4)

    $signed = New-Object byte[] ($contents.Length + $blockBytes.Length + $directory.Length + $patchedEocd.Length)
    $position = 0
    foreach ($part in @($contents, $blockBytes, $directory, $patchedEocd)) {
        [System.Array]::Copy($part, 0, $signed, $position, $part.Length)
        $position += $part.Length
    }

    return [pscustomobject]@{
        Bytes          = $signed
        BlockSize      = $blockBytes.Length
        Digest         = [Convert]::ToHexString($digest)
        SignatureSize  = $signature.Length
        DirectoryMoved = $blockBytes.Length
    }
}

function Test-SignedApk {
    param(
        [Parameter(Mandatory)][byte[]] $Apk,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2] $Certificate
    )

    # Find the signing block by its magic, exactly as the platform verifier
    # does, then recompute the digest over the three sections and check the
    # signature the block carries.
    $eocdOffset = -1
    for ($i = $Apk.Length - 22; $i -ge 0; $i--) {
        if ([BitConverter]::ToUInt32($Apk, $i) -eq 0x06054B50) { $eocdOffset = $i; break }
    }
    if ($eocdOffset -lt 0) { throw 'The signed archive has no end of central directory record.' }
    $directoryOffset = [int][BitConverter]::ToUInt32($Apk, $eocdOffset + 16)
    $directorySize = [int][BitConverter]::ToUInt32($Apk, $eocdOffset + 12)

    $magic = [System.Text.Encoding]::ASCII.GetString($Apk, $directoryOffset - 16, 16)
    if ($magic -cne 'APK Sig Block 42') {
        throw "The bytes before the central directory are '$magic', not an APK signing block."
    }
    $blockSize = [int][BitConverter]::ToUInt64($Apk, $directoryOffset - 24)
    $blockStart = $directoryOffset - ($blockSize + 8)
    if ($blockStart -lt 0) { throw 'The signing block size runs past the start of the archive.' }
    if ([int][BitConverter]::ToUInt64($Apk, $blockStart) -ne $blockSize) {
        throw 'The signing block size fields disagree.'
    }
    $pairId = [BitConverter]::ToUInt32($Apk, $blockStart + 16)
    if ($pairId -ne 0x7109871A) {
        throw ('The signing block carries id 0x{0:X8}, not the v2 scheme id.' -f $pairId)
    }

    # Rebuild the sections as the verifier sees them: the end of central
    # directory is digested with its offset field pointing at the signing block.
    $contents = New-Object byte[] $blockStart
    [System.Array]::Copy($Apk, 0, $contents, 0, $blockStart)
    $directory = New-Object byte[] $directorySize
    [System.Array]::Copy($Apk, $directoryOffset, $directory, 0, $directorySize)
    $eocd = New-Object byte[] ($Apk.Length - $eocdOffset)
    [System.Array]::Copy($Apk, $eocdOffset, $eocd, 0, $eocd.Length)
    [System.Array]::Copy([BitConverter]::GetBytes([uint32]$blockStart), 0, $eocd, 16, 4)

    $digest = Get-ApkContentDigest -Sections @($contents, $directory, $eocd)

    # Walk into the block far enough to recover signed data and signature.
    $cursor = $blockStart + 20                       # block size, pair size, id
    $cursor += 4                                     # signers sequence length
    $cursor += 4                                     # signer length
    $signedDataLength = [int][BitConverter]::ToUInt32($Apk, $cursor); $cursor += 4
    $signedData = New-Object byte[] $signedDataLength
    [System.Array]::Copy($Apk, $cursor, $signedData, 0, $signedDataLength)
    $cursor += $signedDataLength
    $cursor += 4                                     # signatures sequence length
    $cursor += 4                                     # signature length
    $cursor += 4                                     # algorithm id
    $signatureLength = [int][BitConverter]::ToUInt32($Apk, $cursor); $cursor += 4
    $signature = New-Object byte[] $signatureLength
    [System.Array]::Copy($Apk, $cursor, $signature, 0, $signatureLength)

    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($Certificate)
    $valid = $rsa.VerifyData(
        $signedData,
        $signature,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $valid) { throw 'The signature in the signing block does not verify against the signing certificate.' }

    # The digest inside signed data must match the one just recomputed.
    $embedded = [Convert]::ToHexString($signedData[16..47])
    if ($embedded -cne [Convert]::ToHexString($digest)) {
        throw "The signed digest is $embedded but the archive digests to $([Convert]::ToHexString($digest))."
    }

    return [pscustomobject]@{
        Digest        = [Convert]::ToHexString($digest)
        SignatureSize = $signatureLength
        BlockSize     = $blockSize
    }
}

function Invoke-SignStep {

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    # The signing identity outlives any build folder: Android refuses to upgrade
    # an installed app whose signer changed, so the key lives in the user's
    # local application data rather than beside disposable output.
    $certificate = Get-SigningCertificate -Path $SigningKeyPath

    $signed = New-SignedApk -Apk ([byte[]]$script:BuildContext.UnsignedApk.Bytes) -Certificate $certificate
    $report = Test-SignedApk -Apk $signed.Bytes -Certificate $certificate

    $apkPath = $script:ApkPath
    if ($PSCmdlet.ShouldProcess($apkPath, 'Write signed APK')) {
        Write-BuildFile -Path $apkPath -Bytes $signed.Bytes
    }

    $apkStream = [System.IO.MemoryStream]::new([byte[]]$signed.Bytes, $false)
    try { $apkHash = Get-Sha256Hex -Stream $apkStream }
    finally { $apkStream.Dispose() }

    $script:BuildContext.SignedApk = [pscustomobject]@{
        Path        = $apkPath
        Bytes       = $signed.Bytes
        Sha256      = $apkHash
        Certificate = $certificate.Thumbprint
    }

    Write-Host ('[PASS] Step 11 complete: {5} signed with APK Signature Scheme v2. {0} bytes, {1}-byte signing block, {2}-byte RSA signature, certificate {3}. Signature re-verified against the recomputed content digest. SHA-256 {4}' -f
        $signed.Bytes.Length,
        $report.BlockSize,
        $report.SignatureSize,
        $certificate.Thumbprint,
        $apkHash,
        $apkPath) -ForegroundColor Green
    Write-Host ('       Install with: adb install -r "{0}"' -f $apkPath) -ForegroundColor DarkCyan
}

function Get-RegisteredJavaTypes {
    # Every managed type that has a Java peer says so itself, through a Register
    # attribute carrying the JNI name. That is the whole type map: read the
    # attribute, pair the managed name with the Java name, keep the token.
    param([Parameter(Mandatory)][byte[]] $AssemblyBytes)

    $stream = [System.IO.MemoryStream]::new($AssemblyBytes, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $mvid = $reader.GetGuid($reader.GetModuleDefinition().Mvid).ToByteArray()
        $types = [System.Collections.Generic.List[object]]::new()

        foreach ($handle in $reader.TypeDefinitions) {
            $type = $reader.GetTypeDefinition($handle)
            foreach ($attributeHandle in $type.GetCustomAttributes()) {
                $attribute = $reader.GetCustomAttribute($attributeHandle)

                # The attribute's constructor is a MemberReference when the
                # attribute lives in another assembly and a MethodDefinition
                # when it is declared in this one, which is the case for
                # Mono.Android itself.
                $attributeName = $null
                if ($attribute.Constructor.Kind -eq [System.Reflection.Metadata.HandleKind]::MemberReference) {
                    $member = $reader.GetMemberReference([System.Reflection.Metadata.MemberReferenceHandle]$attribute.Constructor)
                    if ($member.Parent.Kind -eq [System.Reflection.Metadata.HandleKind]::TypeReference) {
                        $attributeName = $reader.GetString($reader.GetTypeReference([System.Reflection.Metadata.TypeReferenceHandle]$member.Parent).Name)
                    }
                }
                elseif ($attribute.Constructor.Kind -eq [System.Reflection.Metadata.HandleKind]::MethodDefinition) {
                    $method = $reader.GetMethodDefinition([System.Reflection.Metadata.MethodDefinitionHandle]$attribute.Constructor)
                    $attributeName = $reader.GetString($reader.GetTypeDefinition($method.GetDeclaringType()).Name)
                }
                if ($attributeName -cne 'RegisterAttribute') { continue }

                $blob = $reader.GetBlobReader($attribute.Value)
                [void]$blob.ReadUInt16()
                $javaName = $null
                try { $javaName = $blob.ReadSerializedString() } catch { }
                # A JNI type name is slash separated. Anything containing a dot
                # came from an attribute shaped differently than expected, and
                # the runtime rejects it outright, so drop it here instead.
                if ([string]::IsNullOrEmpty($javaName) -or $javaName.Contains('.')) { break }

                # Upstream records the type's FullName. A nested type carries no
                # namespace of its own and is written Outer+Inner, so walk the
                # declaring chain rather than reading Namespace directly.
                $managedName = $reader.GetString($type.Name)
                $outermost = $type
                $declaringHandle = $type.GetDeclaringType()
                while (-not $declaringHandle.IsNil) {
                    $outermost = $reader.GetTypeDefinition($declaringHandle)
                    $managedName = "$($reader.GetString($outermost.Name))+$managedName"
                    $declaringHandle = $outermost.GetDeclaringType()
                }
                $namespace = $reader.GetString($outermost.Namespace)
                if (-not [string]::IsNullOrEmpty($namespace)) { $managedName = "$namespace.$managedName" }

                $types.Add([pscustomobject]@{
                    ManagedName = $managedName
                    JavaName    = $javaName
                    Token       = [uint32][System.Reflection.Metadata.Ecma335.MetadataTokens]::GetToken(
                        [System.Reflection.Metadata.EntityHandle]$handle)
                })
                break
            }
        }

        return [pscustomobject]@{ Mvid = $mvid; Types = $types }
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }
}

function Get-TypeMapModules {
    # Assemblies that declare Java peers. The emitted assembly comes last so its
    # own activity is registered alongside the framework bindings.
    # Any assembly in the payload may declare Java peers, and a module the
    # runtime cannot find by MVID is a hard failure, so scan all of them rather
    # than guessing which three matter.
    $modules = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($script:BuildContext.SelectedAssemblies.Keys)) {
        $candidate = $script:BuildContext.SelectedAssemblies[$name]
        if ($null -eq $candidate) { continue }
        $scanned = Get-RegisteredJavaTypes -AssemblyBytes ([byte[]]$candidate.Bytes)
        # An assembly with no Java peers still needs a module entry: the runtime
        # looks modules up by MVID before it looks for a type, and a missing
        # module is reported as a failure rather than an empty result.
        # The emitted assembly's activity declares its Java peer through an
        # Activity attribute with an explicit Name, not through Register, so the
        # scan above does not see it. Add it from the identity we already
        # derived, or the runtime finds the module and no type inside it.
        if ($name -ceq "$($script:AssemblyName).dll") {
            $identity = Get-EmittedActivityIdentity
            $scanned.Types.Add([pscustomobject]@{
                ManagedName = $identity.ManagedTypeName
                JavaName    = ($script:JavaPeerName -replace '\.', '/')
                Token       = $identity.Token
            })
        }

        $modules.Add([pscustomobject]@{
            AssemblyName = [System.IO.Path]::GetFileNameWithoutExtension($name)
            Mvid         = $scanned.Mvid
            Types        = $scanned.Types
        })
    }
    if ($modules.Count -eq 0) { throw 'No assembly in the payload declares a Java peer type.' }
    return $modules
}

function Get-ReturnStubBytes {
    # Four bytes holding one return instruction for the target, from that
    # target's encoder. x86-64's ret is one byte; int3 (0xCC) pads the rest.
    switch ($Architecture) {
        'arm64' { return [BitConverter]::GetBytes([uint32](New-A64BranchRegister -Op 'ret')) }
        'x64'   { return [byte[]](@(New-X64Instruction -Step @{ Op = 'ret' }) + @(0xCC, 0xCC, 0xCC)) }
        'arm32' { return [BitConverter]::GetBytes([uint32](New-A32Instruction -Step @{ Op = 'bx'; Rm = 14 })[0]) }
        default { throw "No return stub for $Architecture." }
    }
}

function New-XamarinAppLibrary {
    # libxamarin-app.so carries the data the Android host reads at startup. The
    # symbol list is the one ApplicationConfigNativeAssemblyGeneratorCLR.cs
    # emits, and the ApplicationConfig layout is ApplicationConfigCLR.cs, both
    # pinned in lib/. Nothing here is copied from a device artifact.
    param(
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][int] $AssemblyCount,
        [Parameter(Mandatory)][uint32] $JniEnvInitClassToken,
        [Parameter(Mandatory)][uint32] $JniEnvInitializeMethodToken,
        [Parameter(Mandatory)][uint32] $JniEnvRegisterJniNativesMethodToken,
        [Parameter(Mandatory)][System.Collections.Generic.List[object]] $TypeMapModules,
        [int] $PageSize = 16384
    )

    $elf = Get-ElfConstants

    # Properties handed to coreclr_initialize. The host fills in the value for
    # HOST_RUNTIME_CONTRACT, which is why it must come first and why its value
    # is left null here; every other value has to be supplied by us, because a
    # null value is dereferenced during initialization.
    #
    # The RuntimeFeature switches are not decoration. Mono.Android reads them to
    # decide which runtime it is hosted on: without them it takes the MonoVM
    # path and calls an internal method CoreCLR refuses to bind, failing with
    # "ECall methods must be packaged into a system module".
    $runtimeProperties = [ordered]@{
        'HOST_RUNTIME_CONTRACT'                                        = $null
        'Microsoft.Android.Runtime.RuntimeFeature.IsCoreClrRuntime'    = 'true'
        'Microsoft.Android.Runtime.RuntimeFeature.IsMonoRuntime'       = 'false'
        'Microsoft.Android.Runtime.RuntimeFeature.IsNativeAotRuntime'  = 'false'
        'Java.Interop.RuntimeFeature.ManagedPeerNativeRegistration'    = 'false'
        'Microsoft.Android.Runtime.RuntimeFeature.ManagedToJavaUsesAssemblyFullName' = 'false'
        'Microsoft.Android.Runtime.RuntimeFeature.TrimmableTypeMap'    = 'false'
    }

    # From 37.0.0-rc.1 the host also fills RUNTIME_IDENTIFIER and
    # APP_CONTEXT_BASE_DIRECTORY, by position, right after the contract
    # (dotnet/android host.cc, ApplicationConfigNativeAssemblyGeneratorCLR.cs).
    # An older host leaves those slots null, so they exist only for a new one.
    $hostVersion = [string]@($script:PackageManifest | Where-Object { $_.Channel -eq 'Android' })[0].Version
    if ((Get-VersionSortKey $hostVersion) -ge (Get-VersionSortKey '37.0.0-rc.1')) {
        $hostFilled = [ordered]@{
            'HOST_RUNTIME_CONTRACT'      = $null
            'RUNTIME_IDENTIFIER'         = $null
            'APP_CONTEXT_BASE_DIRECTORY' = $null
        }
        foreach ($key in $runtimeProperties.Keys) {
            if (-not $hostFilled.Contains($key)) { $hostFilled[$key] = $runtimeProperties[$key] }
        }
        $runtimeProperties = $hostFilled
    }

    # Pointer width from the target's ELF class. Only pointer-typed fields
    # change size; the fixed-width fields (uint32_t, uint64_t) do not.
    $pointerSize = $script:Target.ElfClass / 8
    $writePointer = { if ($pointerSize -eq 4) { $writer.Write([uint32]0) } else { $writer.Write([uint64]0) } }

    $data = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($data, [System.Text.Encoding]::UTF8, $true)
    $symbols = [System.Collections.Generic.List[object]]::new()
    $relocations = [System.Collections.Generic.List[object]]::new()

    $align = {
        param([int] $Boundary)
        while (($data.Position % $Boundary) -ne 0) { $data.WriteByte(0) }
    }
    $define = {
        param([string] $Name, [int] $Size, [string] $Kind = 'OBJECT')
        $symbols.Add([pscustomobject]@{ Name = $Name; Offset = [int]$data.Position; Size = $Size; Kind = $Kind })
    }
    $zeros = {
        param([string] $Name, [int] $Size, [int] $Alignment = 8)
        & $align $Alignment
        & $define $Name $Size
        if ($Size -gt 0) { Write-ByteSpan -Writer $writer -Bytes (New-Object byte[] $Size) }
    }

    # Strings first, so their offsets are known when pointers are written.
    & $align 8
    $packageNameOffset = [int]$data.Position
    Write-ByteSpan -Writer $writer -Bytes ([System.Text.Encoding]::UTF8.GetBytes($PackageName))
    $writer.Write([byte]0)

    $propertyNameOffsets = @()
    $propertyValueOffsets = @()
    foreach ($property in $runtimeProperties.Keys) {
        $propertyNameOffsets += [int]$data.Position
        Write-ByteSpan -Writer $writer -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$property))
        $writer.Write([byte]0)

        $value = $runtimeProperties[$property]
        if ($null -eq $value) {
            $propertyValueOffsets += -1
        }
        else {
            $propertyValueOffsets += [int]$data.Position
            Write-ByteSpan -Writer $writer -Bytes ([System.Text.Encoding]::UTF8.GetBytes([string]$value))
            $writer.Write([byte]0)
        }
    }

    # format_tag, the value xamarin-app.hh declares.
    & $align 8
    & $define 'format_tag' 8
    $writer.Write([uint64]0x00045E6972616D58)

    # application_config. Field order is ApplicationConfigCLR.cs exactly. The
    # pointer after the 13 uint32_t fields lands at 56 on both widths; the two
    # trailing bools follow it, and the struct pads to its pointer alignment.
    $applicationConfigSize = 56 + $pointerSize + 2
    $applicationConfigSize += ($pointerSize - ($applicationConfigSize % $pointerSize)) % $pointerSize
    & $align 8
    $applicationConfigOffset = [int]$data.Position
    & $define 'application_config' $applicationConfigSize
    $writer.Write([byte]0)      # uses_assembly_preload
    $writer.Write([byte]0)      # jni_add_native_method_registration_attribute_present
    $writer.Write([byte]0)      # marshal_methods_enabled
    $writer.Write([byte]0)      # ignore_split_configs
    $writer.Write([uint32]$runtimeProperties.Count)
    $writer.Write([uint32]3)    # package_naming_policy: LowercaseCrc64
    $writer.Write([uint32]0)    # environment_variable_count
    $writer.Write([uint32]0)    # system_property_count
    $writer.Write([uint32]$AssemblyCount)
    $writer.Write([uint32]0)    # bundled_assembly_name_width
    $writer.Write([uint32]0)    # number_of_dso_cache_entries
    $writer.Write([uint32]0)    # number_of_shared_libraries
    $writer.Write([uint32]$JniEnvInitClassToken)
    $writer.Write([uint32]$JniEnvInitializeMethodToken)
    $writer.Write([uint32]$JniEnvRegisterJniNativesMethodToken)
    $writer.Write([uint32]0)    # jni_remapping_replacement_type_count
    $writer.Write([uint32]0)    # jni_remapping_replacement_method_index_entry_count
    $packageNamePointerOffset = [int]$data.Position
    & $writePointer             # android_package_name, supplied by relocation
    $writer.Write([byte]1)      # have_assembly_store
    $writer.Write([byte]0)      # assembly_store_decompression_cache_enabled
    Write-ByteSpan -Writer $writer -Bytes (New-Object byte[] ($applicationConfigSize - 56 - $pointerSize - 2))

    $relocations.Add([pscustomobject]@{ Offset = $packageNamePointerOffset; Target = $packageNameOffset })

    # Property name and value tables. The values are filled in by the host.
    & $align 8
    & $define 'init_runtime_property_names' ($runtimeProperties.Count * $pointerSize)
    foreach ($offset in $propertyNameOffsets) {
        $relocations.Add([pscustomobject]@{ Offset = [int]$data.Position; Target = $offset })
        & $writePointer
    }

    & $align 8
    & $define 'init_runtime_property_values' ($runtimeProperties.Count * $pointerSize)
    foreach ($offset in $propertyValueOffsets) {
        if ($offset -ge 0) {
            $relocations.Add([pscustomobject]@{ Offset = [int]$data.Position; Target = $offset })
        }
        & $writePointer
    }

    # Assembly store runtime state. The host populates both.
    # AssemblyStoreRuntimeData: pointer, uint32_t, uint32_t, pointer.
    # AssemblyStoreSingleAssemblyRuntimeData: four pointers.
    & $zeros 'assembly_store' (8 + 2 * $pointerSize)
    & $zeros 'assembly_store_bundled_assemblies' ($AssemblyCount * 4 * $pointerSize)

    # Everything else is declared and empty: the counts beside them are zero,
    # so the runtime never walks into these.
    & $zeros 'app_environment_variables' 0
    & $zeros 'app_environment_variable_contents' 1 1
    & $zeros 'app_system_properties' 0
    & $zeros 'app_system_property_contents' 1 1
    & $zeros 'bundled_assemblies' 0
    & $zeros 'dso_cache' 0
    & $zeros 'dso_names_data' 1 1
    & $zeros 'dso_jni_preloads_idx' 0
    & $align 4
    & $define 'dso_jni_preloads_idx_stride' 4
    $writer.Write([uint32]0)
    & $align 4
    & $define 'dso_jni_preloads_idx_count' 4
    $writer.Write([uint32]0)
    & $align 4
    & $define 'compressed_assembly_count' 4
    $writer.Write([uint32]0)
    & $zeros 'compressed_assembly_descriptors' 0
    & $align 4
    & $define 'uncompressed_assemblies_data_size' 4
    $writer.Write([uint32]0)
    # Type map. Every managed type with a Java peer, from every assembly that
    # declares one. The runtime matches a module by MVID, hashes the managed
    # type name with CRC-32, binary searches that module's slice of
    # modules_map_data, and follows java_map_index into java_to_managed_map.
    # Structures are TypeMapModule, TypeMapModuleEntry and TypeMapJava from the
    # pinned xamarin-app.hh.
    $javaNameBlob = [System.IO.MemoryStream]::new()
    $managedNameBlob = [System.IO.MemoryStream]::new()
    $assemblyNameBlob = [System.IO.MemoryStream]::new()
    $javaEntries = [System.Collections.Generic.List[object]]::new()
    $moduleRecords = [System.Collections.Generic.List[object]]::new()
    $moduleEntries = [System.Collections.Generic.List[object]]::new()

    $appendUtf8 = {
        param([System.IO.MemoryStream] $Target, [string] $Value)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $offset = [int]$Target.Position
        $Target.Write($bytes, 0, $bytes.Length)
        $Target.WriteByte(0)
        return @($offset, $bytes.Length)
    }

    foreach ($module in $TypeMapModules) {
        $assemblyPlacement = & $appendUtf8 $assemblyNameBlob $module.AssemblyName
        $mapIndex = $moduleEntries.Count

        # Entries are binary searched by hash, so they are sorted by it. A type
        # whose hash collides with another in the same module would need the
        # duplicate table; none do here, and the build fails loudly if that
        # changes rather than silently mapping the wrong type.
        $entries = [System.Collections.Generic.List[object]]::new()
        foreach ($type in $module.Types) {
            $managedPlacement = & $appendUtf8 $managedNameBlob $type.ManagedName
            $javaPlacement = & $appendUtf8 $javaNameBlob $type.JavaName
            $javaIndex = $javaEntries.Count

            $javaEntries.Add([pscustomobject]@{
                ModuleIndex       = $moduleRecords.Count
                ManagedNameIndex  = $managedPlacement[0]
                ManagedNameLength = $managedPlacement[1]
                Token             = $type.Token
                JavaNameIndex     = $javaPlacement[0]
                JavaNameLength    = $javaPlacement[1]
                JavaHash          = Get-Crc32 -Data ([System.Text.Encoding]::UTF8.GetBytes($type.JavaName))
            })

            $entries.Add([pscustomobject]@{
                Hash              = Get-Crc32 -Data ([System.Text.Encoding]::UTF8.GetBytes($type.ManagedName))
                ManagedNameIndex  = $managedPlacement[0]
                ManagedNameLength = $managedPlacement[1]
                JavaMapIndex      = $javaIndex
            })
        }

        foreach ($entry in ($entries | Sort-Object Hash)) { $moduleEntries.Add($entry) }

        $moduleRecords.Add([pscustomobject]@{
            Mvid               = $module.Mvid
            EntryCount         = $entries.Count
            AssemblyNameIndex  = $assemblyPlacement[0]
            AssemblyNameLength = $assemblyPlacement[1]
            MapIndex           = $mapIndex
        })
    }

    $javaNameBytes = $javaNameBlob.ToArray(); $javaNameBlob.Dispose()
    $managedNameBytes = $managedNameBlob.ToArray(); $managedNameBlob.Dispose()
    $assemblyNameBytes = $assemblyNameBlob.ToArray(); $assemblyNameBlob.Dispose()
    # find_module_entry binary searches managed_to_java_map by MVID, so the
    # module array must be sorted by MVID bytes. Emitting it in payload order
    # makes the search miss modules that are present. TypeMapJava.module_index
    # refers to positions in this array, so those are remapped after sorting.
    $moduleOrder = @(0..($moduleRecords.Count - 1))
    $sortedModules = @($moduleOrder | Sort-Object -Property @{ Expression = {
        $bytes = $moduleRecords[$_].Mvid
        ($bytes | ForEach-Object { $_.ToString('X2') }) -join ''
    } })
    $modulePosition = New-Object int[] $moduleRecords.Count
    for ($i = 0; $i -lt $sortedModules.Count; $i++) { $modulePosition[$sortedModules[$i]] = $i }
    foreach ($entry in $javaEntries) { $entry.ModuleIndex = $modulePosition[$entry.ModuleIndex] }
    $moduleRecords = [System.Collections.Generic.List[object]](@($sortedModules | ForEach-Object { $moduleRecords[$_] }))

    # java_to_managed_hashes is binary searched, so the java side must be sorted
    # by hash. The module entries recorded their java_map_index against the
    # unsorted order, so those indices are remapped here. Without this every
    # lookup succeeds and returns an unrelated Java type.
    for ($i = 0; $i -lt $javaEntries.Count; $i++) {
        $javaEntries[$i] | Add-Member -NotePropertyName OriginalIndex -NotePropertyValue $i -Force
    }
    $sortedJava = @($javaEntries | Sort-Object JavaHash)
    $remap = New-Object int[] $javaEntries.Count
    for ($i = 0; $i -lt $sortedJava.Count; $i++) { $remap[$sortedJava[$i].OriginalIndex] = $i }
    foreach ($entry in $moduleEntries) { $entry.JavaMapIndex = $remap[$entry.JavaMapIndex] }

    & $align 4
    & $define 'managed_to_java_map_module_count' 4
    $writer.Write([uint32]$moduleRecords.Count)
    & $align 4
    & $define 'java_type_count' 4
    $writer.Write([uint32]$sortedJava.Count)
    & $align 8
    & $define 'java_type_names_size' 8
    $writer.Write([uint64]$javaNameBytes.Length)

    & $align 1
    & $define 'java_type_names' $javaNameBytes.Length
    Write-ByteSpan -Writer $writer -Bytes $javaNameBytes

    & $align 1
    & $define 'managed_type_names' $managedNameBytes.Length
    Write-ByteSpan -Writer $writer -Bytes $managedNameBytes

    & $align 1
    & $define 'managed_assembly_names' $assemblyNameBytes.Length
    Write-ByteSpan -Writer $writer -Bytes $assemblyNameBytes

    & $align 8
    & $define 'managed_to_java_map' ($moduleRecords.Count * 40)
    foreach ($record in $moduleRecords) {
        Write-ByteSpan -Writer $writer -Bytes ([byte[]]$record.Mvid)
        $writer.Write([uint32]$record.EntryCount)
        $writer.Write([uint32]0)
        $writer.Write([uint32]$record.AssemblyNameIndex)
        $writer.Write([uint32]$record.AssemblyNameLength)
        $writer.Write([uint32]$record.MapIndex)
        $writer.Write([uint32]([uint32]::MaxValue))
    }

    & $align 4
    & $define 'modules_map_data' ($moduleEntries.Count * 16)
    foreach ($entry in $moduleEntries) {
        $writer.Write([uint32]$entry.Hash)
        $writer.Write([uint32]$entry.ManagedNameIndex)
        $writer.Write([uint32]$entry.ManagedNameLength)
        $writer.Write([uint32]$entry.JavaMapIndex)
    }

    & $zeros 'modules_duplicates_data' 0

    & $align 4
    & $define 'java_to_managed_map' ($sortedJava.Count * 24)
    foreach ($entry in $sortedJava) {
        $writer.Write([uint32]$entry.ModuleIndex)
        $writer.Write([uint32]$entry.ManagedNameIndex)
        $writer.Write([uint32]$entry.ManagedNameLength)
        $writer.Write([uint32]$entry.Token)
        $writer.Write([uint32]$entry.JavaNameIndex)
        $writer.Write([uint32]$entry.JavaNameLength)
    }

    & $align 4
    & $define 'java_to_managed_hashes' ($sortedJava.Count * 4)
    foreach ($entry in $sortedJava) { $writer.Write([uint32]$entry.JavaHash) }

    $script:LastTypeMapCounts = [pscustomobject]@{
        Modules = $moduleRecords.Count
        Types   = $sortedJava.Count
    }
    & $zeros 'jni_remapping_method_replacement_index' 0
    & $zeros 'jni_remapping_type_replacements' 0

    # xamarin_app_init: the host calls it to hand over a function pointer
    # resolver. With marshal methods disabled there is nothing to record. The
    # symbol points at the return stub the ELF writer places in the executable
    # segment; nothing is written into the data here.
    & $define 'xamarin_app_init' 4 'FUNC'

    $writer.Flush()
    $payload = $data.ToArray()
    $writer.Dispose()
    $data.Dispose()

    # uncompressed_assemblies_data_buffer lives past the end of the file image.
    $bssSize = 8

    return New-ElfDataLibrary `
        -Soname 'libxamarin-app.so' `
        -Payload $payload `
        -Symbols $symbols `
        -Relocations $relocations `
        -BssSymbolName 'uncompressed_assemblies_data_buffer' `
        -BssSize $bssSize `
        -PageSize $PageSize
}

function Get-JniEnvInitTokens {
    # application_config carries metadata tokens into Mono.Android.dll, so they
    # are read out of the very image this APK ships rather than hard coded.
    # Despite the field name, the class is Android.Runtime.JNIEnvInit.
    $candidate = $script:BuildContext.SelectedAssemblies['Mono.Android.dll']
    if ($null -eq $candidate) { throw 'Mono.Android.dll is not among the selected assemblies.' }

    $stream = [System.IO.MemoryStream]::new([byte[]]$candidate.Bytes, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        foreach ($handle in $reader.TypeDefinitions) {
            $type = $reader.GetTypeDefinition($handle)
            if ($reader.GetString($type.Namespace) -cne 'Android.Runtime') { continue }
            if ($reader.GetString($type.Name) -cne 'JNIEnvInit') { continue }

            $classToken = [System.Reflection.Metadata.Ecma335.MetadataTokens]::GetToken(
                [System.Reflection.Metadata.EntityHandle]$handle)
            $initialize = 0
            $register = 0
            foreach ($methodHandle in $type.GetMethods()) {
                $method = $reader.GetMethodDefinition($methodHandle)
                $name = $reader.GetString($method.Name)
                $token = [System.Reflection.Metadata.Ecma335.MetadataTokens]::GetToken(
                    [System.Reflection.Metadata.EntityHandle]$methodHandle)
                if ($name -ceq 'Initialize') { $initialize = $token }
                elseif ($name -ceq 'RegisterJniNatives') { $register = $token }
            }
            if ($initialize -eq 0 -or $register -eq 0) {
                throw 'Android.Runtime.JNIEnvInit does not declare both Initialize and RegisterJniNatives.'
            }
            return [pscustomobject]@{
                ClassToken         = [uint32]$classToken
                InitializeToken    = [uint32]$initialize
                RegisterJniToken   = [uint32]$register
            }
        }
        throw 'Android.Runtime.JNIEnvInit was not found in Mono.Android.dll.'
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }
}

function Get-EmittedActivityIdentity {
    # The typemap is keyed by the module's MVID, and the Java to managed
    # direction carries the type's metadata token. Both are read back out of the
    # assembly setup.ps1 just emitted.
    $candidate = $script:BuildContext.SelectedAssemblies["$($script:AssemblyName).dll"]
    if ($null -eq $candidate) { throw "$($script:AssemblyName).dll is not among the selected assemblies." }

    $stream = [System.IO.MemoryStream]::new([byte[]]$candidate.Bytes, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $moduleDefinition = $reader.GetModuleDefinition()
        $mvid = $reader.GetGuid($moduleDefinition.Mvid)

        $fullName = "$($script:ManagedNamespace).$($script:ActivityClassName)"
        foreach ($handle in $reader.TypeDefinitions) {
            $type = $reader.GetTypeDefinition($handle)
            $name = $reader.GetString($type.Name)
            $namespace = $reader.GetString($type.Namespace)
            if ("$namespace.$name" -cne $fullName) { continue }
            $token = [System.Reflection.Metadata.Ecma335.MetadataTokens]::GetToken(
                [System.Reflection.Metadata.EntityHandle]$handle)
            return [pscustomobject]@{
                Mvid            = $mvid.ToByteArray()
                Token           = [uint32]$token
                ManagedTypeName = $fullName
            }
        }
        throw "'$fullName' was not found in the emitted assembly."
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }
}
function Invoke-AppDataStep {
    if (Skip-ForNativeAdmission -Step 9 -Output 'libxamarin-app.so') { return }

    $tokens = Get-JniEnvInitTokens
    $typeMapModules = Get-TypeMapModules
    $contract = Get-AndroidNativeContract
    $assemblyCount = $script:BuildContext.SelectedAssemblies.Count

    $library = New-XamarinAppLibrary `
        -PackageName $script:PackageName `
        -AssemblyCount $assemblyCount `
        -JniEnvInitClassToken $tokens.ClassToken `
        -JniEnvInitializeMethodToken $tokens.InitializeToken `
        -JniEnvRegisterJniNativesMethodToken $tokens.RegisterJniToken `
        -TypeMapModules $typeMapModules `
        -PageSize ([int]$contract.elf.maxPageSize)

    # The symbols the shipped runtime leaves undefined. If any is missing the
    # loader rejects the library, so they are checked here instead.
    $required = @(
        'format_tag', 'application_config', 'assembly_store', 'assembly_store_bundled_assemblies',
        'app_environment_variables', 'app_environment_variable_contents',
        'app_system_properties', 'app_system_property_contents',
        'bundled_assemblies', 'dso_cache', 'dso_names_data', 'dso_jni_preloads_idx',
        'dso_jni_preloads_idx_count', 'dso_jni_preloads_idx_stride',
        'init_runtime_property_names', 'init_runtime_property_values',
        'compressed_assembly_count', 'compressed_assembly_descriptors',
        'uncompressed_assemblies_data_size', 'uncompressed_assemblies_data_buffer',
        'managed_to_java_map_module_count', 'java_type_count', 'java_type_names',
        'java_type_names_size', 'managed_type_names', 'managed_assembly_names',
        'managed_to_java_map', 'modules_map_data', 'modules_duplicates_data',
        'java_to_managed_map', 'java_to_managed_hashes',
        'jni_remapping_method_replacement_index', 'jni_remapping_type_replacements',
        'xamarin_app_init'
    )
    $report = Test-XamarinAppLibrary -Library $library -RequiredSymbols $required -PackageName $script:PackageName -AssemblyCount $assemblyCount

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $libraryPath = Join-Path $outputDirectory 'libxamarin-app.so'
    if ($PSCmdlet.ShouldProcess($libraryPath, 'Write application data library')) {
        Write-BuildFile -Intermediate -Path $libraryPath -Bytes $library.Bytes
    }

    $libraryStream = [System.IO.MemoryStream]::new([byte[]]$library.Bytes, $false)
    try { $libraryHash = Get-Sha256Hex -Stream $libraryStream }
    finally { $libraryStream.Dispose() }

    $script:BuildContext.XamarinApp = [pscustomobject]@{
        Path   = $libraryPath
        Bytes  = $library.Bytes
        Sha256 = $libraryHash
    }

    Write-Host ('[PASS] Step 9 complete: libxamarin-app.so emitted as {0} bytes exporting {1} symbols with {2} relative relocations. application_config declares {3} assemblies, package {4}, JNIEnvInit token 0x{5:X8}. All {6} symbols the runtime leaves undefined resolve. SHA-256 {7}' -f
        $report.Size,
        $report.SymbolCount,
        $report.RelocationCount,
        $assemblyCount,
        $script:PackageName,
        $tokens.ClassToken,
        $report.Verified,
        $libraryHash) -ForegroundColor Green
}

function New-ResStringPool {
    # ResStringPool_header (ResourceTypes.h): UTF-16, no styles, 4-byte padded.
    param([Parameter(Mandatory)][string[]] $Strings)

    $data = [System.IO.MemoryStream]::new()
    $dataWriter = [System.IO.BinaryWriter]::new($data)
    $offsets = [System.Collections.Generic.List[uint32]]::new()
    foreach ($s in $Strings) {
        $offsets.Add([uint32]$data.Position)
        $dataWriter.Write([uint16]$s.Length)
        $dataWriter.Write([System.Text.Encoding]::Unicode.GetBytes($s))
        $dataWriter.Write([uint16]0)
    }
    while ($data.Length % 4) { $dataWriter.Write([byte]0) }
    $dataWriter.Flush()

    $headerSize = 28
    $stringsStart = $headerSize + 4 * $Strings.Count
    $chunk = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($chunk)
    $w.Write([uint16]0x0001)                         # RES_STRING_POOL_TYPE
    $w.Write([uint16]$headerSize)
    $w.Write([uint32]($stringsStart + $data.Length))
    $w.Write([uint32]$Strings.Count)
    $w.Write([uint32]0)                              # styleCount
    $w.Write([uint32]0)                              # flags: UTF-16
    $w.Write([uint32]$stringsStart)
    $w.Write([uint32]0)                              # stylesStart
    foreach ($o in $offsets) { $w.Write($o) }
    $w.Write($data.ToArray())
    $w.Flush()
    return , $chunk.ToArray()
}

function New-ResourceTable {
    <#
        A resources.arsc holding one package (0x7f) with one type and one
        entry: mipmap/ic_launcher -> res/mipmap/ic_launcher.png, resource id
        0x7f010000. Layouts follow lib/ResourceTypes.h: ResTable_header,
        ResTable_package, ResTable_typeSpec, ResTable_type with a 64-byte
        ResTable_config, ResTable_entry, Res_value.
    #>
    param(
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $IconPath
    )

    $valueStrings = New-ResStringPool -Strings @($IconPath)
    $typeStrings  = New-ResStringPool -Strings @('mipmap')
    $keyStrings   = New-ResStringPool -Strings @('ic_launcher')

    # ResTable_typeSpec: id 1, one entry, no configuration flags.
    $spec = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($spec)
    $w.Write([uint16]0x0202); $w.Write([uint16]16); $w.Write([uint32](16 + 4))
    $w.Write([byte]1); $w.Write([byte]0); $w.Write([uint16]0); $w.Write([uint32]1)
    $w.Write([uint32]0)
    $w.Flush()

    # ResTable_type: config is all defaults except density NONE (0xFFFF), so a
    # large source image is never scaled up for the screen density.
    $configSize = 64
    $headerSize = 20 + $configSize
    $entriesStart = $headerSize + 4
    $type = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($type)
    $w.Write([uint16]0x0201); $w.Write([uint16]$headerSize); $w.Write([uint32]($entriesStart + 16))
    $w.Write([byte]1); $w.Write([byte]0); $w.Write([uint16]0)
    $w.Write([uint32]1); $w.Write([uint32]$entriesStart)
    $config = [byte[]]::new($configSize)
    [BitConverter]::GetBytes([uint32]$configSize).CopyTo($config, 0)
    [BitConverter]::GetBytes([uint16]0xFFFF).CopyTo($config, 14)   # density
    $w.Write($config)
    $w.Write([uint32]0)                                              # entry 0 offset
    $w.Write([uint16]8); $w.Write([uint16]0); $w.Write([uint32]0)    # ResTable_entry: key 0
    $w.Write([uint16]8); $w.Write([byte]0); $w.Write([byte]0x03)     # Res_value: TYPE_STRING
    $w.Write([uint32]0)                                              # value string 0
    $w.Flush()

    # ResTable_package: 288-byte header, then type and key pools, then chunks.
    $packageHeaderSize = 288
    $typeStringsOffset = $packageHeaderSize
    $keyStringsOffset = $typeStringsOffset + $typeStrings.Length
    $packageSize = $keyStringsOffset + $keyStrings.Length + $spec.Length + $type.Length
    $package = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($package)
    $w.Write([uint16]0x0200); $w.Write([uint16]$packageHeaderSize); $w.Write([uint32]$packageSize)
    $w.Write([uint32]0x7f)
    $name = [byte[]]::new(256)
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($PackageName)
    if ($nameBytes.Length -gt 254) { throw "Package name '$PackageName' exceeds 127 UTF-16 units." }
    $nameBytes.CopyTo($name, 0)
    $w.Write($name)
    $w.Write([uint32]$typeStringsOffset); $w.Write([uint32]1)
    $w.Write([uint32]$keyStringsOffset); $w.Write([uint32]1)
    $w.Write([uint32]0)                                              # typeIdOffset
    $w.Write($typeStrings); $w.Write($keyStrings)
    $w.Write($spec.ToArray()); $w.Write($type.ToArray())
    $w.Flush()

    # ResTable_header.
    $table = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($table)
    $tableSize = 12 + $valueStrings.Length + $package.Length
    $w.Write([uint16]0x0002); $w.Write([uint16]12); $w.Write([uint32]$tableSize)
    $w.Write([uint32]1)
    $w.Write($valueStrings); $w.Write($package.ToArray())
    $w.Flush()
    return , $table.ToArray()
}

function New-BinaryAxmlManifest {
    param(
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $ActivityClassName,
        [string] $ActivityLabel = "Pwsh",
        [int] $VersionCode = 1,
        [string] $VersionName = "1.0",
        [int] $MinSdkVersion = 26,
        [int] $TargetSdkVersion = 37,
        [int] $CompileSdkVersion = 37,
        [string] $CompileSdkVersionCodename = "17",
        [ValidateSet('Xamarin', 'NativeActivity')][string] $Admission = 'Xamarin',
        [string] $NativeLibraryName = 'pwsh-host'
    )

    $attrNames = @(
        'theme',                       # ResID: 0x01010000
        'label',                       # ResID: 0x01010001
        'icon',                        # ResID: 0x01010002
        'name',                        # ResID: 0x01010003
        'exported',                    # ResID: 0x01010010
        'authorities',                 # ResID: 0x01010018
        'initOrder',                   # ResID: 0x0101001A
        'launchMode',                  # ResID: 0x0101001D
        'value',                       # ResID: 0x01010024
        'resource',                    # ResID: 0x01010025
        'minSdkVersion',               # ResID: 0x0101020C
        'versionCode',                 # ResID: 0x0101021B
        'versionName',                 # ResID: 0x0101021C
        'targetSdkVersion',            # ResID: 0x01010270
        'allowBackup',                 # ResID: 0x01010280
        'required',                    # ResID: 0x0101028E
        'banner',                      # ResID: 0x010103F2
        'extractNativeLibs',           # ResID: 0x010104EA
        'compileSdkVersion',           # ResID: 0x01010572
        'compileSdkVersionCodename'    # ResID: 0x01010573
    )

    $resIds = @(
        0x01010000, 0x01010001, 0x01010002, 0x01010003, 0x01010010, 0x01010018,
        0x0101001A, 0x0101001D, 0x01010024, 0x01010025, 0x0101020C,
        0x0101021B, 0x0101021C, 0x01010270, 0x01010280, 0x0101028E,
        0x010103F2, 0x010104EA, 0x01010572, 0x01010573
    )

    $activityFullName = "$PackageName.$ActivityClassName"
    $providerAuthority = "$PackageName.mono.MonoRuntimeProvider.__mono_init__"

    $otherStrings = @(
        'android.permission.INTERNET',
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.WAKE_LOCK',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.REQUEST_INSTALL_PACKAGES',
        'uses-permission',
        $VersionName,
        $CompileSdkVersionCodename,
        $ActivityLabel,
        'action',
        'activity',
        'android',
        'android.app.Application',
        'android.hardware.touchscreen',
        'android.intent.action.MAIN',
        'android.intent.category.LAUNCHER',
        'android.intent.category.LEANBACK_LAUNCHER',
        'android.software.leanback',
        'application',
        'base',
        'category',
        'com.android.dynamic.apk.fused.modules',
        'com.android.vending.splits',
        $PackageName,
        $activityFullName,
        $providerAuthority,
        'http://schemas.android.com/apk/res/android',
        'intent-filter',
        'manifest',
        'meta-data',
        'mono.MonoRuntimeProvider',
        'package',
        'platformBuildVersionCode',
        'platformBuildVersionName',
        'provider',
        'uses-feature',
        'uses-sdk'
    )

    # NativeActivity admission adds only its own strings, so the Xamarin
    # manifest stays byte-identical to the proven one.
    $native = $Admission -eq 'NativeActivity'
    if ($native) {
        $attrNames += 'hasCode'                        # ResID: 0x0101000C
        $resIds += 0x0101000C
        $otherStrings = @($otherStrings | Where-Object { $_ -notin 'mono.MonoRuntimeProvider', $providerAuthority, 'provider' })
        $otherStrings += @('android.app.NativeActivity', 'android.app.lib_name', $NativeLibraryName)
        $activityFullName = 'android.app.NativeActivity'
    }

    $allStrings = $attrNames + $otherStrings
    $strMap = @{}
    for ($i = 0; $i -lt $allStrings.Count; $i++) {
        $strMap[$allStrings[$i]] = $i
    }

    function S([string]$val) { return $strMap[$val] }

    # 2. Build StringPool Chunk
    $spDataMs = [System.IO.MemoryStream]::new()
    $spDataBw = [System.IO.BinaryWriter]::new($spDataMs)
    $strOffsets = [System.Collections.Generic.List[uint32]]::new()

    foreach ($s in $allStrings) {
        $strOffsets.Add([uint32]$spDataMs.Position)
        $chars = [System.Text.Encoding]::Unicode.GetBytes($s)
        $spDataBw.Write([uint16]($chars.Length / 2))
        Write-ByteSpan -Writer $spDataBw -Bytes $chars
        $spDataBw.Write([uint16]0)
    }
    $rawStrBytes = $spDataMs.ToArray()
    $spDataBw.Dispose(); $spDataMs.Dispose()

    $padLen = (4 - ($rawStrBytes.Length % 4)) % 4
    if ($padLen -gt 0) {
        # + on two arrays yields object[]; the cast keeps it byte[].
        $rawStrBytes = [byte[]]($rawStrBytes + [byte[]]::new($padLen))
    }

    $strPoolHdrSize = 28
    $offsetTableSize = $allStrings.Count * 4
    $stringsStart = $strPoolHdrSize + $offsetTableSize
    $strPoolTotalSize = $stringsStart + $rawStrBytes.Length

    $spMs = [System.IO.MemoryStream]::new()
    $spBw = [System.IO.BinaryWriter]::new($spMs)
    $spBw.Write([uint16]0x0001)
    $spBw.Write([uint16]$strPoolHdrSize)
    $spBw.Write([uint32]$strPoolTotalSize)
    $spBw.Write([uint32]$allStrings.Count)
    $spBw.Write([uint32]0)
    $spBw.Write([uint32]0)
    $spBw.Write([uint32]$stringsStart)
    $spBw.Write([uint32]0)
    foreach ($off in $strOffsets) { $spBw.Write([uint32]$off) }
    Write-ByteSpan -Writer $spBw -Bytes $rawStrBytes
    $stringPoolChunk = $spMs.ToArray()
    $spBw.Dispose(); $spMs.Dispose()

    # 3. Build ResourceMap Chunk
    $rmMs = [System.IO.MemoryStream]::new()
    $rmBw = [System.IO.BinaryWriter]::new($rmMs)
    $rmTotalSize = 8 + ($resIds.Count * 4)
    $rmBw.Write([uint16]0x0180)
    $rmBw.Write([uint16]8)
    $rmBw.Write([uint32]$rmTotalSize)
    foreach ($rid in $resIds) { $rmBw.Write([uint32]$rid) }
    $resourceMapChunk = $rmMs.ToArray()
    $rmBw.Dispose(); $rmMs.Dispose()

    # 4. Build XML Tree Elements
    $xmlMs = [System.IO.MemoryStream]::new()
    $xmlBw = [System.IO.BinaryWriter]::new($xmlMs)

    function Write-StartNs([string]$prefix, [string]$uri, [int]$line) {
        $xmlBw.Write([uint16]0x0100)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32](S $prefix))
        $xmlBw.Write([int32](S $uri))
    }

    function Write-EndNs([string]$prefix, [string]$uri, [int]$line) {
        $xmlBw.Write([uint16]0x0101)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32](S $prefix))
        $xmlBw.Write([int32](S $uri))
    }

    function Write-StartElem([string]$name, [array]$attrs, [int]$line) {
        $attrSize = 20
        $attrCount = $attrs.Count
        $totalChunkSize = 36 + ($attrCount * $attrSize)
        $xmlBw.Write([uint16]0x0102)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]$totalChunkSize)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32]-1)
        $xmlBw.Write([int32](S $name))
        $xmlBw.Write([uint16]0x0014)
        $xmlBw.Write([uint16]0x0014)
        $xmlBw.Write([uint16]$attrCount)
        $xmlBw.Write([uint16]0)
        $xmlBw.Write([uint16]0)
        $xmlBw.Write([uint16]0)

        foreach ($at in $attrs) {
            $nsIdx = if ($at.HasNs) { S 'http://schemas.android.com/apk/res/android' } else { -1 }
            $nameIdx = S $at.Name
            $xmlBw.Write([int32]$nsIdx)
            $xmlBw.Write([int32]$nameIdx)
            $xmlBw.Write([int32]$at.RawVal)
            $xmlBw.Write([uint16]8)
            $xmlBw.Write([byte]0)
            $xmlBw.Write([byte]$at.DataType)
            $xmlBw.Write([uint32]$at.Data)
        }
    }

    function Write-EndElem([string]$name, [int]$line) {
        $xmlBw.Write([uint16]0x0103)
        $xmlBw.Write([uint16]16)
        $xmlBw.Write([uint32]24)
        $xmlBw.Write([uint32]$line)
        $xmlBw.Write([uint32]4294967295)
        $xmlBw.Write([int32]-1)
        $xmlBw.Write([int32](S $name))
    }

    function Attr-Ref([string]$name, [uint32]$resVal) {
        [PSCustomObject]@{ HasNs = $true; Name = $name; RawVal = -1; DataType = 0x01; Data = $resVal }
    }
    function Attr-String([string]$name, [string]$strVal, [bool]$hasNs = $true) {
        $sIdx = S $strVal
        [PSCustomObject]@{ HasNs = $hasNs; Name = $name; RawVal = $sIdx; DataType = 0x03; Data = [uint32]$sIdx }
    }
    function Attr-IntDec([string]$name, [int]$intVal, [bool]$hasNs = $true) {
        [PSCustomObject]@{ HasNs = $hasNs; Name = $name; RawVal = -1; DataType = 0x10; Data = [uint32]$intVal }
    }
    function Attr-Bool([string]$name, [bool]$boolVal) {
        $bData = if ($boolVal) { [uint32]4294967295 } else { [uint32]0 }
        [PSCustomObject]@{ HasNs = $true; Name = $name; RawVal = -1; DataType = 0x12; Data = $bData }
    }

    Write-StartNs 'android' 'http://schemas.android.com/apk/res/android' 8

    $manifestAttrs = @(
        (Attr-IntDec 'versionCode' $VersionCode),
        (Attr-String 'versionName' $VersionName),
        (Attr-IntDec 'compileSdkVersion' $CompileSdkVersion),
        (Attr-String 'compileSdkVersionCodename' $CompileSdkVersionCodename),
        (Attr-String 'package' $PackageName $false),
        (Attr-IntDec 'platformBuildVersionCode' $CompileSdkVersion $false),
        (Attr-String 'platformBuildVersionName' $CompileSdkVersionCodename $false)
    )
    Write-StartElem 'manifest' $manifestAttrs 8

    $usesSdkAttrs = @(
        (Attr-IntDec 'minSdkVersion' $MinSdkVersion),
        (Attr-IntDec 'targetSdkVersion' $TargetSdkVersion)
    )
    Write-StartElem 'uses-sdk' $usesSdkAttrs 9
    Write-EndElem   'uses-sdk' 9

    foreach ($permission in @(
        'android.permission.INTERNET',
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.WAKE_LOCK',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.REQUEST_INSTALL_PACKAGES')) {
        Write-StartElem 'uses-permission' @((Attr-String 'name' $permission)) 10
        Write-EndElem 'uses-permission' 10
    }

    Write-StartElem 'uses-feature' @(
        (Attr-String 'name' 'android.software.leanback'),
        (Attr-Bool 'required' $false)
    ) 10
    Write-EndElem 'uses-feature' 10

    foreach ($permission in @(
        'android.permission.INTERNET',
        'android.permission.ACCESS_NETWORK_STATE',
        'android.permission.WAKE_LOCK',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.FOREGROUND_SERVICE',
        'android.permission.REQUEST_INSTALL_PACKAGES')) {
        Write-StartElem 'uses-permission' @((Attr-String 'name' $permission)) 10
        Write-EndElem 'uses-permission' 10
    }

    Write-StartElem 'uses-feature' @(
        (Attr-String 'name' 'android.hardware.touchscreen'),
        (Attr-Bool 'required' $false)
    ) 11
    Write-EndElem 'uses-feature' 11

    $appAttrs = @(
        (Attr-String 'label' $ActivityLabel),
        (Attr-Ref 'icon' 0x7f010000),
        (Attr-String 'name' 'android.app.Application'),
        (Attr-Bool 'allowBackup' $true),
        (Attr-Bool 'extractNativeLibs' $true)
    )
    # Attributes are written in resource-id order; hasCode (0x0101000C)
    # follows name (0x01010003).
    if ($native) { $appAttrs = @($appAttrs[0..2]) + @((Attr-Bool 'hasCode' $false)) + @($appAttrs[3..4]) }
    Write-StartElem 'application' $appAttrs 12

    $activityAttrs = @(
        (Attr-Ref 'theme' 0x0103022E),
        (Attr-String 'label' $ActivityLabel),
        (Attr-String 'name' $activityFullName),
        (Attr-Bool 'exported' $true),
        (Attr-IntDec 'launchMode' 1)
    )
    Write-StartElem 'activity' $activityAttrs 13

    Write-StartElem 'intent-filter' @() 14
    Write-StartElem 'action' @((Attr-String 'name' 'android.intent.action.MAIN')) 15
    Write-EndElem 'action' 15
    Write-StartElem 'category' @((Attr-String 'name' 'android.intent.category.LAUNCHER')) 16
    Write-EndElem 'category' 16
    Write-StartElem 'category' @((Attr-String 'name' 'android.intent.category.LEANBACK_LAUNCHER')) 17
    Write-EndElem 'category' 17
    Write-EndElem 'intent-filter' 14
    if ($native) {
        # NativeActivity loads lib<value>.so and calls ANativeActivity_onCreate
        # (lib/native_activity.h).
        Write-StartElem 'meta-data' @((Attr-String 'name' 'android.app.lib_name'), (Attr-String 'value' $NativeLibraryName)) 18
        Write-EndElem 'meta-data' 18
    }
    Write-EndElem 'activity' 13

    if (-not $native) {
        $providerAttrs = @(
            (Attr-String 'name' 'mono.MonoRuntimeProvider'),
            (Attr-Bool 'exported' $false),
            (Attr-String 'authorities' $providerAuthority),
            (Attr-IntDec 'initOrder' 1999999999)
        )
        Write-StartElem 'provider' $providerAttrs 20
        Write-EndElem 'provider' 20
    }

    $meta1Attrs = @(
        (Attr-String 'name' 'com.android.dynamic.apk.fused.modules'),
        (Attr-String 'value' 'base')
    )
    Write-StartElem 'meta-data' $meta1Attrs 0
    Write-EndElem 'meta-data' 0


    Write-EndElem 'application' 12
    Write-EndElem 'manifest' 8
    Write-EndNs 'android' 'http://schemas.android.com/apk/res/android' 8

    $xmlTreeBytes = $xmlMs.ToArray()
    $xmlBw.Dispose(); $xmlMs.Dispose()

    $totalFileSize = 8 + $stringPoolChunk.Length + $resourceMapChunk.Length + $xmlTreeBytes.Length
    $docMs = [System.IO.MemoryStream]::new()
    $docBw = [System.IO.BinaryWriter]::new($docMs)
    $docBw.Write([uint16]0x0003)
    $docBw.Write([uint16]8)
    $docBw.Write([uint32]$totalFileSize)
    Write-ByteSpan -Writer $docBw -Bytes $stringPoolChunk
    Write-ByteSpan -Writer $docBw -Bytes $resourceMapChunk
    Write-ByteSpan -Writer $docBw -Bytes $xmlTreeBytes
    $docBytes = $docMs.ToArray()
    $docBw.Dispose(); $docMs.Dispose()

    return ,$docBytes
}

function Get-ResourceChunkConstants {
    if ($null -ne $script:ResourceChunkConstants) { return $script:ResourceChunkConstants }

    # Chunk type values come from AOSP's ResourceTypes.h, which is the
    # definition the platform parser itself is built from.
    $text = Import-LibSourceText -Path 'ResourceTypes.h'
    $constants = @{}
    foreach ($name in @(
        'RES_STRING_POOL_TYPE', 'RES_XML_TYPE', 'RES_XML_START_NAMESPACE_TYPE',
        'RES_XML_END_NAMESPACE_TYPE', 'RES_XML_START_ELEMENT_TYPE',
        'RES_XML_END_ELEMENT_TYPE', 'RES_XML_RESOURCE_MAP_TYPE')) {
        $match = [regex]::Match($text, "$name\s*=\s*0x([0-9A-Fa-f]+)")
        if (-not $match.Success) { throw "ResourceTypes.h does not declare '$name'." }
        $constants[$name] = [uint16]([Convert]::ToUInt32($match.Groups[1].Value, 16))
    }
    $script:ResourceChunkConstants = $constants
    return $script:ResourceChunkConstants
}

function Test-ResChunkHeader {
    # AOSP's validate_chunk (libs/androidfw/ResourceTypes.cpp): the header is at
    # least the structure's size, fits inside the chunk, both sizes are 4-byte
    # aligned, and the chunk lies inside its container.
    param([Parameter(Mandatory)][byte[]] $Data, [Parameter(Mandatory)][long] $At,
          [Parameter(Mandatory)][int] $MinimumHeaderSize, [Parameter(Mandatory)][long] $End)
    if ($At + 8 -gt $End) { throw "A chunk header at $At runs past its container." }
    $headerSize = [BitConverter]::ToUInt16($Data, $At + 2)
    $size = [long][BitConverter]::ToUInt32($Data, $At + 4)
    if ($headerSize -lt $MinimumHeaderSize) { throw "The chunk at $At has a $headerSize-byte header; its type needs at least $MinimumHeaderSize." }
    if ($headerSize -gt $size) { throw "The chunk at $At has a $headerSize-byte header but is only $size bytes." }
    if ((($headerSize -bor $size) -band 3) -ne 0) { throw "The chunk at $At has size $size and header size $headerSize; both must be multiples of 4." }
    if ($At + $size -gt $End) { throw "A $size-byte chunk at $At runs past its container." }
    [pscustomobject]@{ HeaderSize = [int]$headerSize; Size = [int]$size }
}

function Test-BinaryAxml {
    param([Parameter(Mandatory)][byte[]] $Document)

    $res = Get-ResourceChunkConstants

    if ($Document.Length -lt 8) { throw 'The emitted manifest is too short to hold a chunk header.' }
    $type = [BitConverter]::ToUInt16($Document, 0)
    $headerSize = (Test-ResChunkHeader -Data $Document -At 0 -MinimumHeaderSize 8 -End $Document.Length).HeaderSize
    $fileSize = [int][BitConverter]::ToUInt32($Document, 4)
    if ($type -ne $res['RES_XML_TYPE']) {
        throw ('The emitted manifest declares chunk type 0x{0:X4}; RES_XML_TYPE is 0x{1:X4}.' -f $type, $res['RES_XML_TYPE'])
    }
    if ($fileSize -ne $Document.Length) {
        throw "The emitted manifest declares $fileSize bytes but is $($Document.Length) bytes."
    }

    # Walk the chunks the way the platform parser does, and require that the
    # element nesting closes and the namespace it opens is the one it closes.
    $cursor = $headerSize
    $depth = 0
    $namespaceDepth = 0
    $elements = 0
    $sawStringPool = $false
    $sawResourceMap = $false
    $strings = [System.Collections.Generic.List[string]]::new()
    $parsed = [System.Collections.Generic.List[object]]::new()
    $resourceIds = [System.Collections.Generic.List[uint32]]::new()
    while ($cursor -lt $Document.Length) {
        if (($Document.Length - $cursor) -lt 8) { throw "A chunk header at $cursor runs past the end of the manifest." }
        $chunkType = [BitConverter]::ToUInt16($Document, $cursor)
        # Minimum header sizes are the ResourceTypes.h structures: ResStringPool_header
        # 28, ResXMLTree_node 16 for namespace and element nodes, ResChunk_header 8
        # for the resource map and anything else.
        $minimumHeader = switch ($chunkType) {
            $res['RES_STRING_POOL_TYPE'] { 28 }
            { $_ -in $res['RES_XML_START_NAMESPACE_TYPE'], $res['RES_XML_END_NAMESPACE_TYPE'], $res['RES_XML_START_ELEMENT_TYPE'], $res['RES_XML_END_ELEMENT_TYPE'] } { 16 }
            default { 8 }
        }
        $chunk = Test-ResChunkHeader -Data $Document -At $cursor -MinimumHeaderSize $minimumHeader -End $Document.Length
        $chunkSize = $chunk.Size

        switch ($chunkType) {
            $res['RES_STRING_POOL_TYPE'] {
                $sawStringPool = $true
                # ResStringPool_header (lib/ResourceTypes.h): header, stringCount,
                # styleCount, flags, stringsStart, stylesStart; then the offsets.
                $count = [BitConverter]::ToUInt32($Document, $cursor + 8)
                $utf8 = ([BitConverter]::ToUInt32($Document, $cursor + 16) -band 0x100) -ne 0
                $stringsStart = $cursor + [BitConverter]::ToUInt32($Document, $cursor + 20)
                $offsets = $cursor + [BitConverter]::ToUInt16($Document, $cursor + 2)
                for ($s = 0; $s -lt $count; $s++) {
                    $at = $stringsStart + [BitConverter]::ToUInt32($Document, $offsets + 4 * $s)
                    if ($utf8) {
                        $at += $(if ($Document[$at] -band 0x80) { 2 } else { 1 })
                        $byteLength = $Document[$at]
                        if ($byteLength -band 0x80) { $byteLength = (($byteLength -band 0x7F) -shl 8) -bor $Document[$at + 1]; $at += 2 } else { $at += 1 }
                        $strings.Add([System.Text.Encoding]::UTF8.GetString($Document, $at, $byteLength))
                    }
                    else {
                        $length = [BitConverter]::ToUInt16($Document, $at)
                        if ($length -band 0x8000) { $length = (($length -band 0x7FFF) -shl 16) -bor [BitConverter]::ToUInt16($Document, $at + 2); $at += 4 } else { $at += 2 }
                        $strings.Add([System.Text.Encoding]::Unicode.GetString($Document, $at, 2 * $length))
                    }
                }
            }
            $res['RES_XML_RESOURCE_MAP_TYPE'] {
                $sawResourceMap = $true
                # One resource id per leading string-pool entry; the count comes
                # from the chunk size, so the map may be shorter than the pool.
                $mapHeader = [BitConverter]::ToUInt16($Document, $cursor + 2)
                for ($at = $cursor + $mapHeader; $at -lt $cursor + $chunkSize; $at += 4) { $resourceIds.Add([BitConverter]::ToUInt32($Document, $at)) }
            }
            $res['RES_XML_START_NAMESPACE_TYPE'] { $namespaceDepth++ }
            $res['RES_XML_END_NAMESPACE_TYPE'] { $namespaceDepth-- }
            $res['RES_XML_START_ELEMENT_TYPE'] {
                $depth++; $elements++
                # ResXMLTree_attrExt follows the 16-byte node header: ns, name,
                # attributeStart, attributeSize, attributeCount. Each
                # ResXMLTree_attribute: ns, name, rawValue, typedValue (8 bytes).
                $ext = $cursor + 16
                $attributeStart = [BitConverter]::ToUInt16($Document, $ext + 8)
                $attributeSize = [BitConverter]::ToUInt16($Document, $ext + 10)
                $attributeCount = [BitConverter]::ToUInt16($Document, $ext + 12)
                # AOSP validateNode: the attribute array must lie inside the node.
                if ($attributeStart + $attributeSize * $attributeCount -gt $chunkSize - 16) {
                    throw "The element at $cursor declares attributes past the end of its node."
                }
                $attributes = [ordered]@{}
                $identities = [System.Collections.Generic.List[object]]::new()
                for ($a = 0; $a -lt $attributeCount; $a++) {
                    $at = $ext + $attributeStart + $a * $attributeSize
                    $raw = [BitConverter]::ToInt32($Document, $at + 8)
                    # ResXMLParser::getAttributeNameResID: the name's string index
                    # indexes the resource map; past its end the id is 0.
                    $nameIndex = [BitConverter]::ToInt32($Document, $at + 4)
                    $identities.Add([pscustomobject]@{
                        Name       = $strings[$nameIndex]
                        Namespaced = [BitConverter]::ToInt32($Document, $at) -ge 0
                        ResourceId = if ($nameIndex -ge 0 -and $nameIndex -lt $resourceIds.Count) { $resourceIds[$nameIndex] } else { [uint32]0 }
                    })
                    $attributes[$strings[[BitConverter]::ToInt32($Document, $at + 4)]] = if ($raw -ge 0) { $strings[$raw] } else { [BitConverter]::ToUInt32($Document, $at + 16) }
                }
                $parsed.Add([pscustomobject]@{ Name = $strings[[BitConverter]::ToInt32($Document, $ext + 4)]; Depth = $depth; Attributes = $attributes; Identities = $identities })
            }
            $res['RES_XML_END_ELEMENT_TYPE'] {
                $depth--
                if ($depth -lt 0) { throw "An element closes at $cursor without a matching open." }
            }
        }
        $cursor += $chunkSize
    }

    if (-not $sawStringPool) { throw 'The emitted manifest carries no string pool.' }
    if (-not $sawResourceMap) { throw 'The emitted manifest carries no resource map.' }
    if ($depth -ne 0) { throw "The emitted manifest leaves $depth elements open." }
    if ($namespaceDepth -ne 0) { throw "The emitted manifest leaves $namespaceDepth namespaces open." }

    return [pscustomobject]@{
        FileSize     = $fileSize
        ElementCount = $elements
        Strings      = $strings
        Elements     = $parsed
    }
}

function Assert-ManifestAttributeIds {
    # Every android:-namespaced attribute must resolve, through the resource
    # map, to the id the pinned public-final.xml declares for its name. Text
    # alone is not enough: Android identifies attributes by resource id.
    param([Parameter(Mandatory)] $Report)
    $text = Import-LibSourceText -Path 'public-final.xml'
    $checked = 0
    foreach ($element in $Report.Elements) {
        foreach ($attribute in @($element.Identities | Where-Object Namespaced)) {
            $match = [regex]::Match($text, "<public type=`"attr`" name=`"$([regex]::Escape($attribute.Name))`" id=`"0x([0-9a-fA-F]+)`"")
            if (-not $match.Success) { throw "public-final.xml does not declare android:$($attribute.Name)." }
            $declared = [Convert]::ToUInt32($match.Groups[1].Value, 16)
            if ($attribute.ResourceId -ne $declared) {
                throw ('<{0}> android:{1} maps to 0x{2:X8}; public-final.xml declares 0x{3:X8}.' -f $element.Name, $attribute.Name, $attribute.ResourceId, $declared)
            }
            $checked++
        }
    }
    $checked
}

function Invoke-ManifestStep {

    $manifestBytes = New-BinaryAxmlManifest `
        -PackageName $script:PackageName `
        -ActivityClassName $script:ActivityClassName `
        -ActivityLabel $script:ApplicationLabel `
        -Admission $Admission
    $report = Test-BinaryAxml -Document $manifestBytes
    $checkedIds = Assert-ManifestAttributeIds -Report $report

    $outputDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $manifestPath = Join-Path $outputDirectory 'AndroidManifest.xml'
    if ($PSCmdlet.ShouldProcess($manifestPath, 'Write binary Android manifest')) {
        Write-BuildFile -Intermediate -Path $manifestPath -Bytes $manifestBytes
    }

    $manifestStream = [System.IO.MemoryStream]::new([byte[]]$manifestBytes, $false)
    try { $manifestHash = Get-Sha256Hex -Stream $manifestStream }
    finally { $manifestStream.Dispose() }

    $script:BuildContext.AndroidManifest = [pscustomobject]@{
        Path   = $manifestPath
        Bytes  = $manifestBytes
        Sha256 = $manifestHash
    }

    Write-Host ('[PASS] Step 7 complete: AndroidManifest.xml emitted as {0} bytes of binary XML declaring {1} elements for {2}/{3}, chunk-walked and balanced, {5} android: attributes matched to public-final.xml ids. SHA-256 {4}' -f
        $report.FileSize,
        $report.ElementCount,
        $script:PackageName,
        $(if ($Admission -eq 'NativeActivity') { 'android.app.NativeActivity' } else { $script:ActivityClassName }),
        $manifestHash,
        $checkedIds) -ForegroundColor Green
}
if ($Help) {
    Show-SetupHelp
    exit 0
}

# ==============================================================================
# Interface
#
# Alternate screen buffer, one full-cell canvas, double-buffered atomic flush.
# Input arrives on its own runspace blocking in ReadKey, the build streams its
# output into the same queue, and the event loop blocks in Take(). Nothing
# polls, so an idle interface costs no CPU.
#
# The canvas renders $script:StepGraph directly. There is no second list of
# steps to keep in sync.
# ==============================================================================
$script:BG_NAVY    = '48;2;12;43;106'
$script:FG_TEXT    = '38;2;230;230;230'
$script:FG_MUTED   = '38;2;140;160;190'
$script:FG_ACCENT  = '38;2;120;220;255'
$script:BG_BAR     = '48;2;192;192;192'
$script:FG_BAR     = '38;2;0;0;0'
$script:BG_SEL     = '48;2;230;230;230'
$script:FG_SEL     = '38;2;0;0;0'
$script:FG_SUCCESS = '38;2;57;255;20'
$script:FG_FAIL    = '38;2;255;60;60'
$script:FG_VALUE   = '38;2;255;255;85'
# The status lane is the lane colors reversed.
$script:BG_LANE    = '48;2;120;220;255'
$script:FG_LANE    = '38;2;12;43;106'

$script:UIMode        = 'Config'
$script:ActiveNavIndex = 0
$script:ActiveStep    = 'Ready to initialize.'
$script:ActiveNodeId  = 0
$script:FailedNodeId  = 0
$script:BuildLog      = [System.Collections.Generic.List[string]]::new()
$script:EventQueue    = $null
$script:InputRunspace = $null
$script:InputPowerShell = $null
$script:WorkerRunspace = $null
$script:WorkerPowerShell = $null
$script:ReturnMode    = 'Config'
$script:BuildEnded    = $false
$script:Popup         = $null
$script:OfflineShown  = $false

function Show-Popup {
    param(
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][AllowEmptyString()][string[]] $Lines,
        [switch] $Confirm,
        [scriptblock] $OnYes
    )
    $script:Popup = @{ Title = $Title; Lines = $Lines; Confirm = [bool]$Confirm; OnYes = $OnYes }
}

function Show-DebugPopup {
    $versions = if ($script:ChannelVersions -is [System.Collections.IDictionary]) {
        ($script:Channels | ForEach-Object { '{0}={1} of {2}' -f $_, $script:ChosenVersions[$_], @($script:ChannelVersions[$_]).Count }) -join '  '
    } else { "list: $(if ($null -eq $script:ChannelVersions) { 'loading' } else { $script:ChannelVersions })" }
    $window = try { '{0}x{1}' -f [Console]::WindowWidth, [Console]::WindowHeight } catch { 'none' }
    $last = @($script:BuildLog | Select-Object -Last 3 | ForEach-Object { if ($_.Length -gt 60) { $_.Substring(0, 60) } else { $_ } })
    Show-Popup -Title 'Debug' -Lines (@(
        "pwsh $($PSVersionTable.PSVersion)  $([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
        "PID $PID  window $window  canvas $($script:CanvasWidth)x$($script:CanvasHeight)"
        "mode $($script:UIMode)  return $($script:ReturnMode)  nav $($script:ActiveNavIndex)"
        "debug $Debug  payload $Payload  step $Step  arch $Architecture  whatif $([bool]$WhatIfPreference)"
        "download $Packages  $CacheDirectory"
        $versions
        "node $($script:ActiveNodeId)  failed $($script:FailedNodeId)  done $($script:CompletedNodes.Count)  ended $($script:BuildEnded)"
        "queue $($script:EventQueue.Count)  log $($script:BuildLog.Count) lines"
        "worker $(if ($script:WorkerPowerShell) { $script:WorkerPowerShell.InvocationStateInfo.State } else { 'none' })  resolver $(if ($script:ResolverPowerShell) { $script:ResolverPowerShell.InvocationStateInfo.State } else { 'none' })"
        ''
    ) + $last)
}

function Show-OfflinePopup {
    if ($script:OfflineShown) { return }
    $script:OfflineShown = $true
    Show-Popup -Title 'No internet connection' -Lines @($script:OfflineMessage, 'Connect, then select Build again.')
}
$script:LogSaved      = $false
$script:ChannelVersions = $null
$script:ChosenVersions  = @{
    DotNet     = $(if ($DotNet) { $DotNet } else { Get-PinnedVersion -Channel DotNet })
    Android    = $(if ($Android) { $Android } else { Get-PinnedVersion -Channel Android })
    PowerShell = $(if ($PowerShell) { $PowerShell } else { Get-PinnedVersion -Channel PowerShell })
}
$script:ResolverRunspace = $null
$script:ResolverPowerShell = $null

function Get-VersionDisplay {
    param([Parameter(Mandatory)][string] $Channel)
    $chosen = $script:ChosenVersions[$Channel]
    if ($chosen -ceq (Get-PinnedVersion -Channel $Channel)) { return "$chosen (pinned)" }
    return $chosen
}

function Get-NavigationItems {
    $stepNode = $script:StepGraph[$Step]
    @(
        @{ Id = 'Architecture'; Kind = 'Option'; Label = 'Architecture'; Value = $Architecture
           Caption = switch ($Architecture) {
               'arm64' { 'arm64-v8a, phones' }
               'x64'   { 'x86_64, emulator' }
               'arm32' { 'armeabi-v7a (32-bit devices)' }
           } }
        @{ Id = 'Debug'; Kind = 'Option'; Label = 'Debug'; Value = $(if ($Debug) { 'On' } else { 'Off' })
           Caption = if ($Debug) { 'Intermediates + reference check' } else { 'APK only' } }
        @{ Id = 'Payload'; Kind = 'Option'; Label = 'Payload'; Value = $Payload
           Caption = switch ($Payload) {
               'Minimal'  { 'IL only, no R2R' }
               'Standard' { 'All assemblies + R2R (not built yet)' }
               'SDK'      { 'Standard + PowerShell SDK (not built yet)' }
           } }
        @{ Id = 'Step'; Kind = 'Option'; Label = 'Step'; Value = "$Step  $($stepNode.Key)"; Caption = $stepNode.Title }
        @{ Id = 'DotNet'; Kind = 'Option'; Label = '.NET'; Value = (Get-VersionDisplay DotNet); Caption = '' }
        @{ Id = 'Android'; Kind = 'Option'; Label = 'Android'; Value = (Get-VersionDisplay Android); Caption = '' }
        @{ Id = 'PowerShell'; Kind = 'Option'; Label = 'PowerShell'; Value = (Get-VersionDisplay PowerShell); Caption = '' }
        @{ Id = 'Packages'; Kind = 'Option'; Label = 'Download to'
           Value = if ($Packages -eq 'Memory') { 'Memory' } else { "$CacheDirectory  [Browse...]" }
           Caption = '' }
        @{ Id = 'Build'; Kind = 'Action'; Label = 'Build'; Value = ''; Caption = '' }
    )
}
function Set-OptionValue {
    param([Parameter(Mandatory)][string] $Id, [int] $Direction = 1)

    switch ($Id) {
        'Architecture' {
            $architectures = 'arm64', 'x64', 'arm32'
            $at = [Array]::IndexOf($architectures, $Architecture)
            $script:Architecture = $architectures[(($at + $Direction) % 3 + 3) % 3]
        }
        'Debug' {
            $script:Debug = -not $Debug
        }
        'Payload' {
            $payloads = 'Minimal', 'Standard', 'SDK'
            $at = [Array]::IndexOf($payloads, $Payload)
            $script:Payload = $payloads[(($at + $Direction) % 3 + 3) % 3]
        }
        'Step' {
            $ids = $script:StepIds
            $at = [Math]::Max(0, $ids.IndexOf($Step))
            $script:Step = $ids[(($at + $Direction) % $ids.Count + $ids.Count) % $ids.Count]
        }
        'Packages' {
            $script:Packages = if ($Packages -eq 'Folder') { 'Memory' } else { 'Folder' }
            $script:KeepPackageCache = $script:Packages -eq 'Folder'
        }
        { $_ -in 'DotNet', 'Android', 'PowerShell' } {
            # Right steps to older published versions, left toward newer ones.
            if ($script:ChannelVersions -isnot [System.Collections.IDictionary]) { return }
            $list = @($script:ChannelVersions[$Id])
            $at = [Math]::Max(0, [Array]::IndexOf($list, $script:ChosenVersions[$Id]))
            $at = [Math]::Min($list.Count - 1, [Math]::Max(0, $at + $Direction))
            $script:ChosenVersions[$Id] = $list[$at]
        }
    }
}
# The canvas is the VGA text grid: 80x30 cells, 640x480 at an 8x16 glyph. The
# layout is drawn against this grid and never reflows; a smaller window clips.
$script:CanvasWidth  = 80
$script:CanvasHeight = 30

function Select-CacheFolder {
    # The Windows folder picker. It blocks the loop while open; keys typed
    # meanwhile wait in the queue.
    if (-not $IsWindows) { throw 'The folder picker needs Windows. Use -CacheDirectory <path>.' }
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'Folder for downloaded NuGet packages'
        $dialog.UseDescriptionForTitle = $true
        $dialog.SelectedPath = $CacheDirectory
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:CacheDirectory = $dialog.SelectedPath
        }
    }
    finally { $dialog.Dispose() }
}

function Save-BuildLog {
    $directory = Join-Path $OutputDirectory $script:Target.Abi
    $path = Join-Path $directory ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    $text = ($script:BuildLog -join [Environment]::NewLine) + [Environment]::NewLine
    Write-BuildFile -Path $path -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($text))
    $script:ActiveStep = "Log saved: $path"
    $script:LogSaved = $true
}

# Returns whether the interface keeps running. With no package cache on disk
# there is nothing to ask.
function Request-Exit {
    $downloading = $script:UIMode -eq 'Building' -and $script:ActiveNodeId -gt 0 -and
        $script:StepGraph[$script:ActiveNodeId].Key -eq 'Acquire'
    $prompt = if ($downloading) { 'CancelPrompt' }
              elseif ($Packages -eq 'Folder' -and (Test-Path -LiteralPath $CacheDirectory -PathType Container)) { 'ExitPrompt' }
    if (-not $prompt) { return $false }
    $script:ReturnMode = $script:UIMode
    $script:UIMode = $prompt
    return $true
}

function Get-StatusLane {
    $mode = if ($script:UIMode -eq 'HelpView') { $script:ReturnMode } else { $script:UIMode }
    $status = switch ($mode) {
        'Config'     { if ($WhatIfPreference) { ' Preview only (-WhatIf)' } else { ' Ready' } }
        'ExitPrompt'   { ' Save downloaded NuGet packages? [Y/N]' }
        'CancelPrompt' { ' Cancel the download? [Y/N]' }
        default   { " $script:ActiveStep" }
    }
    $width = $script:CanvasWidth - 2
    $status.PadRight($width).Substring(0, $width)
}

# The status lane is the second-to-last row. Every build line lands here
# directly, one WriteLine-sized write per line, without redrawing the canvas.
function Write-StatusLane {
    $visibleWidth  = [Math]::Min($script:CanvasWidth, [Console]::WindowWidth)
    $visibleHeight = [Math]::Min($script:CanvasHeight, [Console]::WindowHeight)
    if ($visibleWidth -lt 8 -or $visibleHeight -lt 8) { return }
    $lane = (Get-StatusLane).Substring(0, $visibleWidth - 2)
    [Console]::Write("`e[$($visibleHeight - 1);2H`e[$script:BG_LANE;$($script:FG_LANE)m$lane")
}

# Back buffer: every cell of the fixed grid as its SGR prefix plus one glyph.
function Get-CanvasCells {
    $w = $script:CanvasWidth
    $h = $script:CanvasHeight

    $screen = New-Object 'string[][]' $h
    for ($r = 0; $r -lt $h; $r++) {
        $screen[$r] = New-Object 'string[]' $w
        for ($c = 0; $c -lt $w; $c++) {
            $screen[$r][$c] = "`e[$script:BG_NAVY;$($script:FG_TEXT)m "
        }
    }

    $brand = 'github.com/MansfieldPlumbing/Pwsh '
    $header = ' Pwsh for Android Setup'.PadRight($w - $brand.Length) + $brand
    $paddedHeader = $header.PadRight($w).Substring(0, $w)
    for ($c = 0; $c -lt $w; $c++) {
        $screen[0][$c] = "`e[$script:BG_BAR;$($script:FG_BAR)m$($paddedHeader[$c])"
    }

    $footer = if ($script:Popup) { if ($script:Popup.Confirm) { ' Y Yes   N No' } else { ' Enter OK' } } else { switch ($script:UIMode) {
        'Config'   { ' ↑ ↓ Select   ← → Change   Tab Next   F1 Help   F12 Debug   C Console   Esc Exit' }
        'Building' { if ($script:BuildEnded) { ' S Save log   C Console   Esc Back' } else { ' F1 Help   C Console   Esc Cancel' } }
        'LogView'  { ' C/Esc Back' }
        'HelpView'     { ' Esc Close' }
        'ExitPrompt'   { ' Y Save   N Delete   Esc Back' }
        'CancelPrompt' { ' Y Cancel download   N Continue' }
    } }
    $paddedFooter = $footer.PadRight($w).Substring(0, $w)
    for ($c = 0; $c -lt $w; $c++) {
        $screen[$h - 1][$c] = "`e[$script:BG_BAR;$($script:FG_BAR)m$($paddedFooter[$c])"
    }

    $paddedStatus = Get-StatusLane
    for ($c = 0; $c -lt $paddedStatus.Length; $c++) {
        $screen[$h - 2][$c + 1] = "`e[$script:BG_LANE;$($script:FG_LANE)m$($paddedStatus[$c])"
    }

    $DrawText = {
        param([int] $y, [int] $x, [string] $str, [string] $color = "$script:BG_NAVY;$script:FG_TEXT")
        for ($k = 0; $k -lt $str.Length; $k++) {
            if (($x + $k) -lt $w -and $y -lt ($h - 2) -and $y -ge 0) {
                $screen[$y][$x + $k] = "`e[${color}m" + $str[$k]
            }
        }
    }

    $mode = if ($script:UIMode -eq 'HelpView') { $script:ReturnMode } else { $script:UIMode }
    if ($mode -eq 'Config') {
        & $DrawText 2 4 'Pwsh for Android' "$script:BG_NAVY;$script:FG_ACCENT"
        & $DrawText 3 4 'Choose the build settings, then select Build.' "$script:BG_NAVY;$script:FG_MUTED"

        $items = Get-NavigationItems
        $row = 5
        for ($i = 0; $i -lt $items.Count; $i++) {
            if ($row -ge ($h - 3)) { break }
            $item = $items[$i]
            $text = if ($item.Kind -eq 'Option') { ' {0,-15}{1,-14}' -f $item.Label, $item.Value } else { " $($item.Label) " }
            if ($i -eq $script:ActiveNavIndex) {
                & $DrawText $row 6 $text "$script:BG_SEL;$script:FG_SEL"
            }
            else {
                & $DrawText $row 6 $text "$script:BG_NAVY;$script:FG_TEXT"
                if ($item.Value) { & $DrawText $row 22 $item.Value "$script:BG_NAVY;$script:FG_VALUE" }
            }
            if ($items[$i].Caption) {
                & $DrawText ($row + 1) 9 $items[$i].Caption "$script:BG_NAVY;$script:FG_MUTED"
                $row += 3
            }
            else { $row += 2 }
        }
    }
    elseif ($mode -eq 'Building') {
        & $DrawText 2 4 "Building $script:PackageName.apk" "$script:BG_NAVY;$script:FG_ACCENT"
        $plan = Resolve-StepOrder -Target $Step
        & $DrawText 3 4 ("{0} of {1} steps complete." -f $script:CompletedNodes.Count, $plan.Count) "$script:BG_NAVY;$script:FG_MUTED"

        $row = 5
        foreach ($id in $plan) {
            if ($row -ge ($h - 3)) { break }
            $node = $script:StepGraph[$id]
            $label = '{0,2}  {1}' -f $id, $node.Title
            if ($id -eq $script:FailedNodeId) {
                & $DrawText $row 6 "[ FAIL ] $label" "$script:BG_NAVY;$script:FG_FAIL"
            }
            elseif ($script:CompletedNodes.Contains($id)) {
                & $DrawText $row 6 "[ DONE ] $label" "$script:BG_NAVY;$script:FG_SUCCESS"
            }
            elseif ($id -eq $script:ActiveNodeId) {
                & $DrawText $row 6 "[ RUN  ] $label" "$script:BG_SEL;$script:FG_SEL"
            }
            else {
                & $DrawText $row 6 "[ WAIT ] $label" "$script:BG_NAVY;$script:FG_MUTED"
            }
            $row++
        }
    }
    elseif ($script:UIMode -eq 'LogView') {
        $maxLines = $h - 4
        $start = [Math]::Max(0, $script:BuildLog.Count - $maxLines)
        $count = [Math]::Min($maxLines, $script:BuildLog.Count - $start)
        if ($count -gt 0) {
            $slice = $script:BuildLog.GetRange($start, $count)
            for ($i = 0; $i -lt $slice.Count; $i++) {
                $line = $slice[$i]
                $color = if ($line -match '^\s*\[PASS\]') { $script:FG_SUCCESS }
                         elseif ($line -match '^\s*(\[FAIL\]|Failed)') { $script:FG_FAIL }
                         elseif ($line -match '^\s*\[PLAN\]') { $script:FG_VALUE }
                         else { $script:FG_TEXT }
                & $DrawText (2 + $i) 2 $line "$script:BG_NAVY;$color"
            }
        }
    }
    elseif ($script:UIMode -eq 'ExitPrompt') {
        & $DrawText 2 4 'Exit Setup' "$script:BG_NAVY;$script:FG_ACCENT"
        & $DrawText 4 4 'Save downloaded NuGet packages?' "$script:BG_NAVY;$script:FG_TEXT"
        & $DrawText 6 6 ('Y  Keep {0}' -f $CacheDirectory) "$script:BG_NAVY;$script:FG_MUTED"
        & $DrawText 7 6 'N  Delete them' "$script:BG_NAVY;$script:FG_MUTED"
    }
    elseif ($script:UIMode -eq 'CancelPrompt') {
        & $DrawText 2 4 'Exit Setup' "$script:BG_NAVY;$script:FG_ACCENT"
        & $DrawText 4 4 'NuGet packages are downloading.' "$script:BG_NAVY;$script:FG_TEXT"
        & $DrawText 5 4 'Do you want to cancel?  [ Y / N ]' "$script:BG_NAVY;$script:FG_TEXT"
    }

    if ($script:UIMode -eq 'HelpView') {
        $box = @(
            ''
            '  Command-line arguments'
            ''
            '  -h, --help                  Show help'
            '  -c, --console               Run without this screen'
            '  -Step <1-11>                Build through a step'
            '  -Debug                      Intermediates + reference check'
            '  -Payload <name>             Minimal, Standard, or SDK'
            '  -Architecture <abi>         arm64-v8a'
            '  -Packages <mode>            Folder or Memory'
            '  -DotNet <version>           .NET runtime (default pinned)'
            '  -Android <version>          Android host (default pinned)'
            '  -PowerShell <version>       SMA and SDK (default pinned)'
            '  -OutputDirectory <path>     Build output'
            '  -DeletePackages             Delete packages on exit'
            '  -WhatIf                     Preview only'
            ''
            '  pwsh -File setup.ps1 -c -Step 11'
            ''
        )
        $boxWidth = 72
        $left = 4
        $top = 5
        $color = "$script:BG_BAR;$script:FG_BAR"
        & $DrawText $top $left ('┌' + ('─' * ($boxWidth - 2)) + '┐') $color
        for ($i = 0; $i -lt $box.Count; $i++) {
            & $DrawText ($top + 1 + $i) $left ('│' + $box[$i].PadRight($boxWidth - 2) + '│') $color
        }
        & $DrawText ($top + 1 + $box.Count) $left ('└' + ('─' * ($boxWidth - 2)) + '┘') $color
    }

    if ($script:Popup) {
        $inner = [Math]::Max($script:Popup.Title.Length, ($script:Popup.Lines | Measure-Object -Property Length -Maximum).Maximum) + 4
        $boxWidth = [Math]::Min($w - 4, $inner + 2)
        $left = [int](($w - $boxWidth) / 2)
        $body = @('', "  $($script:Popup.Title)", '') + @($script:Popup.Lines | ForEach-Object { "  $_" }) + @('', $(if ($script:Popup.Confirm) { '  [ Y / N ]' } else { '  Enter OK' }), '')
        $top = [int](($h - $body.Count - 2) / 2)
        $color = "$script:BG_BAR;$script:FG_BAR"
        & $DrawText $top $left ('┌' + ('─' * ($boxWidth - 2)) + '┐') $color
        for ($i = 0; $i -lt $body.Count; $i++) {
            $line = $body[$i].PadRight($boxWidth - 2).Substring(0, $boxWidth - 2)
            & $DrawText ($top + 1 + $i) $left ('│' + $line + '│') $color
        }
        & $DrawText ($top + 1 + $body.Count) $left ('└' + ('─' * ($boxWidth - 2)) + '┘') $color
    }

    return , $screen
}

# Front buffer: one write per frame, SGR emitted only when it changes. A window
# smaller than the grid clips; the footer stays pinned to the window bottom.
function Render-Canvas {
    $w = $script:CanvasWidth
    $h = $script:CanvasHeight
    $visibleWidth  = [Math]::Min($w, [Console]::WindowWidth)
    $visibleHeight = [Math]::Min($h, [Console]::WindowHeight)
    if ($visibleWidth -lt 8 -or $visibleHeight -lt 8) { return }

    $screen = Get-CanvasCells
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("`e[H")
    $firstRow = $h - $visibleHeight
    for ($r = $firstRow; $r -lt $h; $r++) {
        $lastFmt = ''
        for ($c = 0; $c -lt $visibleWidth; $c++) {
            $cell = $screen[$r][$c]
            $split = $cell.IndexOf('m')
            $fmt = $cell.Substring(0, $split + 1)
            $chr = $cell.Substring($split + 1)
            if ($fmt -eq $lastFmt) { [void]$sb.Append($chr) }
            else { [void]$sb.Append($cell); $lastFmt = $fmt }
        }
        if ($r -lt ($h - 1)) { [void]$sb.Append("`n") }
    }
    [Console]::Write($sb.ToString())
}

function Request-Build {
    # Debug asks first; a normal build starts straight away.
    if ($Debug) {
        Show-Popup -Title 'Debug build' -Confirm -Lines @(
            'This writes the intermediates and runs the'
            '.NET SDK reference build in a temp folder.'
            ''
            'Are you sure?'
        ) -OnYes { Start-PipelineWorker }
    }
    else { Start-PipelineWorker }
}

function Start-PipelineWorker {
    # One build at a time. While one runs, Build only returns to its view.
    if ($script:WorkerPowerShell -and
        $script:WorkerPowerShell.InvocationStateInfo.State -eq [System.Management.Automation.PSInvocationState]::Running) {
        $script:UIMode = 'Building'
        return
    }
    if ($script:WorkerPowerShell) { $script:WorkerPowerShell.Dispose() }
    if ($script:WorkerRunspace)   { $script:WorkerRunspace.Dispose() }

    $script:UIMode = 'Building'
    $script:ActiveNodeId = 0
    $script:FailedNodeId = 0
    $script:ActiveStep = 'Starting'
    $script:BuildEnded = $false
    $script:LogSaved = $false
    $script:CompletedNodes.Clear()

    $script:WorkerRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:WorkerRunspace.Open()

    # Hermetic: the block sees only what its param() block declares, passed
    # explicitly below. Nothing is shared through session state.
    $script:WorkerPowerShell = [PowerShell]::Create()
    $script:WorkerPowerShell.Runspace = $script:WorkerRunspace
    [void]$script:WorkerPowerShell.AddScript({
        param($EventQueue, $ScriptPath, $TargetStep, $Architecture, $DebugRun, $Payload, $DotNet, $Android, $PowerShell, $Packages,
              $CacheDirectory, $OutputDirectory, $SigningKeyPath, $DeletePackages, $PreviewOnly)
        Set-StrictMode -Version Latest
        try {
            $arguments = @{
                Headless        = $true
                Step            = $TargetStep
                Architecture    = $Architecture
                Payload         = $Payload
                DotNet          = $DotNet
                Android         = $Android
                PowerShell      = $PowerShell
                Packages        = $Packages
                CacheDirectory  = $CacheDirectory
                OutputDirectory = $OutputDirectory
                SigningKeyPath  = $SigningKeyPath
                # The user confirmed the plan before the interface opened.
                AcceptWritePlan = $true
            }
            if ($DeletePackages) { $arguments['DeletePackages'] = $true }
            if ($PreviewOnly)    { $arguments['WhatIf'] = $true }
            if ($DebugRun)       { $arguments['Debug'] = $true }
            $EventQueue.Add([PSCustomObject]@{
                Type = 'Output'
                Text = "[$(Get-Date -Format 'HH:mm:ss')] setup.ps1 -Step $TargetStep -Payload $Payload$(if ($DebugRun) { ' -Debug' })$(if ($PreviewOnly) { ' -WhatIf' })"
            })

            $global:LASTEXITCODE = 0
            $lastFail = $null
            & $ScriptPath @arguments 6>&1 2>&1 | ForEach-Object {
                $line = $_.ToString()
                if ($line -like '`[FAIL`]*') { $lastFail = $line }
                $EventQueue.Add([PSCustomObject]@{ Type = 'Output'; Text = $line })
            }
            if ($LASTEXITCODE -ne 0 -or $lastFail) {
                $EventQueue.Add([PSCustomObject]@{ Type = 'Failed'; Text = $(if ($lastFail) { $lastFail -replace '^\[FAIL\]\s*' } else { "exit code $LASTEXITCODE" }) })
            }
            else {
                $EventQueue.Add([PSCustomObject]@{ Type = 'Done' })
            }
        }
        catch {
            $EventQueue.Add([PSCustomObject]@{ Type = 'Failed'; Text = $_.Exception.Message })
        }
    }).AddParameters([ordered]@{
        EventQueue      = $script:EventQueue
        ScriptPath      = $PSCommandPath
        TargetStep      = $Step
        Architecture    = $Architecture
        DebugRun        = [bool]$Debug
        Payload         = $Payload
        DotNet          = $script:ChosenVersions['DotNet']
        Android         = $script:ChosenVersions['Android']
        PowerShell      = $script:ChosenVersions['PowerShell']
        Packages        = $Packages
        CacheDirectory  = $CacheDirectory
        OutputDirectory = $OutputDirectory
        SigningKeyPath  = $SigningKeyPath
        # The cache question is asked once, on exit from the interface.
        DeletePackages  = $false
        # A fresh runspace does not inherit $WhatIfPreference. Forward it, or a
        # -WhatIf run would perform real downloads from inside the interface.
        PreviewOnly     = [bool]$WhatIfPreference
    })
    [void]$script:WorkerPowerShell.BeginInvoke()
}

function Invoke-SetupInterface {
    $script:EventQueue = [System.Collections.Concurrent.BlockingCollection[PSCustomObject]]::new()
    $script:BuildLog.Add('[INIT] Blocking event bus online.')

    $script:InputRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:InputRunspace.Open()
    $script:InputPowerShell = [PowerShell]::Create()
    $script:InputPowerShell.Runspace = $script:InputRunspace
    [void]$script:InputPowerShell.AddScript({
        param($EventQueue)
        while ($true) {
            try { $EventQueue.Add([PSCustomObject]@{ Type = 'Key'; Data = [Console]::ReadKey($true) }) }
            catch { break }
        }
    }).AddArgument($script:EventQueue)
    [void]$script:InputPowerShell.BeginInvoke()

    $script:ResolverRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $script:ResolverRunspace.Open()
    $script:ResolverPowerShell = [PowerShell]::Create()
    $script:ResolverPowerShell.Runspace = $script:ResolverRunspace
    [void]$script:ResolverPowerShell.AddScript({
        param($EventQueue, $ServiceIndex, $Manifest, $Channels, $FeedVersionsBody, $ChannelVersionsBody)
        Set-StrictMode -Version Latest
        try {
            ${function:Get-FeedVersions} = $FeedVersionsBody
            ${function:Get-ChannelVersions} = $ChannelVersionsBody
            $index = Invoke-RestMethod -Uri $ServiceIndex
            $base = ([string]@($index.resources | Where-Object { @($_.'@type') -contains 'PackageBaseAddress/3.0.0' })[0].'@id').TrimEnd('/') + '/'
            $versions = Get-ChannelVersions -PackageBaseAddress $base -Manifest $Manifest -Channels $Channels
            $EventQueue.Add([PSCustomObject]@{ Type = 'Versions'; Data = $versions })
        }
        catch {
            $offline = $false
            for ($e = $_.Exception; $e; $e = $e.InnerException) {
                if ($e -is [System.Net.Http.HttpRequestException] -or $e -is [System.Net.Sockets.SocketException]) { $offline = $true }
            }
            $EventQueue.Add([PSCustomObject]@{ Type = 'VersionsFailed'; Text = $_.Exception.Message; Offline = $offline })
        }
    }).AddParameters([ordered]@{
        EventQueue          = $script:EventQueue
        ServiceIndex        = $script:FeedManifest[0].ServiceIndex
        Manifest            = $script:PackageManifest
        Channels            = $script:Channels
        FeedVersionsBody    = ${function:Get-FeedVersions}.ToString()
        ChannelVersionsBody = ${function:Get-ChannelVersions}.ToString()
    })
    [void]$script:ResolverPowerShell.BeginInvoke()

    $result = 'Exit'
    Render-Canvas
    $running = $true

    while ($running) {
        $event = $script:EventQueue.Take()
        $dirty = $false

        do {
          try {
            switch ($event.Type) {
                'Key' {
                    $key = $event.Data
                    if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') {
                        $running = $false; break
                    }

                    if ($script:Popup) {
                        if ($script:Popup.Confirm) {
                            if ($key.Key -eq 'Y') { $onYes = $script:Popup.OnYes; $script:Popup = $null; if ($onYes) { . $onYes }; $dirty = $true }
                            elseif ($key.Key -in 'N', 'Escape') { $script:Popup = $null; $dirty = $true }
                        }
                        elseif ($key.Key -in 'Enter', 'Escape') { $script:Popup = $null; $dirty = $true }
                    }
                    elseif ($key.Key -eq 'F12') {
                        Show-DebugPopup; $dirty = $true
                    }
                    elseif ($key.Key -eq 'F1' -and $script:UIMode -in 'Config', 'Building') {
                        $script:ReturnMode = $script:UIMode; $script:UIMode = 'HelpView'; $dirty = $true
                    }
                    elseif ($key.Key -eq 'C' -and $script:UIMode -in 'Config', 'Building') {
                        $script:ReturnMode = $script:UIMode; $script:UIMode = 'LogView'; $dirty = $true
                    }
                    elseif ($script:UIMode -eq 'Config') {
                        $items = Get-NavigationItems
                        switch ($key.Key) {
                            'Escape'     { $running = Request-Exit; $dirty = $true }
                            'Tab' {
                                $delta = if ($key.Modifiers -band [ConsoleModifiers]::Shift) { $items.Count - 1 } else { 1 }
                                $script:ActiveNavIndex = ($script:ActiveNavIndex + $delta) % $items.Count; $dirty = $true
                            }
                            'UpArrow'    { $script:ActiveNavIndex = ($script:ActiveNavIndex + $items.Count - 1) % $items.Count; $dirty = $true }
                            'DownArrow'  { $script:ActiveNavIndex = ($script:ActiveNavIndex + 1) % $items.Count; $dirty = $true }
                            'LeftArrow'  { if ($items[$script:ActiveNavIndex].Kind -eq 'Option') { Set-OptionValue -Id $items[$script:ActiveNavIndex].Id -Direction -1; $dirty = $true } }
                            'RightArrow' { if ($items[$script:ActiveNavIndex].Kind -eq 'Option') { Set-OptionValue -Id $items[$script:ActiveNavIndex].Id -Direction 1; $dirty = $true } }
                            'B'          { Request-Build; $dirty = $true }
                            'Enter' {
                                $row = $items[$script:ActiveNavIndex]
                                if ($row.Id -eq 'Build') { Request-Build }
                                elseif ($row.Id -eq 'Packages' -and $Packages -eq 'Folder') { Select-CacheFolder }
                                else { Set-OptionValue -Id $row.Id -Direction 1 }
                                $dirty = $true
                            }
                        }
                    }
                    elseif ($script:UIMode -eq 'Building') {
                        switch ($key.Key) {
                            'S' { if ($script:BuildEnded) { Save-BuildLog; $dirty = $true } }
                            'Escape' {
                                if (-not $script:BuildEnded) { $running = Request-Exit }
                                else { $script:UIMode = 'Config' }
                                $dirty = $true
                            }
                        }
                    }
                    elseif ($script:UIMode -eq 'ExitPrompt') {
                        switch ($key.Key) {
                            'Y'      { $script:KeepPackageCache = $true;  $running = $false }
                            'N'      { $script:KeepPackageCache = $false; $running = $false }
                            'Escape' { $script:UIMode = $script:ReturnMode; $dirty = $true }
                        }
                    }
                    elseif ($script:UIMode -eq 'CancelPrompt') {
                        switch ($key.Key) {
                            'Y' { $running = $false }
                            { $_ -in 'N', 'Escape' } { $script:UIMode = $script:ReturnMode; $dirty = $true }
                        }
                    }
                    elseif ($script:UIMode -eq 'HelpView') {
                        if ($key.Key -in 'Escape', 'F1', 'Enter') { $script:UIMode = $script:ReturnMode; $dirty = $true }
                    }
                    elseif ($script:UIMode -eq 'LogView') {
                        if ($key.Key -in @('Escape', 'C')) {
                            $script:UIMode = $script:ReturnMode
                            $dirty = $true
                        }
                    }
                }

                'Output' {
                    $text = $event.Text
                    $script:BuildLog.Add($text)
                    $trimmed = $text.Trim()
                    if ($trimmed) {
                        $script:ActiveStep = $trimmed
                        # The steps announce themselves. Completion is the
                        # authority on progress; nothing is inferred.
                        if ($trimmed -match '^\[PASS\] Step (\d+) complete') {
                            $finished = [int]$Matches[1]
                            [void]$script:CompletedNodes.Add($finished)
                            $plan = Resolve-StepOrder -Target $Step
                            $at = $plan.IndexOf($finished)
                            $script:ActiveNodeId = if ($at -ge 0 -and $at -lt ($plan.Count - 1)) { $plan[$at + 1] } else { 0 }
                            $dirty = $true
                        }
                        elseif ($script:ActiveNodeId -eq 0) {
                            $script:ActiveNodeId = (Resolve-StepOrder -Target $Step)[0]
                            $dirty = $true
                        }
                        # Ordinary lines only move the status lane. The canvas
                        # redraws when a step changes state.
                        if ($script:UIMode -eq 'Building' -and -not $dirty) { Write-StatusLane }
                        else { $dirty = $true }
                    }
                }

                'Versions' {
                    $script:ChannelVersions = $event.Data
                    $dirty = $true
                }

                'VersionsFailed' {
                    $script:ChannelVersions = 'failed'
                    $script:BuildLog.Add("Version list: $($event.Text)")
                    if ($event.Offline) { Show-OfflinePopup }
                    $dirty = $true
                }

                'Done' {
                    $script:ActiveNodeId = 0
                    $script:ActiveStep = 'Done. S saves the log.'
                    $script:BuildEnded = $true
                    $script:BuildLog.Add('Done')
                    $dirty = $true
                }

                'Failed' {
                    $script:FailedNodeId = $script:ActiveNodeId
                    $script:BuildEnded = $true
                    $script:ActiveNodeId = 0
                    $script:ActiveStep = "Failed: $($event.Text)"
                    if ($event.Text -like "*$script:OfflineMessage*") { Show-OfflinePopup }
                    $script:BuildLog.Add("[FAIL] $($event.Text)")
                    $dirty = $true
                }
            }
          }
          catch {
            $script:ActiveStep = "[FAIL] $($_.Exception.Message)"
            $script:BuildLog.Add($script:ActiveStep)
            $dirty = $true
          }
        } while ($running -and $script:EventQueue.TryTake([ref]$event))

        if ($running -and $dirty) {
            try { Render-Canvas }
            catch { [Console]::Write("`e[H`e[0m[FAIL] Render: $($_.Exception.Message)") }
        }
    }

    return $result
}

$useInteractiveMode = if ($Interactive) {
    if (-not (Test-InteractiveConsole)) {
        throw '-Interactive requires an attached interactive console.'
    }
    $true
}
elseif ($Headless) {
    $false
}
else {
    Test-InteractiveConsole
}

# Informed consent: show every write location before anything is written.
$writePlan = Resolve-WritePlan
Show-WritePlan -Plan $writePlan.Plan
if ($WhatIfPreference) {
    Write-Host 'WhatIf: nothing will be written.'
}
elseif (-not $AcceptWritePlan -and -not $writePlan.Explicit) {
    if ($useInteractiveMode) {
        $answer = Read-Host 'Write to these locations? [y/N]'
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'Nothing was written. Pass -OutputDirectory, -SigningKeyPath and -CacheDirectory to choose other locations.'
            exit 0
        }
    }
    else {
        Write-Host '[FAIL] Unattended run without consent. Pass -AcceptWritePlan, or give -OutputDirectory, -SigningKeyPath and (with -Packages Folder) -CacheDirectory.' -ForegroundColor Red
        exit 2
    }
}
Enable-WritePlan

if ($useInteractiveMode) {
    $originalOutputEncoding   = [Console]::OutputEncoding
    $originalInputEncoding    = [Console]::InputEncoding
    $originalCursorVisible    = [Console]::CursorVisible
    $originalTreatControlC    = [Console]::TreatControlCAsInput
    $originalBufferWidth      = try { [Console]::BufferWidth } catch { $null }
    $originalBufferHeight     = try { [Console]::BufferHeight } catch { $null }

    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true

        # Match the buffer to the window so the canvas cannot leave a scrollbar
        # thumb artifact behind it.
        if ($IsWindows) {
            try {
                [Console]::BufferHeight = [Console]::WindowHeight
                [Console]::BufferWidth  = [Console]::WindowWidth
            }
            catch { }
        }

        # Alternate buffer, hidden cursor, no auto-wrap, cleared scrollback,
        # then ask the terminal for the 80x30 grid (XTWINOPS; ignored where
        # unsupported, and the canvas clips instead).
        [Console]::Write("`e[?1049h`e[?25l`e[?7l`e[3J")
        [Console]::Write("`e[8;$($script:CanvasHeight);$($script:CanvasWidth)t`e[2J")

        $interfaceResult = Invoke-SetupInterface
    }
    finally {
        if ($script:InputPowerShell)  { $script:InputPowerShell.Stop(); $script:InputPowerShell.Dispose() }
        if ($script:InputRunspace)    { $script:InputRunspace.Dispose() }
        if ($script:WorkerPowerShell) { $script:WorkerPowerShell.Stop(); $script:WorkerPowerShell.Dispose() }
        if ($script:WorkerRunspace)   { $script:WorkerRunspace.Dispose() }
        if ($script:ResolverPowerShell) { $script:ResolverPowerShell.Stop(); $script:ResolverPowerShell.Dispose() }
        if ($script:ResolverRunspace)   { $script:ResolverRunspace.Dispose() }

        [Console]::Write("`e[?7h`e[?25h`e[?1049l`e[0m")
        [Console]::CursorVisible        = $originalCursorVisible
        [Console]::TreatControlCAsInput = $originalTreatControlC
        [Console]::OutputEncoding       = $originalOutputEncoding
        [Console]::InputEncoding        = $originalInputEncoding

        if ($IsWindows -and $originalBufferWidth -and $originalBufferHeight) {
            try {
                [Console]::BufferWidth  = $originalBufferWidth
                [Console]::BufferHeight = $originalBufferHeight
            }
            catch { }
        }
    }

    # The interface runs the build itself, in a worker runspace. Reaching here
    # means it was dismissed; apply the answer to the package question.
    if ($interfaceResult -eq 'Help') { Show-SetupHelp }
    if ($Packages -eq 'Folder' -and -not $script:KeepPackageCache -and (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($CacheDirectory, 'Delete downloaded package cache')) {
            Remove-DownloadedPackages -Directory $CacheDirectory
            Write-Host ('Deleted {0}' -f $CacheDirectory)
        }
    }
    exit 0
}

$script:RunningStep = 0
$repositoryBefore = Get-RepositorySnapshot
try {
    foreach ($id in $script:StepSelection) { Invoke-StepNode -Target $id }
    if ($Debug -and -not $WhatIfPreference) { Invoke-ReferenceCrossCheck }
}
catch {
    # One line, the step, and the reason. The full record stays available in
    # $Error for anyone dot-sourcing the script.
    if (Test-NetworkFailure -Exception $_.Exception) {
        Write-Host ('[FAIL] Step {0}: {1}' -f $script:RunningStep, $script:OfflineMessage) -ForegroundColor Red
    }
    else {
        Write-Host ('[FAIL] Step {0}: {1}' -f $script:RunningStep, $_.Exception.Message) -ForegroundColor Red
        Write-Host ('       {0}' -f $_.InvocationInfo.PositionMessage.Split("`n")[0]) -ForegroundColor DarkRed
    }
    $script:ExitCode = 1
}
finally {
    # Only the downloaded package cache is ever removed, and only when the run
    # was told to. The verified lib specifications are small and are kept.
    # Only a Folder download location is ever removed, and only when asked.
    if ($Packages -eq 'Folder' -and -not $script:KeepPackageCache -and (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($CacheDirectory, 'Delete downloaded package cache')) {
            Remove-DownloadedPackages -Directory $CacheDirectory
            Write-Host ('[PASS] Downloaded packages deleted: {0}' -f $CacheDirectory) -ForegroundColor Green
        }
    }

    Show-WrittenFiles
    $repositoryChanges = @(Compare-RepositorySnapshot -Before $repositoryBefore)
    if ($repositoryChanges.Count -gt 0) {
        Write-Host ('[FAIL] The repository changed during the build ({0} files):' -f $repositoryChanges.Count) -ForegroundColor Red
        $repositoryChanges | ForEach-Object { Write-Host "       $_" -ForegroundColor Red }
        $script:ExitCode = 1
    }
    else {
        Write-Host '[PASS] Repository unchanged.' -ForegroundColor Green
    }
}

exit $(if (Get-Variable -Name ExitCode -Scope Script -ErrorAction Ignore) { $script:ExitCode } else { 0 })
