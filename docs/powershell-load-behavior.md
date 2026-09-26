# PowerShell load behavior on Unix builds

Evidence for choosing the device payload. Source is PowerShell/PowerShell at
tag `v7.7.0-preview.5`, commit `149ab5cd6cad34869177f86ef9a3da8414f85dc6`.
The payload ships the `runtimes/unix` build of System.Management.Automation,
so code under `#if !UNIX` is absent from it.

## How the payload is decided

- Upper bound: the static AssemblyRef closure. `tools/Get-AssemblyClosure.ps1`
  computes it over SHA-512-pinned packages: 124 images from
  System.Management.Automation, Microsoft.PowerShell.Commands.Utility,
  Microsoft.PowerShell.Commands.Management and Microsoft.PowerShell.Security
  on android-arm64, 82 of them carrying ReadyToRun code.
- Lower bound: the assemblies CoreCLR actually asks the host for, logged by
  `-TraceAssemblyProbe` on a device run.
- Shipped: the lower bound, plus what each supported feature needs, each entry
  with its reason.

Static reading cannot settle JIT-time loads: RyuJIT resolves the type tokens
of a method it compiles, which can load an assembly on a branch that never
runs. Where that matters below, the device trace decides.

## Verified at the commit

| Assembly | Finding | Source |
| --- | --- | --- |
| Microsoft.Management.Infrastructure | `[ciminstance]` is a built-in type accelerator with no platform guard, so the assembly loads when the accelerator table initializes. | `engine/parser/TypeResolver.cs:750` |
| System.Management, System.DirectoryServices | The `wmi`, `wmiclass`, `wmisearcher`, `adsi` and `adsisearcher` accelerators are inside `#if !UNIX`; the Unix build does not reference them at startup. | `engine/parser/TypeResolver.cs:808-814` |
| Microsoft.ApplicationInsights | The telemetry static constructor reads `POWERSHELL_TELEMETRY_OPTOUT` and returns early when set, but `TelemetryConfiguration.CreateDefault()` and `new TelemetryClient` are in the same method. Whether the opt-out lets the assembly be dropped is for the device trace to decide. | `utils/Telemetry.cs:178-207` |
| Newtonsoft.Json | `PowerShellConfig` parses the configuration file with Newtonsoft; experimental-feature and module-path code read it. | `engine/PSConfiguration.cs:12-13, 58` |

The Microsoft.Management.Infrastructure 3.0.0 package ships reference
assemblies only and no `runtime.json`. Its Unix implementation comes from the
separate Microsoft.Management.Infrastructure.Runtime.Unix package.

## Reported, not yet verified here

From a first-pass source survey. Each item needs its own check before a
payload decision depends on it.

- `InitialSessionState.CreateDefault2()` imports no modules and one snap-in,
  Microsoft.PowerShell.Core; utility and management modules load on demand.
- Microsoft.CodeAnalysis (Roslyn) loads only when `Add-Type` compiles source;
  Markdig and Microsoft.PowerShell.MarkdownRender only when the Markdown
  cmdlets run; JsonSchema.Net, JsonPointer.Net and Json.More.Net only when
  `Test-Json` validates a schema; Humanizer only from the web cmdlets.
- Microsoft.PowerShell.Commands.Utility defines 111 cmdlets, four of them
  Windows-only (`ConvertFrom-SddlString`, `Out-GridView`, `Show-Command`,
  `Out-Printer`). Microsoft.PowerShell.Commands.Management defines 57, fourteen
  of them Windows-only (the service cmdlets, `Get-ComputerInfo`, `Get-HotFix`,
  `Rename-Computer`, `Set-TimeZone`, `Clear-RecycleBin`).
