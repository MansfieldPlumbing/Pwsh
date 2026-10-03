# Pwsh — PowerShell runspaces on Android

> A bespoke SDK in one PowerShell script, bringing in-process PowerShell
> runspaces to Android—because “every system” should mean every system.

**Status: 1.0-preview.** The build and Android hosting substrate are working;
the integrated terminal and general application surface remain gated work.

One PowerShell script. No .NET SDK, no Android SDK, no JDK, no NuGet client, no
MSBuild, no Roslyn, no `aapt2`, no `javac`, no `d8`, no `apksigner`, no
`zipalign`. You run `setup.ps1` and you get a signed APK.

```powershell
pwsh -NoProfile -File .\setup.ps1 -c -Step 9 -AcceptWritePlan
```

Before writing anything, the script prints its write plan: every location it
will write to. Interactive runs ask for confirmation; unattended runs need
`-AcceptWritePlan` or explicit locations.

That is the entire toolchain. `pwsh` is the only thing you need installed, and
the script restores everything else it requires from pinned, hash-verified
addresses.

## Status

Steps 1 through 9 pass for the current x86-64 development candidate: a
18,244,452-byte signed, debuggable APK with no DEX and no .NET for Android. The framework's
`android.app.NativeActivity` loads the emitted `libpwsh-host.so`, which starts
CoreCLR, serves the requested startup images from a 104-assembly IL-only store, opens a
PowerShell runspace on the main thread and runs `Profile.ps1`. The preceding
91-image payload is proven on the x86_64 emulator, a Samsung Galaxy S23 (arm64)
and an onn 4K Plus (arm32). The 102-image command candidate failed Utility
import on the emulator; the current candidate adds its pinned MarkdownRender
and Markdig dependencies. It passes the [x86-64 hardware Canvas probe](docs/receipt-hardware-canvas-x64.md),
including filesystem/JSON commands and extended liveness with telemetry disabled.
The current command payload still needs arm64/arm32 receipts and cryptographic
command execution. Hardware Canvas remains a diagnostic script; the managed
UI, installed startup payload and IME are subsequent gates.

The artifact above is the retained 104-image diagnostic build. The current source
payload is 98 images; dependencies leave it in the order of step 2 of
[the implementation plan](docs/implementation-plan.md), each only when its
replacement passes. It is not yet a replacement release.

The APK preview has an explicit [release finish line](ROADMAP.md#release-apk-preview-finish-line):
a working installed console, an independent retained graphical pane, Android
text input, profile recovery, and matching release-artifact receipts. Full TUI
compatibility and optional native application hosting are later capabilities.
| Emitted | Proven by |
| --- | --- |
| IL-only assembly store | CoreCLR loaded CoreLib, SMA and the startup set in place from the mapped store |
| `libassembly-store.so` | the host resolved the store symbol and served the requested startup images |
| `libpwsh-host.so` | `ANativeActivity_onCreate` started CoreCLR; `Admit` returned 0x50575348 |
| `libpsl-native.so` | SMA's native calls during `Open` resolved |
| `Dev.MansfieldPlumbing.Pwsh.dll` | `RunPowerShell` opened the runspace and ran `Profile.ps1` |
| `AndroidManifest.xml` | Android installed and launched the package |
| APK zip and v2 signature | Android accepted the install |

Not yet done, stated plainly:

- **Command payload device gate.** The build now admits and imports
  `Microsoft.PowerShell.Commands.Utility`, `.Commands.Management` and
  `.Security` directly from the in-memory store, and verifies one registered
  cmdlet from each family before `Profile.ps1`. The APK builds; execution on
  all three device backends is not yet recorded.
- **The console is still a probe, not the product shell.** The PowerShell
  console model passes its 63 conformance vectors on all three backends, and
  the device probe draws it, consumes input and reflows after pinch-to-resize.
  It is not yet wired into the release host as an interactive terminal.
- **CellCanvas does not run yet.** It ran under .NET for Android; it returns
  when gate 2e supplies its Android compatibility surface (`ROADMAP.md`).
- **Startup.** Without ReadyToRun the JIT compiles the startup path: about
  1.0 s on the S23 and 7 s on the onn. A leaner initial session is next.
- **Hashing and TLS** need the planned emitted `NativeActivity` subclass,
  which loads the runtime's Android crypto library from Java.
- **Release metadata** is not complete. The SBOM, applicable third-party
  notices and per-backend release receipts remain release gates.

## Platform support

PowerShell is not released for Android, and .NET treats Android as an
application platform rather than a PowerShell host, so every backend here is
this project's own work. The three backends are not equally easy to prove:

| ABI | Proven on | Notes |
| --- | --- | --- |
| x86-64 | Android emulator (API 36) | The fastest loop; finds the next boundary first. |
| arm64 | A physical phone (API 36) | Confirms each gate on real hardware. |
| arm32 | An onn 4K Plus, Google TV (API 34) | The only arm32 hardware available. Phone-class arm32 is **not tested**: current arm64 phones often ship without 32-bit support, and emulated ARM on an x86-64 image proves the translator, not the hardware. |

Google TV makes arm32 harder than a phone would:

- **Activity re-creation.** Google TV destroys and re-creates activities in a
  running process far more readily than a phone. The host currently starts
  CoreCLR on every `ANativeActivity_onCreate`, so a re-creation fails
  (`coreclr_initialize` 0x80131022); the fix, re-attaching the running session
  to the new activity, is on the [roadmap](ROADMAP.md) and applies to every ABI.
- **No touch, no window resize.** Input is a remote (D-pad, Select, Back) and an
  on-screen keyboard; windows do not resize in normal use. TV receipts check
  relaunch and re-creation instead of resize.
- **Slower hardware.** Startup is about 7 s with the IL-only store, and
  interpreted drawing is slow until the console is lowered to IL.

## Design

**The build script is inside the thing it builds.** The assemblies `setup.ps1`
relies on are all among the 98 it ships, because a PowerShell host and an APK
builder need the same things:

```
System.Reflection.Emit + ILGeneration + Lightweight   emits the app assembly
System.Reflection.Metadata                            reads MVIDs and tokens
System.IO.Compression + ZipFile                       reads packages, writes the APK
System.Net.Http                                       acquires packages
System.Security.Cryptography + Pkcs + Formats.Asn1    digests, keys, v2 signing
```

The APK should therefore be able to rebuild itself on the device. That is a design goal and has not been
run.

**Scripts are meant to be the application layer.** The planned host starts a
runspace and runs a start script; a `.ps1` is a feature, not a configuration
file. Today the activity runs `Profile.ps1` in a runspace it opens at startup (see Status).

## Documentation

Published at [learn.mansfieldplumbing.dev/Pwsh](https://learn.mansfieldplumbing.dev/Pwsh/).
Status of every item is in [ROADMAP.md](ROADMAP.md); proofs are in
[docs/receipt-hardware-canvas-x64.md](docs/receipt-hardware-canvas-x64.md) and
the established facts in [AGENTS.md](AGENTS.md).

| Topic | Document |
| --- | --- |
| Startup modes, crash-loop breaker, Recovery, private storage | [docs/console-host.md](docs/console-host.md) |
| Console core and its 63 conformance vectors | [docs/console-reference.md](docs/console-reference.md) |
| Text editing: one core, cell and proportional layouts | [docs/editor.md](docs/editor.md) |
| Start tiles, control surfaces, endpoint tiles and zones, navigation tree | [docs/views-and-tiles.md](docs/views-and-tiles.md) |
| Commands as scripts on `PATH` | [docs/work-optional-scripts.md](docs/work-optional-scripts.md) |
| Processes, native bundles, the broker, updates outside a store | [docs/native-extensions.md](docs/native-extensions.md) |
| Lowering PowerShell to IL, the IL stack check | [docs/lowering.md](docs/lowering.md) |
| Payload reduction and compatibility stand-ins | [docs/implementation-plan.md](docs/implementation-plan.md) |
| Working practices | [docs/practices.md](docs/practices.md) |
| What is published where, and what is never published | [docs/publishing.md](docs/publishing.md) |

## What this actually is

It is not a terminal emulator, and it is not a shell that shells out to a
packaged binary. The APK carries a CoreCLR runtime and
`System.Management.Automation`. Scripts are meant to be the application layer:
the APK is the appliance, and a `.ps1` is a feature.

PowerShell binds by reflection at runtime, so an ILLink-style reachability pass
cannot see what a script will call, and static trimming does not apply. Whole
assemblies can still be dropped when measurement on the device shows they are
never loaded.

That is why the store is 111 MB where a trimmed MSBuild build is 8 MB. The gap
was measured as 4.4x trimming and 3.2x Zstandard compression.

## Why no build tools

Because none of them are load-bearing. An APK is a ZIP with a particular index,
a binary XML manifest, native libraries, optional DEX, and a signature block.
Every one of those is a documented byte format. This preview deliberately has
no DEX. The SDKs are convenient, not necessary, and once you drop them the
build stops depending on a machine's installed state.

What replaces them is provenance. Every input is pinned by SHA-256 and verified
before it is parsed:

- NuGet packages are resolved through the v3 service index, downloaded, and
  checked against pinned digests. Identity and version are re-read from the
  `.nuspec` inside the verified archive.
- The binary format specifications live in `lib/`, each pinned to an exact
  upstream commit: `dotnet/android` for the store, `llvm-project` for ELF64, `aosp-mirror` for binary XML.
- The script holds exactly one constant: the SHA-256 of the root provenance
  manifest. Every other digest, address, format constant and ordered name chains
  back to it.

Step 1 re-downloads every pinned address and proves the published bytes still
hash to the recorded digest. Provenance is a build step, not a README claim.

One hard lesson is encoded here: pin source and binaries at the *same* version.
Reading a newer `host.cc` than the runtime pack we ship produced a null pointer
dereference inside `coreclr_initialize`, because the newer host fills in runtime
property values the shipped one does not.

## Steps

Each step runs its dependencies first, so `-Step 9` is a full build.

| Step | What it does |
| --- | --- |
| 1 | Verify pinned specifications against their digests and upstream addresses |
| 2 | Acquire and hash the pinned NuGet packages |
| 3 | Inspect and classify every payload in those packages |
| 4 | Select the 98-assembly payload; re-emit ReadyToRun images as IL-only |
| 5 | Emit and verify the assembly store |
| 6 | Wrap the store in an ELF library; emit `libpwsh-host.so` and `libpsl-native.so` |
| 7 | Emit the binary `AndroidManifest.xml` |
| 8 | Assemble the unsigned APK archive |
| 9 | Sign with APK Signature Scheme v2 |

`-h` explains every switch. `-Architecture`, `-Debug`, `-CacheDirectory`,
`-OutputDirectory`, `-SigningKeyPath`, `-AcceptWritePlan` and `-DeletePackages`
are available non-interactively;
running with no switches opens the interactive interface, and a redirected or
unattended session runs headlessly through the same functions.

## Notable mechanics

**The managed host is emitted, not compiled.** `Dev.MansfieldPlumbing.Pwsh.dll`
holds the entries the native host calls. They are LINQ expression trees compiled
into a `PersistedAssemblyBuilder` assembly; the build rejects any tree that still
holds a dynamic call site or a constant IL cannot encode. No compiler runs in
the build, and the only C# in the repository is upstream reference files in
`lib/`, which are never compiled.

**Machine code comes from named encoders.** The native host, the store library
and `libpsl-native.so` are written instruction by instruction for x86-64, A64 and
Thumb-2/A32, decoded back by an independent decoder and checked against each
ABI's control-flow rules.

**ReadyToRun is removed.** Every runtime image that carries precompiled code is
re-emitted IL-only: its IL, field data, metadata and resources are kept, its
native code is dropped, and its method and field addresses are rewritten. The
store serves the images in place and the JIT compiles what runs.

## Layout

```
setup.ps1         the build
lib/              pinned specifications, restored on demand, never executed
lib/manifest.json the root provenance manifest; setup.ps1 holds only its digest
ROADMAP.md        where the project is going, gate by gate
docs/DEVELOPER.md decisions, proofs, architecture targets, testing
scripts/          the frozen CellCanvas workload, its reference inventory, device probes
modules/          console model; Android Canvas binding from PowerShell (JNI, NDK)
src/addons/       optional host-side capabilities; inert until separately admitted
tools/            device script runner (run-as, no rebuild); payload closure probe; pre-push scan
.githooks/        pre-push hook (git config core.hooksPath .githooks)
```

By default, the only file the build writes inside the repository is the signed
APK under `build\`. With `-KeepIntermediates`, its intermediates are written
there too. The build fails if anything outside its confirmed write plan changes
during a run, and it ends by listing every file it wrote with its SHA-512.

The signed APK is written to `build\dev.mansfieldplumbing.pwsh.apk` (the
Android package name). `build\` is the only place inside the repository the
script writes, and git ignores it. `-ApkPath` puts the APK elsewhere. Every
intermediate artifact stays in memory; `-KeepIntermediates` writes them to
`build\` for inspection. The signing key and package cache never go inside
the repository and default to per-user data:
`%LOCALAPPDATA%\Pwsh` on Windows, the Library folders on macOS, and the XDG
data and cache directories on Linux.
`-OutputDirectory`, `-SigningKeyPath` and `-CacheDirectory` override them.
Packages stay in memory unless `-Packages Folder` is chosen. The APK signing
key is created once and reused, because Android refuses to upgrade an
installed app whose signer changed.

`lib/` also holds C# files from `dotnet/android`. They are upstream producer
references, read to confirm a format. They are never compiled, imported, or
executed.

## Author

Pwsh is written and maintained by Scott Mansfield
([MansfieldPlumbing](https://github.com/MansfieldPlumbing)). So far there are
no other contributors.

## Disclaimer

Pwsh is an independent project and is neither affiliated with, nor authorized,
sponsored, or approved by Microsoft Corporation. Microsoft, .NET and PowerShell
are trademarks of the Microsoft group of companies. Android is a trademark of
Google LLC. All other trademarks are the property of their respective owners.
The names are used here only to describe what this project builds and runs on.

The packages `setup.ps1` downloads, including the .NET runtime and PowerShell,
are published by Microsoft and remain under their own licenses.
