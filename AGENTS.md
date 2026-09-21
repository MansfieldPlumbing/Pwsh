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

- `setup.ps1` emits AArch64 `ET_DYN` ELF64 libraries with `.dynsym`, a hash
  table, a dynamic section, section headers and `R_AARCH64_RELATIVE`
  relocations (`New-*` ELF functions and `Add-ElfSectionTable` in `setup.ps1`).
  It does not yet emit executable code sections or `DT_NEEDED` entries.
- Terminal's `libpsl-native.so` was eight exported functions: seven empty and
  one returning 1 (`src/libpsl/libpsl-native.c` in the predecessor Terminal
  project). It was built with the Android NDK.
- `setup.ps1` does not package `libpsl-native.so`.
- The shipped payload has no Roslyn (`Microsoft.CodeAnalysis.*`), so
  `Add-Type -TypeDefinition` and `-MemberDefinition` cannot work on device.
  `Add-Type -LiteralPath` loads precompiled .NET assemblies only, not native
  libraries (`lib/arm64-v8a.lean-assembly-order.txt`).
- RyuJitDetach lifts leaf-only RyuJIT bodies into AMD64 Windows PE files; its
  shim owns every call. It does not produce ARM64 or Android code (its README).
- PSPersistence persists selected SMA expression trees as reloadable
  assemblies. It does not produce native code (its README).

## Open questions

Verify each on hardware before relying on it.

- Whether System.Management.Automation calls `libpsl-native` during runspace
  creation on Android, now that `setup.ps1` does not ship it.
- The exact runtime properties `coreclr_initialize` needs without the .NET for
  Android host.
- Whether `libSystem.Security.Cryptography.Native.Android.so` must be
  initialized with the Java VM before hashing or TLS work.
- How the host resolves the per-install native library directory.
