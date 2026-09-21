# Pwsh repository contract

Keep this repository narrow and evidence-led.

- `setup.ps1` is the build. Its steps are nodes in `$script:StepGraph`.
- `lib/` holds pinned inputs only. Every file is listed in `lib/manifest.json`
  with its SHA-256; `setup.ps1` holds only the manifest's digest.
- `setup.ps1 -Debug` writes the intermediates and cross-checks against a .NET
  for Android reference build made in a temporary folder. The reference build
  is removed when `lib/classes.dex` is emitted.
- `docs/` holds forward-looking design, clearly separated from proofs.
- The only generated file in the repository is the signed APK beside
  `setup.ps1` (ignored by git). Intermediates stay in memory unless
  `-KeepIntermediates` writes them to `..\Build\Pwsh`. `setup.ps1` writes only
  to locations in its confirmed write plan and fails if anything else in the
  repository changes during a run.

## Rules

- Every input is pinned by SHA-256. Nothing is taken from the machine's
  installed state. A tool may be fetched ephemerally only if it is pinned, and
  only to verify output, never to produce it.
- Every capability claim names a gate and passes it on hardware. Unproven work
  is described as planned, not as done.
- New code must not depend on .NET for Android (Xamarin) types. Android is
  reached through its C APIs or JNI.
- No tick or polling loops. Work is driven by blocking waits on events.
- Native code starts the runtime and nothing else. Logic belongs in emitted IL
  or PowerShell.
- Machine code, if emitted, comes from named instruction encoders, never raw
  hex, and is decoded back and checked by the build.
- Do not vendor upstream repositories, donor code, graphics work, JavaScript
  parsing work, or unrelated application archaeology here.

## Established facts

Facts are grouped by the kind of evidence behind them. The kinds are not
interchangeable: a specification says what should be true, an independent
implementation catches a wrong reading of the specification, and hardware
shows what survived the platform. Emitter and reader in `setup.ps1` can share
one wrong interpretation and still agree, so a fact moves to a stronger group
only when that group's evidence exists. Name the source for every new fact.

### Specified (pinned sources in `lib/`)

- ELF constants, dynamic tags and relocation types are read from `ELF.h`,
  `DynamicTags.def`, `AArch64.def`, `x86_64.def` and `ARM.def`
  (`Get-ElfConstants`).
- Android ARM32 uses soft-float argument passing: clang's
  `arm::getDefaultFloatABI` returns SoftFP for the Android environment
  (`ARM.cpp`). ARM32 relocates with REL, addend in place (`ARM.def`).
- bionic's `VerifyElfHeader` checks magic, class, byte order, `e_type`,
  `e_version`, `e_machine`, `e_shentsize` and `e_shstrndx`, and never reads
  `e_flags` (`linker_phdr.cpp`, android-14.0.0_r1).
- A 32-bit assembly store carries no 64-bit flag in its version word
  (`xamarin-app.hh` lines 14-19). Store name hashes are 32-bit on every target.

### Implemented (checked by the build on every run)

- `setup.ps1` emits `ET_DYN` shared libraries for three targets: ELF64
  `EM_AARCH64` and `EM_X86_64`, and ELF32 `EM_ARM`. `$script:Targets` holds
  each target's machine, ELF class, RELATIVE relocation, RID and ABI.
- `libpsl-native.so` has 21 exports for every target, reaches libc through a
  GOT with `DT_NEEDED libc.so` and `DT_FLAGS BIND_NOW`, and every instruction
  is decoded back by an independent decoder (`Test-ElfCodeLibrary*`).
- The store library reserves eight dynamic entries on ELF64 targets and seven
  on ELF32 (`New-ElfPayloadLibrary`). The difference is deliberate: both sizes
  reproduce bytes proven on hardware. Do not make them agree as part of any
  other change.
- The payload is the names in `lib/arm64-v8a.lean-assembly-order.txt`, pinned
  by digest; its length (96) is the assembly count every step checks.
- The payload has no cmdlet modules (`Microsoft.PowerShell.Commands.*`), so
  `Get-ChildItem` and `Get-Process` are absent, and no Roslyn
  (`Microsoft.CodeAnalysis.*`), so `Add-Type -TypeDefinition` and
  `-MemberDefinition` cannot work on device.

### Independently cross-checked (implementations this repository did not write)

- The predecessor arm32 APK (built by .NET for Android and NDK clang 17)
  matches the emitted ELF32 header fields, including `e_flags` `0x05000200`,
  and uses the same A32 encodings for `bx lr` and loads into `pc`. Its
  `libpsl-native.so` exported eight stubs; `GetCurrentThreadId` returned 1.
- `System.Linq` in the pinned runtime references `System.Numerics.Vectors`
  from `Enumerable.Sum`, `Average` and `FillIncrementing` (metadata read from
  the built store), so that assembly must ship.
- `Read-ElfImage` resolves all 36 symbols of the predecessor arm32
  `libxamarin-app.so` through its LLD 18 SysV hash table: 37 buckets, 25 in
  use, six collision chains, the longest four entries. That exercises the
  reader's own hash function and chain walk against an independent writer.
- `-Debug` compares the emitted type-map name and `classes.dex` against a .NET
  SDK reference build.

### Proven on hardware

- The x86_64 emulator (API 36) runs CanvasDemo in-process.
- The arm64 phone (Samsung Galaxy S23, API 36) and the arm32 device (API 34)
  start CoreCLR, load the store and reach the host, which stops at
  `START_MISSING` because no `Profile.ps1` is placed.
- SMA calls `libpsl-native` during startup; the .NET for Android host waits
  for a Java-side load of it, so the activity calls
  `JavaSystem.LoadLibrary("psl-native")` (x86_64 emulator).
- The arm32 host rejected a store whose version word carried the 64-bit flag;
  emitter and reader had agreed on it (arm32 device).

### Other repositories (their READMEs)

- RyuJitDetach lifts leaf-only RyuJIT bodies into AMD64 Windows PE files; its
  shim owns every call. It does not produce ARM64 or Android code.
- PSPersistence persists selected SMA expression trees as reloadable
  assemblies. It does not produce native code.
## Rules for specific changes

- `scripts/CanvasDemo.ps1` is frozen (SHA-256
  `8E96992365A72E81B1A1EEB518AE9052020519EA175EC5465BAC4A989928F3B9`). Xamarin
  is removable implementation; the frozen script is evidence. Remove
  dependencies beneath it. Do not edit it, and do not replace it with a new
  application API as part of removing Xamarin.
- Leaving Xamarin proceeds by gates, each proved alone: 2a CoreCLR runs one
  managed log line from `ANativeActivity_onCreate`; 2b the owned host serves
  assemblies from the existing store; 2c a runspace opens with
  `UseCurrentThread` and `DefaultRunspace` stays set on the main thread; 2d
  `Profile.ps1` runs through the same path as today; 2e an owned compatibility
  assembly satisfies the CanvasDemo contract; 2f the frozen bytes run with
  Mono.Android, Mono.Android.Runtime, Java.Interop, libmonodroid,
  libxamarin-app, Xamarin DEX and type maps absent.
- Compatibility is scoped by the frozen workload, not by namespace. Defining
  `Android.Graphics.Bitmap` obliges exactly the constructors, members, return
  values, lifetime and interactions the frozen script reaches, taken from its
  AST resolved against the pinned Mono.Android metadata and from a traced run
  on the Xamarin baseline. Do not build Java peer tracking, arbitrary Java
  subclassing, type maps or the Java.Interop object model.
- The script keeps running on the Android main thread, as in the baseline.
  JNI calls use `activity->env` only on that thread; any other thread attaches
  through `activity->vm`. Android's own `Canvas`, `Bitmap`, `Paint` and AGSL
  `RuntimeShader` stay the implementation, reached through JNI on the
  `Surface` from `ANativeWindow_toSurface`; the real `setContentView` is never
  called over `NativeActivity`'s content view.
- Layering. QuickPS Android mechanisms are literal and policy-free: NDK
  exports, JNI function-table dispatch, looper and input primitives, the
  choreographer binding. The Pwsh compatibility assembly owns the
  `[UnmanagedCallersOnly]` callbacks installed in the `NativeActivity`
  callback table and passed to `AChoreographer`, turns them into the
  Xamarin-shaped `Touch`, `KeyPress` and `PostOnAnimation`, and invokes the
  frozen script's delegates on the main thread. No hand-written native stub
  sits between the callback and managed code. Only the compatibility
  assembly uses `Android.*` and `Java.*` names.- Before modifying `Read-ElfImage`, the SysV ELF hash implementation, or the
  emitted ELF hash-table structure, add and pass a permanent multi-bucket hash
  self-test that covers successful chained lookups and missing-symbol lookups.

## Open questions

Verify each on hardware before relying on it.

- To prove at gate 2c, then promote: QuickPS's function-table call performs
  JNI on Android, shown by `GetVersion`, `FindClass`, `GetMethodID` and one
  `Call*MethodA` with a `jvalue[]`, using slot numbers from a pinned Android 14
  `jni.h`; `QuickPS/src/Native.ps1` runs unchanged under the owned CoreCLR host;
  its `CallingConvention.StdCall` attribute is harmless on arm64, x64 and arm32.- The exact runtime properties `coreclr_initialize` needs without the .NET for
  Android host.
- Whether `libSystem.Security.Cryptography.Native.Android.so` must be
  initialized with the Java VM before hashing or TLS work.
- How the host resolves the per-install native library directory.
- Whether the ELF32 store library should reserve eight dynamic entries like
  ELF64. Changing it alters proven arm32 bytes, so it needs its own device run.
- A permanent self-test for `Read-ElfImage` hash lookups, including missing
  names that hash into occupied and empty buckets. Every emitted table has one
  bucket, so the build itself never exercises bucket selection.
