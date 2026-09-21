# Pwsh — a scripting appliance for Android

One PowerShell script. No .NET SDK, no Android SDK, no JDK, no NuGet client, no
MSBuild, no Roslyn, no `aapt2`, no `javac`, no `d8`, no `apksigner`, no
`zipalign`. You run `setup.ps1` and you get a signed APK.

```powershell
pwsh -NoProfile -File .\setup.ps1 -c -Step 11 -AcceptWritePlan
```

Before writing anything, the script prints its write plan: every location it
will write to. Interactive runs ask for confirmation; unattended runs need
`-AcceptWritePlan` or explicit locations.

That is the entire toolchain. `pwsh` is the only thing you need installed, and
the script restores everything else it requires from pinned, hash-verified
addresses.

## Status

Steps 1 through 11 pass. `-Step 11` produces a signed `dev.mansfieldplumbing.pwsh.apk` that installs
on a Samsung Galaxy S23, launches, initializes CoreCLR, loads its assemblies out of the
emitted assembly store, resolves its activity through the emitted type map, and
runs emitted IL to draw its first screen. Verified on hardware.

Every artifact the script emits has been exercised by the device:

| Emitted | Proven by |
| --- | --- |
| XABA assembly store | CoreCLR loaded CoreLib, System.Runtime and Mono.Android from it |
| `libassembly-store.so` | `dlopen` plus `dlsym` of `_assembly_store` succeeded |
| `libxamarin-app.so` | 34 symbols resolved; the type map lookup succeeded |
| `AndroidManifest.xml` | Android installed and launched the package |
| `classes2.dex` | the Java peer instantiated the activity |
| `Pwsh.dll` IL | `OnCreate` ran and drew the first screen |
| APK zip and v2 signature | Android accepted the install |

Not yet done, stated plainly:

- **The host is minimal.** The activity opens a runspace and runs
  `Profile.ps1` in-process; on the x86_64 emulator that runs CanvasDemo. The
  payload carries no cmdlet modules, so commands such as `Get-ChildItem` and
  `Get-Process` (`Microsoft.PowerShell.Commands.Management`) are not present.
- **The type map covers only the emitted assembly.** `Mono.Android` needs its
  own module entry, so type registration still logs failures. It is derivable
  from the `Register` attributes those types already carry.
- **`classes.dex` is acquired, not emitted.** See Training wheels below.

## Design

**The build script is inside the thing it builds.** The assemblies `setup.ps1`
relies on are all among the 96 it ships, because a PowerShell host and an APK
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
  upstream commit: `dotnet/android` for the store, type map and application
  config, `llvm-project` for ELF64, `aosp-mirror` for binary XML.
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

Each step runs its dependencies first, so `-Step 11` is a full build.

| Step | What it does |
| --- | --- |
| 1 | Verify pinned specifications against their upstream addresses |
| 2 | Acquire and hash the pinned NuGet packages |
| 3 | Inspect and classify every payload in those packages |
| 4 | Select the 96-assembly lean payload |
| 5 | Emit and verify the XABA assembly store |
| 6 | Wrap the store in an ELF shared library for the target; emit `libpsl-native.so` |
| 7 | Emit the binary `AndroidManifest.xml` |
| 8 | Emit the Java peer class as Dalvik bytecode |
| 9 | Emit `libxamarin-app.so`, the application data library |
| 10 | Assemble the unsigned APK archive |
| 11 | Sign with APK Signature Scheme v2 |

`-h` explains every switch. `-Architecture`, `-Debug`, `-CacheDirectory`,
`-OutputDirectory`, `-SigningKeyPath`, `-AcceptWritePlan` and `-DeletePackages`
are available non-interactively;
running with no switches opens the interactive interface, and a redirected or
unattended session runs headlessly through the same functions.

## Notable mechanics

**Assemblies are emitted, not compiled.** `Pwsh.dll` contains a real Android
activity deriving from `Android.App.Activity`, with `OnCreate` emitted as IL
through `PersistedAssemblyBuilder`. The target `Mono.Android` contract is loaded
into an isolated `AssemblyLoadContext` so generated code binds against the
target runtime rather than the host's. No compiler runs in the build. The only
C# in the repository is the upstream reference files in `lib/` and the small
reference activity that `-Debug` hands to the .NET SDK for its cross-check;
the normal build compiles none of it.

**Dalvik bytecode is written directly.** Step 8 emits a DEX file containing the
Java peer: class definition, string table in ordinal order, Adler-32 checksum
and SHA-1 signature, and hand-assembled instructions. This is what lets the
build skip `javac` and `d8` entirely. Adding an intent, provider or service role
is another emitted peer plus another manifest element, not another toolchain.

**Names are derived, not chosen.** .NET Android names a generated Java peer
`crc64` plus a CRC-64/Jones hash of `namespace:assembly`. The polynomial upstream
documents is the normal form; a reflected implementation needs its reverse, and
getting that backwards yields a plausible-looking wrong answer. The derivation is
checked at build time against a known mapping, and `-Debug` re-checks it
against a fresh .NET for Android reference build.

**The type map is computed from our own output.** The module is keyed by the
MVID of the assembly the script just emitted, entries are hashed with the same
CRC-32 the store index uses, and the metadata token is read back out of the
emitted image.

**R2R is excluded deliberately.** ReadyToRun images are classified and rejected;
the payload is IL and RyuJIT handles it on device.

## Training wheels

`lib/classes.dex` is acquired, not emitted, and is the one input whose
provenance does not chain to a published package. It comes from a .NET for
Android reference build against the same pinned packs; `setup.ps1 -Debug`
rebuilds that reference in a temporary folder and compares its `classes.dex`
with the pinned copy.

It goes away with the planned move off .NET for Android: the main activity
becomes `android.app.NativeActivity`, which needs no DEX at all, and any Java
classes still required are emitted by `setup.ps1`. See `docs/roadmap.md`.

## Layout

```
setup.ps1         the build
lib/              pinned specifications, restored on demand, never executed
lib/manifest.json the root provenance manifest; setup.ps1 holds only its digest
docs/roadmap.md   where the project is going
docs/DEVELOPER.md decisions, proofs, architecture targets, testing
```

The only file the build writes inside the repository is the signed APK. It
fails if anything else in the repository changed during a run, and it ends by
listing every file it wrote with its SHA-512.

The signed APK is written next to `setup.ps1` as
`dev.mansfieldplumbing.pwsh.apk` (the Android package name; `*.apk` is
ignored by git). `-ApkPath` puts it elsewhere. Every intermediate artifact
stays in memory. `-KeepIntermediates` writes them for inspection to
`..\Build\Pwsh`, side by side with the repository, created if missing. The build root holds a
`.gitignore` of `*`, so no repository that contains it tracks build output. The signing key and package cache default to per-user data:
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
