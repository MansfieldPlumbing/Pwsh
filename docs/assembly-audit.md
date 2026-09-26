# Assembly audit

Status: draft. Its decisions predate the source checks in
`powershell-load-behavior.md` and are reconciled against them before any
payload is frozen from this list.

Date: 2026-09-25. Produced by an earlier version of
`tools/Get-AssemblyClosure.ps1`; every number
below is that script's output, not an estimate.

This audit covers the Android payload only: the assemblies in the store and
the APK. What the Windows build host loads to run `setup.ps1` is a separate
list (see Build host), and none of it ships.

## Pins

Runtime: `Microsoft.NETCore.App.Runtime.android-arm64` `11.0.0-rc.1.26425.128`,
built from dotnet/dotnet commit `3551975be08744f0418857c5bed8ab1545c5dd47`.
PowerShell: `7.7.0-preview.5`, the newest release (there is no 7.7 RC).
Out-of-band runtime packages are taken at the runtime's version when
their nuspec names the same commit.

Every package is admitted only when it hashes to the SHA-512 published in its
NuGet catalog entry. These are the packages the payload draws from:

| Package | Version | SHA-512 |
| --- | --- | --- |
| `Microsoft.NETCore.App.Runtime.android-arm64` | `11.0.0-rc.1.26425.128` | `6800BE43058D535A83BAFC3606D495F49FE7A1D68359B577D914BAF9AB5AB6840C833A78F605EBBEC2A60E1B4B918907BC9185C9BBFC00524EB188A7A4A2EF47` |
| `Microsoft.PowerShell.Commands.Management` | `7.7.0-preview.5` | `C1AEAA063FBD09494095D0DB170D49D6232A9F15ECE658EC51D04C66E17C88CEAAE306A39597263F3C585C31A74097822BB87455FA3650687E80D32665454B80` |
| `Microsoft.PowerShell.Commands.Utility` | `7.7.0-preview.5` | `1BA02A3BAD7A1FB584FF449317A0A077CF6FE0DF5D0EE7C50D7AF80C332D37B738BD700BD323EBC4BE73DDC879B1FF8F1196BFC4D8FCBEFAEE313D8AC458A006` |
| `Microsoft.PowerShell.Security` | `7.7.0-preview.5` | `E6FC7B2DC41617E3A52D81FD387981249FD99D4741B74FC5C5CC84A086E01691B247CE2E9AA7194F6F98D6C514FF24712B37B9EC83A258C5DA7A7131685C0D32` |
| `Newtonsoft.Json` | `13.0.4` | `6D1FAFF84FF227A83B195DAE5F0D8EAD44A36187E32E438B0BC243E24092DB79AC2DAA672AD7493C1240EF97F01C7FBE12B21F7DE22ACD82132F102EAF82805C` |
| `System.Management.Automation` | `7.7.0-preview.5` | `1632FC2767839BE940C83A408D90A48D98F5E43EC053DC18550EA5F04C3AF1B2919E11AD7F0352E50CAD3F85AB5F9E6D55C045BDA877C7D3BE6C9D0369F02945` |
| `System.Security.Cryptography.Pkcs` | `11.0.0-rc.1.26425.128` | `4E5902AAAA3F430F279BD44FAA8EF2E545D5F6B373C30A47AF00E63F94C1184866BC31258D8AE5E278F5D5371E8CEF7AA182864BB99A79C601A459BD6A49E2E6` |

## Method

1. Roots: `System.Management.Automation` and the three cmdlet assemblies
   (`Microsoft.PowerShell.Commands.Utility`, `.Commands.Management`,
   `Microsoft.PowerShell.Security`).
2. Follow every `AssemblyRef` through the runtime pack and the packages'
   NuGet dependency graph. Result: 124 assemblies, 96,632 KB.
3. Exclude the clusters below. Excluded assemblies are not traversed; every
   reference a kept assembly still holds to one is listed under Severed.
   Result: 86 assemblies, 77,978 KB, 38 removed.

The closure is static. An assembly is kept because metadata references it,
not because a traced run loaded it.

## Removed

| Cluster | Assemblies | KB | Why it does not ship |
| --- | --- | --- | --- |
| C# compiler | `Microsoft.CodeAnalysis`, `.CSharp` | 9,944 | Roslyn serves `Add-Type -TypeDefinition`/`-MemberDefinition`. The product emits IL; it never compiles C#. |
| Markdown | `Microsoft.PowerShell.MarkdownRender`, `Markdig.Signed` | 509 | `ConvertFrom-Markdown`, `Show-Markdown`. Not a product capability. |
| JSON Schema | `JsonSchema.Net`, `JsonPointer.Net`, `Json.More`, `Humanizer` | 730 | `Test-Json -Schema`. `System.Text.Json` and `Newtonsoft.Json` stay. |
| Telemetry | `Microsoft.ApplicationInsights` | 377 | PowerShell usage telemetry. The appliance sends none. |
| GDI+ | `System.Drawing.Common`, `System.Private.Windows.Core`, `System.Private.Windows.GdiPlus`, `Microsoft.Win32.SystemEvents` | 1,804 | `[SupportedOSPlatform("windows")]`. Cannot run on Android. |
| Windows services | `System.ServiceProcess.ServiceController`, `System.Diagnostics.EventLog` | 87 | `[SupportedOSPlatform("windows")]`: `Get-Service` and event logs. |
| Windows registry and ACLs | `Microsoft.Win32.Registry`, `System.IO.FileSystem.AccessControl`, `System.Security.AccessControl`, `System.Security.Principal.Windows` | 155 | `[SupportedOSPlatform("windows")]`: the registry provider, `Get-Acl`, `Set-Acl`. |
| CIM | `Microsoft.Management.Infrastructure` | 0 | Its package has no assembly for Android; CIM cmdlets cannot run. |

Removing `Microsoft.ApplicationInsights` and `MarkdownRender` also removes
`netstandard`, the only thing that referenced it, and with it every assembly
reachable only through that facade.

Everything removed: `Humanizer`, `Json.More`, `JsonPointer.Net`, `JsonSchema.Net`, `Markdig.Signed`, `Microsoft.ApplicationInsights`, `Microsoft.CodeAnalysis`, `Microsoft.CodeAnalysis.CSharp`, `Microsoft.PowerShell.MarkdownRender`, `Microsoft.Win32.Registry`, `Microsoft.Win32.SystemEvents`, `netstandard`, `System.ComponentModel.Annotations`, `System.Diagnostics.Contracts`, `System.Diagnostics.EventLog`, `System.Drawing.Common`, `System.IO.FileSystem.AccessControl`, `System.IO.IsolatedStorage`, `System.Linq.Parallel`, `System.Linq.Queryable`, `System.Net.HttpListener`, `System.Net.WebClient`, `System.Net.WebProxy`, `System.Net.WebSockets`, `System.Net.WebSockets.Client`, `System.Private.DataContractSerialization`, `System.Private.Windows.Core`, `System.Private.Windows.GdiPlus`, `System.Reflection.DispatchProxy`, `System.Runtime.CompilerServices.VisualC`, `System.Runtime.Serialization.Json`, `System.Runtime.Serialization.Xml`, `System.Security.AccessControl`, `System.Security.Principal.Windows`, `System.ServiceProcess.ServiceController`, `System.Threading.Overlapped`, `System.Web.HttpUtility`, `System.Xml.XPath.XDocument`.

## Severed references

Each row is a call site in a kept assembly that must never run on the device.
A severed reference is harmless until the JIT compiles a method that uses the
missing type; then it throws `FileNotFoundException`.

| Excluded | Referenced by |
| --- | --- |
| `Humanizer` | `Microsoft.PowerShell.Commands.Utility` |
| `JsonPointer.Net` | `Microsoft.PowerShell.Commands.Utility` |
| `JsonSchema.Net` | `Microsoft.PowerShell.Commands.Utility` |
| `Microsoft.ApplicationInsights` | `System.Management.Automation` |
| `Microsoft.CodeAnalysis` | `Microsoft.PowerShell.Commands.Utility` |
| `Microsoft.CodeAnalysis.CSharp` | `Microsoft.PowerShell.Commands.Utility` |
| `Microsoft.Management.Infrastructure` | `Microsoft.PowerShell.Commands.Management`, `System.Management.Automation` |
| `Microsoft.PowerShell.MarkdownRender` | `Microsoft.PowerShell.Commands.Utility` |
| `Microsoft.Win32.Registry` | `Microsoft.PowerShell.Commands.Utility`, `System.Management.Automation` |
| `System.Drawing.Common` | `Microsoft.PowerShell.Commands.Utility` |
| `System.IO.FileSystem.AccessControl` | `Microsoft.PowerShell.Security`, `System.Management.Automation` |
| `System.Security.AccessControl` | `Microsoft.PowerShell.Commands.Management`, `Microsoft.PowerShell.Security`, `System.Management.Automation` |
| `System.Security.Principal.Windows` | `Microsoft.PowerShell.Commands.Management`, `Microsoft.PowerShell.Security`, `System.Management.Automation` |
| `System.ServiceProcess.ServiceController` | `Microsoft.PowerShell.Commands.Management` |

## Kept

86 assemblies, 77,978 KB. 64 carry ReadyToRun code;
none of our code uses it, and the payload ships IL only. Each R2R image is
re-emitted as a plain IL assembly: metadata, IL bodies, field data and
resources, and nothing else.

| Assembly | KB | R2R | Package |
| --- | --- | --- | --- |
| `Microsoft.CSharp` | 862 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `Microsoft.PowerShell.Commands.Management` | 956 | no | Microsoft.PowerShell.Commands.Management |
| `Microsoft.PowerShell.Commands.Utility` | 1,511 | no | Microsoft.PowerShell.Commands.Utility |
| `Microsoft.PowerShell.Security` | 316 | no | Microsoft.PowerShell.Security |
| `Microsoft.Win32.Primitives` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `Newtonsoft.Json` | 706 | no | Newtonsoft.Json |
| `System.Collections` | 317 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Collections.Concurrent` | 142 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Collections.Immutable` | 1,152 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Collections.NonGeneric` | 101 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Collections.Specialized` | 102 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.ComponentModel` | 17 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.ComponentModel.EventBasedAsync` | 38 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.ComponentModel.Primitives` | 77 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.ComponentModel.TypeConverter` | 844 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Console` | 85 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Data.Common` | 3,112 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.DiagnosticSource` | 556 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.FileVersionInfo` | 45 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.Process` | 441 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.StackTrace` | 29 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.TextWriterTraceListener` | 63 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.TraceSource` | 147 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Diagnostics.Tracing` | 16 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Drawing.Primitives` | 124 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Formats.Asn1` | 270 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.Compression` | 739 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.Compression.Brotli` | 82 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.Compression.ZipFile` | 146 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.FileSystem.DriveInfo` | 90 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.FileSystem.Watcher` | 136 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.MemoryMappedFiles` | 91 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.Pipelines` | 205 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.IO.Pipes` | 144 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Linq` | 841 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Linq.Expressions` | 4,748 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Management.Automation` | 13,873 | no | System.Management.Automation |
| `System.Memory` | 172 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Http` | 1,939 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Mail` | 619 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.NameResolution` | 282 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.NetworkInformation` | 111 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Ping` | 113 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Primitives` | 243 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Quic` | 384 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Requests` | 404 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Security` | 706 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.Sockets` | 682 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Net.WebHeaderCollection` | 59 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Numerics.Vectors` | 16 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.ObjectModel` | 75 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Private.CoreLib` | 18,435 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Private.Uri` | 253 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Private.Xml` | 8,747 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Private.Xml.Linq` | 429 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Reflection.Emit` | 334 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Reflection.Emit.ILGeneration` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Reflection.Emit.Lightweight` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Reflection.Metadata` | 1,247 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Reflection.Primitives` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Resources.Writer` | 44 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime` | 45 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.InteropServices` | 108 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.Intrinsics` | 18 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.Loader` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.Numerics` | 551 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.Serialization.Formatters` | 124 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Runtime.Serialization.Primitives` | 29 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Security.Claims` | 99 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Security.Cryptography` | 2,498 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Security.Cryptography.Pkcs` | 299 | no | System.Security.Cryptography.Pkcs |
| `System.Text.Encoding.CodePages` | 844 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Text.Encoding.Extensions` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Text.Encodings.Web` | 120 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Text.Json` | 2,717 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Text.RegularExpressions` | 1,159 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Threading` | 79 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Threading.Channels` | 161 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Threading.Tasks.Parallel` | 135 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Threading.Thread` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Threading.ThreadPool` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Transactions.Local` | 381 | yes | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Xml.ReaderWriter` | 21 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Xml.XDocument` | 16 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Xml.XmlSerializer` | 17 | no | Microsoft.NETCore.App.Runtime.android-arm64 |
| `System.Xml.XPath` | 15 | no | Microsoft.NETCore.App.Runtime.android-arm64 |

Not in this list and added by the build: `Dev.MansfieldPlumbing.Pwsh.dll`,
the managed entry points of `libpwsh-host.so`. Gone from the payload: the
.NET for Android assemblies (`Mono.Android`, `Mono.Android.Runtime`,
`Java.Interop`, `_Microsoft.Android.Resource.Designer`) and the empty `Probe`.

## Still to interrogate

Kept because a root references them. Each needs a stated user or a removal:

- `Microsoft.CSharp` (the `dynamic` binder), referenced by SMA and
  `Commands.Utility`.
- `System.Data.Common`, referenced by SMA and `Newtonsoft.Json`.
- `System.Net.Mail` (`Send-MailMessage`).
- `System.Net.Quic`, `[SupportedOSPlatform("linux")]` and reached through
  `System.Net.Http`.
- `System.Security.Cryptography.Pkcs` (certificate and CMS cmdlets; unverified which).
- `System.Transactions.Local`, `System.Resources.Writer`,
  `System.Diagnostics.TextWriterTraceListener`.

## Proof obligations

1. Device run: CoreCLR's probe log (`-TraceAssemblyProbe`) over startup and
   the gate workloads on all three backends. Every requested name must be in
   the kept list, and no request may be for an excluded name.
2. Every severed call site must be shown unreachable on those paths, or its
   cmdlet removed from the session state.
3. The store must contain no image with a ReadyToRun header.

## Build host

`setup.ps1` runs in `pwsh` on Windows. What it loads is not payload:
`System.Reflection.Metadata`, `System.Reflection.Emit`
(`PersistedAssemblyBuilder`), `System.Linq.Expressions`,
`System.IO.Compression`, and the host's own SMA for the types the emitted
`Dev.MansfieldPlumbing.Pwsh.dll` references.

The one coupling: an assembly emitted on the host records the host SMA's
version in its `AssemblyRef`. Checked on 2026-09-25: the host is PowerShell
7.7.0-preview.4 (SMA 7.7.0.4) and the payload is 7.7.0-preview.5. The build
must pin that reference to the payload's SMA, not inherit the host's.
