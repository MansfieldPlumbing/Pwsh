# Processes, native bundles and the broker

Status: design, 2026-10-02. Each capability below is its own gate with its own
receipt; none is proven yet. Policy citations are system/sepolicy `7595d4f4`
and frameworks/base `299fe6f5`, as in [AGENTS.md](../AGENTS.md).

Pwsh is meant to replace a terminal app for real work: run tools, compile
code, extend itself, without an old target SDK and without a store. Android
allows all of that through two doors, and the line between them decides every
design below.

## Managed code: anything, on the device

An app may JIT into executable memory in its own process (`app.te:199`) and
read its own files (`untrusted_app_all.te:27`). So:

- PowerShell lowers code to IL on the device (expression trees through
  `PersistedAssemblyBuilder`) and can run it immediately: the assembly loads
  from its bytes in the running process and RyuJIT compiles it on first call.
  The copy saved to private storage loads at later starts without lowering
  again. A restart is needed only to replace code already loaded in the
  default load context, which cannot unload; loading lowered code into a
  collectible `AssemblyLoadContext` allows replacing it in place (standard
  .NET behaviour, not yet run on a device with the in-memory store). See
  [lowering.md](lowering.md).
- Managed packages (a NuGet package is mostly a zip of IL assemblies) can be
  fetched, unpacked into private storage and loaded in-process.

## Native code: built on the PC, shipped signed

- `execve` of a file the app wrote is denied from target SDK 29
  (`app_neverallows.te:60-69`). Mapping an app-written file as executable is
  currently audited, not denied (`untrusted_app_all.te:28`), which is a door
  Google can close, so nothing is built on it.
- Installed code in `/data/app` may be mapped and executed
  (`app.te:427`) and never written by the app (`public/app.te:108-110`).

Native code therefore reaches the device only through the package installer:
in the APK, or later in a signed split APK added to the installed app
(`PackageInstaller.MODE_INHERIT_EXISTING`, `PackageInstaller.java:2227`).

### User native bundles

Every user builds and signs their own APK; the signing key is generated per
user and stays in `%LOCALAPPDATA%`. Bundling their own libraries and
executables is one more input:

- `setup.ps1 -NativeLibrary <paths>` packages them into `lib/<abi>/`. The
  installer extracts only entries named `lib*.so`
  (`NativeLibraryHelper.cpp:276`), so executables ship renamed (`git` becomes
  `libgit.so`) with a name map, and PowerShell runs them by path from the
  native library directory. Executables need native libraries
  extracted to real files; libraries loaded with `dlopen` do not.
- The build checks each one before it ships: ELF machine and class match the
  target, load segments are aligned for 16 KB-page devices, and its SHA-256 is
  recorded like every other input.
- On the device, libraries load through `NativeLibrary.Load` and delegates,
  the same way the console reaches `libandroid` today.

### Which Linux binaries run

| Binary | Runs | Why |
| --- | --- | --- |
| Built with the NDK (bionic) | Yes | Android's own loader and libc |
| Statically linked (Go, Rust or C against static musl) | Usually | No loader or libc needed |
| Dynamically linked against glibc | Only with its loader bundled | It asks for `/lib/ld-linux-aarch64.so.1`, which Android lacks; launch it through a bundled loader with `--library-path` |

Expect occasional failures from the app's seccomp filter (an unusual syscall
ends the process) and from tools that assume Linux paths such as
`/etc/resolv.conf`. The broker addresses the second.

## The broker

The broker gives bundled binaries what Android lacks, without a proot
container and without PowerShell on any per-syscall path.

- The PowerShell host listens on a Unix domain socket in private storage,
  never in the abstract namespace (any app can connect there), and checks every
  peer's UID with `SO_PEERCRED`.
- A binary asks it for capabilities: open a content URI, a camera or sensor
  stream, a file the user picked, a network socket, a path that Linux tools
  expect. Dynamically linked binaries do this through a shim loaded with
  `LD_PRELOAD`, which can also rewrite paths such as `/etc/resolv.conf` into
  private storage at `open()` time; statically linked ones speak the broker's
  protocol or are launched through a wrapper.
- The broker answers by passing a file descriptor (`SCM_RIGHTS`). Control goes
  over the socket; data goes through the passed descriptor at full speed.
  PowerShell handles a few requests per operation, never per byte.
- It delegates; it does not escalate. The broker runs in the same app sandbox
  (same seccomp filter, same SELinux domain), so a binary gets only what the
  app could do.

proot traces every syscall of the child and rewrites it transparently, which
is general but stops the process on each call. The broker needs the binary's
cooperation (the shim or the protocol) and in return costs nothing on the data
path.

## Layered loading

Loading is layered the way `PATH` is: a newer layer shadows an older one, so
most updates need no APK.

| Layer, checked first to last | Holds | Updated by |
| --- | --- | --- |
| Admitted overlay, in private storage | Managed assemblies: lowered code and newer builds of shipped ones, SMA included | The device or the paired PC, without the package installer |
| APK store | Everything shipped | A signed APK or split |

- **Preemption** happens in the host's `external_assembly_probe`, which CoreCLR
  asks before anything else; it consults the overlay's active manifest before
  the store table. Assembly resolve events cannot do this, because they fire
  only when the probe finds nothing. The probe is emitted native code, so this
  is one change to the host on all three instruction sets, gated like any
  other host change.
- **Admitted means signed.** The overlay is writable by the app, so a hash list
  beside it proves nothing. The active manifest carries a signature from the
  user's PC key, checked against a public key shipped in the APK. Code lowered
  on the device is admitted as a cache of shipped or user source (re-derivable,
  never authoritative), or under a device key held in Android Keystore.
- **Promotion is atomic.** One active pointer selects a whole manifest; a
  partially written update is never live. Loading takes effect at the next
  process start, or in place for code loaded into a collectible load context.
- **Rollback belongs to Recovery.** An overlay that breaks startup trips the
  crash-loop breaker, and Recovery's `reset` drops the active pointer so the
  app starts from the APK store again ([console-host.md](console-host.md)).

An APK update is then needed only for native changes: the host itself, native
bundles, and the shipped public key.

## Updating outside a store

The PC builds and signs with the user's key; updates install as a full APK or
as a split added to the installed app, and the app can start its own update
through `PackageInstaller` with the install-packages permission, which Android
confirms with the user. Whether a sideloaded app that is its own installer of
record can update without that confirmation on current Android is not yet
traced in the pinned source.

## Building APKs on the device

`setup.ps1` needs only what the payload already ships (Reflection.Emit,
Reflection.Metadata, compression, HTTP, cryptography), so the app can run it.
With layered loading, an APK carries only what cannot be overlaid: the native
host, the manifest (package name, permissions, activities, icon), the signer
identity, native bundles and the store baseline. Rebuilding is for adding a
capability, not for changing code.

That makes the phone an APK factory: from a script or a tile, build a new app
with its own package name, icon and permissions on the shared runtime baseline
(about 15 MB today), with the script as its start point. A new package has no
key conflict, since Android requires the same key only to update an existing
package; each generated app gets its own key in Android Keystore and installs
through `PackageInstaller` with the user's confirmation.

Emitting the host's ELF on the device needs the rule change proposed below.
The work is tested in separable parts:

1. **Build:** run `setup.ps1` on the device and compare its APK with the PC
   build of the same inputs, byte for byte wherever the build is
   deterministic. Pure evidence; no policy change.
2. **New package:** build a different package (a script or tile as its own
   app) on the device, sign it with a Keystore key, install it, and run it.
3. **Install as an update:** Android installs an update only when it is signed
   by the installed app's key, which today never leaves the PC. This needs a
   decision: a device key in Android Keystore from the first install (the PC
   can then no longer update that install), or key rotation through APK
   Signature Scheme v3, which `setup.ps1` does not yet emit (it signs with v2).
   It also needs a rule change: [AGENTS.md](../AGENTS.md) allows native machine
   code to be emitted only by the build machine, and `setup.ps1` emits ELF.
   Proposed wording: native code may be emitted on the device only by
   `setup.ps1` itself, into an APK that reaches the device only through the
   package installer, with the same decode-back and ABI checks as a PC build.

## A federation of apps

Built apps can stay separate packages rather than one large app: each is its
own process and Linux UID, crashes alone, holds only its own permissions, and
updates alone. The costs are a CoreCLR runtime and an assembly store per
process (tens of MB of memory, and about 15 MB of APK each, since one package
cannot load another's store), a startup per app, and no shared private
storage.

- **Discovery needs no hub.** Android's package database is the registry:
  every installed app's components, `<meta-data>`, permissions and signing
  certificates. Each built app declares a `<meta-data>` marker naming its role
  and socket; others find it through `PackageManager`, reached through JNI on
  framework classes, and see it only if their own manifest lists it in
  `<queries>` (package visibility, Android 11 and later).
- **Trust is checked, never assumed.** Before connecting, an app confirms the
  peer package is signed with the same key, then talks over an abstract Unix
  socket whose every connection is checked: the peer UID from `SO_PEERCRED`
  must belong to that verified package. `sharedUserId` is deprecated and not
  used.
- **Telemetry** (liveness, startup times, errors, presented frames) flows to
  whichever app the user chooses as the dashboard, found the same way; a Start
  tile is the natural one.
- **AppFunctions** (Android 16) lets an app expose functions to assistants and
  agents. Exposing them needs a service class declared in the manifest, so it
  depends on the same decision as the fixed Java classes for text input.

The `PackageManager` and AppFunctions details above are taken from platform
documentation and are traced in the pinned frameworks source before
implementation.

## Examples

- **git**: cross-compile with the NDK on the PC (git and its helpers,
  `git-remote-https`, curl, TLS and zlib, built with relocatable paths, since
  Termux's binaries are hardwired to Termux's prefix), ship as a native bundle,
  call it as `git` through the name map. A build project in its own
  repository.
- **scrcpy**: its server half is a jar that runs on the controlled phone
  through `adb shell`. The client half needs no native port: a managed adb
  client starts the server, the protocol is implemented in PowerShell, and
  Android's `MediaCodec` (through JNI) decodes the H.264 stream onto a surface
  the app owns.

The pattern: protocols and logic in PowerShell or IL, heavy lifting through
Android's own system APIs, native code only when nothing else exists, built on
the PC and shipped signed.
