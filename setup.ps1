#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low', PositionalBinding = $false)]
param(
    [Alias('h')]
    [switch] $Help,

    # One step (5), a range (1-5, 4-5), or a list (2,3). Steps hand data to each
    # other in memory, so a selection also runs whatever its steps depend on.
    [ValidatePattern('^\d{1,2}(-\d{1,2})?(,\d{1,2}(-\d{1,2})?)*$')]
    [string] $Step = '1',

    # Download location. Folder: -CacheDirectory (the current account temporary directory unless
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


    # Validate the manifest emitter and reader only, then exit: no packages, no
    # store, no APK, and nothing written. -Aapt2Path additionally has an
    # installed aapt2 parse both manifests (diagnostic only).
    [switch] $ValidateManifest,
    [string] $Aapt2Path = '',

    # Diagnostic, NativeActivity on x86_64 only: the host's assembly probe logs
    # each path CoreCLR asks for, exactly as given, and whether the store has it.
    [switch] $TraceAssemblyProbe,

    # Diagnostic, NativeActivity only: android:debuggable="true", so that
    # adb shell run-as can place files such as Profile.ps1 in the app's private
    # files directory. Without it the manifest is the release one, unchanged.
    [switch] $Debuggable,

    # What the host starts (docs/console-host.md).
    # Profile:     Profile.ps1 from the app's files directory (gate 2d).
    # ConsoleHost: the shipped console (scripts/console/Start-Console.ps1),
    #              which then runs Profile.ps1 inside the console session.
    [ValidateSet('Profile', 'ConsoleHost')]
    [string] $Startup = 'Profile',

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

    # GNU-style spellings (--help, --step 9, --payload=standard). pwsh -File
    # already maps --name to -name; this catches them under & and dot-sourcing.
    [Parameter(ValueFromRemainingArguments)]
    [string[]] $LongArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Debug: write the intermediates.
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
        'packages'                              { $Packages = (Get-Culture).TextInfo.ToTitleCase((& $value).ToLowerInvariant()) }
        'debug'                                 { $Debug = $true }
        'payload'                               { $Payload = & $value }
        'startup'                               { $Startup = (Get-Culture).TextInfo.ToTitleCase((& $value).ToLowerInvariant()).Replace('Consolehost', 'ConsoleHost') }
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

if ($Startup -cnotin 'Profile', 'ConsoleHost') {
    Write-Host "[FAIL] -Startup must be Profile or ConsoleHost, not '$Startup'." -ForegroundColor Red
    exit 2
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
                            steps it depends on first, so -Step 9 is a full
                            build.
                              1  Verify pinned specifications against upstream
                              2  Acquire and hash the pinned NuGet packages
                              3  Inspect and classify every package payload
                              4  Select the assembly set for the target
                              5  Emit and verify the XABA assembly store
                              6  Wrap the store in an ELF library for the target
                              7  Emit the binary AndroidManifest.xml
                              8  Assemble the unsigned APK archive
                              9  Sign the APK with Signature Scheme v2
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
  suggestions and shown, not used silently: the signed APK and the
  intermediates (only with -KeepIntermediates) in build\ under this
  repository, which git ignores; the signing key and cache in per-user data
  (LocalApplicationData\Pwsh on Windows, the XDG directories elsewhere).
  Nothing else inside this repository is written, and the signing key and
  cache never are. Unattended runs stop unless every location is
  given or -AcceptWritePlan is set. -WhatIf prints the plan and writes
  nothing.
  -Architecture <arm64|x64|arm32>
                            Target. arm64 for phones, x64 for the x86_64
                            emulator. arm32 for 32-bit ARMv7 devices.
  -ValidateManifest         Check the manifest and adaptive-icon emitters in
                            seconds: binary XML through the production reader
                            and resource-id check, plus malformed-document
                            controls for the manifest.
                            Writes nothing. -Aapt2Path <aapt2.exe> adds an
                            independent parse (one temporary file, deleted).
  -Debug                    Write the intermediates (as -KeepIntermediates).
  -Startup <Profile|ConsoleHost>
                            Profile (default): the host runs Profile.ps1
                            from the app's files directory. ConsoleHost: the
                            host starts the shipped console from the APK's
                            scripts, which runs Profile.ps1 inside it.
  -Payload <Minimal|Standard|SDK>
                            Minimal: the pinned assembly set, IL only, no
                            ReadyToRun (R2R) code. Standard: every runtime
                            assembly, R2R code included. SDK: Standard plus
                            the PowerShell SDK assemblies. Standard and SDK
                            are not built yet.
  -Packages <Memory|Folder> Download location. Memory (default): never
                            written to disk. Folder: -CacheDirectory,
                            reused next run.
                            In the interface, Enter opens Browse.
  -DeletePackages           Delete the downloaded package cache on exit.
                            Without it packages are kept. The interface asks
                            on exit.
  -WhatIf                   Preview filesystem and device mutations.

EXAMPLES
  .\setup.ps1
  .\setup.ps1 -h
  .\setup.ps1 -c -Step 1
  .\setup.ps1 -c -Step 9
  .\setup.ps1 -c -Step 1-5
  .\setup.ps1 -c -Step 9 -DeletePackages
  .\setup.ps1 -Interactive

EXECUTION CONTRACT
  With no mode switch, an attached interactive console opens the setup
  interface. Redirected and unattended sessions run headlessly. The same
  phase functions execute in both modes. Every switch also takes a GNU
  spelling: --help, --console, --step 9, --payload=standard,
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
$script:StepIds = @(1, 2, 3, 4, 5, 6, 7, 8, 9)
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
        Caption = 'Downloads the packages pinned in lib/manifest.json and checks each SHA-512.'
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
        Title = 'Wrap the store in an ELF library for the target'
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
        Key = 'Assemble'; DependsOn = @(7)
        Title = 'Assemble the unsigned APK archive'
        Caption = 'Every entry read back byte-identical by an independent reader.'
        Action = { Invoke-AssembleStep }
    }
    9  = @{
        Key = 'Sign'; DependsOn = @(8)
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
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & $script:StepGraph[$id].Action
        Write-Host ('[TIME] Step {0} ({1}): {2:N1} s' -f $id, $script:StepGraph[$id].Key, $stopwatch.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        [void]$script:CompletedNodes.Add($id)
    }
}

# Packages are not declared here. lib/manifest.json pins each one by id,
# version, RID and SHA-512; step 2 downloads exactly those (Get-PackagePins).
$script:PackageManifest = @()

$script:LibDirectory = Join-Path $PSScriptRoot 'lib'

# ==============================================================================
# Write plan
#
# Every file this script creates goes through Write-BuildFile, which admits a
# path only when it lies under an explicitly approved location and outside this
# repository. The written set is reported with SHA-512 digests at the end.
# ==============================================================================

$script:RepositoryRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
# The one place inside the repository this script writes. .gitignore excludes it.
$script:BuildDirectory = Join-Path $script:RepositoryRoot 'build'
$script:ApprovedWriteRoots = [System.Collections.Generic.List[string]]::new()
$script:WrittenFiles = [System.Collections.Generic.List[object]]::new()
$script:LibRestoreDirectory = $null

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
    $script:ApkPath = if ([string]::IsNullOrWhiteSpace($ApkPath)) { Join-Path $script:BuildDirectory $script:ApkFileName }
                      else { [System.IO.Path]::GetFullPath($ApkPath) }

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $script:OutputDirectory = $script:BuildDirectory
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

    foreach ($entry in @(
            @{ Name = 'APK'; Path = $script:ApkPath },
            @{ Name = 'Build output'; Path = $script:OutputDirectory })) {
        if ((Test-PathInside -Path $entry.Path -Root $script:RepositoryRoot) -and
            -not (Test-PathInside -Path $entry.Path -Root $script:BuildDirectory)) {
            throw "$($entry.Name) location '$($entry.Path)' is inside the repository but outside '$script:BuildDirectory'."
        }
    }
    # Secrets and downloads never go inside the repository, build folder included.
    foreach ($entry in @(
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
    $repositoryNote = if ((Test-PathInside -Path $script:ApkPath -Root $script:BuildDirectory) -or
        ($KeepIntermediates -and (Test-PathInside -Path $script:OutputDirectory -Root $script:BuildDirectory))) {
        "written only under $script:BuildDirectory, which git ignores"
    } else { 'never written' }
    Write-Host ('  {0,-14} {1}' -f 'Repository', "$script:RepositoryRoot ($repositoryNote)")
}

function Enable-WritePlan {
    $script:ApprovedWriteRoots.Clear()
    if ($KeepIntermediates) { $script:ApprovedWriteRoots.Add($script:OutputDirectory) }
    $script:ApprovedWriteRoots.Add([System.IO.Path]::GetDirectoryName($script:SigningKeyPath))
    $script:ApprovedWriteRoots.Add([System.IO.Path]::GetDirectoryName($script:ApkPath))
    if ($Packages -eq 'Folder') {
        $script:ApprovedWriteRoots.Add($script:CacheDirectory)
        $script:LibRestoreDirectory = Join-Path $script:CacheDirectory 'lib'
    }
}

function Assert-ApprovedWritePath {
    param([Parameter(Mandatory)][string] $Path)
    # Inside the repository, only the build folder; it must also be in the plan.
    if ((Test-PathInside -Path $Path -Root $script:RepositoryRoot) -and
        -not (Test-PathInside -Path $Path -Root $script:BuildDirectory)) {
        throw "Refusing to write '$Path': it is inside the repository, outside '$script:BuildDirectory'."
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
    # Path, length and last write time of every file in the repository except
    # .git and the build folder, which is never enumerated.
    $snapshot = @{}
    $top = Get-ChildItem -LiteralPath $script:RepositoryRoot -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.git' -and -not (Test-PathInside -Path $_.FullName -Root $script:BuildDirectory) }
    foreach ($item in $top) {
        $files = if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue } else { $item }
        foreach ($file in $files) {
            $snapshot[$file.FullName] = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
        }
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
$script:RepositoryLibBaseUrl = 'https://raw.githubusercontent.com/MansfieldPlumbing/Pwsh/fea685e5769999ef969a988bb63686cd1fd73d81/lib/'
$script:LibRootManifestPath = 'manifest.json'
$script:LibRootManifestSha256 = '04E0B859FB6569884749E9E4FCC1057EB106FB220361C1BF722D0F7F634B5913'
$script:LibSourceManifest = $null

function Get-LibFileBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Sha256,
        [string] $Url,
        [string] $Transport = '',
        [string] $Commit = '',
        [string] $File = ''
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
    $bytes = if ([string]::IsNullOrWhiteSpace($Url)) {
        Get-UpstreamSourceBytes -Url $address
    }
    else {
        Get-UpstreamSourceBytes -Url $address -Transport $Transport -Commit $Commit -File $File
    }

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

function Get-GitPktLine {
    # One pkt-line: four hex digits giving the total length, then the payload.
    param([Parameter(Mandatory)][string] $Text)
    $payload = [Text.Encoding]::UTF8.GetBytes($Text)
    [byte[]]([Text.Encoding]::ASCII.GetBytes(('{0:x4}' -f ($payload.Length + 4))) + $payload)
}

function Get-GitObject {
    # Fetches exactly one object by id over git's smart-HTTP protocol v2 and
    # returns its type and bytes after checking that they hash to that id.
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Id,
        [string[]] $Arguments = @()
    )
    if ($Id -cnotmatch '^[0-9a-f]{40}$') { throw "Git object id '$Id' is not a full SHA-1." }
    $request = [IO.MemoryStream]::new()
    foreach ($line in @('command=fetch')) { $b = Get-GitPktLine "$line`n"; $request.Write($b, 0, $b.Length) }
    $delim = [Text.Encoding]::ASCII.GetBytes('0001'); $request.Write($delim, 0, 4)
    foreach ($line in @($Arguments) + @("want $Id", 'no-progress', 'done')) { $b = Get-GitPktLine "$line`n"; $request.Write($b, 0, $b.Length) }
    $flush = [Text.Encoding]::ASCII.GetBytes('0000'); $request.Write($flush, 0, 4)

    $response = Invoke-WebRequest -Uri ($Repository.TrimEnd('/') + '/git-upload-pack') -Method Post -UseBasicParsing -SkipHttpErrorCheck `
        -Body $request.ToArray() -ContentType 'application/x-git-upload-pack-request' `
        -Headers @{ 'Git-Protocol' = 'version=2'; 'Accept' = 'application/x-git-upload-pack-result' }
    if ([int]$response.StatusCode -ne 200) { throw "git-upload-pack at '$Repository' returned HTTP $([int]$response.StatusCode)." }
    $bytes = $response.RawContentStream.ToArray()

    # Sections are text pkt-lines until 'packfile'; after it every pkt-line
    # carries a side-band byte: 1 pack data, 2 progress, 3 fatal error.
    $pack = [IO.MemoryStream]::new()
    $inPack = $false
    $pos = 0
    while ($pos + 4 -le $bytes.Length) {
        $length = [Convert]::ToInt32([Text.Encoding]::ASCII.GetString($bytes, $pos, 4), 16)
        $pos += 4
        if ($length -lt 4) { if ($length -eq 0 -and $inPack) { break }; continue }
        $size = $length - 4
        if ($pos + $size -gt $bytes.Length) { throw 'git-upload-pack response is truncated.' }
        if (-not $inPack) {
            $text = [Text.Encoding]::UTF8.GetString($bytes, $pos, $size).TrimEnd("`n")
            if ($text.StartsWith('ERR ')) { throw "git-upload-pack refused: $($text.Substring(4))" }
            if ($text -ceq 'packfile') { $inPack = $true }
        } else {
            switch ($bytes[$pos]) {
                1 { $pack.Write($bytes, $pos + 1, $size - 1) }
                2 { }
                3 { throw "git-upload-pack error: $([Text.Encoding]::UTF8.GetString($bytes, $pos + 1, $size - 1).Trim())" }
                default { throw "git-upload-pack sent unknown side-band channel $($bytes[$pos])." }
            }
        }
        $pos += $size
    }
    if (-not $inPack) { throw 'git-upload-pack response carried no packfile.' }

    $p = $pack.ToArray()
    if ($p.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($p, 0, 4) -cne 'PACK') { throw 'Packfile header is missing.' }
    $version = ([uint32]$p[4] -shl 24) -bor ([uint32]$p[5] -shl 16) -bor ([uint32]$p[6] -shl 8) -bor [uint32]$p[7]
    $count = ([uint32]$p[8] -shl 24) -bor ([uint32]$p[9] -shl 16) -bor ([uint32]$p[10] -shl 8) -bor [uint32]$p[11]
    if ($version -notin 2, 3) { throw "Packfile version $version is not supported." }
    if ($count -ne 1) { throw "Expected exactly one object for $Id; the server sent $count." }
    $packHash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
    $packHash.AppendData($p, 0, $p.Length - 20)
    if ([Convert]::ToHexString($packHash.GetHashAndReset()) -cne [Convert]::ToHexString($p, $p.Length - 20, 20)) { throw 'Packfile checksum does not match.' }

    # Object header: type in bits 4-6 of the first byte, size as a
    # little-endian base-128 varint starting with its low four bits.
    $i = 12
    $c = $p[$i++]
    $type = ($c -shr 4) -band 7
    [long]$objectSize = $c -band 15
    $shift = 4
    while ($c -band 0x80) { $c = $p[$i++]; $objectSize = $objectSize -bor ([long]($c -band 0x7f) -shl $shift); $shift += 7 }
    $typeName = @{ 1 = 'commit'; 2 = 'tree'; 3 = 'blob'; 4 = 'tag' }[[int]$type]
    if (-not $typeName) { throw "Object $Id arrived as pack type $type (a delta); only whole objects are accepted." }

    $compressed = [IO.MemoryStream]::new($p, $i, $p.Length - 20 - $i, $false)
    $inflater = [IO.Compression.ZLibStream]::new($compressed, [IO.Compression.CompressionMode]::Decompress)
    $data = [IO.MemoryStream]::new()
    try { $inflater.CopyTo($data) } finally { $inflater.Dispose() }
    $content = $data.ToArray()
    if ($content.Length -ne $objectSize) { throw "Object $Id inflated to $($content.Length) bytes; its header says $objectSize." }

    # A git object id is SHA-1 over "<type> <size>\0<content>".
    $header = [Text.Encoding]::ASCII.GetBytes("$typeName $($content.Length)`0")
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
    $hasher.AppendData($header); $hasher.AppendData($content)
    $actual = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    if ($actual -cne $Id) { throw "Object requested as $Id hashes to $actual." }
    [pscustomobject]@{ Type = $typeName; Content = $content }
}

function Get-GitPinnedFile {
    # Walks commit -> root tree -> one tree per directory -> file, fetching one
    # object per request, so each object's id is proven by its parent.
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $Path
    )
    $object = Get-GitObject -Repository $Repository -Id $Commit -Arguments @('deepen 1', 'filter tree:0')
    if ($object.Type -cne 'commit') { throw "$Commit is a $($object.Type), not a commit." }
    $text = [Text.Encoding]::UTF8.GetString($object.Content)
    if ($text -cnotmatch '^tree ([0-9a-f]{40})\n') { throw "Commit $Commit names no tree." }
    $id = $Matches[1]
    $segments = $Path.Split('/')
    for ($s = 0; $s -lt $segments.Count; $s++) {
        $tree = Get-GitObject -Repository $Repository -Id $id -Arguments @('filter tree:1')
        if ($tree.Type -cne 'tree') { throw "Object $id on the path to '$Path' is a $($tree.Type), not a tree." }
        # Tree entry: "<octal mode> <name>\0" then a 20-byte object id.
        $b = $tree.Content; $k = 0; $found = $null
        while ($k -lt $b.Length) {
            $space = [Array]::IndexOf($b, [byte]0x20, $k)
            $nul = [Array]::IndexOf($b, [byte]0, $space)
            $mode = [Text.Encoding]::ASCII.GetString($b, $k, $space - $k)
            $name = [Text.Encoding]::UTF8.GetString($b, $space + 1, $nul - $space - 1)
            $entryId = [Convert]::ToHexString($b, $nul + 1, 20).ToLowerInvariant()
            $k = $nul + 21
            if ($name -ceq $segments[$s]) { $found = @{ Mode = $mode; Id = $entryId }; break }
        }
        if (-not $found) { throw "'$($segments[0..$s] -join '/')' is not in commit $Commit." }
        $last = $s -eq $segments.Count - 1
        if ($last -and $found.Mode -notin '100644', '100755') { throw "'$Path' is not a regular file in commit $Commit (mode $($found.Mode))." }
        if (-not $last -and $found.Mode -ne '40000') { throw "'$($segments[0..$s] -join '/')' is not a directory in commit $Commit." }
        $id = $found.Id
    }
    $blob = Get-GitObject -Repository $Repository -Id $id
    if ($blob.Type -cne 'blob') { throw "'$Path' resolved to a $($blob.Type), not a blob." }
    [byte[]]$blob.Content
}

function Get-UpstreamSourceBytes {
    # Fetches a pinned source and returns the file's bytes; the caller checks
    # them against the pinned SHA-256. A plain address is one HTTPS GET.
    # 'git-v2' reads a file at a pinned commit through git's smart-HTTP
    # protocol, which android.googlesource.com keeps serving when its web view
    # does not; every object on the way is checked against its git id.
    param(
        [Parameter(Mandatory)][string] $Url,
        [string] $Transport = '',
        [string] $Commit = '',
        [string] $File = ''
    )

    if ($Transport -ceq 'git-v2') {
        return Get-GitPinnedFile -Repository $Url -Commit $Commit -Path $File
    }
    if (-not [string]::IsNullOrEmpty($Transport)) { throw "Unknown upstream transport '$Transport'." }
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -SkipHttpErrorCheck
    if ([int]$response.StatusCode -ne 200) {
        throw "Upstream source '$Url' returned HTTP $([int]$response.StatusCode)."
    }
    return $response.RawContentStream.ToArray()
}

function Get-PinField {
    # An optional string field of a provenance pin; empty when absent.
    param([Parameter(Mandatory)] $Pin, [Parameter(Mandatory)][string] $Name)
    $property = $Pin.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    [string]$property.Value
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
        if ($transport -and $transport -cne 'git-v2') {
            throw "Source '$($source.path)' declares unknown transport '$transport'."
        }
        if ($transport -ceq 'git-v2') {
            if ((Get-PinField -Pin $source -Name 'commit') -cnotmatch '^[0-9a-f]{40}$') {
                throw "Source '$($source.path)' uses git-v2 without a full commit SHA."
            }
            $file = Get-PinField -Pin $source -Name 'file'
            if ([string]::IsNullOrWhiteSpace($file) -or $file.StartsWith('/') -or ($file -split '/') -contains '..') {
                throw "Source '$($source.path)' uses git-v2 without a relative file path inside the repository."
            }
        }
    }
    if (@($sources | Group-Object -Property path | Where-Object Count -ne 1).Count -ne 0) {
        throw 'The root provenance manifest lists a source more than once.'
    }

    # The exact NuGet packages the build downloads. Nothing is resolved at build
    # time: tools/Get-AssemblyClosure.ps1 resolves and checks them against
    # NuGet's catalog when the pins change, and each .nupkg must hash to its pin.
    $pins = @($manifest.packages)
    if ($pins.Count -eq 0) { throw 'The root provenance manifest declares no packages.' }
    foreach ($pin in $pins) {
        if ([string]$pin.id -notmatch '^[A-Za-z0-9_.-]+$') { throw "Package pin has a malformed id: '$($pin.id)'." }
        if ([string]$pin.version -notmatch '^\d+(\.\d+){2,3}(-[0-9A-Za-z.]+)?$') {
            throw "Package pin '$($pin.id)' is not an exact version: '$($pin.version)'."
        }
        if ([string]$pin.sha512 -notmatch '^[0-9A-F]{128}$') { throw "Package pin '$($pin.id)' has a malformed SHA-512." }
        if ($null -ne $pin.rid -and [string]$pin.rid -notin @($script:Targets.Values | ForEach-Object { $_.Rid })) {
            throw "Package pin '$($pin.id)' names unknown RID '$($pin.rid)'."
        }
    }
    if (@($pins | Group-Object -Property id, rid | Where-Object Count -ne 1).Count -ne 0) {
        throw 'The root provenance manifest pins a package more than once for one RID.'
    }
    $script:PackagePins = @($pins | ForEach-Object {
        [pscustomobject]@{ Id = [string]$_.id; Version = [string]$_.version; Rid = $_.rid; Sha512 = [string]$_.sha512 } })

    $script:LibSourceManifest = $sources
    return $script:LibSourceManifest
}

function Get-PackagePins {
    # This target's packages: every pin without a RID and the pins for its RID,
    # in manifest order.
    [void](Get-LibSourceManifest)
    @($script:PackagePins | Where-Object { $null -eq $_.Rid -or [string]$_.Rid -ceq $script:Target.Rid })
}

function Get-PinnedVersion {
    # The version shown for .NET, Android and PowerShell: that of the package
    # which defines each for the build.
    param([Parameter(Mandatory)][ValidateSet('DotNet', 'Android', 'PowerShell')][string] $Channel)
    $id = switch ($Channel) {
        'DotNet'     { "Microsoft.NETCore.App.Runtime.$($script:Target.Rid)" }
        'Android'    { 'Microsoft.Android.Runtime.37.android' }
        'PowerShell' { 'System.Management.Automation' }
    }
    $pin = @(Get-PackagePins | Where-Object Id -ceq $id)
    if ($pin.Count -ne 1) { throw "No single package pin for '$id'." }
    $pin[0].Version
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
    return Get-LibFileBytes -Path $Path -Sha256 ([string]$pin.sha256) -Url ([string]$pin.url) -Transport (Get-PinTransport -Pin $pin) `
        -Commit (Get-PinField -Pin $pin -Name 'commit') -File (Get-PinField -Pin $pin -Name 'file')
}
function Import-LibSourceText {
    param([Parameter(Mandatory)][string] $Path)

    return [System.Text.Encoding]::UTF8.GetString((Import-LibSourceBytes -Path $Path))
}

function Get-JniFunctionTable {
    # All fields in this pinned C declaration are pointers. Reserved entries
    # participate in indexing; offsets are computed with the target pointer size.
    $text = Import-LibSourceText -Path 'jni.h'
    $body = [regex]::Match($text, '(?s)struct JNINativeInterface\s*\{(?<body>.*?)\n\};')
    if (-not $body.Success) { throw 'jni.h does not declare JNINativeInterface.' }
    $fields = [regex]::Matches($body.Groups['body'].Value,
        'void\*\s+(?<reserved>reserved[0-3])\s*;|\(\*(?<function>[A-Za-z][A-Za-z0-9_]*)\)')
    $slots = [ordered]@{}
    for ($index = 0; $index -lt $fields.Count; $index++) {
        $field = $fields[$index]
        $name = if ($field.Groups['reserved'].Success) { $field.Groups['reserved'].Value } else { $field.Groups['function'].Value }
        if ($slots.Contains($name)) { throw "Duplicate JNI field '$name'." }
        $slots[$name] = $index
    }
    if ($slots.Count -ne 233 -or $slots.GetVersion -ne 4 -or $slots.GetObjectRefType -ne 232) {
        throw 'The admitted JNI 1.6 table has an unexpected shape.'
    }
    return $slots
}

function Get-MinimalAssemblyManifest {
    $text = Import-LibSourceText -Path 'minimal-assembly-order.txt'
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        if (-not $trimmed.EndsWith('.dll', [StringComparison]::Ordinal)) {
            throw "The minimal assembly order contains a non-assembly entry: '$trimmed'."
        }
        $names.Add($trimmed)
    }

    # The list is pinned by digest in lib/manifest.json, so its length is the
    # authoritative assembly count; every later check compares against it.
    if ($names.Count -eq 0) {
        throw 'The minimal assembly order is empty.'
    }
    if (@($names | Group-Object | Where-Object Count -ne 1).Count -ne 0) {
        throw 'The minimal assembly order contains duplicate entries.'
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

        $remoteBytes = Get-UpstreamSourceBytes -Url ([string]$pin.url) -Transport (Get-PinTransport -Pin $pin) `
            -Commit (Get-PinField -Pin $pin -Name 'commit') -File (Get-PinField -Pin $pin -Name 'file')
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

    $script:JniFunctionTable = Get-JniFunctionTable
    # Historical probes carry a generated table. Check every entry without
    # executing their module, when the repository copy is available.
    $jniModule = Join-Path $PSScriptRoot 'modules/AndroidCanvas.psm1'
    if (Test-Path -LiteralPath $jniModule -PathType Leaf) {
        $jniTokens = $null; $jniErrors = $null
        $jniAst = [System.Management.Automation.Language.Parser]::ParseFile($jniModule, [ref]$jniTokens, [ref]$jniErrors)
        if ($jniErrors.Count) { throw 'AndroidCanvas.psm1 contains syntax errors.' }
        $assignment = @($jniAst.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -ceq '$script:JniSlot'
        }, $false))
        if ($assignment.Count -ne 1) { throw 'AndroidCanvas.psm1 must declare one JNI slot table.' }
        $tableAst = $assignment[0].Right.Find({ param($node)
            $node -is [System.Management.Automation.Language.HashtableAst]
        }, $false)
        if ($null -eq $tableAst) { throw 'The probe JNI slot initializer is not a literal table.' }
        $probeSlots = $tableAst.SafeGetValue()
        if ($probeSlots.Count -ne ($script:JniFunctionTable.Count - 4)) { throw 'The probe JNI table has a different function count.' }
        foreach ($name in $probeSlots.Keys) {
            if (-not $script:JniFunctionTable.Contains($name) -or $probeSlots[$name] -ne $script:JniFunctionTable[$name]) {
                throw "The probe JNI slot '$name' differs from the admitted header."
            }
        }
    }
    Write-Host '[PASS] JNI 1.6: 233 pointer entries derived from the admitted header.' -ForegroundColor Green
    $attributeCount = Test-AndroidAttributeIds
    $names = Get-MinimalAssemblyManifest
    $contract = Get-AndroidNativeContract
    Write-Host ('[PASS] Step 1 complete: {0} lib specifications verified locally, {1} byte-identical to their pinned upstream addresses, {2} ordered assembly names, {4} framework attribute ids checked against upstream, and XABA magic 0x{3} imported.' -f
        $localCount,
        $remoteCount,
        $names.Count,
        ([uint32]$contract.xaba.magic).ToString('X8'),
        $attributeCount) -ForegroundColor Green
}

$script:BuildContext = [ordered]@{
    PackageBytes     = @{}
    PayloadInventory = $null
    PayloadCandidates = $null
    SelectedAssemblies = $null
    AssemblyStore    = $null
    StoreLibrary     = $null
    PslNative        = $null
    AndroidManifest  = $null
    UnsignedApk      = $null
    SignedApk        = $null
}

# Application identity.
$script:PackageName = 'dev.mansfieldplumbing.pwsh'
$script:ActivityClassName = 'MainActivity'
$script:ApplicationLabel = 'Pwsh'
$script:ResourceChunkConstants = $null

# The managed host assembly and its namespace share the package's name.
$script:ManagedNamespace = 'Dev.MansfieldPlumbing.Pwsh'

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

# The NuGet v3 package content resource (flat container): one GET per pinned
# package, https://learn.microsoft.com/nuget/api/package-base-address-resource
$script:PackageBaseAddress = 'https://api.nuget.org/v3-flatcontainer/'

function Get-PackageAddress {
    param([Parameter(Mandatory)] $Package)
    $id = [Uri]::EscapeDataString(([string]$Package.Id).ToLowerInvariant())
    $version = [Uri]::EscapeDataString(([string]$Package.Version).ToLowerInvariant())
    '{0}{1}/{2}/{1}.{2}.nupkg' -f $script:PackageBaseAddress, $id, $version
}

function Assert-PackageIdentity {
    # A package whose bytes matched its pin must also name the pinned id and
    # version in its own nuspec. Returns the archive's entry count.
    param(
        [Parameter(Mandatory)][byte[]] $PackageBytes,
        [Parameter(Mandatory)] $Package
    )
    $packageStream = [System.IO.MemoryStream]::new($PackageBytes, $false)
    $archive = [System.IO.Compression.ZipArchive]::new($packageStream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    try {
        $nuspecEntries = @($archive.Entries | Where-Object { $_.FullName -notmatch '/' -and $_.Name -like '*.nuspec' })
        if ($nuspecEntries.Count -ne 1) {
            throw "Package '$($Package.Id)' contains $($nuspecEntries.Count) root nuspec files; exactly one is required."
        }
        # XmlDocument reads the encoding declaration and byte-order mark itself.
        $document = [xml]::new()
        $entryStream = $nuspecEntries[0].Open()
        try { $document.Load($entryStream) } finally { $entryStream.Dispose() }
        $metadata = $document.package.metadata
        if ([string]$metadata.id -cne [string]$Package.Id) {
            throw "Package identity mismatch. Pinned '$($Package.Id)', the nuspec names '$($metadata.id)'."
        }
        if ([string]$metadata.version -ine [string]$Package.Version) {
            throw "Package version mismatch for '$($Package.Id)'. Pinned '$($Package.Version)', the nuspec names '$($metadata.version)'."
        }
        $archive.Entries.Count
    }
    finally {
        $archive.Dispose()
        $packageStream.Dispose()
    }
}

$script:OfflineMessage = 'Pwsh Setup requires an internet connection.'

function Test-NetworkFailure {
    # True only when no server answered. An HTTP status is an answer: the
    # connection works, and the error names the server's refusal instead.
    param([Parameter(Mandatory)][Exception] $Exception)
    for ($e = $Exception; $e; $e = $e.InnerException) {
        if ($e -is [System.Net.Http.HttpRequestException] -and $null -ne $e.StatusCode) { return $false }
    }
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

function Get-FileSha512 {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try { return [Convert]::ToHexString([System.Security.Cryptography.SHA512]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Get-VerifiedPackageBytes {
    <#
        Returns one pinned package's bytes, after they hash to its pinned
        SHA-512. Folder keeps a verified copy in $CacheDirectory and reuses it;
        Memory never writes. Returns $null under -WhatIf.
    #>
    param([Parameter(Mandatory)] $Package)

    $fileName = '{0}.{1}.nupkg' -f $Package.Id, $Package.Version
    $address = Get-PackageAddress -Package $Package

    if ($Packages -eq 'Memory') {
        if (-not $PSCmdlet.ShouldProcess($address, 'Download into memory and verify')) { return $null }
        $bytes = [byte[]](Invoke-WebRequest -Uri $address -UseBasicParsing).Content
        $actual = [Convert]::ToHexString([System.Security.Cryptography.SHA512]::HashData($bytes))
        if ($actual -cne $Package.Sha512) {
            throw "SHA-512 mismatch for '$fileName'. The pin is $($Package.Sha512); the download hashes to $actual."
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
            throw "SHA-512 mismatch for '$fileName'. The pin is $($Package.Sha512); the download hashes to $actual."
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
    if ($Packages -ne 'Memory' -and -not (Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        if ($PSCmdlet.ShouldProcess($CacheDirectory, 'Create package cache directory')) {
            New-ApprovedDirectory -Path $CacheDirectory
        }
    }

    $script:PackageManifest = @(Get-PackagePins)
    $runtimeId = "Microsoft.NETCore.App.Runtime.$($script:Target.Rid)"
    if (@($script:PackageManifest | Where-Object Id -ceq $runtimeId).Count -ne 1) {
        throw "lib/manifest.json pins no single runtime pack '$runtimeId'."
    }

    $loaded = 0
    foreach ($package in $script:PackageManifest) {
        $bytes = Get-VerifiedPackageBytes -Package $package
        if ($null -eq $bytes) {
            Write-Host ('[PLAN] Package not loaded during WhatIf: {0} {1}' -f $package.Id, $package.Version) -ForegroundColor Yellow
            continue
        }
        $entryCount = Assert-PackageIdentity -PackageBytes $bytes -Package $package
        $script:BuildContext.PackageBytes[[string]$package.Id] = $bytes
        $loaded++
        Write-Host ('[PASS] Package: {0} {1} | {2} bytes | {3} entries | SHA-512 matches pin' -f
            $package.Id, $package.Version, $bytes.Length, $entryCount) -ForegroundColor Green
    }

    # The record of what this build used.
    $recordDirectory = Join-Path $OutputDirectory $script:Target.Abi
    $recordPath = Join-Path $recordDirectory 'packages.json'
    if ($PSCmdlet.ShouldProcess($recordPath, 'Write package record')) {
        $record = @($script:PackageManifest | ForEach-Object { [ordered]@{ Id = $_.Id; Version = $_.Version; Sha512 = $_.Sha512 } })
        $json = ConvertTo-Json -InputObject $record -Depth 4
        Write-BuildFile -Intermediate -Path $recordPath -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json + [Environment]::NewLine))
    }

    Write-Host ('[PASS] Step 2 complete: {0} packages, each matching its pinned SHA-512. .NET {1} | Android {2} | PowerShell {3}' -f
        $loaded,
        (Get-PinnedVersion -Channel DotNet),
        (Get-PinnedVersion -Channel Android),
        (Get-PinnedVersion -Channel PowerShell)) -ForegroundColor Green
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
# Re-emits a ReadyToRun image as an IL-only PE32 image. Kept: the IL bodies,
# field RVA data, metadata and managed resources. Dropped: native code, the R2R
# header, exception/reloc/debug/import data and the strong-name signature.
#
# Sources (runtime ab19415702aa8139d5369e47c73edb47343c34ad):
# - pedecoder.cpp:1228 CheckILOnly: with no R2R header, only import, resource,
#   security, basereloc, debug, IAT and COM directories are allowed, sections
#   must not be shared, and imports/relocations/entry point are optional.
# - System.Reflection.Metadata Tables.cs:431 and :1811: the RVA is the first
#   4 bytes of every MethodDef and FieldRVA row.
# - readytorun-format.md: a single-file R2R image retains its IL and metadata.

function Get-RvaFileOffset($Headers, [int]$Rva) {
    foreach ($s in $Headers.SectionHeaders) {
        if ($Rva -ge $s.VirtualAddress -and $Rva -lt $s.VirtualAddress + [Math]::Max($s.VirtualSize, $s.SizeOfRawData)) {
            return $Rva - $s.VirtualAddress + $s.PointerToRawData
        }
    }
    throw "RVA 0x$($Rva.ToString('X')) is in no section."
}

function Get-FieldRvaDataSize($Reader, $Field) {
    # Field signature: 0x06, optional custom modifiers, then the type.
    $blob = $Reader.GetBlobReader($Field.Signature)
    if ($blob.ReadByte() -ne 0x06) { throw 'Not a field signature.' }
    $type = $blob.ReadByte()
    while ($type -in 0x1F, 0x20) { [void]$blob.ReadCompressedInteger(); $type = $blob.ReadByte() }
    switch ($type) {
        { $_ -in 0x02, 0x04, 0x05 } { return 1 }
        { $_ -in 0x03, 0x06, 0x07 } { return 2 }
        { $_ -in 0x08, 0x09, 0x0C } { return 4 }
        { $_ -in 0x0A, 0x0B, 0x0D } { return 8 }
        0x11 {
            $handle = $blob.ReadTypeHandle()
            if ($handle.Kind -ne [Reflection.Metadata.HandleKind]::TypeDefinition) { throw 'FieldRVA value type is not defined in this assembly.' }
            $size = $Reader.GetTypeDefinition([Reflection.Metadata.TypeDefinitionHandle]$handle).GetLayout().Size
            if ($size -le 0) { throw 'FieldRVA value type has no explicit size.' }
            return $size
        }
        default { throw "FieldRVA field has unsupported element type 0x$($type.ToString('X2'))." }
    }
}

function ConvertTo-IlOnlyImage {
    param([Parameter(Mandatory)][byte[]]$Image, [Parameter(Mandatory)][byte[]]$Template)
    $pe = [Reflection.PortableExecutable.PEReader]::new([IO.MemoryStream]::new($Image, $false))
    try {
        $h = $pe.PEHeaders
        $cor = $h.CorHeader
        if ($cor.ManagedNativeHeaderDirectory.Size -eq 0) { return , $Image }
        if ($cor.VtableFixupsDirectory.Size -ne 0) { throw 'Image has vtable fixups (mixed mode); not convertible.' }
        $md = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)

        $text = [IO.MemoryStream]::new()
        $base = 0x2000
        $text.Write([byte[]]::new(72), 0, 72)                      # CLI header, filled last
        function Align([int]$n) { while ($text.Length % $n) { $text.WriteByte(0) } }

        # IL bodies, deduplicated by original RVA; fat bodies stay 4-aligned.
        $methodRva = @{}
        foreach ($mh in $md.MethodDefinitions) {
            $rva = $md.GetMethodDefinition($mh).RelativeVirtualAddress
            if ($rva -eq 0 -or $methodRva.ContainsKey($rva)) { continue }
            $size = [Reflection.Metadata.PEReaderExtensions]::GetMethodBody($pe, $rva).Size
            $off = Get-RvaFileOffset $h $rva
            if (($Image[$off] -band 3) -eq 3) { Align 4 }
            $methodRva[$rva] = $base + [int]$text.Length
            $text.Write($Image, $off, $size)
        }

        # Field RVA data, keeping each blob's original power-of-two alignment (max 16).
        $fieldRva = @{}
        foreach ($fh in $md.FieldDefinitions) {
            $field = $md.GetFieldDefinition($fh)
            $rva = $field.GetRelativeVirtualAddress()
            if ($rva -eq 0 -or $fieldRva.ContainsKey($rva)) { continue }
            $size = Get-FieldRvaDataSize $md $field
            $align = 1; while ($align -lt 16 -and ($rva % ($align * 2)) -eq 0) { $align *= 2 }
            Align $align
            $fieldRva[$rva] = $base + [int]$text.Length
            $text.Write($Image, (Get-RvaFileOffset $h $rva), $size)
        }

        # Metadata, with the RVA column of MethodDef and FieldRVA rewritten.
        Align 4
        $mdRva = $base + [int]$text.Length
        $metadata = [byte[]]::new($cor.MetadataDirectory.Size)
        [Array]::Copy($Image, (Get-RvaFileOffset $h $cor.MetadataDirectory.RelativeVirtualAddress), $metadata, 0, $metadata.Length)
        $ext = [Reflection.Metadata.Ecma335.MetadataReaderExtensions]
        foreach ($pair in @(@([Reflection.Metadata.Ecma335.TableIndex]::MethodDef, $methodRva), @([Reflection.Metadata.Ecma335.TableIndex]::FieldRva, $fieldRva))) {
            $table = $pair[0]; $map = $pair[1]
            $start = $ext::GetTableMetadataOffset($md, $table); $row = $ext::GetTableRowSize($md, $table); $count = $ext::GetTableRowCount($md, $table)
            for ($r = 0; $r -lt $count; $r++) {
                $at = $start + $r * $row
                $old = [BitConverter]::ToInt32($metadata, $at)
                if ($old -eq 0) { continue }
                if (-not $map.ContainsKey($old)) { throw "No relocated data for $table RVA 0x$($old.ToString('X'))." }
                [BitConverter]::GetBytes([int]$map[$old]).CopyTo($metadata, $at)
            }
        }
        $text.Write($metadata, 0, $metadata.Length)

        # Managed resources, 8-aligned; offsets inside are relative to this blob.
        $resRva = 0; $resSize = $cor.ResourcesDirectory.Size
        if ($resSize) {
            Align 8
            $resRva = $base + [int]$text.Length
            $text.Write($Image, (Get-RvaFileOffset $h $cor.ResourcesDirectory.RelativeVirtualAddress), $resSize)
        }

        # CLI header (ECMA-335 II.25.3.3): IL-only, no entry point, no strong name.
        $cli = [IO.BinaryWriter]::new([IO.MemoryStream]::new())
        $cli.Write([uint32]72); $cli.Write([uint16]2); $cli.Write([uint16]5)
        $cli.Write([uint32]$mdRva); $cli.Write([uint32]$metadata.Length)
        $cli.Write([uint32]1)                                       # COMIMAGE_FLAGS_ILONLY
        $cli.Write([uint32]0)                                       # entry point token
        $cli.Write([uint32]$resRva); $cli.Write([uint32]$resSize)
        $cli.Write([byte[]]::new(8 * 5))                            # strong name, code manager, vtable fixups, EAT jumps, managed native header
        $textBytes = $text.ToArray()
        [Array]::Copy($cli.BaseStream.ToArray(), 0, $textBytes, 0, 72)

        # PE32 headers from the pack's IL-only template, then patched.
        $t = [Reflection.PortableExecutable.PEReader]::new([IO.MemoryStream]::new($Template, $false))
        $lfanew = [BitConverter]::ToInt32($Template, 0x3C)
        $headerSize = 0x200
        $rawSize = [int]([Math]::Ceiling($textBytes.Length / 512) * 512)
        $out = [byte[]]::new($headerSize + $rawSize)
        [Array]::Copy($Template, 0, $out, 0, $lfanew + 4 + 20 + 224)
        $t.Dispose()
        $coff = $lfanew + 4; $opt = $coff + 20
        [BitConverter]::GetBytes([uint16]1).CopyTo($out, $coff + 2)          # one section
        [BitConverter]::GetBytes([uint32]0).CopyTo($out, $coff + 4)          # timestamp: deterministic
        [BitConverter]::GetBytes([uint32]$rawSize).CopyTo($out, $opt + 4)    # SizeOfCode
        [BitConverter]::GetBytes([uint32]0).CopyTo($out, $opt + 8)           # SizeOfInitializedData
        [BitConverter]::GetBytes([uint32]0).CopyTo($out, $opt + 16)          # AddressOfEntryPoint
        [BitConverter]::GetBytes([uint32]$base).CopyTo($out, $opt + 20)      # BaseOfCode
        $imageSize = $base + [int]([Math]::Ceiling($textBytes.Length / 0x2000) * 0x2000)
        [BitConverter]::GetBytes([uint32]$imageSize).CopyTo($out, $opt + 56) # SizeOfImage
        [BitConverter]::GetBytes([uint32]$headerSize).CopyTo($out, $opt + 60)# SizeOfHeaders
        [BitConverter]::GetBytes([uint32]0).CopyTo($out, $opt + 64)          # CheckSum
        for ($d = 0; $d -lt 16; $d++) { [Array]::Clear($out, $opt + 96 + 8 * $d, 8) }
        [BitConverter]::GetBytes([uint32]$base).CopyTo($out, $opt + 96 + 8 * 14)   # COM descriptor
        [BitConverter]::GetBytes([uint32]72).CopyTo($out, $opt + 96 + 8 * 14 + 4)
        $sec = $opt + 224
        [Array]::Clear($out, $sec, 40)
        [Text.Encoding]::ASCII.GetBytes('.text').CopyTo($out, $sec)
        [BitConverter]::GetBytes([uint32]$textBytes.Length).CopyTo($out, $sec + 8)
        [BitConverter]::GetBytes([uint32]$base).CopyTo($out, $sec + 12)
        [BitConverter]::GetBytes([uint32]$rawSize).CopyTo($out, $sec + 16)
        [BitConverter]::GetBytes([uint32]$headerSize).CopyTo($out, $sec + 20)
        [BitConverter]::GetBytes([uint32]0x60000020).CopyTo($out, $sec + 36) # code, execute, read
        [Array]::Copy($textBytes, 0, $out, $headerSize, $textBytes.Length)
        return , $out
    } finally { $pe.Dispose() }
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

# Methods compiled from expression trees during this build.
$script:PersistedMethods = [System.Collections.Generic.List[object]]::new()

# -Startup ConsoleHost script assets, read once by Get-StartupScriptAssets.
$script:StartupScriptAssets = $null

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
$script:ExpressionFactories = $null

function Initialize-ExpressionKit {
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
        BoundConstants     = 0
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
                # LambdaCompiler emits only these as IL literals (ILGen.CanEmitConstant,
                # runtime ab194157); anything else is loaded from a closure, and a
                # persisted method has none, so the load reads argument 0 instead.
                $code = [Type]::GetTypeCode([Nullable]::GetUnderlyingType($Node.Type) ?? $Node.Type)
                if ($code -notin 'Boolean', 'SByte', 'Int16', 'Int32', 'Int64', 'Single', 'Double', 'Char',
                        'Byte', 'UInt16', 'UInt32', 'UInt64', 'Decimal', 'String' -and
                    $Node.Value -isnot [Type] -and $Node.Value -isnot [Reflection.MethodBase]) {
                    $report.BoundConstants++
                }
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
    if ($report.DynamicNodes -or $report.CallSiteReferences -or $report.CallSiteConstants -or $report.BoundConstants) {
        throw ("$($Owner.FullName).$Name is not fully persisted: " +
            "$($report.DynamicNodes) dynamic node(s), " +
            "$($report.CallSiteReferences) call-site reference(s), " +
            "$($report.CallSiteConstants) call-site constant(s), " +
            "$($report.BoundConstants) constant(s) IL cannot encode.")
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

function New-FindProfileMethod {
    # FindProfile(files, index, fallback): the first of files whose name is
    # Profile.ps1 ignoring case, else fallback. The Xamarin program type and the
    # NativeActivity NativeHost both define it from this one generator.
    param([Parameter(Mandatory)][Reflection.Emit.TypeBuilder] $Owner, [Parameter(Mandatory)][Reflection.MethodAttributes] $Attributes)
    # Profile.ps1 is found whatever its letter case. PowerShell does not care
    # about case and neither does this menu; only Android's filesystem does.
    $getFiles = Get-ExactMethod ([IO.Directory]) 'GetFiles' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $getFileName = Get-ExactMethod ([IO.Path]) 'GetFileName' @([string]) ([Reflection.BindingFlags]'Public,Static')
    $ignoreCaseEquals = Get-ExactMethod ([string]) 'Equals' @([string], [string], [StringComparison]) ([Reflection.BindingFlags]'Public,Static')
    $candidateFiles = [Linq.Expressions.Expression]::Parameter([string[]], 'files')
    $candidateIndex = [Linq.Expressions.Expression]::Parameter([int], 'index')
    $candidateFallback = [Linq.Expressions.Expression]::Parameter([string], 'fallback')
    $findProfileMethod = $Owner.DefineMethod(
        'FindProfile', $Attributes, [string], [Type[]]@([string[]], [int], [string]))

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

    [pscustomobject]@{ Method = $findProfileMethod; GetFiles = $getFiles; GetFileName = $getFileName }
}

function New-ManagedHostAssemblyBytes {
    # Dev.MansfieldPlumbing.Pwsh: the managed entries the emitted native host
    # reaches through coreclr_create_delegate. It references SMA and CoreLib
    # only; no Android binding assembly is loaded or referenced.
    $identity = [Reflection.AssemblyName]::new($script:ManagedNamespace)
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($identity, [object].Assembly)
    $module = $builder.DefineDynamicModule("$($script:ManagedNamespace).dll")
    # The New-Clr* helpers bind the Expression factory overloads through this.
    Initialize-ExpressionKit

        # The managed entries the emitted native host reaches through
        # coreclr_create_delegate. They touch no Android type, so Mono.Android
        # is never loaded. RunPowerShell (gates 2b and 2c) opens a runspace on
        # the calling (main) thread, runs a script whose value is 'PWSH'
        # (0x50575348) and returns that value, or the HResult of the first
        # exception.
        # Boundary markers go to logcat through liblog, bound by P/Invoke.
        $logType = $module.DefineType('Dev.MansfieldPlumbing.Pwsh.NativeLog',
            [Reflection.TypeAttributes]'NotPublic,Abstract,Sealed,BeforeFieldInit')
        $logWrite = $logType.DefinePInvokeMethod('__android_log_write', 'liblog.so',
            [Reflection.MethodAttributes]'Public,Static,PinvokeImpl,HideBySig', [Reflection.CallingConventions]::Standard,
            [int], [type[]]@([int], [string], [string]),
            [Runtime.InteropServices.CallingConvention]::Cdecl, [Runtime.InteropServices.CharSet]::Ansi)
        $logWrite.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
        $logType.CreateType() | Out-Null
        $infoPriority = Get-AndroidLogPriority -Name 'ANDROID_LOG_INFO'
        $errorPriority = Get-AndroidLogPriority -Name 'ANDROID_LOG_ERROR'
        $log = { param([int] $Priority, [Linq.Expressions.Expression] $Text)
            New-StaticCall $logWrite @((New-ClrConstant $Priority ([int])), (New-ClrConstant 'Pwsh' ([string])), $Text) }
        $mark = { param([string] $Text) & $log $infoPriority (New-ClrConstant $Text ([string])) }

        $rs = [Management.Automation.Runspaces.RunspaceFactory]
        # Borrowed for this NativeActivity invocation; never publish one
        # process-global current Activity. native_activity.h owns its lifetime.
        $nativeActivity = [Linq.Expressions.Expression]::Parameter([IntPtr], 'nativeActivity')
        $runspaceType = [Management.Automation.Runspaces.Runspace]
        $issVar = [Linq.Expressions.Expression]::Variable([Management.Automation.Runspaces.InitialSessionState], 'iss')
        $runspaceVar = [Linq.Expressions.Expression]::Variable($runspaceType, 'runspace')
        $shellVar = [Linq.Expressions.Expression]::Variable([powershell], 'shell')
        $resultVar = [Linq.Expressions.Expression]::Variable([int], 'result')
        $filesVar = [Linq.Expressions.Expression]::Variable([string], 'files')
        $profileVar = [Linq.Expressions.Expression]::Variable([string], 'profile')
        $moduleShell = [Linq.Expressions.Expression]::Variable([powershell], 'moduleShell')
        $profileShell = [Linq.Expressions.Expression]::Variable([powershell], 'profileShell')
        $stateShell = [Linq.Expressions.Expression]::Variable([powershell], 'stateShell')
        $startCommand = [Linq.Expressions.Expression]::Variable([Management.Automation.CommandInfo], 'startCommand')
        $errorVar = [Linq.Expressions.Expression]::Variable([Exception], 'error')
        $invoke = @([powershell].GetMethods() | Where-Object { $_.Name -eq 'Invoke' -and -not $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 0 })
        if ($invoke.Count -ne 1) { throw "PowerShell.Invoke(): $($invoke.Count) non-generic parameterless overloads." }
        $results = New-ClrCall $shellVar $invoke[0]
        $first = [Linq.Expressions.Expression]::Property($results, 'Item', [Linq.Expressions.Expression[]]@(New-ClrConstant 0 ([int])))
        $firstValue = [Linq.Expressions.Expression]::Unbox(
            (New-ClrProperty $first (Get-ExactProperty ([psobject]) 'BaseObject')), [int])
        $nativeHostType = $module.DefineType('Dev.MansfieldPlumbing.Pwsh.NativeHost',
            [Reflection.TypeAttributes]'Public,Abstract,Sealed,BeforeFieldInit')
        $concat = Get-ExactMethod ([string]) 'Concat' @([string], [string])
        $hexText = { param($value) New-ClrCall $value (Get-ExactMethod ([int]) 'ToString' @([string])) @((New-ClrConstant 'x8' ([string]))) }
        # Gate 2d substrate: Profile.ps1 through the product's path, less
        # what needs an Activity ($Activity, recovery UI, animation), which
        # waits for gate 2e. The files directory is internalDataPath, the
        # base directory the host passes without its trailing separator;
        # FindProfile is the product's case-insensitive lookup.
        $nativeFind = New-FindProfileMethod -Owner $nativeHostType -Attributes ([Reflection.MethodAttributes]'Private,Static,HideBySig')
        $sessionState = New-ClrProperty $runspaceVar (Get-ExactProperty $runspaceType 'SessionStateProxy')
        $profileErrors = New-ClrProperty (New-ClrProperty $profileShell (Get-ExactProperty ([powershell]) 'Streams')) (Get-ExactProperty ([Management.Automation.PSDataStreams]) 'Error')
        $errorCollection = (Get-ExactProperty ([Management.Automation.PSDataStreams]) 'Error').PropertyType
        $firstError = [Linq.Expressions.Expression]::MakeIndex($profileErrors, $errorCollection.GetProperty('Item', [type[]]@([int])), [Linq.Expressions.Expression[]]@((New-ClrConstant 0 ([int]))))
        $moduleErrors = New-ClrProperty (New-ClrProperty $moduleShell (Get-ExactProperty ([powershell]) 'Streams')) (Get-ExactProperty ([Management.Automation.PSDataStreams]) 'Error')
        $firstModuleError = [Linq.Expressions.Expression]::MakeIndex($moduleErrors, $errorCollection.GetProperty('Item', [type[]]@([int])), [Linq.Expressions.Expression[]]@((New-ClrConstant 0 ([int]))))
        $stateResults = New-ClrCall $stateShell $invoke[0]
        $stateValue = [Linq.Expressions.Expression]::Unbox((New-ClrProperty ([Linq.Expressions.Expression]::Property($stateResults, 'Item', [Linq.Expressions.Expression[]]@(New-ClrConstant 0 ([int])))) (Get-ExactProperty ([psobject]) 'BaseObject')), [int])
        $profilePhase = New-ClrBlock @() @(
            (New-ClrAssign $filesVar (New-StaticCall (Get-ExactMethod ([IO.Path]) 'TrimEndingDirectorySeparator' @([string])) @((New-ClrProperty $null (Get-ExactProperty ([AppContext]) 'BaseDirectory'))))),
            (New-ClrAssign $profileVar (New-StaticCall $nativeFind.Method @(
                (New-StaticCall $nativeFind.GetFiles @($filesVar)),
                (New-ClrConstant 0 ([int])),
                (New-StaticCall (Get-ExactMethod ([IO.Path]) 'Combine' @([string], [string])) @($filesVar, (New-ClrConstant 'Profile.ps1' ([string]))))))),
            [Linq.Expressions.Expression]::IfThenElse(
                (New-StaticCall (Get-ExactMethod ([IO.File]) 'Exists' @([string])) @($profileVar)),
                (New-ClrBlock @() @(
                    (& $log $infoPriority (New-StaticCall $concat @((New-ClrConstant 'GATE2D found ' ([string])), (New-StaticCall $nativeFind.GetFileName @($profileVar))))),
                    (New-ClrCall $sessionState (Get-ExactMethod ([Management.Automation.Runspaces.SessionStateProxy]) 'SetVariable' @([string], [object])) @(
                        (New-ClrConstant 'PSScriptRoot' ([string])), [Linq.Expressions.Expression]::Convert($filesVar, [object]))),
                    (New-ClrAssign $startCommand (New-ClrCall (New-ClrProperty $sessionState (Get-ExactProperty ([Management.Automation.Runspaces.SessionStateProxy]) 'InvokeCommand')) `
                        (Get-ExactMethod ([Management.Automation.CommandInvocationIntrinsics]) 'GetCommand' @([string], [Management.Automation.CommandTypes])) @(
                            $profileVar, (New-ClrConstant ([Management.Automation.CommandTypes]::ExternalScript) ([Management.Automation.CommandTypes]))))),
                    (New-ClrAssign $profileShell (New-StaticCall (Get-ExactMethod ([powershell]) 'Create' @($runspaceType)) @($runspaceVar))),
                    (New-ClrCall $profileShell (Get-ExactMethod ([powershell]) 'AddCommand' @([Management.Automation.CommandInfo])) @($startCommand)),
                    (& $mark 'GATE2D START_INVOKE_BEGIN'),
                    (New-ClrCall $profileShell $invoke[0]),
                    (& $mark 'GATE2D START_INVOKE_END'),
                    [Linq.Expressions.Expression]::IfThen(
                        (New-ClrProperty $profileShell (Get-ExactProperty ([powershell]) 'HadErrors')),
                        [Linq.Expressions.Expression]::Throw((New-ClrNew ([InvalidOperationException].GetConstructor([type[]]@([string]))) @(
                            [Linq.Expressions.Expression]::Condition(
                                [Linq.Expressions.Expression]::GreaterThan((New-ClrProperty $profileErrors (Get-ExactProperty $errorCollection 'Count')), (New-ClrConstant 0 ([int]))),
                                (New-ClrCall $firstError (Get-ExactMethod ([Management.Automation.ErrorRecord]) 'ToString' @())),
                                (New-ClrConstant 'Profile.ps1 reported one or more PowerShell errors.' ([string]))))))),
                    # State the profile left in the runspace, read by a second pipeline.
                    (New-ClrAssign $stateShell (New-StaticCall (Get-ExactMethod ([powershell]) 'Create' @($runspaceType)) @($runspaceVar))),
                    (New-ClrCall $stateShell (Get-ExactMethod ([powershell]) 'AddScript' @([string])) @((New-ClrConstant '[int]$global:Gate2d' ([string])))),
                    (& $log $infoPriority (New-StaticCall $concat @((New-ClrConstant 'GATE2D profile state 0x' ([string])), (& $hexText $stateValue)))))),
                (& $mark 'GATE2D START_MISSING')))
        $startPhase = $profilePhase
        $appDirVar = [Linq.Expressions.Expression]::Variable([string], 'appScripts')
        $userDirVar = [Linq.Expressions.Expression]::Variable([string], 'userScripts')
        $markerVar = [Linq.Expressions.Expression]::Variable([string], 'assetMarker')
        if ($Startup -eq 'ConsoleHost') {
            # docs/console-host.md: copy the APK's assets/scripts into
            # PWSH_APP_SCRIPTS when the asset set changed, put PWSH_USER_SCRIPTS
            # then PWSH_APP_SCRIPTS on PATH, and run the shipped start script.
            # AAssetManager calls: include/android/asset_manager.h at
            # frameworks/native bfcf7507 (lines 78-84, 95, 102, 114, 124, 131,
            # 156, 175); size_t and off64_t cross as nint and long.
            $assets = Get-StartupScriptAssets
            $assetType = $module.DefineType('Dev.MansfieldPlumbing.Pwsh.AndroidAssets',
                [Reflection.TypeAttributes]'NotPublic,Abstract,Sealed,BeforeFieldInit')
            $import = { param([string] $Name, [Type] $Return, [Type[]] $Parameters)
                $m = $assetType.DefinePInvokeMethod($Name, 'libandroid.so',
                    [Reflection.MethodAttributes]'Public,Static,PinvokeImpl,HideBySig', [Reflection.CallingConventions]::Standard,
                    $Return, $Parameters, [Runtime.InteropServices.CallingConvention]::Cdecl, [Runtime.InteropServices.CharSet]::Ansi)
                $m.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
                $m }
            $openDir = & $import 'AAssetManager_openDir' ([IntPtr]) @([IntPtr], [string])
            $nextName = & $import 'AAssetDir_getNextFileName' ([IntPtr]) @([IntPtr])
            $closeDir = & $import 'AAssetDir_close' ([void]) @([IntPtr])
            $openAsset = & $import 'AAssetManager_open' ([IntPtr]) @([IntPtr], [string], [int])
            $assetLength = & $import 'AAsset_getLength64' ([long]) @([IntPtr])
            $assetRead = & $import 'AAsset_read' ([int]) @([IntPtr], [byte[]], [IntPtr])
            $closeAsset = & $import 'AAsset_close' ([void]) @([IntPtr])
            $assetType.CreateType() | Out-Null
            $streamingMode = 2   # AASSET_MODE_STREAMING

            # ExtractScripts(manager, directory): every file of assets/scripts
            # written to directory; returns the count. Throws on a missing
            # directory, an unopenable asset or a short read.
            $mgr = [Linq.Expressions.Expression]::Parameter([IntPtr], 'manager')
            $dest = [Linq.Expressions.Expression]::Parameter([string], 'directory')
            $dirVar = [Linq.Expressions.Expression]::Variable([IntPtr], 'dir')
            $namePtrVar = [Linq.Expressions.Expression]::Variable([IntPtr], 'namePtr')
            $nameVar = [Linq.Expressions.Expression]::Variable([string], 'name')
            $assetVar = [Linq.Expressions.Expression]::Variable([IntPtr], 'asset')
            $bytesVar = [Linq.Expressions.Expression]::Variable([byte[]], 'bytes')
            $chunkVar = [Linq.Expressions.Expression]::Variable([byte[]], 'chunk')
            $readVar = [Linq.Expressions.Expression]::Variable([int], 'read')
            $offsetVar = [Linq.Expressions.Expression]::Variable([int], 'offset')
            $countVar = [Linq.Expressions.Expression]::Variable([int], 'count')
            $zero = [Linq.Expressions.Expression]::Default([IntPtr])
            $fail = { param([Linq.Expressions.Expression] $Message)
                [Linq.Expressions.Expression]::Throw((New-ClrNew ([InvalidOperationException].GetConstructor([type[]]@([string]))) @($Message))) }
            $namesDone = [Linq.Expressions.Expression]::Label('namesDone')
            $readDone = [Linq.Expressions.Expression]::Label('readDone')
            $readLoop = [Linq.Expressions.Expression]::Loop((New-ClrBlock @() @(
                [Linq.Expressions.Expression]::IfThen(
                    [Linq.Expressions.Expression]::GreaterThanOrEqual($offsetVar, [Linq.Expressions.Expression]::ArrayLength($bytesVar)),
                    [Linq.Expressions.Expression]::Break($readDone)),
                (New-ClrAssign $readVar (New-StaticCall $assetRead @($assetVar, $chunkVar,
                    (New-ClrNew ([IntPtr].GetConstructor([type[]]@([int]))) @([Linq.Expressions.Expression]::ArrayLength($chunkVar)))))),
                [Linq.Expressions.Expression]::IfThen(
                    [Linq.Expressions.Expression]::LessThanOrEqual($readVar, (New-ClrConstant 0 ([int]))),
                    [Linq.Expressions.Expression]::Break($readDone)),
                (New-StaticCall (Get-ExactMethod ([Buffer]) 'BlockCopy' @([Array], [int], [Array], [int], [int])) @(
                    $chunkVar, (New-ClrConstant 0 ([int])), $bytesVar, $offsetVar, $readVar)),
                (New-ClrAssign $offsetVar ([Linq.Expressions.Expression]::Add($offsetVar, $readVar))))), $readDone)
            $nameLoop = [Linq.Expressions.Expression]::Loop((New-ClrBlock @() @(
                (New-ClrAssign $namePtrVar (New-StaticCall $nextName @($dirVar))),
                [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($namePtrVar, $zero), [Linq.Expressions.Expression]::Break($namesDone)),
                (New-ClrAssign $nameVar (New-StaticCall (Get-ExactMethod ([Runtime.InteropServices.Marshal]) 'PtrToStringUTF8' @([IntPtr])) @($namePtrVar))),
                (New-ClrAssign $assetVar (New-StaticCall $openAsset @($mgr,
                    (New-StaticCall $concat @((New-ClrConstant 'scripts/' ([string])), $nameVar)),
                    (New-ClrConstant $streamingMode ([int]))))),
                [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($assetVar, $zero),
                    (& $fail (New-StaticCall $concat @((New-ClrConstant 'Cannot open asset scripts/' ([string])), $nameVar)))),
                (New-ClrAssign $bytesVar ([Linq.Expressions.Expression]::NewArrayBounds([byte], [Linq.Expressions.Expression[]]@(
                    [Linq.Expressions.Expression]::Convert((New-StaticCall $assetLength @($assetVar)), [int]))))),
                (New-ClrAssign $offsetVar (New-ClrConstant 0 ([int]))),
                $readLoop,
                (New-StaticCall $closeAsset @($assetVar)),
                [Linq.Expressions.Expression]::IfThen(
                    [Linq.Expressions.Expression]::NotEqual($offsetVar, [Linq.Expressions.Expression]::ArrayLength($bytesVar)),
                    (& $fail (New-StaticCall $concat @((New-ClrConstant 'Short read of asset scripts/' ([string])), $nameVar)))),
                (New-StaticCall (Get-ExactMethod ([IO.File]) 'WriteAllBytes' @([string], [byte[]])) @(
                    (New-StaticCall (Get-ExactMethod ([IO.Path]) 'Combine' @([string], [string])) @($dest, $nameVar)), $bytesVar)),
                (New-ClrAssign $countVar ([Linq.Expressions.Expression]::Add($countVar, (New-ClrConstant 1 ([int]))))))), $namesDone)
            $extract = Add-PersistedMethod $nativeHostType 'ExtractScripts' ([Reflection.MethodAttributes]'Private,Static,HideBySig') ([int]) @([IntPtr], [string]) `
                ([Func[IntPtr, string, int]]) @($mgr, $dest) (New-ClrBlock @($dirVar, $namePtrVar, $nameVar, $assetVar, $bytesVar, $chunkVar, $readVar, $offsetVar, $countVar) @(
                    (New-ClrAssign $dirVar (New-StaticCall $openDir @($mgr, (New-ClrConstant 'scripts' ([string]))))),
                    [Linq.Expressions.Expression]::IfThen([Linq.Expressions.Expression]::Equal($dirVar, $zero),
                        (& $fail (New-ClrConstant 'The APK has no assets/scripts directory.' ([string])))),
                    (New-ClrAssign $chunkVar ([Linq.Expressions.Expression]::NewArrayBounds([byte], [Linq.Expressions.Expression[]]@((New-ClrConstant 65536 ([int])))))),
                    (New-ClrAssign $countVar (New-ClrConstant 0 ([int]))),
                    $nameLoop,
                    (New-StaticCall $closeDir @($dirVar)),
                    $countVar))

            $assetManagerOffset = Get-NativeActivityFieldOffset -Field 'assetManager' -PointerSize ($script:Target.ElfClass / 8)
            $combine = Get-ExactMethod ([IO.Path]) 'Combine' @([string], [string])
            $setEnv = Get-ExactMethod ([Environment]) 'SetEnvironmentVariable' @([string], [string])
            $createDir = Get-ExactMethod ([IO.Directory]) 'CreateDirectory' @([string])
            $startPhase = New-ClrBlock @() @(
                (New-ClrAssign $filesVar (New-StaticCall (Get-ExactMethod ([IO.Path]) 'TrimEndingDirectorySeparator' @([string])) @((New-ClrProperty $null (Get-ExactProperty ([AppContext]) 'BaseDirectory'))))),
                (New-ClrAssign $appDirVar (New-StaticCall $combine @($filesVar, (New-ClrConstant 'app-scripts' ([string]))))),
                (New-ClrAssign $userDirVar (New-StaticCall $combine @($filesVar, (New-ClrConstant 'scripts' ([string]))))),
                (New-ClrAssign $markerVar (New-StaticCall $combine @($appDirVar, (New-ClrConstant '.assets' ([string]))))),
                [Linq.Expressions.Expression]::IfThen(
                    [Linq.Expressions.Expression]::Not([Linq.Expressions.Expression]::AndAlso(
                        (New-StaticCall (Get-ExactMethod ([IO.File]) 'Exists' @([string])) @($markerVar)),
                        (New-StaticCall (Get-ExactMethod ([string]) 'Equals' @([string], [string])) @(
                            (New-StaticCall (Get-ExactMethod ([IO.File]) 'ReadAllText' @([string])) @($markerVar)),
                            (New-ClrConstant $assets.Sha256 ([string])))))),
                    (New-ClrBlock @() @(
                        [Linq.Expressions.Expression]::IfThen(
                            (New-StaticCall (Get-ExactMethod ([IO.Directory]) 'Exists' @([string])) @($appDirVar)),
                            (New-StaticCall (Get-ExactMethod ([IO.Directory]) 'Delete' @([string], [bool])) @($appDirVar, (New-ClrConstant $true ([bool]))))),
                        (New-StaticCall $createDir @($appDirVar)),
                        (& $log $infoPriority (New-StaticCall $concat @((New-ClrConstant 'CONSOLEHOST copied script assets: ' ([string])),
                            (New-ClrCall (New-StaticCall $extract @(
                                (New-StaticCall (Get-ExactMethod ([Runtime.InteropServices.Marshal]) 'ReadIntPtr' @([IntPtr], [int])) @($nativeActivity, (New-ClrConstant $assetManagerOffset ([int])))),
                                $appDirVar)) (Get-ExactMethod ([int]) 'ToString' @()))))),
                        (New-StaticCall (Get-ExactMethod ([IO.File]) 'WriteAllText' @([string], [string])) @($markerVar, (New-ClrConstant $assets.Sha256 ([string]))))))),
                (New-StaticCall $createDir @($userDirVar)),
                (New-StaticCall $setEnv @((New-ClrConstant 'PWSH_APP_SCRIPTS' ([string])), $appDirVar)),
                (New-StaticCall $setEnv @((New-ClrConstant 'PWSH_USER_SCRIPTS' ([string])), $userDirVar)),
                (New-StaticCall $setEnv @((New-ClrConstant 'PATH' ([string])), (New-StaticCall (Get-ExactMethod ([string]) 'Concat' @([string[]])) @(
                    [Linq.Expressions.Expression]::NewArrayInit([string], [Linq.Expressions.Expression[]]@(
                        $userDirVar, (New-ClrConstant ':' ([string])), $appDirVar, (New-ClrConstant ':' ([string])),
                        [Linq.Expressions.Expression]::Coalesce(
                            (New-StaticCall (Get-ExactMethod ([Environment]) 'GetEnvironmentVariable' @([string])) @((New-ClrConstant 'PATH' ([string])))),
                            (New-ClrConstant '' ([string]))))))))),
                (New-ClrAssign $profileVar (New-StaticCall $combine @($appDirVar, (New-ClrConstant 'Start-Console.ps1' ([string]))))),
                (New-ClrAssign $startCommand (New-ClrCall (New-ClrProperty $sessionState (Get-ExactProperty ([Management.Automation.Runspaces.SessionStateProxy]) 'InvokeCommand')) `
                    (Get-ExactMethod ([Management.Automation.CommandInvocationIntrinsics]) 'GetCommand' @([string], [Management.Automation.CommandTypes])) @(
                        $profileVar, (New-ClrConstant ([Management.Automation.CommandTypes]::ExternalScript) ([Management.Automation.CommandTypes]))))),
                (New-ClrAssign $profileShell (New-StaticCall (Get-ExactMethod ([powershell]) 'Create' @($runspaceType)) @($runspaceVar))),
                (New-ClrCall $profileShell (Get-ExactMethod ([powershell]) 'AddCommand' @([Management.Automation.CommandInfo])) @($startCommand)),
                (& $mark 'CONSOLEHOST START_INVOKE_BEGIN'),
                (New-ClrCall $profileShell $invoke[0]),
                (& $mark 'CONSOLEHOST START_INVOKE_END'),
                [Linq.Expressions.Expression]::IfThen(
                    (New-ClrProperty $profileShell (Get-ExactProperty ([powershell]) 'HadErrors')),
                    [Linq.Expressions.Expression]::Throw((New-ClrNew ([InvalidOperationException].GetConstructor([type[]]@([string]))) @(
                        [Linq.Expressions.Expression]::Condition(
                            [Linq.Expressions.Expression]::GreaterThan((New-ClrProperty $profileErrors (Get-ExactProperty $errorCollection 'Count')), (New-ClrConstant 0 ([int]))),
                            (New-ClrCall $firstError (Get-ExactMethod ([Management.Automation.ErrorRecord]) 'ToString' @())),
                            (New-ClrConstant 'Start-Console.ps1 reported one or more PowerShell errors.' ([string]))))))))
        }
        # CreateDefault2 imports only Microsoft.PowerShell.Core. The three
        # command assemblies are admitted by the store, loaded by identity
        # through the external probe, and imported from Assembly objects so
        # no filesystem path or package extraction is involved.
        $assemblyNameCtor = [Reflection.AssemblyName].GetConstructor([type[]]@([string]))
        $assemblyLoad = Get-ExactMethod ([Reflection.Assembly]) 'Load' @([Reflection.AssemblyName]) ([Reflection.BindingFlags]'Public,Static')
        $commandAssemblies = [Linq.Expressions.Expression]::NewArrayInit(
            [Reflection.Assembly],
            [Linq.Expressions.Expression[]]@(
                (New-StaticCall $assemblyLoad @((New-ClrNew $assemblyNameCtor @((New-ClrConstant 'Microsoft.PowerShell.Commands.Management' ([string])))))),
                (New-StaticCall $assemblyLoad @((New-ClrNew $assemblyNameCtor @((New-ClrConstant 'Microsoft.PowerShell.Commands.Utility' ([string])))))),
                (New-StaticCall $assemblyLoad @((New-ClrNew $assemblyNameCtor @((New-ClrConstant 'Microsoft.PowerShell.Security' ([string]))))))))
        $importExpressions = @(
            (& $mark 'COMMANDS import begin'),
            (New-ClrAssign $moduleShell (New-StaticCall (Get-ExactMethod ([powershell]) 'Create' @($runspaceType)) @($runspaceVar))),
            (New-ClrCall $moduleShell (Get-ExactMethod ([powershell]) 'AddCommand' @([string])) @((New-ClrConstant 'Import-Module' ([string])))),
            (New-ClrCall $moduleShell (Get-ExactMethod ([powershell]) 'AddParameter' @([string], [object])) @(
                (New-ClrConstant 'Assembly' ([string])), [Linq.Expressions.Expression]::Convert($commandAssemblies, [object]))),
            (New-ClrCall $moduleShell $invoke[0]),
            [Linq.Expressions.Expression]::IfThen(
                (New-ClrProperty $moduleShell (Get-ExactProperty ([powershell]) 'HadErrors')),
                [Linq.Expressions.Expression]::Throw((New-ClrNew ([InvalidOperationException].GetConstructor([type[]]@([string]))) @(
                    [Linq.Expressions.Expression]::Condition(
                        [Linq.Expressions.Expression]::GreaterThan((New-ClrProperty $moduleErrors (Get-ExactProperty $errorCollection 'Count')), (New-ClrConstant 0 ([int]))),
                        (New-ClrCall $firstModuleError (Get-ExactMethod ([Management.Automation.ErrorRecord]) 'ToString' @())),
                        (New-ClrConstant 'One or more command assemblies failed to import.' ([string]))))))),
            (& $mark 'COMMANDS import complete'))
        $commandLookup = New-ClrProperty $sessionState (Get-ExactProperty ([Management.Automation.Runspaces.SessionStateProxy]) 'InvokeCommand')
        foreach ($commandName in 'Get-ChildItem', 'ConvertTo-Json', 'ConvertFrom-SecureString') {
            $importExpressions += [Linq.Expressions.Expression]::IfThen(
                [Linq.Expressions.Expression]::Equal(
                    (New-ClrCall $commandLookup (Get-ExactMethod ([Management.Automation.CommandInvocationIntrinsics]) 'GetCommand' @([string], [Management.Automation.CommandTypes])) @(
                        (New-ClrConstant $commandName ([string])),
                        (New-ClrConstant ([Management.Automation.CommandTypes]::Cmdlet) ([Management.Automation.CommandTypes])))),
                    [Linq.Expressions.Expression]::Constant($null, [Management.Automation.CommandInfo])),
                [Linq.Expressions.Expression]::Throw((New-ClrNew ([InvalidOperationException].GetConstructor([type[]]@([string]))) @(
                    (New-ClrConstant "Command assembly admission did not register '$commandName'." ([string]))))))
        }
        $importExpressions += (& $mark 'COMMANDS verified')
        $importCommands = New-ClrBlock @() $importExpressions
        $try = New-ClrBlock @() @(
            [Linq.Expressions.Expression]::IfThen(
                [Linq.Expressions.Expression]::Equal($nativeActivity, [Linq.Expressions.Expression]::Default([IntPtr])),
                [Linq.Expressions.Expression]::Throw((New-ClrNew ([ArgumentNullException].GetConstructor([type[]]@([string]))) @(
                    (New-ClrConstant 'nativeActivity' ([string])))))),
            (New-StaticCall ([Management.Automation.PowerShellAssemblyLoadContextInitializer].GetMethod(
                'SetPowerShellAssemblyLoadContext', [Reflection.BindingFlags]'Public,Static', $null, [type[]]@([string]), $null)) @(
                (New-ClrProperty $null (Get-ExactProperty ([AppContext]) 'BaseDirectory')))),
            (& $mark 'GATE2B managed resolution complete'),
            (& $mark 'GATE2C CreateDefault2'),
            (New-ClrAssign $issVar (New-StaticCall (Get-ExactMethod ([Management.Automation.Runspaces.InitialSessionState]) 'CreateDefault2' @()))),
            (New-ClrAssign (New-ClrProperty $issVar (Get-ExactProperty ([Management.Automation.Runspaces.InitialSessionState]) 'LanguageMode')) `
                (New-ClrConstant ([Management.Automation.PSLanguageMode]::FullLanguage) ([Management.Automation.PSLanguageMode]))),
            (& $mark 'GATE2C CreateRunspace'),
            (New-ClrAssign $runspaceVar (New-StaticCall (Get-ExactMethod $rs 'CreateRunspace' @([Management.Automation.Runspaces.InitialSessionState])) @($issVar))),
            (New-ClrAssign (New-ClrProperty $runspaceVar (Get-ExactProperty $runspaceType 'ThreadOptions')) `
                (New-ClrConstant ([Management.Automation.Runspaces.PSThreadOptions]::UseCurrentThread) ([Management.Automation.Runspaces.PSThreadOptions]))),
            (& $mark 'GATE2C Open'),
            (New-ClrCall $runspaceVar (Get-ExactMethod $runspaceType 'Open' @())),
            (New-ClrAssign (New-ClrProperty $null (Get-ExactProperty $runspaceType 'DefaultRunspace')) $runspaceVar),
            (& $mark 'GATE2C DefaultRunspace set'),
            $importCommands,
            # Gate 2e admission prerequisite. The facade may read env/vm/
            # clazz from this borrowed pointer on the owning main thread.
            # Revocation at onDestroy belongs to the lifecycle gate.
            (New-ClrCall $sessionState (Get-ExactMethod ([Management.Automation.Runspaces.SessionStateProxy]) 'SetVariable' @([string], [object])) @(
                (New-ClrConstant 'NativeActivityHandle' ([string])), [Linq.Expressions.Expression]::Convert($nativeActivity, [object]))),
            (New-ClrAssign $shellVar (New-StaticCall (Get-ExactMethod ([powershell]) 'Create' @($runspaceType)) @($runspaceVar))),
            (New-ClrCall $shellVar (Get-ExactMethod ([powershell]) 'AddScript' @([string])) @((New-ClrConstant '0x50575348' ([string])))),
            (New-ClrAssign $resultVar $firstValue),
            (& $log $infoPriority (New-StaticCall (Get-ExactMethod ([string]) 'Concat' @([string], [string])) @(
                (New-ClrConstant 'GATE2C script result 0x' ([string])),
                (New-ClrCall $resultVar (Get-ExactMethod ([int]) 'ToString' @([string])) @((New-ClrConstant 'x8' ([string]))))))),
            $startPhase,
            $resultVar)
        # Run holds every SMA reference. Admit references none, so a load or
        # JIT failure of Run surfaces as an exception inside Admit's try.
        $run = Add-PersistedMethod $nativeHostType 'Run' ([Reflection.MethodAttributes]'Private,Static,HideBySig') ([int]) @([IntPtr]) `
            ([Func[IntPtr,int]]) @($nativeActivity) (New-ClrBlock (@($issVar, $runspaceVar, $shellVar, $resultVar, $filesVar, $profileVar, $moduleShell, $profileShell, $stateShell, $startCommand) +
                $(if ($Startup -eq 'ConsoleHost') { @($appDirVar, $userDirVar, $markerVar) } else { @() })) @($try))
        # RunPowerShell returns the HResult of any exception, and the native
        # host logs it. The handler first logs the exception's type and
        # message (not ToString, which pulls in stack-trace machinery), inside
        # its own try, so the HResult comes back even if that logging fails.
        $describe = New-StaticCall (Get-ExactMethod ([string]) 'Concat' @([string], [string], [string], [string])) @(
            (New-ClrConstant 'GATE2B exception ' ([string])),
            (New-ClrProperty (New-ClrCall $errorVar (Get-ExactMethod ([object]) 'GetType' @())) (Get-ExactProperty ([type]) 'FullName')),
            (New-ClrConstant ': ' ([string])),
            (New-ClrProperty $errorVar (Get-ExactProperty ([Exception]) 'Message')))
        $catch = [Linq.Expressions.Expression]::Catch($errorVar, (New-ClrBlock @() @(
            [Linq.Expressions.Expression]::TryCatch(
                (New-ClrBlock @() @((& $log $errorPriority $describe), [Linq.Expressions.Expression]::Empty())),
                [Linq.Expressions.Expression]::Catch([Exception], [Linq.Expressions.Expression]::Empty())),
            (New-ClrProperty $errorVar (Get-ExactProperty ([Exception]) 'HResult')))))
        [void](Add-PersistedMethod $nativeHostType 'RunPowerShell' ([Reflection.MethodAttributes]'Public,Static,HideBySig') ([int]) @([IntPtr]) `
            ([Func[IntPtr,int]]) @($nativeActivity) ([Linq.Expressions.Expression]::TryCatch((New-ClrBlock @() @(
                # Set this before the separate Run method can JIT/load SMA.
                # lib/Telemetry.cs: its static constructor returns before
                # creating an Application Insights client when opted out.
                (New-StaticCall (Get-ExactMethod ([Environment]) 'SetEnvironmentVariable' @([string], [string])) @(
                    (New-ClrConstant 'POWERSHELL_TELEMETRY_OPTOUT' ([string])),
                    (New-ClrConstant '1' ([string])))),
                (New-StaticCall $run @($nativeActivity)))), $catch)))
        # Gate 2a, kept as an in-process invariant: the host calls it first
        # and requires 'PWSH' (0x50575348) before it calls RunPowerShell.
        [void](Add-PersistedMethod $nativeHostType 'Admit' ([Reflection.MethodAttributes]'Public,Static,HideBySig') ([int]) @() `
            ([Func[int]]) @() ([Linq.Expressions.Expression]::Constant([int]0x50575348, [int])))
        $nativeHostType.CreateType() | Out-Null

    $stream = [IO.MemoryStream]::new()
    try {
        $builder.Save($stream)
        return ,(Set-DeterministicMvid -Assembly $stream.ToArray())
    }
    finally { $stream.Dispose() }
}

function Add-GeneratedAssemblyCandidates {
    $generated = [ordered]@{
        "$($script:ManagedNamespace).dll" = New-ManagedHostAssemblyBytes
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
    if ($Payload -ne 'Minimal') {
        throw "Payload '$Payload' is not built yet. Only Minimal is."
    }
    $manifest = Get-MinimalAssemblyManifest
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
        throw "Minimal assembly selection produced $($selected.Count) entries; the pinned list names $($manifest.Count)."
    }

    # Every ReadyToRun image is re-emitted IL-only: its IL, field data, metadata
    # and resources are kept and its native code is dropped. The PE headers
    # follow the runtime pack's own IL-only images; the first by package path
    # is the template.
    $template = @($script:BuildContext.PayloadCandidates |
        Where-Object { -not $_.ReferenceOnly -and -not $_.IsReadyToRun -and $_.PackageId -like 'Microsoft.NETCore.App.Runtime.*' } |
        Sort-Object -Property PackagePath -CaseSensitive)[0]
    if ($null -eq $template) { throw 'The runtime pack supplies no IL-only image to use as a PE header template.' }
    $converted = 0
    foreach ($name in @($selected.Keys)) {
        $candidate = $selected[$name]
        if (-not $candidate.IsReadyToRun) { continue }
        $bytes = ConvertTo-IlOnlyImage -Image ([byte[]]$candidate.Bytes) -Template ([byte[]]$template.Bytes)
        if (Test-ReadyToRunImage -ImageBytes $bytes) { throw "$name still carries a ReadyToRun header after conversion." }
        $copy = $candidate.PSObject.Copy()
        $copy.Bytes = $bytes
        $copy.IsReadyToRun = $false
        $selected[$name] = $copy
        $converted++
    }

    $script:BuildContext.SelectedAssemblies = $selected
    Write-Host "[PASS] Step 4 complete: $($selected.Count) ordered runtime assemblies selected in memory; $converted ReadyToRun images re-emitted IL-only; reference-only images and Probe.r2r.dll rejected." -ForegroundColor Green
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
        [Parameter(Mandatory)][pscustomobject] $Contract,
        # Each image starts at a multiple of this, zero-padded. 1 reproduces
        # the upstream layout (images end to end).
        [ValidateSet(1, 16)][int] $DataAlignment = 1
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

    # Descriptors, in the same order as the minimal assembly manifest. The index is
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
        $cursor = [uint32](($cursor + $DataAlignment - 1) -band -bnot ($DataAlignment - 1))

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

        # ASSEMBLY DATA, each image at its descriptor's offset; the gap before
        # it is zero padding.
        for ($i = 0; $i -lt $payloads.Count; $i++) {
            $writer.Flush()
            $gap = [long]$descriptors[$i].DataOffset - $stream.Position
            if ($gap -lt 0 -or $gap -ge $DataAlignment) { throw "Assembly $i would start at $($stream.Position); its descriptor declares $($descriptors[$i].DataOffset)." }
            if ($gap -gt 0) { Write-ByteSpan -Writer $writer -Bytes ([byte[]]::new($gap)) }
            Write-ByteSpan -Writer $writer -Bytes $payloads[$i]
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
        [Parameter(Mandatory)][pscustomobject] $Contract,
        [ValidateSet(1, 16)][int] $DataAlignment = 1
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

    # Layout, read from the descriptors alone: each image starts on the
    # alignment with a PE 'MZ' signature, images do not overlap, every gap is
    # zero padding shorter than the alignment, and the last image ends the store.
    $layout = @(for ($i = 0; $i -lt $entryCount; $i++) {
        $descriptorOffset = $descriptorStart + ($i * $descriptorSize)
        [pscustomobject]@{ Index = $i; Offset = [long][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 4); Size = [long][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 8) }
    }) | Sort-Object Offset
    $previousEnd = [long]$cursor
    foreach ($region in $layout) {
        if ($region.Offset % $DataAlignment) { throw "Assembly '$($names[$region.Index])' starts at $($region.Offset), not a multiple of $DataAlignment." }
        if ($region.Offset -lt $previousEnd) { throw "Assembly '$($names[$region.Index])' at $($region.Offset) overlaps the bytes before it, which end at $previousEnd." }
        if ($region.Offset - $previousEnd -ge $DataAlignment) { throw "Assembly '$($names[$region.Index])' is preceded by $($region.Offset - $previousEnd) bytes of padding." }
        for ($k = $previousEnd; $k -lt $region.Offset; $k++) { if ($StoreBytes[$k] -ne 0) { throw "Padding byte $k before '$($names[$region.Index])' is not zero." } }
        if ($StoreBytes[$region.Offset] -ne 0x4D -or $StoreBytes[$region.Offset + 1] -ne 0x5A) { throw "Assembly '$($names[$region.Index])' does not start with a PE signature." }
        $previousEnd = $region.Offset + $region.Size
    }
    if ($previousEnd -ne $StoreBytes.Length) { throw "The last assembly ends at $previousEnd; the store is $($StoreBytes.Length) bytes." }

    $entries = for ($i = 0; $i -lt $entryCount; $i++) {
        $descriptorOffset = $descriptorStart + ($i * $descriptorSize)
        [pscustomobject]@{
            Name   = $names[$i]
            Offset = [long][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 4)
            Size   = [long][BitConverter]::ToUInt32($StoreBytes, $descriptorOffset + 8)
        }
    }

    return [pscustomobject]@{
        EntryCount      = $entryCount
        IndexEntryCount = $indexEntryCount
        MetadataSize    = $cursor
        TotalSize       = $StoreBytes.Length
        Entries         = @($entries)
    }
}

function Test-StoreImageAlignment {
    # Reads the final store library the way the loader maps it and CoreCLR
    # decodes it: the payload symbol's address plus each entry's offset is the
    # image's address, up to the page-aligned load bias. Every image must start
    # 16-byte aligned, and every fat method header (ECMA-335 II.25.4.3) inside
    # it must land 4-byte aligned, the condition corhlpr.cpp DecoderInit checks.
    param(
        [Parameter(Mandatory)][byte[]] $LibraryBytes,
        [Parameter(Mandatory)][string] $SymbolName,
        [Parameter(Mandatory)][object[]] $Entries
    )
    $elf = Read-ElfImage -Image $LibraryBytes
    $store = @($elf.Symbols | Where-Object { $_.Name -ceq $SymbolName })
    if ($store.Count -ne 1) { throw "The store library defines '$SymbolName' $($store.Count) times." }
    $segment = @($elf.Segments | Where-Object { $_.Type -eq 1 -and $store[0].Value -ge $_.Address -and $store[0].Value -lt $_.Address + $_.FileSize })
    if ($segment.Count -ne 1) { throw "'$SymbolName' lies in $($segment.Count) loadable segments." }
    $fat = 0; $tiny = 0
    foreach ($entry in $Entries) {
        $address = [long]$store[0].Value + $entry.Offset
        $fileOffset = [long]$segment[0].Offset + ($address - $segment[0].Address)
        if ($address % 16) { throw "'$($entry.Name)' is mapped at library address 0x$('{0:X}' -f $address), not 16-byte aligned." }
        $pe = [System.Reflection.PortableExecutable.PEReader]::new([System.IO.MemoryStream]::new($LibraryBytes, [int]$fileOffset, [int]$entry.Size, $false))
        try {
            $metadata = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
            $sections = $pe.PEHeaders.SectionHeaders
            foreach ($handle in $metadata.MethodDefinitions) {
                $rva = $metadata.GetMethodDefinition($handle).RelativeVirtualAddress
                if ($rva -eq 0) { continue }
                $section = $pe.PEHeaders.GetContainingSectionIndex($rva)
                if ($section -lt 0) { throw "'$($entry.Name)' has a method body at RVA 0x$('{0:X}' -f $rva) outside every section." }
                $inImage = [long]$rva - $sections[$section].VirtualAddress + $sections[$section].PointerToRawData
                $flags = $LibraryBytes[$fileOffset + $inImage] -band 3
                if ($flags -eq 2) { $tiny++; continue }
                if ($flags -ne 3) { throw "'$($entry.Name)' has a method header at RVA 0x$('{0:X}' -f $rva) that is neither tiny nor fat." }
                if (($address + $inImage) % 4) { throw "'$($entry.Name)' has a fat method header at RVA 0x$('{0:X}' -f $rva) mapped at 0x$('{0:X}' -f ($address + $inImage)), not 4-byte aligned." }
                $fat++
            }
        }
        finally { $pe.Dispose() }
    }
    [pscustomobject]@{ Images = $Entries.Count; FatMethods = $fat; TinyMethods = $tiny }
}

function Invoke-StoreStep {

    $contract = Get-AndroidNativeContract
    $selected = $script:BuildContext.SelectedAssemblies
    # The store carries IL only: no image may keep a ReadyToRun header, and each
    # must declare itself IL-only (pedecoder.cpp CheckILOnly, runtime ab194157).
    foreach ($name in $selected.Keys) {
        $bytes = [byte[]]$selected[$name].Bytes
        if (Test-ReadyToRunImage -ImageBytes $bytes) { throw "Store image $name carries a ReadyToRun header." }
        $reader = [System.Reflection.PortableExecutable.PEReader]::new([System.IO.MemoryStream]::new($bytes, $false))
        try {
            if (($reader.PEHeaders.CorHeader.Flags -band [System.Reflection.PortableExecutable.CorFlags]::ILOnly) -eq 0) { throw "Store image $name is not flagged IL-only." }
        } finally { $reader.Dispose() }
    }
    # NativeActivity serves images to CoreCLR in place, without the copy the
    # .NET for Android host makes (lib/assembly-store.cc), so this layout owns
    # their alignment: every image starts on a 16-byte boundary. CoreCLR needs
    # a fat method header 4-byte aligned on 64-bit hosts (corhlpr.cpp
    # DecoderInit); 16 is the store's own invariant, above that.
    $alignment = 16
    $storeBytes = New-AssemblyStoreBytes -SelectedAssemblies $selected -Contract $contract -DataAlignment $alignment
    $report = Test-AssemblyStoreBytes -StoreBytes $storeBytes -SelectedAssemblies $selected -Contract $contract -DataAlignment $alignment

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
        Path    = $storePath
        Bytes   = $storeBytes
        Sha256  = $storeHash
        Entries = $report.Entries
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
        # Process-lifetime writable data after the GOT. Each entry is a byte
        # array, or @{ Bytes; Pointers = @(@{ At; Target }) } whose pointer-sized
        # slots at At receive the address of Target (a Data, WritableData or
        # function label) through the target's RELATIVE relocation.
        [System.Collections.IDictionary] $WritableData = @{},
        [int] $PageSize = 16384,
        # The instruction set of Functions; the target's own when empty.
        [string] $InstructionSet = ''
    )

    $elf = Get-ElfConstants
    $L = Get-ElfLayout -Class $script:Target.ElfClass
    $w = $L.Word
    $isa = if ($InstructionSet) { Get-InstructionSet -Isa $InstructionSet } else { Get-InstructionSet }
    $form = $script:Target.RelocationForm
    $relocationEntry = Get-ElfRelocationEntrySize -Layout $L -Form $form
    $relocationTags = Get-ElfRelocationTags -Form $form

    # Imports, in first-use order.
    $imports = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Functions.PSBase.Keys) {
        foreach ($step in $Functions[$name]) {
            if ($step['Import'] -and -not $imports.Contains($step['Import'])) { $imports.Add($step['Import']) }
        }
    }
    $exports = @($Functions.PSBase.Keys)
    $symbols = @($imports) + $exports

    $strings = New-ElfStringTable -Strings (@($Soname) + @($Needed) + $symbols)
    $hashBytes = Get-ElfHashTableBytes -Symbols $symbols

    $programHeaderCount = 6
    $dynstrOffset = $L.Header + $L.ProgramHeader * $programHeaderCount
    $dynsymOffset = Get-AlignedOffset ($dynstrOffset + $strings.Bytes.Length) $w
    $dynsymSize = $L.Symbol * ($symbols.Count + 1)
    $hashOffset = Get-AlignedOffset ($dynsymOffset + $dynsymSize) $w
    $pointerCount = 0
    # PSBase.Keys: a dictionary's .Keys would return an entry named 'keys'.
    foreach ($label in $WritableData.PSBase.Keys) { if ($WritableData[$label] -is [System.Collections.IDictionary]) { $pointerCount += @($WritableData[$label].Pointers).Count } }
    $relocationOffset = Get-AlignedOffset ($hashOffset + $hashBytes.Length) $w
    $relocationSize = $relocationEntry * ($imports.Count + $pointerCount)
    $dynamicOffset = Get-AlignedOffset ($relocationOffset + $relocationSize) $w
    $dynamicSize = $L.Dynamic * (11 + $Needed.Count)
    $metaEnd = $dynamicOffset + $dynamicSize

    $textOffset = Get-AlignedOffset $metaEnd $PageSize
    $functionOffset = [ordered]@{}
    $functionSize = @{}
    $cursor = $textOffset
    $labels = @{}
    foreach ($name in $exports) {
        $functionOffset[$name] = $cursor
        $labels[$name] = @{}
        $size = 0
        foreach ($step in $Functions[$name]) {
            if ($step.Op -eq 'label') {
                if ($labels[$name].ContainsKey($step.Name)) { throw "$name defines label '$($step.Name)' twice." }
                $labels[$name][$step.Name] = $cursor + $size
            }
            $size += & $isa.Length -Step $step
        }
        $functionSize[$name] = $size
        $cursor += $size
    }
    $dataOffset = [ordered]@{}
    foreach ($label in $Data.PSBase.Keys) {
        $dataOffset[$label] = $cursor
        $cursor += $Data[$label].Length
    }
    $textEnd = $cursor
    $gotOffset = Get-AlignedOffset $textEnd $PageSize
    $gotSize = $w * [Math]::Max(1, $imports.Count)
    $writableOffset = [ordered]@{}
    $writableEnd = $gotOffset + $gotSize
    foreach ($label in $WritableData.PSBase.Keys) {
        $entry = $WritableData[$label]
        [byte[]] $bytes = if ($entry -is [System.Collections.IDictionary]) { $entry.Bytes } else { $entry }
        $writableEnd = Get-AlignedOffset $writableEnd 16
        $writableOffset[$label] = $writableEnd
        $writableEnd += $bytes.Length
    }
    $rwSize = $writableEnd - $gotOffset
    $imageSize = $writableEnd

    # Addresses by label: read-only data, writable data, and exported functions.
    $address = @{}
    foreach ($label in $dataOffset.PSBase.Keys) { $address[$label] = $dataOffset[$label] }
    foreach ($label in $writableOffset.PSBase.Keys) {
        if ($address.ContainsKey($label)) { throw "Data label '$label' is defined twice." }
        $address[$label] = $writableOffset[$label]
    }
    foreach ($name in $exports) { if (-not $address.ContainsKey($name)) { $address[$name] = $functionOffset[$name] } }

    $image = New-Object byte[] $imageSize
    Write-ElfHeader $image $L $programHeaderCount
    $ph = $L.Header
    foreach ($s in @(
            @($elf['PT_PHDR'], $elf['PF_R'], $L.Header, ($L.ProgramHeader * $programHeaderCount), $w),
            @($elf['PT_LOAD'], $elf['PF_R'], 0, $metaEnd, $PageSize),
            @($elf['PT_LOAD'], ($elf['PF_R'] -bor $elf['PF_X']), $textOffset, ($textEnd - $textOffset), $PageSize),
            @($elf['PT_LOAD'], ($elf['PF_R'] -bor $elf['PF_W']), $gotOffset, $rwSize, $PageSize),
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
        Write-ElfSymbol $image $L ($dynsymOffset + $L.Symbol * $index) $strings.Offset[$name] ($functionOffset[$name] + $isa.StateBit) $functionSize[$name] $functionInfo 1
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

    # Writable data, then its pointer slots. REL writes each addend into the
    # slot, so the data is copied first.
    $relocationIndex = $imports.Count
    foreach ($label in $WritableData.PSBase.Keys) {
        $entry = $WritableData[$label]
        [byte[]] $writableBytes = if ($entry -is [System.Collections.IDictionary]) { $entry.Bytes } else { $entry }
        [System.Array]::Copy($writableBytes, 0, $image, $writableOffset[$label], $writableBytes.Length)
        if ($entry -is [System.Collections.IDictionary]) {
            foreach ($pointer in @($entry.Pointers)) {
                if (-not $address.ContainsKey($pointer.Target)) { throw "Writable '$label' points at undefined label '$($pointer.Target)'." }
                if ($pointer.At + $w -gt $writableBytes.Length) { throw "Writable '$label' has a pointer slot past its end." }
                # A symbol-less RELATIVE relocation carries the whole value, so a
                # pointer to a function carries its instruction set's state bit.
                $value = $address[$pointer.Target] + $(if ($Functions.Contains($pointer.Target)) { $isa.StateBit } else { 0 })
                Write-ElfRelocation $image $L ($relocationOffset + $relocationEntry * $relocationIndex) $form ($writableOffset[$label] + $pointer.At) 0 $elf[$script:Target.RelativeRelocation] $value
                $relocationIndex++
            }
        }
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
            $target = if ($step['Import']) { $gotSlot[$step['Import']] }
                elseif ($step['Data']) {
                    if (-not $address.ContainsKey($step['Data'])) { throw "$name refers to undefined data '$($step['Data'])'." }
                    $address[$step['Data']]
                }
                elseif ($step['Label']) {
                    if (-not $labels[$name].ContainsKey($step['Label'])) { throw "$name branches to undefined label '$($step['Label'])'." }
                    $labels[$name][$step['Label']]
                }
                else { 0 }
            $bytes = [byte[]]@(& $isa.Encode -Step $step -Pc $pc -Target $target)
            if ($bytes.Length -ne $length) { throw "$($isa.Name) step '$($step.Op)' encoded to $($bytes.Length) bytes, expected $length." }
            [System.Array]::Copy($bytes, 0, $image, $pc, $length)
            $pc += $length
        }
    }
    foreach ($label in $Data.PSBase.Keys) {
        [System.Array]::Copy([byte[]]$Data[$label], 0, $image, $dataOffset[$label], $Data[$label].Length)
    }

    $image = Add-ElfSectionTable -Image $image -Layout $L -DynstrOffset $dynstrOffset -DynstrSize $strings.Bytes.Length -DynamicOffset $dynamicOffset -DynamicSize $dynamicSize

    [pscustomobject]@{
        Bytes     = $image
        Soname    = $Soname
        Exports   = $functionOffset
        Imports   = @($imports)
        GotSlots  = $gotSlot
        DataAt    = $address
        Labels    = $labels
        Functions = $Functions
        Isa       = $isa.Id
        StateBit  = $isa.StateBit
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
    $isa = Get-InstructionSet -Isa $Library.Isa

    $executable = @($image.Segments | Where-Object { $_.Type -eq $elf['PT_LOAD'] -and ($_.Flags -band $elf['PF_X']) })
    if ($executable.Count -ne 1) { throw "$($Library.Soname) must have exactly one executable segment." }
    if ($executable[0].Align -lt 16384) { throw "$($Library.Soname) is not 16 KB aligned." }
    if (-not ($image.Tags[[uint64]$elf['DT_FLAGS']] -band $elf['DF_BIND_NOW'])) { throw 'DT_FLAGS lacks BIND_NOW.' }
    if ($image.RelocationForm -ne $script:Target.RelocationForm) { throw "$($Library.Soname) uses $($image.RelocationForm); the target uses $($script:Target.RelocationForm)." }
    $tags = Get-ElfRelocationTags -Form $image.RelocationForm
    if ($image.Tags[[uint64]$tags.Entry] -ne (Get-ElfRelocationEntrySize -Layout $image.Layout -Form $image.RelocationForm)) { throw 'The relocation entry size is wrong.' }

    $slotImport = @{}
    foreach ($relocation in $image.Relocations) {
        if ($relocation.Type -eq $elf[$script:Target.RelativeRelocation]) {
            if ($relocation.Symbol -ne 0 -or $relocation.Addend -lt 0 -or $relocation.Addend -ge $bytes.Length) { throw "RELATIVE relocation at $($relocation.Offset) does not address the image." }
            continue
        }
        if ($relocation.Type -ne $elf[$script:Target.GotRelocation]) { throw "Relocation at $($relocation.Offset) is neither $($script:Target.GotRelocation) nor $($script:Target.RelativeRelocation)." }
        if ($relocation.Addend -ne 0) { throw "GOT slot $($relocation.Offset) carries a nonzero addend." }
        $slotImport[[long]$relocation.Offset] = $relocation.SymbolName
    }

    $steps = 0
    foreach ($name in $Library.Exports.PSBase.Keys) {
        $symbol = $image.Resolved[$name]
        if (-not $symbol -or $symbol.Section -eq 0) { throw "Export '$name' does not resolve." }
        if ($symbol.Value -ne $Library.Exports[$name] + $isa.StateBit) { throw "Export '$name' resolves to $($symbol.Value), expected $($Library.Exports[$name] + $isa.StateBit)." }
        $pc = [long]$symbol.Value - $isa.StateBit
        if ($pc % $isa.Alignment) { throw "Export '$name' is not aligned to a $($isa.Name) instruction." }
        foreach ($step in $Library.Functions[$name]) {
            $pc += & $isa.Verify -Image $bytes -Pc $pc -Step $step -DataAt $Library.DataAt -SlotImport $slotImport -Labels $Library.Labels[$name] -Name $name
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

# ==============================================================================
# Thumb-2 (T32) machine code
#
# The arm32 NativeActivity host is Thumb-2, as the NDK builds the pinned .NET for
# Android arm32 host (its exported functions carry the Thumb bit). Only the
# forms that host needs. A 32-bit instruction is two little-endian halfwords,
# first halfword first. Field layouts follow the Arm A-profile architecture
# reference (T32 encodings); LLVM 23.1.1's integrated assembler is the
# out-of-tree cross-check. libpsl-native stays A32; calls between the two
# interwork through blx and loads into pc.
#
# Calling convention: AAPCS32, soft-float (lib/ARM.cpp). Arguments r0-r3 then
# the stack at [sp], [sp, #4], ...; result r0; r4-r11 callee-saved; r12 (ip)
# free to clobber, used for calls through the GOT; lr holds the return
# address; sp 8-byte aligned at every call. Variadic calls take no extra setup.
# Code addresses carry state in bit 0 (1 = Thumb) wherever the ABI treats them
# as code pointers: exported STT_FUNC values and relocated function pointers.
# ==============================================================================

function Get-T32Halfwords {
    # MOVW/MOVT: imm16 = imm4:i:imm3:imm8.
    param([Parameter(Mandatory)][uint32] $Base, [Parameter(Mandatory)][int] $Rd, [Parameter(Mandatory)][uint32] $Imm16)
    $imm4 = ($Imm16 -shr 12) -band 0xF; $i = ($Imm16 -shr 11) -band 1; $imm3 = ($Imm16 -shr 8) -band 7; $imm8 = $Imm16 -band 0xFF
    @([uint16]($Base -bor ($i -shl 10) -bor $imm4), [uint16](($imm3 -shl 12) -bor ($Rd -shl 8) -bor $imm8))
}

function New-T32Branch {
    # B.W (T4, imm24 = S:I1:I2:imm10:imm11, J1 = NOT(I1 XOR S)) and B<c>.W (T3,
    # imm20 = S:J2:J1:imm6:imm11). Distance is from the instruction address + 4.
    param([ValidateSet('b', 'beq', 'bne', 'bhs')][string] $Op, [long] $Distance)
    if ($Distance % 2) { throw "$Op distance $Distance is odd." }
    if ($Op -eq 'b') {
        if ($Distance -lt -16777216 -or $Distance -gt 16777214) { throw "b.w distance $Distance out of range." }
        $v = [long]($Distance -band 0x1FFFFFF)
        $s = ($v -shr 24) -band 1; $i1 = ($v -shr 23) -band 1; $i2 = ($v -shr 22) -band 1
        $j1 = (-bnot ($i1 -bxor $s)) -band 1; $j2 = (-bnot ($i2 -bxor $s)) -band 1
        return @([uint16](0xF000 -bor ($s -shl 10) -bor (($v -shr 12) -band 0x3FF)), [uint16](0x9000 -bor ($j1 -shl 13) -bor ($j2 -shl 11) -bor (($v -shr 1) -band 0x7FF)))
    }
    if ($Distance -lt -1048576 -or $Distance -gt 1048574) { throw "$Op.w distance $Distance out of range." }
    $cond = switch ($Op) { 'beq' { 0 } 'bne' { 1 } 'bhs' { 2 } }
    $v = [long]($Distance -band 0x1FFFFF)
    $s = ($v -shr 20) -band 1; $j2 = ($v -shr 19) -band 1; $j1 = ($v -shr 18) -band 1
    @([uint16](0xF000 -bor ($s -shl 10) -bor ($cond -shl 6) -bor (($v -shr 12) -band 0x3F)), [uint16](0x8000 -bor ($j1 -shl 13) -bor ($j2 -shl 11) -bor (($v -shr 1) -band 0x7FF)))
}

function Get-T32RegisterList {
    param([Parameter(Mandatory)][int[]] $Registers, [Parameter(Mandatory)][int] $Extra)
    $list = 0; $flag = 0
    foreach ($r in $Registers) {
        if ($r -eq $Extra) { $flag = 1 } elseif ($r -ge 0 -and $r -le 7) { $list = $list -bor (1 -shl $r) } else { throw "r$r cannot be in a 16-bit push or pop." }
    }
    @($list, $flag)
}

function Get-T32StepLength {
    param([Parameter(Mandatory)] $Step)
    switch ($Step.Op) {
        'label' { 0 }
        { $_ -in 'push', 'pop', 'sub-sp', 'add-sp', 'mov', 'movs', 'cmp', 'cmp-imm', 'adds', 'adds-imm' } { 2 }
        { $_ -in 'movw', 'movt', 'ldr', 'str', 'b', 'beq', 'bne', 'bhs' } { 4 }
        'lea-data' { 10 }
        { $_ -in 'load-data', 'load-got' } { 14 }
        { $_ -in 'call-import', 'call-data' } { 16 }
        default { throw "Unknown T32 step '$($Step.Op)'." }
    }
}

function New-T32Step {
    # Halfwords for one step at Pc, as bytes. Target is the label address for
    # branches, the data address for data steps and the GOT slot for imports.
    # A PC-relative address is movw/movt of (Target - (add + 4)), then
    # add Rd, pc, the sequence clang emits with -mexecute-only.
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $pcRelative = {
        param([int] $Rd, [long] $At)
        $value = [uint32](($Target - ($At + 8 + 4)) -band 0xFFFFFFFFL)
        (Get-T32Halfwords 0xF240 $Rd ($value -band 0xFFFF)) + (Get-T32Halfwords 0xF2C0 $Rd ($value -shr 16)) +
            @([uint16](0x4400 -bor ((($Rd -shr 3) -band 1) -shl 7) -bor (15 -shl 3) -bor ($Rd -band 7)))
    }
    $ldrw = { param([int] $Rt, [int] $Rn, [int] $Imm) if ($Imm -lt 0 -or $Imm -gt 4095) { throw "ldr.w offset $Imm out of range." }; @([uint16](0xF8D0 -bor $Rn), [uint16](($Rt -shl 12) -bor $Imm)) }
    $low = { param([int[]] $Regs) foreach ($r in $Regs) { if ($r -lt 0 -or $r -gt 7) { throw "$($Step.Op) needs r0-r7, not r$r." } } }
    $hw = switch ($Step.Op) {
        'label'    { @() }
        'push'     { $rl = Get-T32RegisterList $Step.Registers 14; @([uint16](0xB400 -bor ($rl[1] -shl 8) -bor $rl[0])) }
        'pop'      { $rl = Get-T32RegisterList $Step.Registers 15; @([uint16](0xBC00 -bor ($rl[1] -shl 8) -bor $rl[0])) }
        { $_ -in 'sub-sp', 'add-sp' } {
            if ($Step.Imm % 4 -or $Step.Imm -lt 0 -or $Step.Imm -gt 508) { throw "$($Step.Op) #$($Step.Imm) is not a multiple of 4 in [0, 508]." }
            @([uint16]($(if ($Step.Op -eq 'sub-sp') { 0xB080 } else { 0xB000 }) -bor ($Step.Imm / 4)))
        }
        'mov'      { @([uint16](0x4600 -bor ((($Step.Rd -shr 3) -band 1) -shl 7) -bor ($Step.Rm -shl 3) -bor ($Step.Rd -band 7))) }
        'movs'     { & $low @($Step.Rd); if ($Step.Imm -lt 0 -or $Step.Imm -gt 255) { throw "movs #$($Step.Imm) out of range." }; @([uint16](0x2000 -bor ($Step.Rd -shl 8) -bor $Step.Imm)) }
        'movw'     { Get-T32Halfwords 0xF240 $Step.Rd ([uint32]$Step.Imm) }
        'movt'     { Get-T32Halfwords 0xF2C0 $Step.Rd ([uint32]$Step.Imm) }
        'cmp'      { & $low @($Step.Rn, $Step.Rm); @([uint16](0x4280 -bor ($Step.Rm -shl 3) -bor $Step.Rn)) }
        'cmp-imm'  { & $low @($Step.Rn); if ($Step.Imm -lt 0 -or $Step.Imm -gt 255) { throw "cmp #$($Step.Imm) out of range." }; @([uint16](0x2800 -bor ($Step.Rn -shl 8) -bor $Step.Imm)) }
        'adds'     { & $low @($Step.Rd, $Step.Rn, $Step.Rm); @([uint16](0x1800 -bor ($Step.Rm -shl 6) -bor ($Step.Rn -shl 3) -bor $Step.Rd)) }
        'adds-imm' { & $low @($Step.Rd); if ($Step.Imm -lt 0 -or $Step.Imm -gt 255) { throw "adds #$($Step.Imm) out of range." }; @([uint16](0x3000 -bor ($Step.Rd -shl 8) -bor $Step.Imm)) }
        'ldr'      { & $ldrw $Step.Rt $Step.Rn $Step.Offset }
        'str'      { if ($Step.Offset -lt 0 -or $Step.Offset -gt 4095) { throw "str.w offset out of range." }; @([uint16](0xF8C0 -bor $Step.Rn), [uint16](($Step.Rt -shl 12) -bor $Step.Offset)) }
        { $_ -in 'b', 'beq', 'bne', 'bhs' } { New-T32Branch -Op $Step.Op -Distance ($Target - ($Pc + 4)) }
        'lea-data' { & $pcRelative $Step.Rd $Pc }
        { $_ -in 'load-data', 'load-got' } { (& $pcRelative $Step.Rd $Pc) + (& $ldrw $Step.Rd $Step.Rd 0) }
        { $_ -in 'call-import', 'call-data' } { (& $pcRelative 12 $Pc) + (& $ldrw 12 12 0) + @([uint16](0x4780 -bor (12 -shl 3))) }
        default    { throw "Unknown T32 step '$($Step.Op)'." }
    }
    [byte[]]@($hw | ForEach-Object { [BitConverter]::GetBytes([uint16]$_) } | ForEach-Object { $_ })
}

function Read-T32Instruction {
    # Independent decode of the forms above from their fixed bits. Returns the
    # form and its operands, and Length 2 or 4.
    param([Parameter(Mandatory)][uint16] $First, [uint16] $Second = 0)
    $one = { param($o) $o | Add-Member Length 2 -PassThru }
    $two = { param($o) $o | Add-Member Length 4 -PassThru }
    if (($First -band 0xFE00) -eq 0xB400) { return & $one ([pscustomobject]@{ Op = 'push'; Registers = @(0..7 | Where-Object { $First -band (1 -shl $_) }) + @(if ($First -band 0x100) { 14 }) }) }
    if (($First -band 0xFE00) -eq 0xBC00) { return & $one ([pscustomobject]@{ Op = 'pop'; Registers = @(0..7 | Where-Object { $First -band (1 -shl $_) }) + @(if ($First -band 0x100) { 15 }) }) }
    if (($First -band 0xFF80) -eq 0xB080) { return & $one ([pscustomobject]@{ Op = 'sub-sp'; Imm = 4 * ($First -band 0x7F) }) }
    if (($First -band 0xFF80) -eq 0xB000) { return & $one ([pscustomobject]@{ Op = 'add-sp'; Imm = 4 * ($First -band 0x7F) }) }
    if (($First -band 0xFF00) -eq 0x4600) { return & $one ([pscustomobject]@{ Op = 'mov'; Rd = (($First -shr 4) -band 8) -bor ($First -band 7); Rm = ($First -shr 3) -band 0xF }) }
    if (($First -band 0xFF00) -eq 0x4400) { return & $one ([pscustomobject]@{ Op = 'add-reg'; Rd = (($First -shr 4) -band 8) -bor ($First -band 7); Rm = ($First -shr 3) -band 0xF }) }
    if (($First -band 0xFF87) -eq 0x4780) { return & $one ([pscustomobject]@{ Op = 'blx'; Rm = ($First -shr 3) -band 0xF }) }
    if (($First -band 0xFFC0) -eq 0x4280) { return & $one ([pscustomobject]@{ Op = 'cmp'; Rn = $First -band 7; Rm = ($First -shr 3) -band 7 }) }
    if (($First -band 0xF800) -eq 0x2000) { return & $one ([pscustomobject]@{ Op = 'movs'; Rd = ($First -shr 8) -band 7; Imm = $First -band 0xFF }) }
    if (($First -band 0xF800) -eq 0x2800) { return & $one ([pscustomobject]@{ Op = 'cmp-imm'; Rn = ($First -shr 8) -band 7; Imm = $First -band 0xFF }) }
    if (($First -band 0xF800) -eq 0x3000) { return & $one ([pscustomobject]@{ Op = 'adds-imm'; Rd = ($First -shr 8) -band 7; Imm = $First -band 0xFF }) }
    if (($First -band 0xFE00) -eq 0x1800) { return & $one ([pscustomobject]@{ Op = 'adds'; Rd = $First -band 7; Rn = ($First -shr 3) -band 7; Rm = ($First -shr 6) -band 7 }) }
    if (($First -band 0xFBF0) -eq 0xF240 -or ($First -band 0xFBF0) -eq 0xF2C0) {
        if ($Second -band 0x8000) { throw ('T32 0x{0:X4} {1:X4} is not MOVW/MOVT.' -f $First, $Second) }
        $imm = (($First -band 0xF) -shl 12) -bor ((($First -shr 10) -band 1) -shl 11) -bor ((($Second -shr 12) -band 7) -shl 8) -bor ($Second -band 0xFF)
        return & $two ([pscustomobject]@{ Op = $(if ($First -band 0x80) { 'movt' } else { 'movw' }); Rd = ($Second -shr 8) -band 0xF; Imm = [uint32]$imm })
    }
    if (($First -band 0xFFF0) -eq 0xF8D0) { return & $two ([pscustomobject]@{ Op = 'ldr'; Rn = $First -band 0xF; Rt = ($Second -shr 12) -band 0xF; Offset = $Second -band 0xFFF }) }
    if (($First -band 0xFFF0) -eq 0xF8C0) { return & $two ([pscustomobject]@{ Op = 'str'; Rn = $First -band 0xF; Rt = ($Second -shr 12) -band 0xF; Offset = $Second -band 0xFFF }) }
    if (($First -band 0xF800) -eq 0xF000 -and ($Second -band 0xD000) -eq 0x9000) {
        $s = ($First -shr 10) -band 1; $j1 = ($Second -shr 13) -band 1; $j2 = ($Second -shr 11) -band 1
        $i1 = (-bnot ($j1 -bxor $s)) -band 1; $i2 = (-bnot ($j2 -bxor $s)) -band 1
        $v = ($s -shl 24) -bor ($i1 -shl 23) -bor ($i2 -shl 22) -bor (($First -band 0x3FF) -shl 12) -bor (($Second -band 0x7FF) -shl 1)
        if ($s) { $v -= 0x2000000 }
        return & $two ([pscustomobject]@{ Op = 'b'; Distance = [long]$v })
    }
    if (($First -band 0xF800) -eq 0xF000 -and ($Second -band 0xD000) -eq 0x8000) {
        $cond = ($First -shr 6) -band 0xF
        $s = ($First -shr 10) -band 1; $j1 = ($Second -shr 13) -band 1; $j2 = ($Second -shr 11) -band 1
        $v = ($s -shl 20) -bor ($j2 -shl 19) -bor ($j1 -shl 18) -bor (($First -band 0x3F) -shl 12) -bor (($Second -band 0x7FF) -shl 1)
        if ($s) { $v -= 0x200000 }
        $op = switch ($cond) { 0 { 'beq' } 1 { 'bne' } 2 { 'bhs' } default { throw "T32 condition $cond is not used here." } }
        return & $two ([pscustomobject]@{ Op = $op; Distance = [long]$v })
    }
    throw ('Unrecognized T32 instruction 0x{0:X4} 0x{1:X4}.' -f $First, $Second)
}

function Test-T32Step {
    # Decodes the step at Pc and checks it against the intended step, including
    # every PC-relative target. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [hashtable] $Labels, [string] $Name)
    $at = $Pc
    $next = { $first = [BitConverter]::ToUInt16($Image, [int]$script:t32At); $second = if ($script:t32At + 2 -lt $Image.Length) { [BitConverter]::ToUInt16($Image, [int]$script:t32At + 2) } else { 0 }; $d = Read-T32Instruction -First $first -Second $second; $script:t32At += $d.Length; $d }
    $script:t32At = $Pc
    $pcRelative = {
        param([int] $Rd)
        $w = & $next; $t = & $next; $a = & $next
        if ($w.Op -ne 'movw' -or $t.Op -ne 'movt' -or $a.Op -ne 'add-reg' -or $w.Rd -ne $Rd -or $t.Rd -ne $Rd -or $a.Rd -ne $Rd -or $a.Rm -ne 15) { throw "$Name at ${Pc}: expected movw/movt/add pc into r$Rd." }
        [long]((($script:t32At - 2 + 4) + ([long]$t.Imm -shl 16 -bor $w.Imm)) -band 0xFFFFFFFFL)
    }
    $ok = switch ($Step.Op) {
        'label'    { $true }
        { $_ -in 'push', 'pop' } { $d = & $next; $d.Op -eq $Step.Op -and (@($d.Registers) -join ',') -eq (@($Step.Registers | Sort-Object) -join ',') }
        { $_ -in 'sub-sp', 'add-sp' } { $d = & $next; $d.Op -eq $Step.Op -and $d.Imm -eq $Step.Imm }
        'mov'      { $d = & $next; $d.Op -eq 'mov' -and $d.Rd -eq $Step.Rd -and $d.Rm -eq $Step.Rm }
        { $_ -in 'movs', 'movw', 'movt' } { $d = & $next; $d.Op -eq $Step.Op -and $d.Rd -eq $Step.Rd -and $d.Imm -eq [uint32]$Step.Imm }
        'cmp'      { $d = & $next; $d.Op -eq 'cmp' -and $d.Rn -eq $Step.Rn -and $d.Rm -eq $Step.Rm }
        'cmp-imm'  { $d = & $next; $d.Op -eq 'cmp-imm' -and $d.Rn -eq $Step.Rn -and $d.Imm -eq $Step.Imm }
        'adds'     { $d = & $next; $d.Op -eq 'adds' -and $d.Rd -eq $Step.Rd -and $d.Rn -eq $Step.Rn -and $d.Rm -eq $Step.Rm }
        'adds-imm' { $d = & $next; $d.Op -eq 'adds-imm' -and $d.Rd -eq $Step.Rd -and $d.Imm -eq $Step.Imm }
        { $_ -in 'ldr', 'str' } { $d = & $next; $d.Op -eq $Step.Op -and $d.Rt -eq $Step.Rt -and $d.Rn -eq $Step.Rn -and $d.Offset -eq $Step.Offset }
        { $_ -in 'b', 'beq', 'bne', 'bhs' } { $d = & $next; $d.Op -eq $Step.Op -and ($Pc + 4 + $d.Distance) -eq $Labels[$Step.Label] }
        'lea-data' { (& $pcRelative $Step.Rd) -eq $DataAt[$Step.Data] }
        'load-data' { $target = & $pcRelative $Step.Rd; $l = & $next; $target -eq $DataAt[$Step.Data] -and $l.Op -eq 'ldr' -and $l.Rt -eq $Step.Rd -and $l.Rn -eq $Step.Rd -and $l.Offset -eq 0 }
        'load-got' { $target = & $pcRelative $Step.Rd; $l = & $next; $SlotImport[$target] -ceq $Step.Import -and $l.Op -eq 'ldr' -and $l.Rt -eq $Step.Rd -and $l.Rn -eq $Step.Rd -and $l.Offset -eq 0 }
        { $_ -in 'call-import', 'call-data' } {
            $target = & $pcRelative 12; $l = & $next; $x = & $next
            $where = if ($Step.Op -eq 'call-import') { $SlotImport[$target] -ceq $Step.Import } else { $target -eq $DataAt[$Step.Data] }
            $where -and $l.Op -eq 'ldr' -and $l.Rt -eq 12 -and $l.Rn -eq 12 -and $l.Offset -eq 0 -and $x.Op -eq 'blx' -and $x.Rm -eq 12
        }
    }
    if (-not $ok) { throw "$Name at ${Pc}: the decoded bytes do not match step $($Step.Op)." }
    $length = Get-T32StepLength -Step $Step
    if ($script:t32At - $Pc -ne $length) { throw "$Name at ${Pc}: step $($Step.Op) decoded as $($script:t32At - $Pc) bytes, expected $length." }
    $length
}

function Test-T32CallAbi {
    <#
        Checks a T32 step program against AAPCS32 over its control-flow graph:
        arguments r0-r3 set, and stacked arguments stored at [sp, #4k], on every
        path to a call; a call keeps only r4-r11 and defines r0; sp stays 8-byte
        aligned at calls and returns to its entry value at the exit; equal stack
        depth at joins; a function that calls or writes r4-r11 pushes them with
        lr in its first step and leaves only through the matching pop into pc;
        every block reachable.
    #>
    param([Parameter(Mandatory)][object[]] $Steps, [int] $Parameters = 0, [string] $Name = 'function')

    $calleeSaved = 4..11
    $branches = @('b', 'beq', 'bne', 'bhs')
    $calls = @('call-import', 'call-data')
    $labelIndex = @{}
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') {
            if ($labelIndex.ContainsKey($Steps[$i]['Name'])) { throw "$Name defines label '$($Steps[$i]['Name'])' twice." }
            $labelIndex[$Steps[$i]['Name']] = $i
        }
    }
    foreach ($step in $Steps) { if ($step['Op'] -in $branches -and -not $labelIndex.ContainsKey($step['Label'])) { throw "$Name branches to undefined label '$($step['Label'])'." } }

    $saved = if ($Steps.Count -and $Steps[0]['Op'] -eq 'push') { @($Steps[0]['Registers']) } else { @() }
    $makesCalls = @($Steps | Where-Object { $_['Op'] -in $calls }).Count -gt 0
    if ($makesCalls -and 14 -notin $saved) { throw "$Name calls without pushing lr in its first step." }
    $restore = @($saved | ForEach-Object { if ($_ -eq 14) { 15 } else { $_ } } | Sort-Object)
    for ($i = 1; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        if ($step['Op'] -eq 'push') { throw "$Name pushes after its first step." }
        if ($step['Op'] -eq 'pop' -and (@($step['Registers'] | Sort-Object) -join ',') -ne ($restore -join ',')) { throw "$Name pops {$(@($step['Registers']) -join ',')}, not the {$($restore -join ',')} its prologue saved." }
        $written = if ($step['Op'] -in 'str', 'cmp', 'cmp-imm') { $null } elseif ($step['Op'] -in 'ldr') { $step['Rt'] } else { $step['Rd'] }
        if ($null -ne $written -and $written -in $calleeSaved -and $written -notin $saved) { throw "$Name writes callee-saved r$written without pushing it." }
        if ($null -ne $written -and $written -in 13, 15) { throw "$Name writes r$written directly." }
    }

    $leaders = [System.Collections.Generic.SortedSet[int]]::new()
    [void]$leaders.Add(0)
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') { [void]$leaders.Add($i) }
        if ($Steps[$i]['Op'] -in ($branches + @('pop')) -and $i + 1 -lt $Steps.Count) { [void]$leaders.Add($i + 1) }
    }
    $starts = @($leaders)
    $blockOf = @{}
    for ($b = 0; $b -lt $starts.Count; $b++) {
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        for ($i = $starts[$b]; $i -lt $end; $i++) { $blockOf[$i] = $b }
    }
    $copy = { param($s) [pscustomobject]@{ Depth = $s.Depth; Written = [System.Collections.Generic.HashSet[int]]::new($s.Written); Slots = [System.Collections.Generic.HashSet[int]]::new($s.Slots) } }
    $entry = [pscustomobject]@{ Depth = 0; Written = [System.Collections.Generic.HashSet[int]]::new(); Slots = [System.Collections.Generic.HashSet[int]]::new() }
    for ($a = 0; $a -lt $Parameters; $a++) { [void]$entry.Written.Add($a) }
    $inState = @{ 0 = $entry }
    $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue(0)
    $flow = {
        param([int] $target, $state)
        if (-not $inState.ContainsKey($target)) { $inState[$target] = & $copy $state; $queue.Enqueue($target); return }
        $current = $inState[$target]
        if ($current.Depth -ne $state.Depth) { throw "$Name reaches block $target with stack depths $($current.Depth) and $($state.Depth)." }
        $before = $current.Written.Count + $current.Slots.Count
        $current.Written.IntersectWith($state.Written); $current.Slots.IntersectWith($state.Slots)
        if ($current.Written.Count + $current.Slots.Count -ne $before) { $queue.Enqueue($target) }
    }
    $guard = 0
    while ($queue.Count -gt 0) {
        if (++$guard -gt 10000) { throw "${Name}: control-flow analysis did not converge." }
        $b = $queue.Dequeue()
        $state = & $copy $inState[$b]
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        $fallsThrough = $true
        for ($i = $starts[$b]; $i -lt $end; $i++) {
            $step = $Steps[$i]
            switch ($step['Op']) {
                'label'  { }
                'push'   { $state.Depth += 4 * @($step['Registers']).Count }
                'sub-sp' { $state.Depth += $step['Imm']; $state.Slots.Clear() }
                'add-sp' { $state.Depth -= $step['Imm']; $state.Slots.Clear() }
                'str'    { if ($step['Rn'] -eq 13) { [void]$state.Slots.Add($step['Offset']) } }
                'cmp'    { } 'cmp-imm' { }
                'pop'    {
                    $state.Depth -= 4 * @($step['Registers']).Count
                    if ($state.Depth -ne 0) { throw "$Name leaves with sp $($state.Depth) bytes below entry." }
                    $fallsThrough = $false
                }
                { $_ -in $calls } {
                    $callee = "$($step['Import'])$($step['Data'])"
                    if ($state.Depth % 8 -ne 0) { throw "$Name calls $callee with sp $($state.Depth) bytes below entry, not 8-byte aligned." }
                    $count = [int]$step['Args']
                    for ($a = 0; $a -lt [Math]::Min(4, $count); $a++) { if (-not $state.Written.Contains($a)) { throw "$Name calls $callee without setting r$a on every path." } }
                    for ($a = 4; $a -lt $count; $a++) { if (-not $state.Slots.Contains(4 * ($a - 4))) { throw "$Name calls $callee without storing argument $($a + 1) at [sp, #$(4 * ($a - 4))] on every path." } }
                    $state.Written.IntersectWith([int[]]$calleeSaved); [void]$state.Written.Add(0)
                    $state.Slots.Clear()
                }
                { $_ -in 'beq', 'bne', 'bhs' } { & $flow $blockOf[$labelIndex[$step['Label']]] $state }
                'b' { & $flow $blockOf[$labelIndex[$step['Label']]] $state; $fallsThrough = $false }
                default { $r = if ($step['Op'] -eq 'ldr') { $step['Rt'] } else { $step['Rd'] }; if ($null -ne $r) { [void]$state.Written.Add($r) } }
            }
        }
        if ($fallsThrough -and $b + 1 -lt $starts.Count) { & $flow ($b + 1) $state }
        if ($fallsThrough -and $b + 1 -ge $starts.Count) { throw "$Name runs off its end without pop into pc." }
    }
    for ($b = 0; $b -lt $starts.Count; $b++) {
        if (-not $inState.ContainsKey($b)) {
            $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
            if (@($Steps[$starts[$b]..($end - 1)] | Where-Object { $_['Op'] -ne 'label' }).Count) { throw "$Name has unreachable code at step $($starts[$b])." }
        }
    }
}

function Get-InstructionSet {
    # The selected target's instruction set, as the operations the shared ELF
    # code-library writer and reader call. Everything machine-specific stays in
    # that instruction set's own section. A library may name its own (the arm32
    # host is T32 beside A32 libpsl-native). StateBit is bit 0 of a code
    # address in that instruction set: 1 for Thumb, as ELF STT_FUNC values and
    # function pointers carry it (AAELF32, AAPCS32).
    param([string] $Isa = $script:Target.Isa)
    switch ($Isa) {
        'A64' { return [pscustomobject]@{ Id = 'A64'; Name = 'A64'; Alignment = 4; StateBit = 0; Length = ${function:Get-A64StepLength}; Encode = ${function:New-A64Step}; Verify = ${function:Test-A64Step} } }
        'X64' { return [pscustomobject]@{ Id = 'X64'; Name = 'x86-64'; Alignment = 1; StateBit = 0; Length = ${function:Get-X64StepLength}; Encode = ${function:New-X64Step}; Verify = ${function:Test-X64Step} } }
        'A32' { return [pscustomobject]@{ Id = 'A32'; Name = 'A32'; Alignment = 4; StateBit = 0; Length = ${function:Get-A32StepLength}; Encode = ${function:New-A32Step}; Verify = ${function:Test-A32Step} } }
        'T32' {
            if ($script:Target.Machine -ne 'EM_ARM') { throw 'T32 code needs the ARM target.' }
            return [pscustomobject]@{ Id = 'T32'; Name = 'T32'; Alignment = 2; StateBit = 1; Length = ${function:Get-T32StepLength}; Encode = ${function:New-T32Step}; Verify = ${function:Test-T32Step} }
        }
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

function New-A64PairTransfer {
    # STP / LDP of two X registers: pre-index, post-index or signed offset.
    # opc 10 101 0 mode L imm7 Rt2 Rn Rt; the offset is imm7 * 8.
    param([ValidateSet('stp-pre', 'ldp-post', 'stp', 'ldp')][string] $Op, [ValidateRange(0, 30)][int] $Rt,
          [ValidateRange(0, 30)][int] $Rt2, [ValidateRange(0, 31)][int] $Rn = 31, [int] $Offset)
    if ($Offset % 8 -or $Offset -lt -512 -or $Offset -gt 504) { throw "$Op offset $Offset is not a multiple of 8 in [-512, 504]." }
    $base = switch ($Op) { 'stp-pre' { 0xA9800000u } 'ldp-post' { 0xA8C00000u } 'stp' { 0xA9000000u } 'ldp' { 0xA9400000u } }
    [uint32]($base -bor (([long]($Offset / 8) -band 0x7F) -shl 15) -bor ($Rt2 -shl 10) -bor ($Rn -shl 5) -bor $Rt)
}

function New-A64AddImmediate {
    # ADD Xd, Xn|SP, #imm12: 1 0 0 100010 0 imm12 Rn Rd. Register 31 is SP here.
    param([ValidateRange(0, 31)][int] $Rd, [ValidateRange(0, 31)][int] $Rn, [ValidateRange(0, 4095)][int] $Imm)
    [uint32](0x91000000u -bor ($Imm -shl 10) -bor ($Rn -shl 5) -bor $Rd)
}

function New-A64AddRegister {
    # ADD Xd, Xn, Xm: 1 0 0 01011 00 0 Rm 000000 Rn Rd
    param([ValidateRange(0, 30)][int] $Rd, [ValidateRange(0, 30)][int] $Rn, [ValidateRange(0, 30)][int] $Rm)
    [uint32](0x8B000000u -bor ($Rm -shl 16) -bor ($Rn -shl 5) -bor $Rd)
}

function New-A64CompareImmediate {
    # CMP Wn, #imm12 is SUBS WZR, Wn, #imm12: 0 1 1 100010 0 imm12 Rn 11111
    param([ValidateRange(0, 30)][int] $Rn, [ValidateRange(0, 4095)][int] $Imm)
    [uint32](0x7100001Fu -bor ($Imm -shl 10) -bor ($Rn -shl 5))
}

function New-A64LoadStore {
    # LDR/STR (unsigned offset): 64-bit 11 111 0 01 opc imm12 Rn Rt, imm12 =
    # offset / 8; LDR W: 10 111 0 01 01, imm12 = offset / 4.
    param([ValidateSet('ldr64', 'ldr32', 'str64')][string] $Op, [ValidateRange(0, 30)][int] $Rt,
          [ValidateRange(0, 31)][int] $Rn, [int] $Offset)
    $scale = if ($Op -eq 'ldr32') { 4 } else { 8 }
    if ($Offset % $scale -or $Offset -lt 0 -or $Offset / $scale -gt 4095) { throw "$Op offset $Offset is not a multiple of $scale in range." }
    $base = switch ($Op) { 'ldr64' { 0xF9400000u } 'ldr32' { 0xB9400000u } 'str64' { 0xF9000000u } }
    [uint32]($base -bor ([long]($Offset / $scale) -shl 10) -bor ($Rn -shl 5) -bor $Rt)
}

function New-A64Branch {
    # B imm26; B.cond imm19 cond; CBZ/CBNZ sf 011010 op imm19 Rt. The distance
    # is in instructions and must fit the field exactly.
    param([ValidateSet('b', 'b.hs', 'cbz', 'cbnz')][string] $Op, [long] $Distance, [int] $Rt = 0, [bool] $Is64 = $false)
    if ($Distance % 4) { throw "$Op distance $Distance is not a multiple of 4." }
    $words = [long]($Distance / 4)
    $bits = if ($Op -eq 'b') { 26 } else { 19 }
    $limit = [long]1 -shl ($bits - 1)
    if ($words -lt -$limit -or $words -ge $limit) { throw "$Op distance $Distance does not fit imm$bits." }
    $field = [uint32]($words -band (([long]1 -shl $bits) - 1))
    switch ($Op) {
        'b'    { [uint32](0x14000000u -bor $field) }
        'b.hs' { [uint32](0x54000000u -bor ($field -shl 5) -bor 2) }
        'cbz'  { [uint32]((([uint32]$Is64) -shl 31) -bor 0x34000000u -bor ($field -shl 5) -bor $Rt) }
        'cbnz' { [uint32]((([uint32]$Is64) -shl 31) -bor 0x35000000u -bor ($field -shl 5) -bor $Rt) }
    }
}

function Read-A64Instruction {
    # Independent decode: classifies by the fixed opcode bits and extracts the
    # fields, without calling any encoder.
    param([Parameter(Mandatory)][uint32] $Word)

    $signed = { param([uint32] $value, [int] $bits) $v = [long]$value; if ($v -band ([long]1 -shl ($bits - 1))) { $v - ([long]1 -shl $bits) } else { $v } }
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
    if (($Word -band 0xFFC00000u) -eq 0xB9400000u) {
        return [pscustomobject]@{ Op = 'ldr32'; Offset = (($Word -shr 10) -band 0xFFF) * 4; Rn = ($Word -shr 5) -band 31; Rt = $Word -band 31 }
    }
    if (($Word -band 0xFFC00000u) -eq 0xF9000000u) {
        return [pscustomobject]@{ Op = 'str64'; Offset = (($Word -shr 10) -band 0xFFF) * 8; Rn = ($Word -shr 5) -band 31; Rt = $Word -band 31 }
    }
    foreach ($pair in @(@(0xA9800000u, 'stp-pre'), @(0xA8C00000u, 'ldp-post'), @(0xA9000000u, 'stp'), @(0xA9400000u, 'ldp'))) {
        if (($Word -band 0xFFC00000u) -eq $pair[0]) {
            return [pscustomobject]@{ Op = $pair[1]; Offset = 8 * (& $signed (($Word -shr 15) -band 0x7F) 7); Rt2 = ($Word -shr 10) -band 31; Rn = ($Word -shr 5) -band 31; Rt = $Word -band 31 }
        }
    }
    if (($Word -band 0xFFC00000u) -eq 0x91000000u) {
        return [pscustomobject]@{ Op = 'add-imm'; Imm = ($Word -shr 10) -band 0xFFF; Rn = ($Word -shr 5) -band 31; Rd = $Word -band 31 }
    }
    if (($Word -band 0xFFE0FC00u) -eq 0x8B000000u) {
        return [pscustomobject]@{ Op = 'add-reg'; Rm = ($Word -shr 16) -band 31; Rn = ($Word -shr 5) -band 31; Rd = $Word -band 31 }
    }
    if (($Word -band 0xFFC0001Fu) -eq 0x7100001Fu) {
        return [pscustomobject]@{ Op = 'cmp-imm32'; Imm = ($Word -shr 10) -band 0xFFF; Rn = ($Word -shr 5) -band 31 }
    }
    if (($Word -band 0xFC000000u) -eq 0x14000000u) {
        return [pscustomobject]@{ Op = 'b'; Distance = 4 * (& $signed ($Word -band 0x3FFFFFF) 26) }
    }
    if (($Word -band 0xFF000010u) -eq 0x54000000u) {
        return [pscustomobject]@{ Op = 'b.cond'; Cond = $Word -band 0xF; Distance = 4 * (& $signed (($Word -shr 5) -band 0x7FFFF) 19) }
    }
    if (($Word -band 0x7E000000u) -eq 0x34000000u) {
        return [pscustomobject]@{ Op = $(if ($Word -band 0x01000000u) { 'cbnz' } else { 'cbz' }); Is64 = [bool]($Word -shr 31); Rt = $Word -band 31; Distance = 4 * (& $signed (($Word -shr 5) -band 0x7FFFF) 19) }
    }
    if (($Word -band 0xFFFFFC1Fu) -eq 0xD63F0000u) {
        return [pscustomobject]@{ Op = 'blr'; Rn = ($Word -shr 5) -band 31 }
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
        'label' { 0 }
        'tail' { 12 }
        { $_ -in 'call-import', 'call-data' } { 12 }
        { $_ -in 'lea-data', 'load64-data', 'load32-data', 'load-got' } { 8 }
        { $_ -in 'movz', 'movn', 'mov', 'ret', 'adr-data', 'stp-pre', 'ldp-post', 'stp', 'ldp', 'add-imm', 'add-reg', 'cmp-imm32', 'ldr64', 'ldr32', 'str64', 'b', 'b.hs', 'cbz', 'cbnz' } { 4 }
        default { throw "Unknown A64 step '$($Step.Op)'." }
    }
}

function New-A64Step {
    # Bytes for one step at Pc. Target is the GOT slot for 'tail', 'load-got'
    # and 'call-import', the data address for data steps, and the label
    # address for branches. Page-relative forms are ADRP x, then an ADD, LDR
    # or LDR+BLR on the page offset.
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $pages = ([long]($Target -band -4096) - [long]($Pc -band -4096)) -shr 12
    $low = [int]($Target -band 0xFFF)
    $words = switch ($Step.Op) {
        'label' { , [uint32[]]@() }
        { $_ -in 'movz', 'movn' } { , [uint32[]]@(New-A64MovWide -Op $Step.Op -Rd $Step.Rd -Imm16 $Step.Imm -Is64 ([bool]$Step.Is64)) }
        'mov' { , [uint32[]]@(New-A64MovRegister -Rd $Step.Rd -Rm $Step.Rm -Is64 ([bool]$Step.Is64)) }
        'ret' { , [uint32[]]@(New-A64BranchRegister -Op ret) }
        'adr-data' { , [uint32[]]@(New-A64Adr -Op adr -Rd $Step.Rd -Imm21 ($Target - $Pc)) }
        'tail' { , [uint32[]]@((New-A64Adr -Op adrp -Rd 16 -Imm21 $pages), (New-A64LdrUnsigned -Rt 16 -Rn 16 -Offset $low), (New-A64BranchRegister -Op br -Rn 16)) }
        { $_ -in 'stp-pre', 'ldp-post', 'stp', 'ldp' } { , [uint32[]]@(New-A64PairTransfer -Op $Step.Op -Rt $Step.Rt -Rt2 $Step.Rt2 -Offset $Step.Offset) }
        'add-imm' { , [uint32[]]@(New-A64AddImmediate -Rd $Step.Rd -Rn $Step.Rn -Imm $Step.Imm) }
        'add-reg' { , [uint32[]]@(New-A64AddRegister -Rd $Step.Rd -Rn $Step.Rn -Rm $Step.Rm) }
        'cmp-imm32' { , [uint32[]]@(New-A64CompareImmediate -Rn $Step.Rn -Imm $Step.Imm) }
        { $_ -in 'ldr64', 'ldr32', 'str64' } { , [uint32[]]@(New-A64LoadStore -Op $Step.Op -Rt $Step.Rt -Rn $Step.Rn -Offset $Step.Offset) }
        'lea-data' { , [uint32[]]@((New-A64Adr -Op adrp -Rd $Step.Rd -Imm21 $pages), (New-A64AddImmediate -Rd $Step.Rd -Rn $Step.Rd -Imm $low)) }
        'load64-data' { , [uint32[]]@((New-A64Adr -Op adrp -Rd $Step.Rd -Imm21 $pages), (New-A64LoadStore -Op ldr64 -Rt $Step.Rd -Rn $Step.Rd -Offset $low)) }
        'load32-data' { , [uint32[]]@((New-A64Adr -Op adrp -Rd $Step.Rd -Imm21 $pages), (New-A64LoadStore -Op ldr32 -Rt $Step.Rd -Rn $Step.Rd -Offset $low)) }
        'load-got' { , [uint32[]]@((New-A64Adr -Op adrp -Rd $Step.Rd -Imm21 $pages), (New-A64LoadStore -Op ldr64 -Rt $Step.Rd -Rn $Step.Rd -Offset $low)) }
        { $_ -in 'call-import', 'call-data' } { , [uint32[]]@((New-A64Adr -Op adrp -Rd 16 -Imm21 $pages), (New-A64LoadStore -Op ldr64 -Rt 16 -Rn 16 -Offset $low), [uint32](0xD63F0000u -bor (16 -shl 5))) }
        { $_ -in 'b', 'b.hs' } { , [uint32[]]@(New-A64Branch -Op $Step.Op -Distance ($Target - $Pc)) }
        { $_ -in 'cbz', 'cbnz' } { , [uint32[]]@(New-A64Branch -Op $Step.Op -Distance ($Target - $Pc) -Rt $Step.Rt -Is64 ([bool]$Step.Is64)) }
        default { throw "Unknown A64 step '$($Step.Op)'." }
    }
    if ($words.Count -eq 0) { return }
    [byte[]]@($words | ForEach-Object { [BitConverter]::GetBytes([uint32]$_) } | ForEach-Object { $_ })
}

function Test-A64Step {
    # Decodes the step at Pc with Read-A64Instruction and checks it against the
    # intended step. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [hashtable] $Labels, [string] $Name)
    if ($Step.Op -eq 'label') {
        if ($Labels -and $Labels[$Step.Name] -ne $Pc) { throw "$Name label '$($Step.Name)' is at $($Labels[$Step.Name]), expected $Pc." }
        return 0
    }
    $at = { param([int] $k) Read-A64Instruction -Word ([BitConverter]::ToUInt32($Image, [int]$Pc + 4 * $k)) }
    $word = & $at 0
    # ADRP at Pc plus the page offset in the next word: the address both select.
    $paged = {
        param($second, [int] $scale)
        if ($word.Op -ne 'adrp') { return $null }
        (($Pc -band -4096) + ($word.Imm -shl 12)) + $(if ($second.Op -eq 'add-imm') { $second.Imm } else { $second.Offset })
    }
    $ok = switch ($Step.Op) {
        { $_ -in 'movz', 'movn' } { $word.Op -eq $Step.Op -and $word.Rd -eq $Step.Rd -and $word.Imm -eq $Step.Imm -and $word.Hw -eq 0 -and $word.Is64 -eq [bool]$Step.Is64 }
        'mov' { $word.Op -eq 'mov' -and $word.Rd -eq $Step.Rd -and $word.Rm -eq $Step.Rm -and $word.Is64 -eq [bool]$Step.Is64 }
        'ret' { $word.Op -eq 'ret' -and $word.Rn -eq 30 }
        'adr-data' { $word.Op -eq 'adr' -and $word.Rd -eq $Step.Rd -and ($Pc + $word.Imm) -eq $DataAt[$Step.Data] }
        'tail' {
            $w2 = & $at 1; $w3 = & $at 2
            $slot = (($Pc -band -4096) + ($word.Imm -shl 12)) + $w2.Offset
            $word.Op -eq 'adrp' -and $word.Rd -eq 16 -and $w2.Op -eq 'ldr' -and $w2.Rn -eq 16 -and $w2.Rt -eq 16 -and
            $w3.Op -eq 'br' -and $w3.Rn -eq 16 -and $SlotImport[[long]$slot] -ceq $Step.Import
        }
        { $_ -in 'stp-pre', 'ldp-post', 'stp', 'ldp' } { $word.Op -eq $Step.Op -and $word.Rt -eq $Step.Rt -and $word.Rt2 -eq $Step.Rt2 -and $word.Rn -eq 31 -and $word.Offset -eq $Step.Offset }
        'add-imm' { $word.Op -eq 'add-imm' -and $word.Rd -eq $Step.Rd -and $word.Rn -eq $Step.Rn -and $word.Imm -eq $Step.Imm }
        'add-reg' { $word.Op -eq 'add-reg' -and $word.Rd -eq $Step.Rd -and $word.Rn -eq $Step.Rn -and $word.Rm -eq $Step.Rm }
        'cmp-imm32' { $word.Op -eq 'cmp-imm32' -and $word.Rn -eq $Step.Rn -and $word.Imm -eq $Step.Imm }
        'ldr64' { $word.Op -eq 'ldr' -and $word.Rt -eq $Step.Rt -and $word.Rn -eq $Step.Rn -and $word.Offset -eq $Step.Offset }
        'ldr32' { $word.Op -eq 'ldr32' -and $word.Rt -eq $Step.Rt -and $word.Rn -eq $Step.Rn -and $word.Offset -eq $Step.Offset }
        'str64' { $word.Op -eq 'str64' -and $word.Rt -eq $Step.Rt -and $word.Rn -eq $Step.Rn -and $word.Offset -eq $Step.Offset }
        'lea-data' { $w2 = & $at 1; $w2.Op -eq 'add-imm' -and $word.Rd -eq $Step.Rd -and $w2.Rd -eq $Step.Rd -and $w2.Rn -eq $Step.Rd -and (& $paged $w2) -eq $DataAt[$Step.Data] }
        'load64-data' { $w2 = & $at 1; $w2.Op -eq 'ldr' -and $word.Rd -eq $Step.Rd -and $w2.Rt -eq $Step.Rd -and $w2.Rn -eq $Step.Rd -and (& $paged $w2) -eq $DataAt[$Step.Data] }
        'load32-data' { $w2 = & $at 1; $w2.Op -eq 'ldr32' -and $word.Rd -eq $Step.Rd -and $w2.Rt -eq $Step.Rd -and $w2.Rn -eq $Step.Rd -and (& $paged $w2) -eq $DataAt[$Step.Data] }
        'load-got' { $w2 = & $at 1; $w2.Op -eq 'ldr' -and $word.Rd -eq $Step.Rd -and $w2.Rt -eq $Step.Rd -and $w2.Rn -eq $Step.Rd -and $SlotImport[[long](& $paged $w2)] -ceq $Step.Import }
        'call-import' { $w2 = & $at 1; $w3 = & $at 2; $word.Rd -eq 16 -and $w2.Op -eq 'ldr' -and $w2.Rt -eq 16 -and $w2.Rn -eq 16 -and $w3.Op -eq 'blr' -and $w3.Rn -eq 16 -and $SlotImport[[long](& $paged $w2)] -ceq $Step.Import }
        'call-data' { $w2 = & $at 1; $w3 = & $at 2; $word.Rd -eq 16 -and $w2.Op -eq 'ldr' -and $w2.Rt -eq 16 -and $w2.Rn -eq 16 -and $w3.Op -eq 'blr' -and $w3.Rn -eq 16 -and (& $paged $w2) -eq $DataAt[$Step.Data] }
        'b' { $word.Op -eq 'b' -and ($Pc + $word.Distance) -eq $Labels[$Step.Label] }
        'b.hs' { $word.Op -eq 'b.cond' -and $word.Cond -eq 2 -and ($Pc + $word.Distance) -eq $Labels[$Step.Label] }
        { $_ -in 'cbz', 'cbnz' } { $word.Op -eq $Step.Op -and $word.Rt -eq $Step.Rt -and $word.Is64 -eq [bool]$Step.Is64 -and ($Pc + $word.Distance) -eq $Labels[$Step.Label] }
    }
    if (-not $ok) { throw "$Name at ${Pc}: expected $($Step.Op), decoded $($word.Op)." }
    Get-A64StepLength -Step $Step
}

function Test-A64CallAbi {
    <#
        Checks an A64 step program against AAPCS64 over its control-flow graph,
        as Test-X64CallAbi does for System V: arguments x0-x7 set on every path
        to a call; a call keeps only x19-x29 and defines x0; sp stays 16-byte
        aligned and returns to its entry value at ret and tail; equal stack
        depth at joins; x18 (the platform register) is never written; a
        function that calls, or writes x19-x29, saves the pairs in its
        prologue (stp x29, x30, [sp, #-n]! then stp pairs) and restores them in
        reverse order immediately before every exit; every block reachable.
    #>
    param([Parameter(Mandatory)][object[]] $Steps, [int] $Parameters = 0, [string] $Name = 'function')

    $calleeSaved = 19..29
    $branches = @('b', 'b.hs', 'cbz', 'cbnz')
    $calls = @('call-import', 'call-data')
    $labelIndex = @{}
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') {
            if ($labelIndex.ContainsKey($Steps[$i]['Name'])) { throw "$Name defines label '$($Steps[$i]['Name'])' twice." }
            $labelIndex[$Steps[$i]['Name']] = $i
        }
    }
    foreach ($step in $Steps) {
        if ($step['Op'] -in $branches -and -not $labelIndex.ContainsKey($step['Label'])) { throw "$Name branches to undefined label '$($step['Label'])'." }
        foreach ($field in 'Rd', 'Rt', 'Rt2') { if ($step[$field] -eq 18) { throw "$Name writes x18, the platform register." } }
    }

    # Prologue pairs: stp x29, x30, [sp, #-n]!, optionally add x29, sp, #0, then stp pairs.
    $pairs = [System.Collections.Generic.List[object]]::new()
    $k = 0
    if ($Steps.Count -and $Steps[0]['Op'] -eq 'stp-pre') {
        $pairs.Add(@($Steps[0]['Rt'], $Steps[0]['Rt2'])); $k = 1
        if ($Steps[$k]['Op'] -eq 'add-imm' -and $Steps[$k]['Rd'] -eq 29 -and $Steps[$k]['Rn'] -eq 31 -and $Steps[$k]['Imm'] -eq 0) { $k++ }
        while ($k -lt $Steps.Count -and $Steps[$k]['Op'] -eq 'stp') { $pairs.Add(@($Steps[$k]['Rt'], $Steps[$k]['Rt2'])); $k++ }
    }
    $saved = @($pairs | ForEach-Object { $_ }) | Where-Object { $_ -ne $null }
    $makesCalls = @($Steps | Where-Object { $_['Op'] -in $calls }).Count -gt 0
    if ($makesCalls -and 30 -notin $saved) { throw "$Name calls without saving x30 in its prologue." }
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        if ($i -ge $k -and $step['Op'] -notin 'stp', 'ldp', 'ldp-post', 'stp-pre') {
            foreach ($field in 'Rd', 'Rt') {
                $reg = $step[$field]
                if ($null -ne $reg -and $step['Op'] -notin 'str64', 'cbz', 'cbnz' -and $reg -in $calleeSaved -and $reg -notin $saved) { throw "$Name writes callee-saved x$reg without saving it in its prologue." }
            }
        }
        if ($step['Op'] -in 'ret', 'tail' -and $pairs.Count) {

            $restores = [System.Collections.Generic.List[object]]::new()
            $j = $i - 1
            while ($j -ge 0 -and $Steps[$j]['Op'] -in 'ldp', 'ldp-post', 'label') { if ($Steps[$j]['Op'] -ne 'label') { $restores.Insert(0, $Steps[$j]) }; $j-- }
            $expectedOrder = for ($p = $pairs.Count - 1; $p -ge 0; $p--) { , $pairs[$p] }
            if ($restores.Count -ne $pairs.Count) { throw "$Name exits without restoring its $($pairs.Count) saved pairs." }
            for ($r = 0; $r -lt $restores.Count; $r++) {
                $pair = $expectedOrder[$r]
                $op = if ($r -eq $restores.Count - 1) { 'ldp-post' } else { 'ldp' }
                if ($restores[$r]['Op'] -ne $op -or $restores[$r]['Rt'] -ne $pair[0] -or $restores[$r]['Rt2'] -ne $pair[1]) { throw "$Name exits without restoring x$($pair[0]) and x$($pair[1]) in reverse order." }
            }
        }
    }

    $leaders = [System.Collections.Generic.SortedSet[int]]::new()
    [void]$leaders.Add(0)
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') { [void]$leaders.Add($i) }
        if ($Steps[$i]['Op'] -in ($branches + @('ret', 'tail')) -and $i + 1 -lt $Steps.Count) { [void]$leaders.Add($i + 1) }
    }
    $starts = @($leaders)
    $blockOf = @{}
    for ($b = 0; $b -lt $starts.Count; $b++) {
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        for ($i = $starts[$b]; $i -lt $end; $i++) { $blockOf[$i] = $b }
    }
    $copy = { param($s) [pscustomobject]@{ Depth = $s.Depth; Written = [System.Collections.Generic.HashSet[int]]::new($s.Written) } }
    $entry = [pscustomobject]@{ Depth = 0; Written = [System.Collections.Generic.HashSet[int]]::new() }
    for ($a = 0; $a -lt $Parameters; $a++) { [void]$entry.Written.Add($a) }
    $inState = @{ 0 = $entry }
    $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue(0)
    $flow = {
        param([int] $target, $state)
        if (-not $inState.ContainsKey($target)) { $inState[$target] = & $copy $state; $queue.Enqueue($target); return }
        $current = $inState[$target]
        if ($current.Depth -ne $state.Depth) { throw "$Name reaches block $target with stack depths $($current.Depth) and $($state.Depth)." }
        $before = $current.Written.Count
        $current.Written.IntersectWith($state.Written)
        if ($current.Written.Count -ne $before) { $queue.Enqueue($target) }
    }
    $guard = 0
    while ($queue.Count -gt 0) {
        if (++$guard -gt 10000) { throw "${Name}: control-flow analysis did not converge." }
        $b = $queue.Dequeue()
        $state = & $copy $inState[$b]
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        $fallsThrough = $true
        for ($i = $starts[$b]; $i -lt $end; $i++) {
            $step = $Steps[$i]
            switch ($step['Op']) {
                'label'    { }
                'stp-pre'  { $state.Depth -= $step['Offset'] }
                'ldp-post' { $state.Depth -= $step['Offset']; [void]$state.Written.Add($step['Rt']); [void]$state.Written.Add($step['Rt2']) }
                'ldp'      { [void]$state.Written.Add($step['Rt']); [void]$state.Written.Add($step['Rt2']) }
                { $_ -in $calls } {
                    $callee = "$($step['Import'])$($step['Data'])"
                    if ($state.Depth % 16 -ne 0) { throw "$Name calls $callee with sp $($state.Depth) bytes below entry, not 16-byte aligned." }
                    for ($a = 0; $a -lt [int]$step['Args']; $a++) {
                        if (-not $state.Written.Contains($a)) { throw "$Name calls $callee without setting x$a on every path." }
                    }
                    $state.Written.IntersectWith([int[]]$calleeSaved)
                    [void]$state.Written.Add(0)
                }
                { $_ -in 'ret', 'tail' } {
                    if ($state.Depth -ne 0) { throw "$Name leaves with sp $($state.Depth) bytes below entry." }
                    $fallsThrough = $false
                }
                { $_ -in 'b.hs', 'cbz', 'cbnz' } { & $flow $blockOf[$labelIndex[$step['Label']]] $state }
                'b' { & $flow $blockOf[$labelIndex[$step['Label']]] $state; $fallsThrough = $false }
                default { foreach ($field in 'Rd', 'Rt') { if ($null -ne $step[$field] -and $step['Op'] -notin 'str64', 'cbz', 'cbnz', 'stp') { [void]$state.Written.Add($step[$field]) } } }
            }
        }
        if ($fallsThrough -and $b + 1 -lt $starts.Count) { & $flow ($b + 1) $state }
        if ($fallsThrough -and $b + 1 -ge $starts.Count) { throw "$Name runs off its end without ret or tail." }
    }
    for ($b = 0; $b -lt $starts.Count; $b++) {
        if (-not $inState.ContainsKey($b)) {
            $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
            if (@($Steps[$starts[$b]..($end - 1)] | Where-Object { $_['Op'] -ne 'label' }).Count) { throw "$Name has unreachable code at step $($starts[$b])." }
        }
    }
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

function Get-X64Rex {
    # REX prefix: 0100WRXB. Returns nothing when no bit is needed, so the
    # register-0-7 forms keep their REX-less encodings.
    param([bool] $W = $false, [int] $R = 0, [int] $B = 0, [bool] $Force = $false)
    $value = 0x40 -bor ([int]$W -shl 3) -bor ((($R -shr 3) -band 1) -shl 2) -bor (($B -shr 3) -band 1)
    if ($value -ne 0x40 -or $Force) { return , [byte[]]@([byte]$value) }
    , [byte[]]@()
}

function New-X64Instruction {
    # Returns the bytes for one step. RIP-relative forms, branches and calls
    # take the distance from the end of the instruction. Register numbers are
    # 0-15 (rax rcx rdx rbx rsp rbp rsi rdi r8-r15).
    param([Parameter(Mandatory)] $Step, [long] $RipDisplacement = 0)
    $imm32 = { param([long] $v) [BitConverter]::GetBytes([int32]$v) }
    $rip = { param([int] $reg) Get-X64ModRm 0 ($reg -band 7) 5 }
    $base = {
        param([int] $reg, [int] $baseReg, [int] $disp)
        if (($baseReg -band 7) -eq 4) { throw 'Base rsp/r12 needs a SIB byte; use store64-rsp.' }
        if ($disp -lt -128 -or $disp -gt 127) { throw "Displacement $disp does not fit disp8." }
        [byte[]]@((Get-X64ModRm 1 ($reg -band 7) ($baseReg -band 7)), [byte]($disp -band 0xFF))
    }
    $s = $Step
    switch ($s.Op) {
        'label'        { return }
        'mov32'        { return [byte[]]((Get-X64Rex -R $s.Src -B $s.Dst) + @(0x89, (Get-X64ModRm 3 ($s.Src -band 7) ($s.Dst -band 7)))) }
        'mov64'        { return [byte[]]((Get-X64Rex -W $true -R $s.Src -B $s.Dst) + @(0x89, (Get-X64ModRm 3 ($s.Src -band 7) ($s.Dst -band 7)))) }
        'movimm32'     { return [byte[]]((Get-X64Rex -B $s.Dst) + @([byte](0xB8 + ($s.Dst -band 7))) + (& $imm32 $s.Imm)) }
        'movimm64s'    { return [byte[]]((Get-X64Rex -W $true -B $s.Dst) + @(0xC7, (Get-X64ModRm 3 0 ($s.Dst -band 7))) + (& $imm32 $s.Imm)) }
        'xor32'        { return [byte[]]((Get-X64Rex -R $s.Dst -B $s.Dst) + @(0x31, (Get-X64ModRm 3 ($s.Dst -band 7) ($s.Dst -band 7)))) }
        'lea-data'     { return [byte[]]((Get-X64Rex -W $true -R $s.Dst) + @(0x8D, (& $rip $s.Dst)) + (& $imm32 $RipDisplacement)) }
        'load64-data'  { return [byte[]]((Get-X64Rex -W $true -R $s.Dst) + @(0x8B, (& $rip $s.Dst)) + (& $imm32 $RipDisplacement)) }
        'load32-data'  { return [byte[]]((Get-X64Rex -R $s.Dst) + @(0x8B, (& $rip $s.Dst)) + (& $imm32 $RipDisplacement)) }
        'load-got'     { return [byte[]]((Get-X64Rex -W $true -R $s.Dst) + @(0x8B, (& $rip $s.Dst)) + (& $imm32 $RipDisplacement)) }
        'load64-base'  { return [byte[]]((Get-X64Rex -W $true -R $s.Dst -B $s.Base) + @(0x8B) + (& $base $s.Dst $s.Base $s.Disp)) }
        'store64-base' { return [byte[]]((Get-X64Rex -W $true -R $s.Src -B $s.Base) + @(0x89) + (& $base $s.Src $s.Base $s.Disp)) }
        'add64-base'   { return [byte[]]((Get-X64Rex -W $true -R $s.Dst -B $s.Base) + @(0x03) + (& $base $s.Dst $s.Base $s.Disp)) }
        'store64-rsp'  {
            if ($s.Disp -lt 0 -or $s.Disp -gt 127) { throw "Displacement $($s.Disp) does not fit disp8." }
            return [byte[]]((Get-X64Rex -W $true -R $s.Src) + @(0x89, (Get-X64ModRm 1 ($s.Src -band 7) 4), 0x24, [byte]$s.Disp))
        }
        'sub-rsp'      { return [byte[]]@(0x48, 0x83, (Get-X64ModRm 3 5 4), [byte]$s.Imm) }
        'add-rsp'      { return [byte[]]@(0x48, 0x83, (Get-X64ModRm 3 0 4), [byte]$s.Imm) }
        'add64-imm8'   { return [byte[]]((Get-X64Rex -W $true -B $s.Dst) + @(0x83, (Get-X64ModRm 3 0 ($s.Dst -band 7)), [byte]$s.Imm)) }
        'test32'       { return [byte[]]((Get-X64Rex -R $s.Reg -B $s.Reg) + @(0x85, (Get-X64ModRm 3 ($s.Reg -band 7) ($s.Reg -band 7)))) }
        'cmp32-imm'    { return [byte[]]((Get-X64Rex -B $s.Reg) + @(0x81, (Get-X64ModRm 3 7 ($s.Reg -band 7))) + (& $imm32 $s.Imm)) }
        'test64'       { return [byte[]]((Get-X64Rex -W $true -R $s.Reg -B $s.Reg) + @(0x85, (Get-X64ModRm 3 ($s.Reg -band 7) ($s.Reg -band 7)))) }
        'push'         { return [byte[]]((Get-X64Rex -B $s.Reg) + @([byte](0x50 + ($s.Reg -band 7)))) }
        'pop'          { return [byte[]]((Get-X64Rex -B $s.Reg) + @([byte](0x58 + ($s.Reg -band 7)))) }
        'jz'           { return [byte[]](@(0x0F, 0x84) + (& $imm32 $RipDisplacement)) }
        'jnz'          { return [byte[]](@(0x0F, 0x85) + (& $imm32 $RipDisplacement)) }
        'jae'          { return [byte[]](@(0x0F, 0x83) + (& $imm32 $RipDisplacement)) }
        'jmp'          { return [byte[]](@(0xE9) + (& $imm32 $RipDisplacement)) }
        'call-import'  { return [byte[]](@(0xFF, (Get-X64ModRm 0 2 5)) + (& $imm32 $RipDisplacement)) }
        'call-data'    { return [byte[]](@(0xFF, (Get-X64ModRm 0 2 5)) + (& $imm32 $RipDisplacement)) }
        'ret'          { return [byte[]]@(0xC3) }
        'tail'         { return [byte[]](@(0xFF, (Get-X64ModRm 0 4 5)) + (& $imm32 $RipDisplacement)) }
        default        { throw "Unknown x86-64 step '$($s.Op)'." }
    }
}

function Get-X64StepLength {
    # Every form has a fixed width (rel32 and disp32 throughout), so the length
    # is the length of the encoding with a zero displacement.
    param([Parameter(Mandatory)] $Step)
    ([byte[]]@(New-X64Instruction -Step $Step -RipDisplacement 0)).Length
}

function Read-X64Instruction {
    # Independent decode of the forms above, from the prefix, opcode and ModRM
    # bytes. Register numbers are returned 0-15 with the REX bits applied.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $At)
    $p = $At
    $w = 0; $r = 0; $b = 0
    if (($Image[$p] -band 0xF0) -eq 0x40) { $rex = $Image[$p]; $w = ($rex -shr 3) -band 1; $r = (($rex -shr 2) -band 1) * 8; $b = ($rex -band 1) * 8; $p++ }
    $op = $Image[$p]
    $disp32 = { param([long] $o) [BitConverter]::ToInt32($Image, [int]$o) }
    $modrm = { param([byte] $m) [pscustomobject]@{ Mod = $m -shr 6; Reg = ($m -shr 3) -band 7; Rm = $m -band 7 } }
    $result = { param([hashtable] $h, [long] $end) $h.Length = [int]($end - $At); [pscustomobject]$h }
    $s8 = { param([byte] $v) if ($v -ge 128) { [int]$v - 256 } else { [int]$v } }
    if ($op -ge 0x50 -and $op -le 0x57) { return & $result @{ Op = 'push'; Reg = ($op - 0x50) + $b } ($p + 1) }
    if ($op -ge 0x58 -and $op -le 0x5F) { return & $result @{ Op = 'pop'; Reg = ($op - 0x58) + $b } ($p + 1) }
    if ($op -ge 0xB8 -and $op -le 0xBF -and -not $w) { return & $result @{ Op = 'movimm32'; Dst = ($op - 0xB8) + $b; Imm = (& $disp32 ($p + 1)) } ($p + 5) }
    if ($op -eq 0xC3) { return & $result @{ Op = 'ret' } ($p + 1) }
    if ($op -eq 0xE9) { return & $result @{ Op = 'jmp'; Disp = (& $disp32 ($p + 1)) } ($p + 5) }
    if ($op -eq 0x0F -and $Image[$p + 1] -in 0x83, 0x84, 0x85) {
        $branch = switch ($Image[$p + 1]) { 0x83 { 'jae' } 0x84 { 'jz' } 0x85 { 'jnz' } }
        return & $result @{ Op = $branch; Disp = (& $disp32 ($p + 2)) } ($p + 6)
    }
    $m = & $modrm $Image[$p + 1]
    switch ($op) {
        0x89 {
            if ($m.Mod -eq 3) { return & $result @{ Op = $(if ($w) { 'mov64' } else { 'mov32' }); Dst = $m.Rm + $b; Src = $m.Reg + $r } ($p + 2) }
            if ($m.Mod -eq 1 -and $m.Rm -eq 4 -and $Image[$p + 2] -eq 0x24 -and $w) { return & $result @{ Op = 'store64-rsp'; Src = $m.Reg + $r; Disp = (& $s8 $Image[$p + 3]) } ($p + 4) }
            if ($m.Mod -eq 1 -and $m.Rm -ne 4 -and $w) { return & $result @{ Op = 'store64-base'; Src = $m.Reg + $r; Base = $m.Rm + $b; Disp = (& $s8 $Image[$p + 2]) } ($p + 3) }
        }
        0x8B {
            if ($m.Mod -eq 0 -and $m.Rm -eq 5) { return & $result @{ Op = $(if ($w) { 'load64-rip' } else { 'load32-rip' }); Dst = $m.Reg + $r; Disp = (& $disp32 ($p + 2)) } ($p + 6) }
            if ($m.Mod -eq 1 -and $m.Rm -ne 4 -and $w) { return & $result @{ Op = 'load64-base'; Dst = $m.Reg + $r; Base = $m.Rm + $b; Disp = (& $s8 $Image[$p + 2]) } ($p + 3) }
        }
        0x03 { if ($m.Mod -eq 1 -and $m.Rm -ne 4 -and $w) { return & $result @{ Op = 'add64-base'; Dst = $m.Reg + $r; Base = $m.Rm + $b; Disp = (& $s8 $Image[$p + 2]) } ($p + 3) } }
        0x8D { if ($m.Mod -eq 0 -and $m.Rm -eq 5 -and $w) { return & $result @{ Op = 'lea-rip'; Dst = $m.Reg + $r; Disp = (& $disp32 ($p + 2)) } ($p + 6) } }
        0xC7 { if ($m.Mod -eq 3 -and $m.Reg -eq 0 -and $w) { return & $result @{ Op = 'movimm64s'; Dst = $m.Rm + $b; Imm = (& $disp32 ($p + 2)) } ($p + 6) } }
        0x31 { if ($m.Mod -eq 3) { return & $result @{ Op = 'xor32'; Dst = $m.Rm + $b; Src = $m.Reg + $r } ($p + 2) } }
        0x81 { if ($m.Mod -eq 3 -and $m.Reg -eq 7 -and -not $w) { return & $result @{ Op = 'cmp32-imm'; Reg = $m.Rm + $b; Imm = (& $disp32 ($p + 2)) } ($p + 6) } }
        0x85 { if ($m.Mod -eq 3 -and ($m.Reg + $r) -eq ($m.Rm + $b)) { return & $result @{ Op = $(if ($w) { 'test64' } else { 'test32' }); Reg = $m.Rm + $b } ($p + 2) } }
        0x83 {
            if ($m.Mod -eq 3 -and $w -and $m.Rm -eq 4 -and $b -eq 0 -and ($m.Reg -eq 5 -or $m.Reg -eq 0)) { return & $result @{ Op = $(if ($m.Reg -eq 5) { 'sub-rsp' } else { 'add-rsp' }); Imm = [int]$Image[$p + 2] } ($p + 3) }
            if ($m.Mod -eq 3 -and $w -and $m.Reg -eq 0) { return & $result @{ Op = 'add64-imm8'; Dst = $m.Rm + $b; Imm = (& $s8 $Image[$p + 2]) } ($p + 3) }
        }
        0xFF {
            if ($m.Mod -eq 0 -and $m.Rm -eq 5 -and $m.Reg -eq 2) { return & $result @{ Op = 'call-rip'; Disp = (& $disp32 ($p + 2)) } ($p + 6) }
            if ($m.Mod -eq 0 -and $m.Rm -eq 5 -and $m.Reg -eq 4) { return & $result @{ Op = 'jmp-rip'; Disp = (& $disp32 ($p + 2)) } ($p + 6) }
        }
    }
    throw ('Unrecognized x86-64 instruction at {0}: 0x{1:X2}.' -f $At, $op)
}

function New-X64Step {
    # Bytes for one step at Pc. Target is the resolved address of the step's
    # Import GOT slot, Data label or branch Label.
    param([Parameter(Mandatory)] $Step, [long] $Pc, [long] $Target)
    $next = $Pc + (Get-X64StepLength -Step $Step)
    $relative = $Step.Op -in 'tail', 'lea-data', 'load64-data', 'load32-data', 'load-got', 'call-import', 'call-data', 'jz', 'jnz', 'jae', 'jmp'
    $displacement = if ($relative) { $Target - $next } else { 0 }
    if ($displacement -lt [int32]::MinValue -or $displacement -gt [int32]::MaxValue) { throw "x86-64 step '$($Step.Op)' target is out of rel32 range." }
    # @() keeps a one-byte instruction an array; PowerShell unrolls it otherwise.
    [byte[]]@(New-X64Instruction -Step $Step -RipDisplacement $displacement)
}

function Test-X64Step {
    # Decodes the step at Pc with Read-X64Instruction and checks it against the
    # intended step. Returns the step's length.
    param([Parameter(Mandatory)][byte[]] $Image, [Parameter(Mandatory)][long] $Pc, [Parameter(Mandatory)] $Step,
          $DataAt, $SlotImport, [hashtable] $Labels, [string] $Name)
    if ($Step.Op -eq 'label') {
        if ($Labels -and $Labels[$Step.Name] -ne $Pc) { throw "$Name label '$($Step.Name)' is at $($Labels[$Step.Name]), expected $Pc." }
        return 0
    }
    $d = Read-X64Instruction -Image $Image -At $Pc
    $next = $Pc + $d.Length
    $ok = switch ($Step.Op) {
        'mov32'        { $d.Op -eq 'mov32' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Src }
        'mov64'        { $d.Op -eq 'mov64' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Src }
        'movimm32'     { $d.Op -eq 'movimm32' -and $d.Dst -eq $Step.Dst -and $d.Imm -eq $Step.Imm }
        'movimm64s'    { $d.Op -eq 'movimm64s' -and $d.Dst -eq $Step.Dst -and $d.Imm -eq $Step.Imm }
        'xor32'        { $d.Op -eq 'xor32' -and $d.Dst -eq $Step.Dst -and $d.Src -eq $Step.Dst }
        'lea-data'     { $d.Op -eq 'lea-rip' -and $d.Dst -eq $Step.Dst -and ($next + $d.Disp) -eq $DataAt[$Step.Data] }
        'load64-data'  { $d.Op -eq 'load64-rip' -and $d.Dst -eq $Step.Dst -and ($next + $d.Disp) -eq $DataAt[$Step.Data] }
        'load32-data'  { $d.Op -eq 'load32-rip' -and $d.Dst -eq $Step.Dst -and ($next + $d.Disp) -eq $DataAt[$Step.Data] }
        'load-got'     { $d.Op -eq 'load64-rip' -and $d.Dst -eq $Step.Dst -and $SlotImport[[long]($next + $d.Disp)] -ceq $Step.Import }
        'load64-base'  { $d.Op -eq 'load64-base' -and $d.Dst -eq $Step.Dst -and $d.Base -eq $Step.Base -and $d.Disp -eq $Step.Disp }
        'store64-base' { $d.Op -eq 'store64-base' -and $d.Src -eq $Step.Src -and $d.Base -eq $Step.Base -and $d.Disp -eq $Step.Disp }
        'add64-base'   { $d.Op -eq 'add64-base' -and $d.Dst -eq $Step.Dst -and $d.Base -eq $Step.Base -and $d.Disp -eq $Step.Disp }
        'store64-rsp'  { $d.Op -eq 'store64-rsp' -and $d.Src -eq $Step.Src -and $d.Disp -eq $Step.Disp }
        'sub-rsp'      { $d.Op -eq 'sub-rsp' -and $d.Imm -eq $Step.Imm }
        'add-rsp'      { $d.Op -eq 'add-rsp' -and $d.Imm -eq $Step.Imm }
        'add64-imm8'   { $d.Op -eq 'add64-imm8' -and $d.Dst -eq $Step.Dst -and $d.Imm -eq $Step.Imm }
        'test32'       { $d.Op -eq 'test32' -and $d.Reg -eq $Step.Reg }
        'cmp32-imm'    { $d.Op -eq 'cmp32-imm' -and $d.Reg -eq $Step.Reg -and $d.Imm -eq $Step.Imm }
        'test64'       { $d.Op -eq 'test64' -and $d.Reg -eq $Step.Reg }
        'push'         { $d.Op -eq 'push' -and $d.Reg -eq $Step.Reg }
        'pop'          { $d.Op -eq 'pop' -and $d.Reg -eq $Step.Reg }
        { $_ -in 'jz', 'jnz', 'jae', 'jmp' } { $d.Op -eq $Step.Op -and ($next + $d.Disp) -eq $Labels[$Step.Label] }
        'call-import'  { $d.Op -eq 'call-rip' -and $SlotImport[[long]($next + $d.Disp)] -ceq $Step.Import }
        'call-data'    { $d.Op -eq 'call-rip' -and ($next + $d.Disp) -eq $DataAt[$Step.Data] }
        'ret'          { $d.Op -eq 'ret' }
        'tail'         { $d.Op -eq 'jmp-rip' -and $SlotImport[[long]($next + $d.Disp)] -ceq $Step.Import }
    }
    if (-not $ok) { throw "$Name at ${Pc}: expected $($Step.Op), decoded $($d.Op)." }
    $d.Length
}

function Test-X64CallAbi {
    <#
        Checks a step program against the System V AMD64 calling convention
        before it is encoded, over its control-flow graph rather than its text
        order. Blocks start at the entry, at labels, and after branches, ret and
        tail; state flows along every edge to a fixed point:
        - stack depth below entry (8 at entry: the return address) must agree
          at every join, and be 16-aligned at every call and 8 at ret and tail;
        - the registers definitely written are intersected at joins; a call
          keeps only callee-saved registers and then defines rax (its result);
        - stack-argument slots stored at [rsp] are intersected at joins and
          consumed by a call;
        - a call's declared argument registers and stack slots must be
          definitely written; a variadic call must follow xor eax, eax in the
          same block;
        - callee-saved registers (rbx rbp r12-r15) the function writes must be
          pushed in its prologue and popped in reverse order immediately before
          every exit (ret or tail); labels must be defined once, branch targets must
          exist, and every block must be reachable.
        OutgoingSlots tracks only outgoing stack-argument slots, which a call
        consumes. Frame locals that survive calls would need a separate set.
    #>
    param([Parameter(Mandatory)][object[]] $Steps, [int] $Parameters = 0, [string] $Name = 'function')

    $argumentRegisters = @(7, 6, 2, 1, 8, 9)
    $calleeSaved = @(3, 5, 12, 13, 14, 15)
    $branches = @('jz', 'jnz', 'jae', 'jmp')
    $labelIndex = @{}
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') {
            if ($labelIndex.ContainsKey($Steps[$i]['Name'])) { throw "$Name defines label '$($Steps[$i]['Name'])' twice." }
            $labelIndex[$Steps[$i]['Name']] = $i
        }
    }
    foreach ($step in $Steps) {
        if ($step['Op'] -in $branches -and -not $labelIndex.ContainsKey($step['Label'])) { throw "$Name branches to undefined label '$($step['Label'])'." }
    }

    # Prologue: the leading pushes (mov rbp, rsp may sit among them).
    $saved = [System.Collections.Generic.List[int]]::new()
    foreach ($step in $Steps) {
        if ($step['Op'] -eq 'push') { $saved.Add($step['Reg']); continue }
        if ($step['Op'] -eq 'mov64' -and $step['Dst'] -eq 5 -and $step['Src'] -eq 4) { continue }
        break
    }
    $prologueEnd = 0
    while ($prologueEnd -lt $Steps.Count -and ($Steps[$prologueEnd]['Op'] -eq 'push' -or ($Steps[$prologueEnd]['Op'] -eq 'mov64' -and $Steps[$prologueEnd]['Dst'] -eq 5 -and $Steps[$prologueEnd]['Src'] -eq 4))) { $prologueEnd++ }
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        $step = $Steps[$i]
        $dst = if ($step['Op'] -in 'push', 'pop') { $null } else { $step['Dst'] }
        if ($null -ne $dst -and $dst -in $calleeSaved -and $dst -notin $saved) { throw "$Name writes callee-saved register $dst without saving it in its prologue." }
        if ($step['Op'] -in 'ret', 'tail') {
            $j = $i - 1
            foreach ($reg in $saved) {
                while ($j -ge 0 -and $Steps[$j]['Op'] -eq 'label') { $j-- }
                if ($j -lt 0 -or $Steps[$j]['Op'] -ne 'pop' -or $Steps[$j]['Reg'] -ne $reg) { throw "$Name exits without popping register $reg in reverse push order." }
                $j--
            }
        }
    }

    # Basic blocks.
    $leaders = [System.Collections.Generic.SortedSet[int]]::new()
    [void]$leaders.Add(0)
    for ($i = 0; $i -lt $Steps.Count; $i++) {
        if ($Steps[$i]['Op'] -eq 'label') { [void]$leaders.Add($i) }
        if ($Steps[$i]['Op'] -in ($branches + @('ret', 'tail')) -and $i + 1 -lt $Steps.Count) { [void]$leaders.Add($i + 1) }
    }
    $starts = @($leaders)
    $blockOf = @{}
    for ($b = 0; $b -lt $starts.Count; $b++) {
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        for ($i = $starts[$b]; $i -lt $end; $i++) { $blockOf[$i] = $b }
    }

    $copy = { param($s) [pscustomobject]@{ Depth = $s.Depth; Written = [System.Collections.Generic.HashSet[int]]::new($s.Written); OutgoingSlots = [System.Collections.Generic.HashSet[int]]::new($s.OutgoingSlots) } }
    $entry = [pscustomobject]@{ Depth = 8; Written = [System.Collections.Generic.HashSet[int]]::new(); OutgoingSlots = [System.Collections.Generic.HashSet[int]]::new() }
    for ($a = 0; $a -lt $Parameters; $a++) { [void]$entry.Written.Add($argumentRegisters[$a]) }
    $inState = @{ 0 = $entry }
    $queue = [System.Collections.Generic.Queue[int]]::new(); $queue.Enqueue(0)
    $flow = {
        param([int] $target, $state)
        if (-not $inState.ContainsKey($target)) { $inState[$target] = & $copy $state; $queue.Enqueue($target); return }
        $current = $inState[$target]
        if ($current.Depth -ne $state.Depth) { throw "$Name reaches block $target with stack depths $($current.Depth) and $($state.Depth)." }
        $before = $current.Written.Count + $current.OutgoingSlots.Count
        $current.Written.IntersectWith($state.Written)
        $current.OutgoingSlots.IntersectWith($state.OutgoingSlots)
        if ($current.Written.Count + $current.OutgoingSlots.Count -ne $before) { $queue.Enqueue($target) }
    }
    $guard = 0
    while ($queue.Count -gt 0) {
        if (++$guard -gt 10000) { throw "${Name}: control-flow analysis did not converge." }
        $b = $queue.Dequeue()
        $state = & $copy $inState[$b]
        $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
        $previous = $null
        $fallsThrough = $true
        for ($i = $starts[$b]; $i -lt $end; $i++) {
            $step = $Steps[$i]
            $op = $step['Op']
            switch ($op) {
                'label'       { continue }
                'push'        { $state.Depth += 8 }
                'pop'         { $state.Depth -= 8; [void]$state.Written.Add($step['Reg']) }
                'sub-rsp'     { $state.Depth += $step['Imm'] }
                'add-rsp'     { $state.Depth -= $step['Imm'] }
                'store64-rsp' { [void]$state.OutgoingSlots.Add($step['Disp']) }
                { $_ -in 'call-import', 'call-data' } {
                    $callee = "$($step['Import'])$($step['Data'])"
                    if ($state.Depth % 16 -ne 0) { throw "$Name calls $callee with the stack $($state.Depth) bytes below entry, not 16-byte aligned." }
                    for ($a = 0; $a -lt [int]$step['Args']; $a++) {
                        if (-not $state.Written.Contains($argumentRegisters[$a])) { throw "$Name calls $callee without setting argument $($a + 1) on every path." }
                    }
                    for ($k = 0; $k -lt [int]$step['StackArgs']; $k++) {
                        if (-not $state.OutgoingSlots.Contains(8 * $k)) { throw "$Name calls $callee without storing stack argument $($k + 1) at [rsp+$(8 * $k)] on every path." }
                    }
                    if ($step['Variadic'] -and -not ($null -ne $previous -and $previous['Op'] -eq 'xor32' -and $previous['Dst'] -eq 0)) { throw "$Name makes the variadic call $callee without clearing eax immediately before it." }
                    $state.Written.IntersectWith([int[]]$calleeSaved)
                    [void]$state.Written.Add(0)
                    $state.OutgoingSlots.Clear()
                }
                { $_ -in 'ret', 'tail' } {
                    if ($state.Depth -ne 8) { throw "$Name leaves with the stack $($state.Depth) bytes below entry; it must be 8." }
                    $fallsThrough = $false
                }
                { $_ -in 'jz', 'jnz', 'jae' } { & $flow $blockOf[$labelIndex[$step['Label']]] $state }
                'jmp' { & $flow $blockOf[$labelIndex[$step['Label']]] $state; $fallsThrough = $false }
                default { if ($null -ne $step['Dst']) { [void]$state.Written.Add($step['Dst']) } }
            }
            if ($op -ne 'label') { $previous = $step }
        }
        if ($fallsThrough -and $b + 1 -lt $starts.Count) { & $flow ($b + 1) $state }
        if ($fallsThrough -and $b + 1 -ge $starts.Count) { throw "$Name runs off its end without ret or tail." }
    }
    for ($b = 0; $b -lt $starts.Count; $b++) {
        if (-not $inState.ContainsKey($b)) {
            $end = if ($b + 1 -lt $starts.Count) { $starts[$b + 1] } else { $Steps.Count }
            $code = @($Steps[$starts[$b]..($end - 1)] | Where-Object { $_['Op'] -ne 'label' })
            if ($code.Count) { throw "$Name has unreachable code at step $($starts[$b])." }
        }
    }
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
          $DataAt, $SlotImport, [hashtable] $Labels, [string] $Name)
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

function Get-HostRuntimeContractLayout {
    # struct host_runtime_contract in lib/host_runtime_contract.h: every member
    # is size_t, a pointer or a function pointer, so each is one pointer wide
    # and a member's offset is its position times the pointer size.
    param([Parameter(Mandatory)][int] $PointerSize)
    $text = Import-LibSourceText -Path 'host_runtime_contract.h'
    $match = [regex]::Match($text, '(?s)struct host_runtime_contract\s*\{(.*?)\n\};')
    if (-not $match.Success) { throw 'host_runtime_contract.h does not declare struct host_runtime_contract.' }
    $body = [regex]::Replace($match.Groups[1].Value, '//[^\n]*', '')
    $members = [System.Collections.Generic.List[string]]::new()
    foreach ($m in [regex]::Matches($body, '(?s)\(\s*HOST_CONTRACT_CALLTYPE\s*\*\s*(\w+)\s*\)\s*\(.*?\);|(?m)^\s*(?:size_t|void\s*\*)\s*(\w+)\s*;')) {
        $members.Add($(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }))
    }
    if ($members[0] -cne 'size' -or 'external_assembly_probe' -cnotin $members) { throw "host_runtime_contract members parsed as: $($members -join ', ')." }
    $offsets = [ordered]@{}
    for ($i = 0; $i -lt $members.Count; $i++) { $offsets[$members[$i]] = $i * $PointerSize }
    [pscustomobject]@{ Size = $members.Count * $PointerSize; Offsets = $offsets; Members = @($members) }
}

function Get-NativeActivityFieldOffset {
    # The offset of a field of ANativeActivity (lib/native_activity.h), with
    # C natural alignment: pointers and jobject (a JNI reference the size of a
    # pointer, jni.h) are PointerSize wide and aligned; int32_t is 4 wide and
    # aligned. Any other member type before the field throws.
    param([Parameter(Mandatory)][string] $Field, [Parameter(Mandatory)][ValidateSet(4, 8)][int] $PointerSize)
    $text = [System.Text.Encoding]::UTF8.GetString((Import-LibSourceBytes -Path 'native_activity.h'))
    $body = [regex]::Match($text, 'typedef struct ANativeActivity \{(.*?)\} ANativeActivity;', 'Singleline')
    if (-not $body.Success) { throw 'native_activity.h does not declare ANativeActivity.' }
    $offset = 0
    foreach ($line in ($body.Groups[1].Value -split "`n")) {
        $member = [regex]::Match($line, '^\s*(?<type>[A-Za-z_][\w\s]*?\*?)\s*(?<name>\w+);\s*$')
        if (-not $member.Success) { continue }
        $type = $member.Groups['type'].Value.Trim()
        $size = if ($type -match '\*$' -or $type -ceq 'jobject') { $PointerSize } elseif ($type -ceq 'int32_t') { 4 } else {
            throw "ANativeActivity.$($member.Groups['name'].Value), before or at $Field, has unsupported type '$type'." }
        $offset = ($offset + $size - 1) -band -$size
        if ($member.Groups['name'].Value -ceq $Field) { return $offset }
        $offset += $size
    }
    throw "ANativeActivity has no field '$Field'."
}

function New-NativeHostLibrary {
    <#
        Gate 2a: libpwsh-host.so owns CoreCLR start-up. ANativeActivity_onCreate
        (lib/native_activity.h) builds three runtime properties the way the
        pinned .NET for Android host does (HOST_RUNTIME_CONTRACT formatted with
        snprintf "%p", RUNTIME_IDENTIFIER, APP_CONTEXT_BASE_DIRECTORY as
        internalDataPath plus "/"), calls coreclr_initialize and
        coreclr_create_delegate (lib/coreclrhost.h) for
        Dev.MansfieldPlumbing.Pwsh.NativeHost.Admit, calls it, and logs what it
        returns. The contract's external_assembly_probe
        (lib/host_runtime_contract.h) is pwsh_assembly_probe: a linear strcmp
        walk over a table of the store's own entries, returning a pointer into
        the mapped store. libcoreclr.so and the store library are DT_NEEDED, so
        the linker loads them and both resolve through the GOT.
    #>
    param(
        [Parameter(Mandatory)][object[]] $StoreEntries,
        [Parameter(Mandatory)][string] $StoreLibrary,
        [Parameter(Mandatory)][string] $StoreSymbol,
        [int] $PageSize = 16384
    )
    # Pointer-sized fields follow the target: 4 bytes on arm32, 8 elsewhere.
    $ps = if ($script:Target.ElfClass -eq 32) { 4 } else { 8 }
    $pointerBytes = { param([long] $Value) [byte[]]([BitConverter]::GetBytes([uint64]$Value)[0..($ps - 1)]) }

    $info = Get-AndroidLogPriority -Name 'ANDROID_LOG_INFO'
    $errorPriority = Get-AndroidLogPriority -Name 'ANDROID_LOG_ERROR'
    $ascii = { param([string] $s) [System.Text.Encoding]::ASCII.GetBytes("$s`0") }
    $data = [ordered]@{
        fmtDirectory = & $ascii '%s/'
        fmtPointer   = & $ascii '%p'
        packageName  = & $ascii $script:PackageName
        domainName   = & $ascii 'Pwsh'
        keyContract  = & $ascii 'HOST_RUNTIME_CONTRACT'
        keyRid       = & $ascii 'RUNTIME_IDENTIFIER'
        keyBase      = & $ascii 'APP_CONTEXT_BASE_DIRECTORY'
        rid          = & $ascii $script:Target.Rid
        assemblyName = & $ascii $script:ManagedNamespace
        typeName     = & $ascii "$($script:ManagedNamespace).NativeHost"
        methodName   = & $ascii 'Admit'
        tag          = & $ascii 'Pwsh'
        fmtAdmit     = & $ascii 'GATE2A Admit returned 0x%08x'
        fmtInit      = & $ascii 'GATE2A coreclr_initialize failed 0x%08x'
        fmtDelegate  = & $ascii 'GATE2A coreclr_create_delegate failed 0x%08x'
        fmtDirectory2 = & $ascii 'GATE2A base directory does not fit (%d)'
        fmtContract  = & $ascii 'GATE2A contract pointer does not fit (%d)'
    }
    if ($TraceAssemblyProbe) {
        if ($Architecture -ne 'x64') { throw '-TraceAssemblyProbe is implemented for x86_64 only.' }
        $data['fmtProbeRequest'] = & $ascii 'PROBE request: %s'
        $data['fmtProbeHit'] = & $ascii 'PROBE hit:     %s'
        $data['fmtProbeMiss'] = & $ascii 'PROBE miss:    %s'
    }
    if ($Architecture -in 'x64', 'arm64', 'arm32') {
        # Gates 2b/2c: after Admit holds, the host calls RunPowerShell.
        $data['runMethodName'] = & $ascii 'RunPowerShell'
        $data['fmtAdmitWrong'] = & $ascii 'GATE2A Admit returned 0x%08x, expected 0x50575348'
        $data['fmtRunDelegate'] = & $ascii 'GATE2B coreclr_create_delegate RunPowerShell failed 0x%08x'
        $data['fmtBegin'] = & $ascii 'GATE2B begin'
        $data['fmtRun'] = & $ascii 'GATE2B RunPowerShell returned 0x%08x'
    }
    for ($i = 0; $i -lt $StoreEntries.Count; $i++) { $data["assembly$i"] = & $ascii $StoreEntries[$i].Name }

    # host_runtime_contract, laid out from the pinned header: zero except its
    # size and external_assembly_probe.
    $layout = Get-HostRuntimeContractLayout -PointerSize $ps
    $contract = [byte[]]::new($layout.Size)
    [System.Array]::Copy((& $pointerBytes $layout.Size), 0, $contract, $layout.Offsets['size'], $ps)
    $probeOffset = $layout.Offsets['external_assembly_probe']
    # The probe table: name pointer, data offset in the store, data size, each
    # pointer-sized; a zero name pointer ends it.
    $record = 3 * $ps
    $table = [byte[]]::new($record * ($StoreEntries.Count + 1))
    $tablePointers = for ($i = 0; $i -lt $StoreEntries.Count; $i++) {
        [System.Array]::Copy((& $pointerBytes $StoreEntries[$i].Offset), 0, $table, $record * $i + $ps, $ps)
        [System.Array]::Copy((& $pointerBytes $StoreEntries[$i].Size), 0, $table, $record * $i + 2 * $ps, $ps)
        @{ At = $record * $i; Target = "assembly$i" }
    }
    $writable = [ordered]@{
        baseDirectory = [byte[]]::new(512)
        contractText  = [byte[]]::new(32)
        hostHandle    = [byte[]]::new($ps)
        domainId      = [byte[]]::new(8)
        admit         = [byte[]]::new($ps)
        propertyKeys   = @{ Bytes = [byte[]]::new(3 * $ps); Pointers = @(@{ At = 0; Target = 'keyContract' }, @{ At = $ps; Target = 'keyRid' }, @{ At = 2 * $ps; Target = 'keyBase' }) }
        propertyValues = @{ Bytes = [byte[]]::new(3 * $ps); Pointers = @(@{ At = 0; Target = 'contractText' }, @{ At = $ps; Target = 'rid' }, @{ At = 2 * $ps; Target = 'baseDirectory' }) }
        contract      = @{ Bytes = $contract; Pointers = @(@{ At = $probeOffset; Target = 'pwsh_assembly_probe' }) }
        probeTable    = @{ Bytes = $table; Pointers = @($tablePointers) }
    }
    $writable['runPowerShell'] = [byte[]]::new($ps)
    if ($Architecture -eq 'arm64') {
        # 2^32 - 0x50575348. CMP (immediate) holds 12 bits, so the A64 host adds
        # this to Admit's result and tests the low word for zero instead.
        $writable['admitComplement'] = [BitConverter]::GetBytes([uint64]([uint64]0x100000000 - 0x50575348))
    }

    if ($Architecture -eq 'arm64') {
    # AAPCS64: arguments x0-x7 (all seven coreclr_initialize arguments fit),
    # result w0/x0, x19-x28 callee-saved, x29 frame, x30 link, x16 scratch for
    # calls through the GOT, x18 reserved. Variadic calls need no extra setup.
    $logFailure = { param([string] $label, [string] $format) @(
        @{ Op = 'label'; Name = $label },
        @{ Op = 'mov'; Rd = 3; Rm = 0; Is64 = $false },
        @{ Op = 'movz'; Rd = 0; Imm = $errorPriority; Is64 = $false },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = $format },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        @{ Op = 'b'; Label = 'done' }) }
    $onCreate = @(
        @{ Op = 'stp-pre'; Rt = 29; Rt2 = 30; Offset = -32 },
        @{ Op = 'add-imm'; Rd = 29; Rn = 31; Imm = 0 },
        @{ Op = 'stp'; Rt = 19; Rt2 = 20; Offset = 16 },
        @{ Op = 'mov'; Rd = 19; Rm = 0; Is64 = $true },                  # x19 = activity
        # snprintf(baseDirectory, 512, "%s/", activity->internalDataPath)
        @{ Op = 'lea-data'; Rd = 0; Data = 'baseDirectory' },
        @{ Op = 'movz'; Rd = 1; Imm = 512; Is64 = $true },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtDirectory' },
        @{ Op = 'ldr64'; Rt = 3; Rn = 19; Offset = 32 },                  # ANativeActivity: callbacks, vm, env, clazz, internalDataPath
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'cmp-imm32'; Rn = 0; Imm = 512 },
        @{ Op = 'b.hs'; Label = 'directoryFailed' },
        # snprintf(contractText, 32, "%p", &contract)
        @{ Op = 'lea-data'; Rd = 0; Data = 'contractText' },
        @{ Op = 'movz'; Rd = 1; Imm = 32; Is64 = $true },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtPointer' },
        @{ Op = 'lea-data'; Rd = 3; Data = 'contract' },
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'cmp-imm32'; Rn = 0; Imm = 32 },
        @{ Op = 'b.hs'; Label = 'contractFailed' },
        # coreclr_initialize(package, "Pwsh", 3, keys, values, &hostHandle, &domainId)
        @{ Op = 'lea-data'; Rd = 0; Data = 'packageName' },
        @{ Op = 'lea-data'; Rd = 1; Data = 'domainName' },
        @{ Op = 'movz'; Rd = 2; Imm = 3; Is64 = $false },
        @{ Op = 'lea-data'; Rd = 3; Data = 'propertyKeys' },
        @{ Op = 'lea-data'; Rd = 4; Data = 'propertyValues' },
        @{ Op = 'lea-data'; Rd = 5; Data = 'hostHandle' },
        @{ Op = 'lea-data'; Rd = 6; Data = 'domainId' },
        @{ Op = 'call-import'; Import = 'coreclr_initialize'; Args = 7 },
        @{ Op = 'cbnz'; Rt = 0; Is64 = $false; Label = 'initFailed' },
        # coreclr_create_delegate(hostHandle, domainId, "Pwsh", type, "Admit", &admit)
        @{ Op = 'load64-data'; Rd = 0; Data = 'hostHandle' },
        @{ Op = 'load32-data'; Rd = 1; Data = 'domainId' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'assemblyName' },
        @{ Op = 'lea-data'; Rd = 3; Data = 'typeName' },
        @{ Op = 'lea-data'; Rd = 4; Data = 'methodName' },
        @{ Op = 'lea-data'; Rd = 5; Data = 'admit' },
        @{ Op = 'call-import'; Import = 'coreclr_create_delegate'; Args = 6 },
        @{ Op = 'cbnz'; Rt = 0; Is64 = $false; Label = 'delegateFailed' },
        # Admit(); __android_log_print(INFO, "Pwsh", "GATE2A Admit returned 0x%08x", result)
        @{ Op = 'call-data'; Data = 'admit'; Args = 0 },
        # w1 = w0 + (2^32 - magic): zero exactly when Admit returned the magic.
        @{ Op = 'load32-data'; Rd = 1; Data = 'admitComplement' },
        @{ Op = 'add-reg'; Rd = 1; Rn = 0; Rm = 1 },
        @{ Op = 'cbnz'; Rt = 1; Is64 = $false; Label = 'admitWrong' },
        @{ Op = 'mov'; Rd = 3; Rm = 0; Is64 = $false },
        @{ Op = 'movz'; Rd = 0; Imm = $info; Is64 = $false },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtAdmit' },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        # Gates 2b/2c, only after gate 2a held in this process:
        # coreclr_create_delegate(hostHandle, domainId, "Pwsh", type, "RunPowerShell", &runPowerShell)
        @{ Op = 'load64-data'; Rd = 0; Data = 'hostHandle' },
        @{ Op = 'load32-data'; Rd = 1; Data = 'domainId' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'assemblyName' },
        @{ Op = 'lea-data'; Rd = 3; Data = 'typeName' },
        @{ Op = 'lea-data'; Rd = 4; Data = 'runMethodName' },
        @{ Op = 'lea-data'; Rd = 5; Data = 'runPowerShell' },
        @{ Op = 'call-import'; Import = 'coreclr_create_delegate'; Args = 6 },
        @{ Op = 'cbnz'; Rt = 0; Is64 = $false; Label = 'runDelegateFailed' },
        # Log the gate boundary, then RunPowerShell(activity); log its result.
        @{ Op = 'movz'; Rd = 0; Imm = $info; Is64 = $false },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtBegin' },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 3; Variadic = $true },
        @{ Op = 'mov'; Rd = 0; Rm = 19; Is64 = $true }, # borrowed ANativeActivity*
        @{ Op = 'call-data'; Data = 'runPowerShell'; Args = 1 },
        @{ Op = 'mov'; Rd = 3; Rm = 0; Is64 = $false },
        @{ Op = 'movz'; Rd = 0; Imm = $info; Is64 = $false },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtRun' },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        @{ Op = 'b'; Label = 'done' }
    ) + (& $logFailure 'directoryFailed' 'fmtDirectory2') + (& $logFailure 'contractFailed' 'fmtContract') + (& $logFailure 'initFailed' 'fmtInit') + (& $logFailure 'delegateFailed' 'fmtDelegate') +
        (& $logFailure 'admitWrong' 'fmtAdmitWrong') + (& $logFailure 'runDelegateFailed' 'fmtRunDelegate') + @(
        @{ Op = 'label'; Name = 'done' },
        @{ Op = 'ldp'; Rt = 19; Rt2 = 20; Offset = 16 },
        @{ Op = 'ldp-post'; Rt = 29; Rt2 = 30; Offset = 32 },
        @{ Op = 'ret' })

    # bool pwsh_assembly_probe(const char* path, void** data_start, int64_t* size)
    $probe = @(
        @{ Op = 'stp-pre'; Rt = 29; Rt2 = 30; Offset = -48 },
        @{ Op = 'add-imm'; Rd = 29; Rn = 31; Imm = 0 },
        @{ Op = 'stp'; Rt = 19; Rt2 = 20; Offset = 16 },
        @{ Op = 'stp'; Rt = 21; Rt2 = 22; Offset = 32 },
        @{ Op = 'mov'; Rd = 19; Rm = 0; Is64 = $true },
        @{ Op = 'mov'; Rd = 20; Rm = 1; Is64 = $true },
        @{ Op = 'mov'; Rd = 21; Rm = 2; Is64 = $true },
        @{ Op = 'lea-data'; Rd = 22; Data = 'probeTable' },
        @{ Op = 'label'; Name = 'next' },
        @{ Op = 'ldr64'; Rt = 1; Rn = 22; Offset = 0 },
        @{ Op = 'cbz'; Rt = 1; Is64 = $true; Label = 'missing' },
        @{ Op = 'mov'; Rd = 0; Rm = 19; Is64 = $true },
        @{ Op = 'call-import'; Import = 'strcmp'; Args = 2 },
        @{ Op = 'cbz'; Rt = 0; Is64 = $false; Label = 'found' },
        @{ Op = 'add-imm'; Rd = 22; Rn = 22; Imm = 24 },
        @{ Op = 'b'; Label = 'next' },
        @{ Op = 'label'; Name = 'found' },
        @{ Op = 'load-got'; Rd = 0; Import = $StoreSymbol },
        @{ Op = 'ldr64'; Rt = 1; Rn = 22; Offset = 8 },
        @{ Op = 'add-reg'; Rd = 0; Rn = 0; Rm = 1 },
        @{ Op = 'str64'; Rt = 0; Rn = 20; Offset = 0 },
        @{ Op = 'ldr64'; Rt = 1; Rn = 22; Offset = 16 },
        @{ Op = 'str64'; Rt = 1; Rn = 21; Offset = 0 },
        @{ Op = 'movz'; Rd = 0; Imm = 1; Is64 = $false },
        @{ Op = 'b'; Label = 'out' },
        @{ Op = 'label'; Name = 'missing' },
        @{ Op = 'movz'; Rd = 0; Imm = 0; Is64 = $false },
        @{ Op = 'label'; Name = 'out' },
        @{ Op = 'ldp'; Rt = 21; Rt2 = 22; Offset = 32 },
        @{ Op = 'ldp'; Rt = 19; Rt2 = 20; Offset = 16 },
        @{ Op = 'ldp-post'; Rt = 29; Rt2 = 30; Offset = 48 },
        @{ Op = 'ret' })

    Test-A64CallAbi -Steps $onCreate -Parameters 3 -Name 'ANativeActivity_onCreate'
    Test-A64CallAbi -Steps $probe -Parameters 3 -Name 'pwsh_assembly_probe'
    }
    elseif ($Architecture -eq 'arm32') {
    # AAPCS32 in Thumb-2: arguments r0-r3 then [sp], [sp, #4], ...; result r0;
    # r4-r11 callee-saved; r12 scratch for calls through the GOT; sp 8-byte
    # aligned at calls. push {r4-r6, lr} and a 16-byte outgoing area keep sp
    # aligned and hold up to three stacked arguments (coreclr_initialize has
    # seven, coreclr_create_delegate six).
    $internalDataPath = Get-NativeActivityFieldOffset -Field 'internalDataPath' -PointerSize $ps
    $logFailure = { param([string] $label, [string] $format) @(
        @{ Op = 'label'; Name = $label },
        @{ Op = 'mov'; Rd = 3; Rm = 0 },
        @{ Op = 'movs'; Rd = 0; Imm = $errorPriority },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = $format },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        @{ Op = 'b'; Label = 'done' }) }
    $logInfo = { param([string] $format, [bool] $withValue) @(
        if ($withValue) { @{ Op = 'mov'; Rd = 3; Rm = 0 } }
        @{ Op = 'movs'; Rd = 0; Imm = $info },
        @{ Op = 'lea-data'; Rd = 1; Data = 'tag' },
        @{ Op = 'lea-data'; Rd = 2; Data = $format },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = $(if ($withValue) { 4 } else { 3 }); Variadic = $true }) }
    # coreclr_create_delegate(*hostHandle, *domainId, "Pwsh", type, method, slot)
    $createDelegate = { param([string] $method, [string] $slot, [string] $failed) @(
        @{ Op = 'lea-data'; Rd = 0; Data = $method },
        @{ Op = 'str'; Rt = 0; Rn = 13; Offset = 0 },
        @{ Op = 'lea-data'; Rd = 0; Data = $slot },
        @{ Op = 'str'; Rt = 0; Rn = 13; Offset = 4 },
        @{ Op = 'load-data'; Rd = 0; Data = 'hostHandle' },
        @{ Op = 'load-data'; Rd = 1; Data = 'domainId' },
        @{ Op = 'lea-data'; Rd = 2; Data = 'assemblyName' },
        @{ Op = 'lea-data'; Rd = 3; Data = 'typeName' },
        @{ Op = 'call-import'; Import = 'coreclr_create_delegate'; Args = 6 },
        @{ Op = 'cmp-imm'; Rn = 0; Imm = 0 },
        @{ Op = 'bne'; Label = $failed }) }
    $onCreate = @(
        @{ Op = 'push'; Registers = @(4, 5, 6, 14) },
        @{ Op = 'sub-sp'; Imm = 16 },
        @{ Op = 'mov'; Rd = 4; Rm = 0 },                                  # r4 = activity
        # snprintf(baseDirectory, 512, "%s/", activity->internalDataPath)
        @{ Op = 'lea-data'; Rd = 0; Data = 'baseDirectory' },
        @{ Op = 'movw'; Rd = 1; Imm = 512 },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtDirectory' },
        @{ Op = 'ldr'; Rt = 3; Rn = 4; Offset = $internalDataPath },
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'movw'; Rd = 1; Imm = 512 },
        @{ Op = 'cmp'; Rn = 0; Rm = 1 },
        @{ Op = 'bhs'; Label = 'directoryFailed' },
        # snprintf(contractText, 32, "%p", &contract)
        @{ Op = 'lea-data'; Rd = 0; Data = 'contractText' },
        @{ Op = 'movs'; Rd = 1; Imm = 32 },
        @{ Op = 'lea-data'; Rd = 2; Data = 'fmtPointer' },
        @{ Op = 'lea-data'; Rd = 3; Data = 'contract' },
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'cmp-imm'; Rn = 0; Imm = 32 },
        @{ Op = 'bhs'; Label = 'contractFailed' },
        # coreclr_initialize(package, "Pwsh", 3, keys, values, &hostHandle, &domainId)
        @{ Op = 'lea-data'; Rd = 0; Data = 'propertyValues' },
        @{ Op = 'str'; Rt = 0; Rn = 13; Offset = 0 },
        @{ Op = 'lea-data'; Rd = 0; Data = 'hostHandle' },
        @{ Op = 'str'; Rt = 0; Rn = 13; Offset = 4 },
        @{ Op = 'lea-data'; Rd = 0; Data = 'domainId' },
        @{ Op = 'str'; Rt = 0; Rn = 13; Offset = 8 },
        @{ Op = 'lea-data'; Rd = 0; Data = 'packageName' },
        @{ Op = 'lea-data'; Rd = 1; Data = 'domainName' },
        @{ Op = 'movs'; Rd = 2; Imm = 3 },
        @{ Op = 'lea-data'; Rd = 3; Data = 'propertyKeys' },
        @{ Op = 'call-import'; Import = 'coreclr_initialize'; Args = 7 },
        @{ Op = 'cmp-imm'; Rn = 0; Imm = 0 },
        @{ Op = 'bne'; Label = 'initFailed' }
    ) + (& $createDelegate 'methodName' 'admit' 'delegateFailed') + @(
        # Admit() must return 'PWSH'.
        @{ Op = 'call-data'; Data = 'admit'; Args = 0 },
        @{ Op = 'movw'; Rd = 1; Imm = 0x5348 },
        @{ Op = 'movt'; Rd = 1; Imm = 0x5057 },
        @{ Op = 'cmp'; Rn = 0; Rm = 1 },
        @{ Op = 'bne'; Label = 'admitWrong' }
    ) + (& $logInfo 'fmtAdmit' $true) + (& $createDelegate 'runMethodName' 'runPowerShell' 'runDelegateFailed') + (& $logInfo 'fmtBegin' $false) + @(
        @{ Op = 'mov'; Rd = 0; Rm = 4 }, # borrowed ANativeActivity*
        @{ Op = 'call-data'; Data = 'runPowerShell'; Args = 1 }
    ) + (& $logInfo 'fmtRun' $true) + @(
        @{ Op = 'b'; Label = 'done' }
    ) + (& $logFailure 'directoryFailed' 'fmtDirectory2') + (& $logFailure 'contractFailed' 'fmtContract') + (& $logFailure 'initFailed' 'fmtInit') + (& $logFailure 'delegateFailed' 'fmtDelegate') +
        (& $logFailure 'admitWrong' 'fmtAdmitWrong') + (& $logFailure 'runDelegateFailed' 'fmtRunDelegate') + @(
        @{ Op = 'label'; Name = 'done' },
        @{ Op = 'add-sp'; Imm = 16 },
        @{ Op = 'pop'; Registers = @(4, 5, 6, 15) })

    # bool pwsh_assembly_probe(const char* path, void** data_start, int64_t* size)
    # r4 path, r5 data_start, r6 size, r7 table cursor. *size is 64-bit: its
    # high word is written zero.
    $probe = @(
        @{ Op = 'push'; Registers = @(4, 5, 6, 7, 14) },
        @{ Op = 'sub-sp'; Imm = 4 },
        @{ Op = 'mov'; Rd = 4; Rm = 0 },
        @{ Op = 'mov'; Rd = 5; Rm = 1 },
        @{ Op = 'mov'; Rd = 6; Rm = 2 },
        @{ Op = 'lea-data'; Rd = 7; Data = 'probeTable' },
        @{ Op = 'label'; Name = 'next' },
        @{ Op = 'ldr'; Rt = 1; Rn = 7; Offset = 0 },
        @{ Op = 'cmp-imm'; Rn = 1; Imm = 0 },
        @{ Op = 'beq'; Label = 'missing' },
        @{ Op = 'mov'; Rd = 0; Rm = 4 },
        @{ Op = 'call-import'; Import = 'strcmp'; Args = 2 },
        @{ Op = 'cmp-imm'; Rn = 0; Imm = 0 },
        @{ Op = 'beq'; Label = 'found' },
        @{ Op = 'adds-imm'; Rd = 7; Imm = $record },
        @{ Op = 'b'; Label = 'next' },
        @{ Op = 'label'; Name = 'found' },
        @{ Op = 'load-got'; Rd = 0; Import = $StoreSymbol },
        @{ Op = 'ldr'; Rt = 1; Rn = 7; Offset = $ps },
        @{ Op = 'adds'; Rd = 0; Rn = 0; Rm = 1 },
        @{ Op = 'str'; Rt = 0; Rn = 5; Offset = 0 },
        @{ Op = 'ldr'; Rt = 1; Rn = 7; Offset = 2 * $ps },
        @{ Op = 'str'; Rt = 1; Rn = 6; Offset = 0 },
        @{ Op = 'movs'; Rd = 2; Imm = 0 },
        @{ Op = 'str'; Rt = 2; Rn = 6; Offset = 4 },
        @{ Op = 'movs'; Rd = 0; Imm = 1 },
        @{ Op = 'b'; Label = 'out' },
        @{ Op = 'label'; Name = 'missing' },
        @{ Op = 'movs'; Rd = 0; Imm = 0 },
        @{ Op = 'label'; Name = 'out' },
        @{ Op = 'add-sp'; Imm = 4 },
        @{ Op = 'pop'; Registers = @(4, 5, 6, 7, 15) })

    Test-T32CallAbi -Steps $onCreate -Parameters 3 -Name 'ANativeActivity_onCreate'
    Test-T32CallAbi -Steps $probe -Parameters 3 -Name 'pwsh_assembly_probe'
    }
    else {
    # System V AMD64: rax 0, rcx 1, rdx 2, rbx 3, rsp 4, rbp 5, rsi 6, rdi 7, r8 8, r9 9, r12-r14 12-14.
    $logFailure = { param([string] $label, [string] $format) @(
        @{ Op = 'label'; Name = $label },
        @{ Op = 'mov32'; Dst = 1; Src = 0 },
        @{ Op = 'movimm32'; Dst = 7; Imm = $errorPriority },
        @{ Op = 'lea-data'; Dst = 6; Data = 'tag' },
        @{ Op = 'lea-data'; Dst = 2; Data = $format },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        @{ Op = 'jmp'; Label = 'done' }) }
    $onCreate = @(
        @{ Op = 'push'; Reg = 5 },
        @{ Op = 'mov64'; Dst = 5; Src = 4 },
        @{ Op = 'push'; Reg = 3 },
        @{ Op = 'sub-rsp'; Imm = 8 },                                   # the 7th-argument slot; keeps calls 16-byte aligned
        @{ Op = 'mov64'; Dst = 3; Src = 7 },                            # rbx = activity
        # snprintf(baseDirectory, 512, "%s/", activity->internalDataPath)
        @{ Op = 'lea-data'; Dst = 7; Data = 'baseDirectory' },
        @{ Op = 'movimm32'; Dst = 6; Imm = 512 },
        @{ Op = 'lea-data'; Dst = 2; Data = 'fmtDirectory' },
        @{ Op = 'load64-base'; Dst = 1; Base = 3; Disp = 32 },          # ANativeActivity: callbacks, vm, env, clazz, internalDataPath
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'cmp32-imm'; Reg = 0; Imm = 512 },
        @{ Op = 'jae'; Label = 'directoryFailed' },
        # snprintf(contractText, 32, "%p", &contract)
        @{ Op = 'lea-data'; Dst = 7; Data = 'contractText' },
        @{ Op = 'movimm32'; Dst = 6; Imm = 32 },
        @{ Op = 'lea-data'; Dst = 2; Data = 'fmtPointer' },
        @{ Op = 'lea-data'; Dst = 1; Data = 'contract' },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = 'snprintf'; Args = 4; Variadic = $true },
        @{ Op = 'cmp32-imm'; Reg = 0; Imm = 32 },
        @{ Op = 'jae'; Label = 'contractFailed' },
        # coreclr_initialize(package, "Pwsh", 3, keys, values, &hostHandle, &domainId)
        @{ Op = 'lea-data'; Dst = 7; Data = 'packageName' },
        @{ Op = 'lea-data'; Dst = 6; Data = 'domainName' },
        @{ Op = 'movimm32'; Dst = 2; Imm = 3 },
        @{ Op = 'lea-data'; Dst = 1; Data = 'propertyKeys' },
        @{ Op = 'lea-data'; Dst = 8; Data = 'propertyValues' },
        @{ Op = 'lea-data'; Dst = 9; Data = 'hostHandle' },
        @{ Op = 'lea-data'; Dst = 0; Data = 'domainId' },
        @{ Op = 'store64-rsp'; Src = 0; Disp = 0 },
        @{ Op = 'call-import'; Import = 'coreclr_initialize'; Args = 6; StackArgs = 1 },
        @{ Op = 'test32'; Reg = 0 },
        @{ Op = 'jnz'; Label = 'initFailed' },
        # coreclr_create_delegate(hostHandle, domainId, "Pwsh", type, "Admit", &admit)
        @{ Op = 'load64-data'; Dst = 7; Data = 'hostHandle' },
        @{ Op = 'load32-data'; Dst = 6; Data = 'domainId' },
        @{ Op = 'lea-data'; Dst = 2; Data = 'assemblyName' },
        @{ Op = 'lea-data'; Dst = 1; Data = 'typeName' },
        @{ Op = 'lea-data'; Dst = 8; Data = 'methodName' },
        @{ Op = 'lea-data'; Dst = 9; Data = 'admit' },
        @{ Op = 'call-import'; Import = 'coreclr_create_delegate'; Args = 6 },
        @{ Op = 'test32'; Reg = 0 },
        @{ Op = 'jnz'; Label = 'delegateFailed' },
        # Admit(); __android_log_print(INFO, "Pwsh", "GATE2A Admit returned 0x%08x", result)
        @{ Op = 'call-data'; Data = 'admit'; Args = 0 },
        @{ Op = 'cmp32-imm'; Reg = 0; Imm = 0x50575348 },
        @{ Op = 'jnz'; Label = 'admitWrong' },
        @{ Op = 'mov32'; Dst = 1; Src = 0 },
        @{ Op = 'movimm32'; Dst = 7; Imm = $info },
        @{ Op = 'lea-data'; Dst = 6; Data = 'tag' },
        @{ Op = 'lea-data'; Dst = 2; Data = 'fmtAdmit' },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        # Gates 2b/2c, only after gate 2a held in this process:
        # coreclr_create_delegate(hostHandle, domainId, "Pwsh", type, "RunPowerShell", &runPowerShell)
        @{ Op = 'load64-data'; Dst = 7; Data = 'hostHandle' },
        @{ Op = 'load32-data'; Dst = 6; Data = 'domainId' },
        @{ Op = 'lea-data'; Dst = 2; Data = 'assemblyName' },
        @{ Op = 'lea-data'; Dst = 1; Data = 'typeName' },
        @{ Op = 'lea-data'; Dst = 8; Data = 'runMethodName' },
        @{ Op = 'lea-data'; Dst = 9; Data = 'runPowerShell' },
        @{ Op = 'call-import'; Import = 'coreclr_create_delegate'; Args = 6 },
        @{ Op = 'test32'; Reg = 0 },
        @{ Op = 'jnz'; Label = 'runDelegateFailed' },
        # Log the gate boundary, then RunPowerShell(activity); log its result.
        @{ Op = 'movimm32'; Dst = 7; Imm = $info },
        @{ Op = 'lea-data'; Dst = 6; Data = 'tag' },
        @{ Op = 'lea-data'; Dst = 2; Data = 'fmtBegin' },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 3; Variadic = $true },
        @{ Op = 'mov64'; Dst = 7; Src = 3 }, # borrowed ANativeActivity*
        @{ Op = 'call-data'; Data = 'runPowerShell'; Args = 1 },
        @{ Op = 'mov32'; Dst = 1; Src = 0 },
        @{ Op = 'movimm32'; Dst = 7; Imm = $info },
        @{ Op = 'lea-data'; Dst = 6; Data = 'tag' },
        @{ Op = 'lea-data'; Dst = 2; Data = 'fmtRun' },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true },
        @{ Op = 'jmp'; Label = 'done' }
    ) + (& $logFailure 'directoryFailed' 'fmtDirectory2') + (& $logFailure 'contractFailed' 'fmtContract') + (& $logFailure 'initFailed' 'fmtInit') + (& $logFailure 'delegateFailed' 'fmtDelegate') +
        (& $logFailure 'admitWrong' 'fmtAdmitWrong') + (& $logFailure 'runDelegateFailed' 'fmtRunDelegate') + @(
        @{ Op = 'label'; Name = 'done' },
        @{ Op = 'add-rsp'; Imm = 8 },
        @{ Op = 'pop'; Reg = 3 },
        @{ Op = 'pop'; Reg = 5 },
        @{ Op = 'ret' })

    # Diagnostic: __android_log_print(INFO, "Pwsh", format, path), path in r12.
    # Nothing is emitted unless -TraceAssemblyProbe.
    $traceProbe = { param([string] $format) if (-not $TraceAssemblyProbe) { return @() } @(
        @{ Op = 'movimm32'; Dst = 7; Imm = $info },
        @{ Op = 'lea-data'; Dst = 6; Data = 'tag' },
        @{ Op = 'lea-data'; Dst = 2; Data = $format },
        @{ Op = 'mov64'; Dst = 1; Src = 12 },
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'call-import'; Import = '__android_log_print'; Args = 4; Variadic = $true }) }
    # bool pwsh_assembly_probe(const char* path, void** data_start, int64_t* size)
    $probe = @(
        @{ Op = 'push'; Reg = 3 },
        @{ Op = 'push'; Reg = 12 },
        @{ Op = 'push'; Reg = 13 },
        @{ Op = 'push'; Reg = 14 },
        @{ Op = 'sub-rsp'; Imm = 8 },
        @{ Op = 'mov64'; Dst = 12; Src = 7 },
        @{ Op = 'mov64'; Dst = 13; Src = 6 },
        @{ Op = 'mov64'; Dst = 14; Src = 2 }) + (& $traceProbe 'fmtProbeRequest') + @(
        @{ Op = 'lea-data'; Dst = 3; Data = 'probeTable' },
        @{ Op = 'label'; Name = 'next' },
        @{ Op = 'load64-base'; Dst = 6; Base = 3; Disp = 0 },
        @{ Op = 'test64'; Reg = 6 },
        @{ Op = 'jz'; Label = 'missing' },
        @{ Op = 'mov64'; Dst = 7; Src = 12 },
        @{ Op = 'call-import'; Import = 'strcmp'; Args = 2 },
        @{ Op = 'test32'; Reg = 0 },
        @{ Op = 'jz'; Label = 'found' },
        @{ Op = 'add64-imm8'; Dst = 3; Imm = 24 },
        @{ Op = 'jmp'; Label = 'next' },
        @{ Op = 'label'; Name = 'found' },
        @{ Op = 'load-got'; Dst = 0; Import = $StoreSymbol },
        @{ Op = 'add64-base'; Dst = 0; Base = 3; Disp = 8 },
        @{ Op = 'store64-base'; Src = 0; Base = 13; Disp = 0 },
        @{ Op = 'load64-base'; Dst = 0; Base = 3; Disp = 16 },
        @{ Op = 'store64-base'; Src = 0; Base = 14; Disp = 0 }) + (& $traceProbe 'fmtProbeHit') + @(
        @{ Op = 'movimm32'; Dst = 0; Imm = 1 },
        @{ Op = 'jmp'; Label = 'out' },
        @{ Op = 'label'; Name = 'missing' }) + (& $traceProbe 'fmtProbeMiss') + @(
        @{ Op = 'xor32'; Dst = 0 },
        @{ Op = 'label'; Name = 'out' },
        @{ Op = 'add-rsp'; Imm = 8 },
        @{ Op = 'pop'; Reg = 14 },
        @{ Op = 'pop'; Reg = 13 },
        @{ Op = 'pop'; Reg = 12 },
        @{ Op = 'pop'; Reg = 3 },
        @{ Op = 'ret' })

    Test-X64CallAbi -Steps $onCreate -Parameters 3 -Name 'ANativeActivity_onCreate'
    Test-X64CallAbi -Steps $probe -Parameters 3 -Name 'pwsh_assembly_probe'
    }

    $functions = [ordered]@{ 'ANativeActivity_onCreate' = $onCreate; 'pwsh_assembly_probe' = $probe }
    $hostIsa = if ($Architecture -eq 'arm32') { 'T32' } else { '' }
    $library = New-ElfCodeLibrary -Soname 'libpwsh-host.so' -Needed @('libc.so', 'liblog.so', 'libcoreclr.so', $StoreLibrary) `
        -Functions $functions -Data $data -WritableData $writable -PageSize $PageSize -InstructionSet $hostIsa
    $report = Test-ElfCodeLibrary -Library $library

    # The contract as emitted: size, and every member zero but the probe, whose
    # slot is relocated to pwsh_assembly_probe.
    $contractAt = $library.DataAt['contract']
    $readPointer = { param([long] $At) if ($ps -eq 8) { [long][BitConverter]::ToUInt64($library.Bytes, $At) } else { [long][BitConverter]::ToUInt32($library.Bytes, $At) } }
    if ((& $readPointer ($contractAt + $layout.Offsets['size'])) -ne $layout.Size) { throw 'The emitted host_runtime_contract.size is not the pinned structure size.' }
    foreach ($member in $layout.Members) {
        if ($member -in 'size', 'external_assembly_probe') { continue }
        if ((& $readPointer ($contractAt + $layout.Offsets[$member])) -ne 0) { throw "host_runtime_contract.$member is not zero." }
    }
    # The probe is a code pointer: it carries the host instruction set's state bit.
    $probeSlot = @((Read-ElfImage -Image $library.Bytes).Relocations | Where-Object { $_.Offset -eq $contractAt + $probeOffset })
    if ($probeSlot.Count -ne 1 -or $probeSlot[0].Addend -ne $library.Exports['pwsh_assembly_probe'] + $library.StateBit) { throw 'host_runtime_contract.external_assembly_probe is not relocated to pwsh_assembly_probe.' }
    [pscustomobject]@{ Library = $library; Report = $report }
}

function Assert-NativeAdmissionApk {
    # Gate 1 proves absence as well as success, from parsed structures: the
    # archive's own entry names, the manifest's elements and string pool, and
    # the host library's dynamic section.
    param([Parameter(Mandatory)][string[]] $EntryNames)

    $abi = $script:Target.Abi
    $forbidden = @($EntryNames | Where-Object { $_ -like '*.dex' -or $_ -like '*/libmonodroid.so' -or $_ -like '*/libxamarin-app.so' })
    if ($forbidden.Count) { throw "The NativeActivity APK carries Xamarin or DEX entries: $($forbidden -join ', ')" }
    if ("lib/$abi/libpwsh-host.so" -notin $EntryNames) { throw "The NativeActivity APK lacks lib/$abi/libpwsh-host.so." }

    $manifest = Test-BinaryAxml -Document ([byte[]]$script:BuildContext.AndroidManifest.Bytes)
    if (@($manifest.Elements | Where-Object Name -eq 'provider').Count) { throw 'The NativeActivity manifest declares a provider.' }
    if (@($manifest.Strings | Where-Object { $_ -like '*MonoRuntimeProvider*' }).Count) { throw 'The NativeActivity manifest string pool names MonoRuntimeProvider.' }
    $application = @($manifest.Elements | Where-Object Name -eq 'application')[0]
    if ($application.Attributes['hasCode'] -ne 0) { throw 'The NativeActivity manifest does not set android:hasCode="false".' }
    # android:debuggable is present exactly when -Debuggable asked for it.
    if ($Debuggable) {
        if (-not $application.Attributes.Contains('debuggable') -or $application.Attributes['debuggable'] -eq 0) { throw 'The -Debuggable manifest does not set android:debuggable="true".' }
    }
    elseif ($application.Attributes.Contains('debuggable') -or @($manifest.Strings) -ccontains 'debuggable') { throw 'The release NativeActivity manifest carries android:debuggable.' }
    $activity = @($manifest.Elements | Where-Object Name -eq 'activity')
    if ($activity.Count -ne 1 -or $activity[0].Attributes['name'] -cne 'android.app.NativeActivity') { throw 'The manifest activity is not android.app.NativeActivity.' }
    $libName = @($manifest.Elements | Where-Object { $_.Name -eq 'meta-data' -and $_.Attributes['name'] -ceq 'android.app.lib_name' })
    if ($libName.Count -ne 1 -or $libName[0].Attributes['value'] -cne 'pwsh-host') { throw 'The manifest does not name pwsh-host as android.app.lib_name.' }

    $library = Read-ElfImage -Image ([byte[]]$script:BuildContext.NativeHost.Bytes)
    $needed = (@($library.Needed) | Sort-Object) -join ','
    if ($needed -cne 'libassembly-store.so,libc.so,libcoreclr.so,liblog.so') { throw "libpwsh-host.so needs $needed; only libc, liblog, libcoreclr and the store library are allowed." }
    foreach ($export in 'ANativeActivity_onCreate', 'pwsh_assembly_probe') {
        if (-not $library.Resolved.ContainsKey($export)) { throw "libpwsh-host.so does not export $export." }
    }
    foreach ($entry in "lib/$abi/libcoreclr.so", "lib/$abi/libassembly-store.so") {
        if ($entry -notin $EntryNames) { throw "The NativeActivity APK lacks $entry." }
    }

    Write-Host ('[PASS] NativeActivity admission: {0} entries, none DEX, libmonodroid or libxamarin-app; manifest has no provider, hasCode=false, android.app.NativeActivity with lib_name pwsh-host; libpwsh-host.so needs only libc, liblog, libcoreclr and the store library.' -f
        $EntryNames.Count) -ForegroundColor Green
}

function Test-NativeEmitterControls {
    <#
        Regression controls for defects already found in the emitter. They run
        on every build, before any library is emitted:
        - labels named like dictionary members (Keys, Values, Count, Item) are
          placed exactly as ordinary labels, and steps without optional fields
          encode under StrictMode;
        - on x86-64, the ABI checker rejects a variadic call without xor eax,
          a misaligned call, an argument set on only one branch before a join,
          unequal stack depths at a join, and an unsaved callee-saved write.
    #>
    $return = switch ($script:Target.Isa) {
        'A64' { @{ Op = 'ret' } }
        'X64' { @{ Op = 'ret' } }
        'A32' { @{ Op = 'bx'; Rm = 14 } }
    }
    $functions = [ordered]@{ Keys = @($return); Count = @($return) }
    $data = [ordered]@{ Values = [byte[]]@(1, 2, 3, 4); Item = [byte[]]@(5, 6, 7, 8) }
    $writable = [ordered]@{ Keys2 = [byte[]]::new(8); Count2 = @{ Bytes = [byte[]]::new(8); Pointers = @(@{ At = 0; Target = 'Values' }) } }
    $library = New-ElfCodeLibrary -Soname 'libcontrol.so' -Needed @('libc.so') -Functions $functions -Data $data -WritableData $writable -PageSize 16384
    [void](Test-ElfCodeLibrary -Library $library)
    foreach ($label in 'Keys', 'Count', 'Values', 'Item', 'Keys2', 'Count2') {
        if (-not $library.DataAt.ContainsKey($label)) { throw "Emitter control: label '$label' was not placed." }
    }
    if (@($library.Exports.PSBase.Keys).Count -ne 2) { throw 'Emitter control: functions named Keys and Count were not both exported.' }
    $controls = 2

    if ($script:Target.Machine -eq 'EM_ARM') {
        # The arm32 host is T32 (AAPCS32).
        $save = @{ Op = 'push'; Registers = @(4, 14) }
        $restore = @{ Op = 'pop'; Registers = @(4, 15) }
        $call = { param([int] $count) @{ Op = 'call-import'; Import = 'f'; Args = $count } }
        Test-T32CallAbi -Steps @($save, @{ Op = 'lea-data'; Rd = 0; Data = 'a' }, (& $call 1), $restore) -Name 'control'
        $cases = [ordered]@{
            'call without pushing lr'      = @(@{ Op = 'lea-data'; Rd = 0; Data = 'a' }, (& $call 1), @{ Op = 'pop'; Registers = @(15) })
            'argument set on one branch'   = @($save, @{ Op = 'cmp-imm'; Rn = 1; Imm = 0 }, @{ Op = 'beq'; Label = 'join' }, @{ Op = 'lea-data'; Rd = 0; Data = 'a' }, @{ Op = 'label'; Name = 'join' }, (& $call 1), $restore)
            'misaligned call'              = @(@{ Op = 'push'; Registers = @(4, 5, 14) }, @{ Op = 'lea-data'; Rd = 0; Data = 'a' }, (& $call 1), @{ Op = 'pop'; Registers = @(4, 5, 15) })
            'stacked argument not stored'  = @($save, @{ Op = 'sub-sp'; Imm = 8 }, @{ Op = 'movs'; Rd = 0; Imm = 0 }, @{ Op = 'movs'; Rd = 1; Imm = 0 }, @{ Op = 'movs'; Rd = 2; Imm = 0 }, @{ Op = 'movs'; Rd = 3; Imm = 0 }, (& $call 5), @{ Op = 'add-sp'; Imm = 8 }, $restore)
            'unsaved callee-saved write'   = @($save, @{ Op = 'mov'; Rd = 5; Rm = 0 }, $restore)
            'pop differs from push'        = @($save, @{ Op = 'pop'; Registers = @(5, 15) })
            'unreachable code'             = @($save, $restore, @{ Op = 'movs'; Rd = 0; Imm = 0 }, $restore)
        }
        foreach ($case in $cases.PSBase.Keys) {
            $rejected = $false
            try { Test-T32CallAbi -Steps $cases[$case] -Name 'control' } catch { $rejected = $true }
            if (-not $rejected) { throw "T32 ABI control '$case' was accepted." }
            $controls++
        }
    }

    if ($script:Target.Isa -eq 'A64') {
        $frame = @{ Op = 'stp-pre'; Rt = 29; Rt2 = 30; Offset = -16 }
        $unframe = @{ Op = 'ldp-post'; Rt = 29; Rt2 = 30; Offset = 16 }
        $cases = [ordered]@{
            'call without saving x30'      = @(@{ Op = 'lea-data'; Rd = 0; Data = 'a' }, @{ Op = 'call-import'; Import = 'f'; Args = 1 }, @{ Op = 'ret' })
            'argument set on one branch'   = @($frame, @{ Op = 'cbz'; Rt = 1; Is64 = $true; Label = 'join' }, @{ Op = 'lea-data'; Rd = 0; Data = 'a' }, @{ Op = 'label'; Name = 'join' }, @{ Op = 'call-import'; Import = 'f'; Args = 1 }, $unframe, @{ Op = 'ret' })
            'unsaved callee-saved write'   = @(@{ Op = 'mov'; Rd = 19; Rm = 0; Is64 = $true }, @{ Op = 'ret' })
            'restores out of order'        = @($frame, @{ Op = 'stp'; Rt = 19; Rt2 = 20; Offset = 16 }, @{ Op = 'ldp-post'; Rt = 29; Rt2 = 30; Offset = 16 }, @{ Op = 'ret' })
            'writes x18'                   = @(@{ Op = 'movz'; Rd = 18; Imm = 1; Is64 = $true }, @{ Op = 'ret' })
            'unreachable code'             = @(@{ Op = 'ret' }, @{ Op = 'movz'; Rd = 0; Imm = 0; Is64 = $false }, @{ Op = 'ret' })
        }
        foreach ($case in $cases.PSBase.Keys) {
            $rejected = $false
            try { Test-A64CallAbi -Steps $cases[$case] -Name 'control' } catch { $rejected = $true }
            if (-not $rejected) { throw "A64 ABI control '$case' was accepted." }
            $controls++
        }
    }
    if ($script:Target.Isa -eq 'X64') {
        $call = @{ Op = 'call-import'; Import = 'f'; Args = 1 }
        $cases = [ordered]@{
            'variadic call without xor eax' = @(@{ Op = 'push'; Reg = 3 }, @{ Op = 'lea-data'; Dst = 7; Data = 'a' }, @{ Op = 'call-import'; Import = 'f'; Args = 1; Variadic = $true }, @{ Op = 'pop'; Reg = 3 }, @{ Op = 'ret' })
            'misaligned call'               = @(@{ Op = 'lea-data'; Dst = 7; Data = 'a' }, $call, @{ Op = 'ret' })
            'argument set on one branch'    = @(@{ Op = 'push'; Reg = 3 }, @{ Op = 'test32'; Reg = 0 }, @{ Op = 'jz'; Label = 'join' }, @{ Op = 'lea-data'; Dst = 7; Data = 'a' }, @{ Op = 'label'; Name = 'join' }, $call, @{ Op = 'pop'; Reg = 3 }, @{ Op = 'ret' })
            'unequal depth at a join'       = @(@{ Op = 'test32'; Reg = 0 }, @{ Op = 'jz'; Label = 'join' }, @{ Op = 'sub-rsp'; Imm = 8 }, @{ Op = 'label'; Name = 'join' }, @{ Op = 'ret' })
            'unsaved callee-saved write'    = @(@{ Op = 'mov64'; Dst = 3; Src = 7 }, @{ Op = 'ret' })
            'tail without restoring'      = @(@{ Op = 'push'; Reg = 3 }, @{ Op = 'tail'; Import = 'f' })
            'unreachable code'            = @(@{ Op = 'ret' }, @{ Op = 'xor32'; Dst = 0 }, @{ Op = 'ret' })
        }
        foreach ($case in $cases.PSBase.Keys) {
            $rejected = $false
            try { Test-X64CallAbi -Steps $cases[$case] -Name 'control' } catch { $rejected = $true }
            if (-not $rejected) { throw "ABI control '$case' was accepted." }
            $controls++
        }
    }
    $controls
}

function Invoke-NativeStep {

    $controls = Test-NativeEmitterControls
    Write-Host ('[PASS] Emitter controls: {0} regression controls held.' -f $controls) -ForegroundColor Green

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

    $aligned = Test-StoreImageAlignment -LibraryBytes ([byte[]]$library.Bytes) -SymbolName $symbol -Entries $script:BuildContext.AssemblyStore.Entries
    Write-Host ('[PASS] Store alignment: {0} images start 16-byte aligned in the mapped library; {1} fat method headers fall 4-byte aligned, {2} tiny.' -f
        $aligned.Images, $aligned.FatMethods, $aligned.TinyMethods) -ForegroundColor Green
    $nativeHost = New-NativeHostLibrary -StoreEntries $script:BuildContext.AssemblyStore.Entries -StoreLibrary $soname -StoreSymbol $symbol -PageSize $pageSize
    $hostPath = Join-Path $outputDirectory 'libpwsh-host.so'
    if ($PSCmdlet.ShouldProcess($hostPath, 'Write libpwsh-host')) {
        Write-BuildFile -Intermediate -Path $hostPath -Bytes $nativeHost.Library.Bytes
    }
    $script:BuildContext.NativeHost = [pscustomobject]@{ Path = $hostPath; Bytes = $nativeHost.Library.Bytes }
    Write-Host ('[PASS] libpwsh-host.so emitted: {0} bytes, exports {1}, {2} imports through a BIND_NOW GOT, a {3}-entry assembly probe table, {4} instructions decoded back and checked.' -f
        $nativeHost.Report.ImageSize, ($nativeHost.Library.Exports.PSBase.Keys -join ' and '), $nativeHost.Report.Imports, $script:BuildContext.AssemblyStore.Entries.Count, $nativeHost.Report.Steps) -ForegroundColor Green
    # libpsl-native: SMA resolves it by name during startup logging; CoreCLR's
    # default probing finds it in the APK's library directory.
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

function Test-AndroidAttributeIds {
    # The binary XML emitter carries a table of android: attribute names and the
    # resource ids they resolve to. Those ids are declarations in the framework's
    # public-final.xml, so rather than trusting the table, check it. A wrong id
    # produces a manifest that installs and then behaves incorrectly, which is
    # worse than one that fails to build.
    $text = Import-LibSourceText -Path 'public-final.xml'
    $expected = [ordered]@{
        'theme' = 0x01010000; 'label' = 0x01010001; 'icon' = 0x01010002
        'name' = 0x01010003; 'hasCode' = 0x0101000C; 'debuggable' = 0x0101000F; 'exported' = 0x01010010; 'authorities' = 0x01010018
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

function Get-StartupScriptAssets {
    # -Startup ConsoleHost: the scripts the APK carries under assets/scripts/,
    # copied by the host into PWSH_APP_SCRIPTS (docs/work-optional-scripts.md):
    # the console start script, the two modules it imports, and every command
    # bundle under scripts/commands. Flat by file name; a duplicate name fails.
    # Hash: SHA-256 over each name, a NUL, the length and the bytes, in ordinal
    # name order. The host compares it to decide whether to copy again.
    if ($script:StartupScriptAssets) { return $script:StartupScriptAssets }
    $root = $script:RepositoryRoot
    $files = [System.Collections.Generic.List[string]]::new()
    $files.Add((Join-Path $root 'scripts/console/Start-Console.ps1'))
    $files.Add((Join-Path $root 'modules/Console.psm1'))
    $files.Add((Join-Path $root 'modules/AndroidCanvas.psm1'))
    # Bundles shipped in the APK, until the setup.ps1 bundle option (ROADMAP O4)
    # selects them. Adb is PC tooling: its WinUSB transport is Windows-only.
    $shippedBundles = @('Parsers')
    foreach ($bundle in Get-ChildItem -LiteralPath (Join-Path $root 'scripts/commands') -Directory -ErrorAction SilentlyContinue | Where-Object Name -in $shippedBundles | Sort-Object Name) {
        foreach ($file in Get-ChildItem -LiteralPath $bundle.FullName -File -Filter '*.ps1' | Sort-Object Name) { $files.Add($file.FullName) }
    }
    $byName = [System.Collections.Generic.SortedDictionary[string, byte[]]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $files) {
        if (-not [System.IO.File]::Exists($path)) { throw "Startup script asset missing: $path" }
        $name = [System.IO.Path]::GetFileName($path)
        if ($byName.ContainsKey($name)) { throw "Two startup script assets are named '$name'." }
        $byName[$name] = [System.IO.File]::ReadAllBytes($path)
    }
    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($entry in $byName.GetEnumerator()) {
            $hash.AppendData([System.Text.Encoding]::UTF8.GetBytes($entry.Key + [char]0))
            $hash.AppendData([BitConverter]::GetBytes([int64]$entry.Value.Length))
            $hash.AppendData($entry.Value)
        }
        $digest = [Convert]::ToHexString($hash.GetHashAndReset())
    }
    finally { $hash.Dispose() }
    $script:StartupScriptAssets = [pscustomobject]@{ Files = $byName; Sha256 = $digest }
    $script:StartupScriptAssets
}

function Invoke-AssembleStep {

    $abi = $script:Target.Abi
    $runtimePack = "Microsoft.NETCore.App.Runtime.$($script:Target.Rid)"

    $entries = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string] $Name, [byte[]] $Bytes, [bool] $Stored = $false, [int] $Alignment = 0)
        $entries.Add([pscustomobject]@{ Name = $Name; Bytes = $Bytes; Stored = $Stored; Alignment = $Alignment })
    }

    & $add 'AndroidManifest.xml' ([byte[]]$script:BuildContext.AndroidManifest.Bytes) $false 0
    $adaptiveIcon = New-AdaptiveIconAxml -ForegroundResourceId 0x7f010001 -BackgroundResourceId 0x7f020000
    $adaptiveReport = Test-BinaryAxml -Document $adaptiveIcon
    $adaptiveAttributeIds = Assert-ManifestAttributeIds -Report $adaptiveReport
    if ($adaptiveAttributeIds -ne 2) { throw "The adaptive icon has $adaptiveAttributeIds checked android: attributes; expected 2." }
    & $add 'resources.arsc' (New-ResourceTable `
        -PackageName $script:PackageName `
        -IconPath 'res/mipmap-anydpi-v26/ic_launcher.xml' `
        -ForegroundPath 'res/mipmap-nodpi-v4/ic_launcher_foreground.png' `
        -BackgroundColor ([uint32]4278926638)) $true 4
    & $add 'res/mipmap-anydpi-v26/ic_launcher.xml' $adaptiveIcon $false 0
    & $add 'res/mipmap-nodpi-v4/ic_launcher_foreground.png' (Import-LibSourceBytes -Path 'ic_launcher.png') $true 4
    & $add "lib/$abi/libpwsh-host.so" ([byte[]]$script:BuildContext.NativeHost.Bytes) $false 0
    & $add "lib/$abi/libassembly-store.so" ([byte[]]$script:BuildContext.StoreLibrary.Bytes) $false 0
    & $add "lib/$abi/libpsl-native.so" ([byte[]]$script:BuildContext.PslNative.Bytes) $false 0
    # The .NET runtime's native components, from the verified runtime pack.
    foreach ($name in 'libcoreclr.so', 'libclrjit.so', 'libSystem.Native.so', 'libSystem.Globalization.Native.so', 'libSystem.IO.Compression.Native.so', 'libSystem.Security.Cryptography.Native.Android.so') {
        & $add "lib/$abi/$name" (Get-NativePayload -PackageId $runtimePack -EntryPath "runtimes/$($script:Target.Rid)/native/$name") $false 0
    }

    $assetNote = ''
    if ($Startup -eq 'ConsoleHost') {
        $assets = Get-StartupScriptAssets
        foreach ($asset in $assets.Files.GetEnumerator()) { & $add "assets/scripts/$($asset.Key)" ([byte[]]$asset.Value) $false 0 }
        $assetNote = " ConsoleHost startup: $($assets.Files.Count) script assets, set SHA-256 $($assets.Sha256)."
    }

    $apkBytes = New-ApkArchive -Entries $entries
    $report = Test-ApkArchive -Apk $apkBytes -Entries $entries
    Assert-NativeAdmissionApk -EntryNames $report.Names

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

    Write-Host ('[PASS] Step 8 complete: Pwsh-unsigned.apk assembled from {0} entries into {1} bytes, every entry read back byte-identical by an independent reader. SHA-256 {2}{3}' -f
        $report.EntryCount,
        $report.Size,
        $apkHash,
        $assetNote) -ForegroundColor Green
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
    # an installed app whose signer changed, so the key remains in private
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

    Write-Host ('[PASS] Step 9 complete: {5} signed with APK Signature Scheme v2. {0} bytes, {1}-byte signing block, {2}-byte RSA signature, certificate {3}. Signature re-verified against the recomputed content digest. SHA-256 {4}' -f
        $signed.Bytes.Length,
        $report.BlockSize,
        $report.SignatureSize,
        $certificate.Thumbprint,
        $apkHash,
        $apkPath) -ForegroundColor Green
    Write-Host ('       Install with: adb install -r "{0}"' -f $apkPath) -ForegroundColor DarkCyan
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
        A resources.arsc holding one package (0x7f) with two types. The mipmap
        type has two configurations: mipmap/ic_launcher is an anydpi-v26 adaptive-icon XML
        at resource id 0x7f010000; mipmap/ic_launcher_foreground is its nodpi
        bitmap artwork at 0x7f010001. color/ic_launcher_background is the
        adaptive background at 0x7f020000. Layouts follow
        lib/ResourceTypes.h: ResTable_header,
        ResTable_package, ResTable_typeSpec, ResTable_type with a 64-byte
        ResTable_config, ResTable_entry, Res_value.
    #>
    param(
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $IconPath,
        [Parameter(Mandatory)][string] $ForegroundPath,
        [Parameter(Mandatory)][uint32] $BackgroundColor
    )

    $valueStrings = New-ResStringPool -Strings @($IconPath, $ForegroundPath)
    $typeStrings  = New-ResStringPool -Strings @('mipmap', 'color')
    $keyStrings   = New-ResStringPool -Strings @('ic_launcher', 'ic_launcher_foreground', 'ic_launcher_background')

    # ResTable_typeSpec: id 1, two entries, no configuration flags.
    $spec = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($spec)
    $w.Write([uint16]0x0202); $w.Write([uint16]16); $w.Write([uint32](16 + 8))
    $w.Write([byte]1); $w.Write([byte]0); $w.Write([uint16]0); $w.Write([uint32]2)
    $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Flush()

    # ResTable_typeSpec: id 2, one color entry.
    $colorSpec = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($colorSpec)
    $w.Write([uint16]0x0202); $w.Write([uint16]16); $w.Write([uint32]20)
    $w.Write([byte]2); $w.Write([byte]0); $w.Write([uint16]0); $w.Write([uint32]1)
    $w.Write([uint32]0)
    $w.Flush()

    function New-IconTypeChunk {
        param(
            [Parameter(Mandatory)][ValidateRange(0, 1)][int] $EntryIndex,
            [Parameter(Mandatory)][uint16] $Density,
            [Parameter(Mandatory)][uint16] $SdkVersion
        )

        $configSize = 64
        $headerSize = 20 + $configSize
        $entriesStart = $headerSize + 8
        $type = [System.IO.MemoryStream]::new()
        $tw = [System.IO.BinaryWriter]::new($type)
        $tw.Write([uint16]0x0201); $tw.Write([uint16]$headerSize); $tw.Write([uint32]($entriesStart + 16))
        $tw.Write([byte]1); $tw.Write([byte]0); $tw.Write([uint16]0)
        $tw.Write([uint32]2); $tw.Write([uint32]$entriesStart)
        $config = [byte[]]::new($configSize)
        [BitConverter]::GetBytes([uint32]$configSize).CopyTo($config, 0)
        [BitConverter]::GetBytes($Density).CopyTo($config, 14)
        [BitConverter]::GetBytes($SdkVersion).CopyTo($config, 24)
        $tw.Write($config)
        for ($i = 0; $i -lt 2; $i++) {
            $tw.Write([uint32]$(if ($i -eq $EntryIndex) { 0 } else { [uint32]::MaxValue }))
        }
        $tw.Write([uint16]8); $tw.Write([uint16]0); $tw.Write([uint32]$EntryIndex)
        $tw.Write([uint16]8); $tw.Write([byte]0); $tw.Write([byte]0x03) # TYPE_STRING
        $tw.Write([uint32]$EntryIndex)
        $tw.Flush()
        return ,$type.ToArray()
    }

    # Android's resource compiler emits adaptive launcher XML as anydpi-v26;
    # the bitmap foreground remains nodpi so its source pixels are not scaled.
    $iconType = New-IconTypeChunk -EntryIndex 0 -Density ([uint16]0xFFFE) -SdkVersion 26
    $foregroundType = New-IconTypeChunk -EntryIndex 1 -Density ([uint16]0xFFFF) -SdkVersion 0

    # The adaptive-icon inflater requires a resource reference for its
    # background. A color resource is drawable through Resources.getDrawable.
    $configSize = 64
    $headerSize = 20 + $configSize
    $entriesStart = $headerSize + 4
    $colorType = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($colorType)
    $w.Write([uint16]0x0201); $w.Write([uint16]$headerSize); $w.Write([uint32]($entriesStart + 16))
    $w.Write([byte]2); $w.Write([byte]0); $w.Write([uint16]0)
    $w.Write([uint32]1); $w.Write([uint32]$entriesStart)
    $config = [byte[]]::new($configSize)
    [BitConverter]::GetBytes([uint32]$configSize).CopyTo($config, 0)
    $w.Write($config)
    $w.Write([uint32]0)
    $w.Write([uint16]8); $w.Write([uint16]0); $w.Write([uint32]2)
    $w.Write([uint16]8); $w.Write([byte]0); $w.Write([byte]0x1c) # TYPE_INT_COLOR_ARGB8
    $w.Write($BackgroundColor)
    $w.Flush()

    # ResTable_package: 288-byte header, then type and key pools, then chunks.
    $packageHeaderSize = 288
    $typeStringsOffset = $packageHeaderSize
    $keyStringsOffset = $typeStringsOffset + $typeStrings.Length
    $packageSize = $keyStringsOffset + $keyStrings.Length + $spec.Length + $iconType.Length + $foregroundType.Length + $colorSpec.Length + $colorType.Length
    $package = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($package)
    $w.Write([uint16]0x0200); $w.Write([uint16]$packageHeaderSize); $w.Write([uint32]$packageSize)
    $w.Write([uint32]0x7f)
    $name = [byte[]]::new(256)
    $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($PackageName)
    if ($nameBytes.Length -gt 254) { throw "Package name '$PackageName' exceeds 127 UTF-16 units." }
    $nameBytes.CopyTo($name, 0)
    $w.Write($name)
    $w.Write([uint32]$typeStringsOffset); $w.Write([uint32]2)
    $w.Write([uint32]$keyStringsOffset); $w.Write([uint32]3)
    $w.Write([uint32]0)                                              # typeIdOffset
    $w.Write($typeStrings); $w.Write($keyStrings)
    $w.Write($spec.ToArray()); $w.Write($iconType); $w.Write($foregroundType)
    $w.Write($colorSpec.ToArray()); $w.Write($colorType.ToArray())
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

function New-AdaptiveIconAxml {
    <#
        Binary form of Android's adaptive-icon resource. The drawable
        attribute id is taken from the pinned public-final.xml, and the chunk
        structures follow the pinned ResourceTypes.h.
    #>
    param(
        [Parameter(Mandatory)][uint32] $ForegroundResourceId,
        [Parameter(Mandatory)][uint32] $BackgroundResourceId
    )

    $allStrings = @(
        'drawable',
        'adaptive-icon',
        'background',
        'foreground',
        'android',
        'http://schemas.android.com/apk/res/android'
    )
    $strMap = @{}
    for ($i = 0; $i -lt $allStrings.Count; $i++) { $strMap[$allStrings[$i]] = $i }
    function S([string]$Value) { return $strMap[$Value] }

    $stringPoolChunk = New-ResStringPool -Strings $allStrings
    $rm = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($rm)
    $w.Write([uint16]0x0180); $w.Write([uint16]8); $w.Write([uint32]12)
    $w.Write([uint32]0x01010199) # android:drawable, pinned public-final.xml
    $resourceMapChunk = $rm.ToArray()
    $w.Dispose(); $rm.Dispose()

    $tree = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($tree)

    function Write-IconNamespace([uint16]$type) {
        $w.Write($type); $w.Write([uint16]16); $w.Write([uint32]24)
        $w.Write([uint32]1); $w.Write([uint32]4294967295)
        $w.Write([int32](S 'android'))
        $w.Write([int32](S 'http://schemas.android.com/apk/res/android'))
    }
    function Write-IconStartElement([string]$Name, [AllowEmptyCollection()][array]$Attributes, [uint32]$Line) {
        $w.Write([uint16]0x0102); $w.Write([uint16]16)
        $w.Write([uint32](36 + 20 * $Attributes.Count))
        $w.Write($Line); $w.Write([uint32]4294967295)
        $w.Write([int32]-1); $w.Write([int32](S $Name))
        $w.Write([uint16]20); $w.Write([uint16]20); $w.Write([uint16]$Attributes.Count)
        $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint16]0)
        foreach ($attribute in $Attributes) {
            $w.Write([int32](S 'http://schemas.android.com/apk/res/android'))
            $w.Write([int32](S 'drawable'))
            $w.Write([int32]-1)
            $w.Write([uint16]8); $w.Write([byte]0); $w.Write([byte]$attribute.Type)
            $w.Write([uint32]$attribute.Data)
        }
    }
    function Write-IconEndElement([string]$Name, [uint32]$Line) {
        $w.Write([uint16]0x0103); $w.Write([uint16]16); $w.Write([uint32]24)
        $w.Write($Line); $w.Write([uint32]4294967295)
        $w.Write([int32]-1); $w.Write([int32](S $Name))
    }

    Write-IconNamespace 0x0100
    Write-IconStartElement 'adaptive-icon' @() 2
    Write-IconStartElement 'background' @([pscustomobject]@{ Type = 0x01; Data = $BackgroundResourceId }) 3
    Write-IconEndElement 'background' 3
    Write-IconStartElement 'foreground' @([pscustomobject]@{ Type = 0x01; Data = $ForegroundResourceId }) 4
    Write-IconEndElement 'foreground' 4
    Write-IconEndElement 'adaptive-icon' 2
    Write-IconNamespace 0x0101

    $treeBytes = $tree.ToArray()
    $w.Dispose(); $tree.Dispose()

    $document = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($document)
    $size = 8 + $stringPoolChunk.Length + $resourceMapChunk.Length + $treeBytes.Length
    $w.Write([uint16]0x0003); $w.Write([uint16]8); $w.Write([uint32]$size)
    $w.Write($stringPoolChunk); $w.Write($resourceMapChunk); $w.Write($treeBytes)
    $w.Flush()
    $bytes = $document.ToArray()
    $w.Dispose(); $document.Dispose()
    return ,$bytes
}

function New-BinaryAxmlManifest {
    param(
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $ActivityClassName,
        [string] $ActivityLabel = "Pwsh",
        [int] $VersionCode = 1,
        [string] $VersionName = "1.0-preview",
        [int] $MinSdkVersion = 26,
        [int] $TargetSdkVersion = 37,
        [int] $CompileSdkVersion = 37,
        [string] $CompileSdkVersionCodename = "17",
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

    # The pool is built in the order that produced the device-proven manifest:
    # the base strings, less the .NET for Android provider, then NativeActivity's.
    $attrNames += 'hasCode'                        # ResID: 0x0101000C
    $resIds += 0x0101000C
    if ($Debuggable) {
        $attrNames += 'debuggable'                 # ResID: 0x0101000F
        $resIds += 0x0101000F
    }
    $otherStrings = @($otherStrings | Where-Object { $_ -notin 'mono.MonoRuntimeProvider', $providerAuthority, 'provider' })
    $otherStrings += @('android.app.NativeActivity', 'android.app.lib_name', $NativeLibraryName)
    $activityFullName = 'android.app.NativeActivity'

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
    # debuggable (0x0101000F) follows hasCode.
    $flags = @((Attr-Bool 'hasCode' $false)) + @(if ($Debuggable) { (Attr-Bool 'debuggable' $true) })
    $appAttrs = @($appAttrs[0..2]) + $flags + @($appAttrs[3..4])
    Write-StartElem 'application' $appAttrs 12

    $activityAttrs = @(
        (Attr-Ref 'theme' 0x0103022E),
        (Attr-String 'label' $ActivityLabel),
        (Attr-Ref 'icon' 0x7f010000),
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
    # NativeActivity loads lib<value>.so and calls ANativeActivity_onCreate
    # (lib/native_activity.h).
    Write-StartElem 'meta-data' @((Attr-String 'name' 'android.app.lib_name'), (Attr-String 'value' $NativeLibraryName)) 18
    Write-EndElem 'meta-data' 18
    Write-EndElem 'activity' 13

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
                        if ($at + $byteLength -gt $cursor + $chunkSize) { throw "String $s runs past the string pool." }
                        $strings.Add([System.Text.Encoding]::UTF8.GetString($Document, $at, $byteLength))
                    }
                    else {
                        $length = [BitConverter]::ToUInt16($Document, $at)
                        if ($length -band 0x8000) { $length = (($length -band 0x7FFF) -shl 16) -bor [BitConverter]::ToUInt16($Document, $at + 2); $at += 4 } else { $at += 2 }
                        if ($at + 2 * $length -gt $cursor + $chunkSize) { throw "String $s runs past the string pool." }
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

function Get-AxmlChunkOffset {
    # Offset of the Nth chunk of a type, walking the document's chunk sizes.
    param([Parameter(Mandatory)][byte[]] $Document, [Parameter(Mandatory)][uint16] $Type, [int] $Occurrence = 0)
    $cursor = [BitConverter]::ToUInt16($Document, 2)
    $seen = 0
    while ($cursor -lt $Document.Length) {
        if ([BitConverter]::ToUInt16($Document, $cursor) -eq $Type) {
            if ($seen -eq $Occurrence) { return $cursor }
            $seen++
        }
        $cursor += [BitConverter]::ToUInt32($Document, $cursor + 4)
    }
    throw ('No chunk of type 0x{0:X4} at occurrence {1}.' -f $Type, $Occurrence)
}

function Test-ManifestNegativeControls {
    # Each mutation breaks one rule the reader enforces and must be rejected for
    # that reason: AOSP validate_chunk (size and header alignment, minimum
    # header, header within chunk, chunk within container), start-element
    # attribute bounds, string-pool bounds, and resource-map identity.
    param([Parameter(Mandatory)][byte[]] $Document)

    $res = Get-ResourceChunkConstants
    $set16 = { param($d, $at, $v) [System.Array]::Copy([BitConverter]::GetBytes([uint16]$v), 0, $d, $at, 2) }
    $set32 = { param($d, $at, $v) [System.Array]::Copy([BitConverter]::GetBytes([uint32]$v), 0, $d, $at, 4) }
    $pool = Get-AxmlChunkOffset -Document $Document -Type $res['RES_STRING_POOL_TYPE']
    $map = Get-AxmlChunkOffset -Document $Document -Type $res['RES_XML_RESOURCE_MAP_TYPE']
    $endElement = Get-AxmlChunkOffset -Document $Document -Type $res['RES_XML_END_ELEMENT_TYPE']
    $startElement = Get-AxmlChunkOffset -Document $Document -Type $res['RES_XML_START_ELEMENT_TYPE']
    $last = [BitConverter]::ToUInt16($Document, 2)
    while ($last + [BitConverter]::ToUInt32($Document, $last + 4) -lt $Document.Length) { $last += [BitConverter]::ToUInt32($Document, $last + 4) }
    $hasCodeEntry = -1
    for ($i = 0; $i -lt ([BitConverter]::ToUInt32($Document, $map + 4) - 8) / 4; $i++) {
        if ([BitConverter]::ToUInt32($Document, $map + 8 + 4 * $i) -eq 0x0101000C) { $hasCodeEntry = $map + 8 + 4 * $i }
    }
    if ($hasCodeEntry -lt 0) { throw 'The document under test has no android:hasCode resource-map entry.' }
    $firstString = $pool + [BitConverter]::ToUInt32($Document, $pool + 20) + [BitConverter]::ToUInt32($Document, $pool + 28)

    $controls = [ordered]@{
        'misaligned chunk size'        = @({ param($d) & $set32 $d ($pool + 4) ([BitConverter]::ToUInt32($d, $pool + 4) - 2) }, 'multiples of 4')
        'misaligned header size'       = @({ param($d) & $set16 $d ($pool + 2) 30 }, 'multiples of 4')
        'header below minimum'         = @({ param($d) & $set16 $d ($pool + 2) 24 }, 'needs at least 28')
        'header larger than chunk'     = @({ param($d) & $set16 $d ($endElement + 2) 28 }, 'is only 24 bytes')
        'chunk past its container'     = @({ param($d) & $set32 $d ($last + 4) ([BitConverter]::ToUInt32($d, $last + 4) + 4) }, 'runs past its container')
        'attributes past their node'   = @({ param($d) & $set16 $d ($startElement + 16 + 12) 60 }, 'past the end of its node')
        'string past the pool'         = @({ param($d) & $set16 $d $firstString 0x7FFF }, 'runs past the string pool')
        'wrong resource-map id'        = @({ param($d) & $set32 $d $hasCodeEntry 0x01010003 }, 'hasCode maps to 0x01010003')
    }
    foreach ($name in $controls.Keys) {
        $mutated = [byte[]]$Document.Clone()
        & $controls[$name][0] $mutated
        $message = $null
        try { [void](Assert-ManifestAttributeIds -Report (Test-BinaryAxml -Document $mutated)) }
        catch { $message = $_.Exception.Message }
        if ($null -eq $message) { throw "Negative control '$name' was accepted." }
        if ($message -notmatch [regex]::Escape($controls[$name][1])) { throw "Negative control '$name' was rejected for another reason: $message" }
    }
    $controls.Count
}

function Invoke-Aapt2ManifestCheck {
    # Diagnostic only: an independently implemented Android parser reads the
    # manifest. Nothing it produces is used by the build.
    param([Parameter(Mandatory)][byte[]] $Document, [Parameter(Mandatory)][string] $Label)
    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ('pwsh-manifest-check-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    Write-Host ('[ .. ] aapt2 check writes and then deletes {0}' -f $zipPath) -ForegroundColor DarkCyan
    try {
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $stream = $archive.CreateEntry('AndroidManifest.xml').Open()
            try { $stream.Write($Document, 0, $Document.Length) } finally { $stream.Dispose() }
        }
        finally { $archive.Dispose() }
        $output = & $Aapt2Path dump xmltree --file AndroidManifest.xml $zipPath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "aapt2 rejects the $Label manifest: $($output -join ' ')" }
    }
    finally { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
}

function Invoke-ManifestValidation {
    # The inner loop for binary Android XML: production emitters, reader and
    # checks, without the rest of the build. Returns the exit code.
    try {
        [void](Test-AndroidAttributeIds)
        $native = New-BinaryAxmlManifest -PackageName $script:PackageName -ActivityClassName $script:ActivityClassName -ActivityLabel $script:ApplicationLabel
        $count = Assert-ManifestAttributeIds -Report (Test-BinaryAxml -Document $native)
        $controls = Test-ManifestNegativeControls -Document $native
        $adaptive = New-AdaptiveIconAxml -ForegroundResourceId 0x7f010001 -BackgroundResourceId 0x7f020000
        $adaptiveReport = Test-BinaryAxml -Document $adaptive
        $adaptiveIds = Assert-ManifestAttributeIds -Report $adaptiveReport
        $adaptiveNames = @($adaptiveReport.Elements | ForEach-Object Name)
        if (($adaptiveNames -join '/') -cne 'adaptive-icon/background/foreground') {
            throw "The adaptive icon emitted unexpected elements: $($adaptiveNames -join '/')."
        }
        if ($adaptiveIds -ne 2) { throw "The adaptive icon has $adaptiveIds checked android: attributes; expected 2." }
        if ($adaptiveReport.Elements[1].Attributes['drawable'] -ne [uint32]0x7f020000) {
            throw 'The adaptive icon background reference did not round-trip.'
        }
        if ($adaptiveReport.Elements[2].Attributes['drawable'] -ne [uint32]0x7f010001) {
            throw 'The adaptive icon foreground reference did not round-trip.'
        }
        if ($Aapt2Path) { Invoke-Aapt2ManifestCheck -Document $native -Label 'NativeActivity' }
        Write-Host ('[PASS] Binary XML validation: the manifest and adaptive icon pass the reader with {0} and {1} android: attributes matched to public-final.xml ids; {2} malformed-document controls rejected for the expected reason{3}.' -f
            $count, $adaptiveIds, $controls, $(if ($Aapt2Path) { '; aapt2 parses the manifest' } else { '' })) -ForegroundColor Green
        return 0
    }
    catch {
        Write-Host ('[FAIL] Manifest validation: {0}' -f $_.Exception.Message) -ForegroundColor Red
        return 1
    }
}

function Invoke-ManifestStep {

    $manifestBytes = New-BinaryAxmlManifest `
        -PackageName $script:PackageName `
        -ActivityClassName $script:ActivityClassName `
        -ActivityLabel $script:ApplicationLabel
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
        'android.app.NativeActivity',
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
    $versions = 'pinned  .NET {0}  Android {1}  PowerShell {2}' -f
        (Get-PinnedVersion -Channel DotNet), (Get-PinnedVersion -Channel Android), (Get-PinnedVersion -Channel PowerShell)
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
        "worker $(if ($script:WorkerPowerShell) { $script:WorkerPowerShell.InvocationStateInfo.State } else { 'none' })"
        ''
    ) + $last)
}

function Show-OfflinePopup {
    if ($script:OfflineShown) { return }
    $script:OfflineShown = $true
    Show-Popup -Title 'No internet connection' -Lines @($script:OfflineMessage, 'Connect, then select Build again.')
}
$script:LogSaved      = $false

function Get-VersionDisplay {
    # Versions are pinned in lib/manifest.json; the interface shows them and
    # offers no other.
    param([Parameter(Mandatory)][string] $Channel)
    "$(Get-PinnedVersion -Channel $Channel) (pinned)"
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
           Caption = if ($Debug) { 'Intermediates written' } else { 'APK only' } }
        @{ Id = 'Payload'; Kind = 'Option'; Label = 'Payload'; Value = $Payload
           Caption = switch ($Payload) {
               'Minimal'  { 'IL only, no R2R' }
               'Standard' { 'All assemblies + R2R (not built yet)' }
               'SDK'      { 'Standard + PowerShell SDK (not built yet)' }
           } }
        @{ Id = 'Step'; Kind = 'Option'; Label = 'Step'; Value = "$Step  $($stepNode.Key)"; Caption = $stepNode.Title }
        @{ Id = 'DotNet'; Kind = 'Option'; Label = '.NET'; Value = (Get-VersionDisplay DotNet); Caption = 'lib/manifest.json' }
        @{ Id = 'Android'; Kind = 'Option'; Label = 'Android'; Value = (Get-VersionDisplay Android); Caption = 'lib/manifest.json' }
        @{ Id = 'PowerShell'; Kind = 'Option'; Label = 'PowerShell'; Value = (Get-VersionDisplay PowerShell); Caption = 'lib/manifest.json' }
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
        # .NET, Android and PowerShell are pinned; they do not step.
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
            '  -OutputDirectory <path>     Build output'
            '  -DeletePackages             Delete packages on exit'
            '  -WhatIf                     Preview only'
            ''
            '  pwsh -File setup.ps1 -c -Step 9'
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
    Start-PipelineWorker
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
        param($EventQueue, $ScriptPath, $TargetStep, $Architecture, $DebugRun, $Payload, $Packages,
              $CacheDirectory, $OutputDirectory, $SigningKeyPath, $DeletePackages, $PreviewOnly)
        Set-StrictMode -Version Latest
        try {
            $arguments = @{
                Headless        = $true
                Step            = $TargetStep
                Architecture    = $Architecture
                Payload         = $Payload
                Packages        = $Packages
                CacheDirectory  = $CacheDirectory
                OutputDirectory = $OutputDirectory
                SigningKeyPath  = $SigningKeyPath
                # The write plan was approved before the interface opened.
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

if ($ValidateManifest) { exit (Invoke-ManifestValidation) }

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
