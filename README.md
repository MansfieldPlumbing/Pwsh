# Pwsh — a scripting appliance for Android

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

Steps 1 through 9 pass. `-Step 9` produces a signed
`dev.mansfieldplumbing.pwsh.apk` (about 16.5 MB for arm64) with no DEX and no
.NET for Android: the framework's `android.app.NativeActivity` loads the emitted
`libpwsh-host.so`, which starts CoreCLR, serves 91 IL-only assemblies in place
from the emitted store, opens a PowerShell runspace on the main thread and runs
`Profile.ps1`. Proven on the x86_64 emulator, a Samsung Galaxy S23 (arm64) and
an onn 4K Plus (arm32).

| Emitted | Proven by |
| --- | --- |
| IL-only assembly store | CoreCLR loaded CoreLib, SMA and the startup set in place from the mapped store |
| `libassembly-store.so` | the host resolved the store symbol and served every image from it |
| `libpwsh-host.so` | `ANativeActivity_onCreate` started CoreCLR; `Admit` returned 0x50575348 |
| `libpsl-native.so` | SMA's native calls during `Open` resolved |
| `Dev.MansfieldPlumbing.Pwsh.dll` | `RunPowerShell` opened the runspace and ran `Profile.ps1` |
| `AndroidManifest.xml` | Android installed and launched the package |
| APK zip and v2 signature | Android accepted the install |

Not yet done, stated plainly:

- **No cmdlet modules.** Commands such as `Get-ChildItem` and `Get-Process`
  (`Microsoft.PowerShell.Commands.Management`) are not present.
- **Drawing is probes so far.** Run as `Profile.ps1`, `scripts/ScreenProbe.ps1`
  fills the window, and `scripts/probes/canvas` draws text and ANSI colors
  with Android's `Canvas` through JNI, on all three devices; there is no
  terminal renderer or input handling yet.
- **CellCanvas does not run yet.** It ran under .NET for Android; it returns
  when gate 2e supplies its Android compatibility surface (`ROADMAP.md`).
- **Startup.** Without ReadyToRun the JIT compiles the startup path: about
  1.0 s on the S23 and 7 s on the onn. A leaner initial session is next.
- **Hashing and TLS** need the planned emitted `NativeActivity` subclass,
  which loads the runtime's Android crypto library from Java.
## Design

**The build script is inside the thing it builds.** The assemblies `setup.ps1`
relies on are all among the 91 it ships, because a PowerShell host and an APK
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
a DEX file, a binary XML manifest, some ELF64 shared objects, and a signature
block. Every one of those is a documented byte format. The SDKs are convenient,
not necessary, and once you drop them the build stops depending on a machine's
installed state.

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
| 4 | Select the 91-assembly payload; re-emit ReadyToRun images as IL-only |
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
tools/            device script runner (run-as, no rebuild); payload closure probe; pre-push scan
.githooks/        pre-push hook (git config core.hooksPath .githooks)
```

The only file the build writes inside the repository is the signed APK. It
fails if anything else in the repository changed during a run, and it ends by
listing every file it wrote with its SHA-512.

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

Pwsh is an independent project. Neither Pwsh nor its author is affiliated with,
endorsed by, or sponsored by Microsoft Corporation. PowerShell, .NET and
related names are trademarks of Microsoft; Android is a trademark of Google LLC.
They are used here only to describe what this project builds and runs on.

The packages `setup.ps1` downloads, including the .NET runtime and PowerShell,
are published by Microsoft and remain under their own licenses.
