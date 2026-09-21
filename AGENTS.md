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

Each fact names where it was checked.

- `setup.ps1` emits `ET_DYN` shared libraries for three targets: ELF64
  `EM_AARCH64` and `EM_X86_64`, and ELF32 `EM_ARM`. The target table
  (`$script:Targets`) holds each target's machine, ELF class, relocation type,
  RID and ABI. Constants come from the pinned `ELF.h`, `DynamicTags.def` and
  relocation `.def` files (`Get-ElfConstants`).
- `setup.ps1` emits executable code: `libpsl-native.so` with 21 exports for
  every target, through a GOT with `DT_NEEDED libc.so` and `DT_FLAGS BIND_NOW`.
  Every instruction is decoded back by an independent decoder
  (`New-PslNativeLibrary*`, `Test-ElfCodeLibrary*`).
- SMA calls `libpsl-native` during startup (`Native_OpenLog` and
  `Native_SysLog`), so the library must ship. The .NET for Android host waits
  for a Java-side load of it, so the activity calls
  `JavaSystem.LoadLibrary("psl-native")` (checked on the x86_64 emulator).
- ARM32 is ARM-state A32, EABI version 5, soft-float, with REL relocations
  (`lib/ARM.cpp`, `lib/ARM.def`). bionic never reads `e_flags`
  (`lib/linker_phdr.cpp`, android-14.0.0_r1). A 32-bit assembly store carries
  no 64-bit flag in its version word (`lib/xamarin-app.hh` lines 14-19).
- All three targets reach the PowerShell host: CanvasDemo runs on the x86_64
  emulator; the arm64 phone and the arm32 device stop at `START_MISSING`
  because no `Profile.ps1` is placed.
- The payload is the 96 names in `lib/arm64-v8a.lean-assembly-order.txt`,
  pinned by digest; its length is the assembly count every step checks.
  `System.Numerics.Vectors` is required: `System.Linq` references it from
  `Enumerable.Sum`, `Average` and `FillIncrementing`.
- The payload has no cmdlet modules (`Microsoft.PowerShell.Commands.*`), so
  `Get-ChildItem` and `Get-Process` are not present.
- The shipped payload has no Roslyn (`Microsoft.CodeAnalysis.*`), so
  `Add-Type -TypeDefinition` and `-MemberDefinition` cannot work on device.
  `Add-Type -LiteralPath` loads precompiled .NET assemblies only, not native
  libraries (`lib/arm64-v8a.lean-assembly-order.txt`).
- The predecessor `libpsl-native.so` (arm32, NDK clang 17) exported eight
  functions, all stubs; `GetCurrentThreadId` returned 1 (read from the
  installed predecessor APK).
- RyuJitDetach lifts leaf-only RyuJIT bodies into AMD64 Windows PE files; its
  shim owns every call. It does not produce ARM64 or Android code (its README).
- PSPersistence persists selected SMA expression trees as reloadable
  assemblies. It does not produce native code (its README).

## Open questions

Verify each on hardware before relying on it.

- The exact runtime properties `coreclr_initialize` needs without the .NET for
  Android host.
- Whether `libSystem.Security.Cryptography.Native.Android.so` must be
  initialized with the Java VM before hashing or TLS work.
- How the host resolves the per-install native library directory.
