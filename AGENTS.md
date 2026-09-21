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
- CoreCLR takes a host contract from the `HOST_RUNTIME_CONTRACT` property as a
  number parsed with base 0 (`exports.cpp`), and asks its
  `external_assembly_probe` for `System.Private.CoreLib.dll` before the file
  system (`assemblybindercommon.cpp` `BindToSystem`), both at the runtime commit
  of v11.0.0-rc.1.26425.128. The contract's layout is `host_runtime_contract.h`.
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
- With `-Admission NativeActivity`, `libpwsh-host.so` (x86-64, arm64, and arm32 in
  Thumb-2)
  starts CoreCLR: `DT_NEEDED` libc, liblog, libcoreclr and the store library;
  three runtime properties as the pinned .NET for Android host sets them; an
  `external_assembly_probe` that walks a table read back from the store; then
  `coreclr_create_delegate` for `NativeHost.Admit`. Its code passes the
  per-ISA decoder, a control-flow ABI checker (SysV AMD64, AAPCS64 or AAPCS32) and the
  emitter controls in Step 6. It requires `Admit` to return 0x50575348,
  then calls `NativeHost.RunPowerShell` through a second delegate
  and logs what it returns. `-TraceAssemblyProbe` (x86-64, diagnostic) logs each
  probe request exactly as CoreCLR spells it, and whether the store has it.
- The NativeActivity store starts every image on a 16-byte boundary with zero
  padding; the Xamarin store keeps the upstream layout byte for byte. Step 6
  reads the final store library as it is mapped and requires every image to
  start 16-byte aligned and every fat method header to fall 4-byte aligned
  (131,709 fat headers in the lean payload).
- The arm32 host is Thumb-2, as the NDK builds the pinned arm32 .NET for Android
  host (its exported functions carry the Thumb bit); `libpsl-native` stays A32.
  Pointer-sized fields take the target's size, and `internalDataPath`'s offset
  comes from `native_activity.h`. Exported function values and the relocated
  `external_assembly_probe` pointer carry bit 0; the build checks both.
- After the gate 2c script, `RunPowerShell` runs the gate 2d path: the
  product's case-insensitive `Profile.ps1` lookup (`FindProfile`, one generator
  for the Xamarin program type and `NativeHost`) over `internalDataPath`, then
  `$PSScriptRoot`, `GetCommand` as an `ExternalScript`, `Invoke` in the same
  FullLanguage, `UseCurrentThread` runspace, and the product's `HadErrors` rule.
  Its catch logs the exception's type and message before returning the HResult.
- `-Debuggable` (NativeActivity, diagnostic) adds `android:debuggable="true"`
  (0x0101000f, `public-final.xml`) so `adb shell run-as` can place files in the
  app's private files directory. Without it the manifest carries no trace of
  `debuggable`, which the admission check enforces.
- The NativeActivity APK packages the emitted `libpsl-native.so`, so CoreCLR's
  default native probing finds it in the APK's library directory.
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
- The x86-64 encoder's forms (34 cases) and the A64 encoder's forms (23 cases,
  with branch and `adrp` targets resolved) disassemble as intended in MSVC
  `dumpbin`, used as a diagnostic only.
- The T32 encoder's forms (35 cases, branch targets and PC-relative sequences
  included) match the bytes LLVM 23.1.1's integrated assembler emits for the same
  instructions. `dumpbin` no longer supports ARM32, so `clang` is the diagnostic
  oracle here, kept out of tree and never used to produce output.
- `-Debug` compares the emitted type-map name and `classes.dex` against a .NET
  SDK reference build.

### Proven on a device or the emulator

- The x86_64 emulator (API 36) runs CanvasDemo in-process.
- The arm64 phone (Samsung Galaxy S23, API 36) and the arm32 device (API 34)
  start CoreCLR, load the store and reach the host, which stops at
  `START_MISSING` because no `Profile.ps1` is placed.
- SMA calls `libpsl-native` during startup; the .NET for Android host waits
  for a Java-side load of it, so the activity calls
  `JavaSystem.LoadLibrary("psl-native")` (x86_64 emulator).
- Gate 2a, x86_64 emulator (API 36): an APK with no DEX, no `MonoRuntimeProvider`,
  no `libmonodroid` and no `libxamarin-app` logged `GATE2A Admit returned
  0x50575348`, before and after the ABI checker was made control-flow aware.
  CoreCLR accepted pointers into the read-only mapped store for the assemblies
  this gate needs, and `Pwsh.dll` ran a method that touches no Xamarin type
  without resolving its `Mono.Android` reference.
- Gate 2a, arm64 physical device (Samsung Galaxy S23): the same APK shape,
  with an independently emitted A64 host, logged `GATE2A Admit returned
  0x50575348`; the process stayed alive and the crash buffer held nothing for
  it. The Xamarin arm64 build from the same script stayed byte-identical.
- Gate 2a exercised only tiny method headers and ReadyToRun CoreLib code, so
  it did not show that arbitrary IL runs from the original, unaligned store.
  CoreCLR decodes a fat method header only when it is 4-byte aligned on a
  64-bit host (`corhlpr.cpp` `DecoderInit` at v11.0.0-rc.1.26425.128); on a
  32-bit host that check is a debug assert only. The .NET for Android host
  never met it because it copies each assembly into `malloc`ed memory
  (`lib/assembly-store.cc`). Served in place from the unaligned store, a fat
  method failed as `InvalidProgramException` on the x86_64 emulator, while
  ILVerify 10.0.12 and the Windows JIT accepted the same bytes.
- Gates 2b and 2c, x86_64 emulator (API 36), with the aligned store: CoreCLR
  loaded System.Management.Automation and 55 other assemblies in place from
  the read-only mapped store (56 of the 96, those the tested startup path
  requested); the packaged `libpsl-native.so` satisfied the native library
  that `Open` reaches; `CreateDefault2`, `CreateRunspace` with
  `UseCurrentThread`, `Open`, `DefaultRunspace` and the script `0x50575348`
  all ran on the main thread, and `RunPowerShell` returned 0x50575348 after
  `Admit` held in the same process. The process was alive 40 seconds later and
  the crash buffer was empty, with and without `-TraceAssemblyProbe`. The
  Xamarin x86_64 build stayed byte-identical.
- Gates 2b and 2c, arm64 physical device (Samsung Galaxy S23): the same
  sequence, with the A64 host and the aligned arm64 store, logged every marker
  on the main thread (thread id equal to process id) and `RunPowerShell
  returned 0x50575348` about half a second after `Admit`; the process was
  alive 40 seconds later and the crash buffer held nothing for it. The Xamarin
  arm64 build stayed byte-identical.
- Gates 2a, 2b and 2c, arm32 device (API 34): the Thumb-2 host and the aligned
  arm32 store logged every marker on the main thread and `RunPowerShell returned
  0x50575348`; the process was alive 40 seconds later and the crash buffer held
  nothing for it. The Xamarin arm32 build stayed byte-identical. Gate 2c holds on
  all three backends.
- Gate 2d, profile execution substrate: proven on the x86_64 emulator, the
  Samsung Galaxy S23 (arm64) and the arm32 device, with controlled profile
  fixtures placed through `run-as` in a `-Debuggable` build. The owned host
  performs the product's case-insensitive `Profile.ps1` discovery, establishes
  `$PSScriptRoot`, resolves the file as an external script, executes it in the
  existing FullLanguage, `UseCurrentThread` runspace, applies the existing
  `HadErrors` rule, preserves runspace state afterward, and handles the
  missing-profile case: no profile logged `START_MISSING`; `PROFILE.ps1` ran and
  left state a second pipeline read back; a divide-by-zero profile took the
  `HadErrors` path and returned 0x80131509. Each time the process was alive 40
  seconds later with an empty crash buffer. `$Activity`, the recovery UI and the
  animation callback remain gate 2e concerns. The Xamarin builds and the
  release NativeActivity manifest stayed byte-identical.
- The current payload contains no cmdlet modules, so commands such as
  `Join-Path` and `Write-Error` are unavailable in this `CreateDefault2`
  runspace. Profile fixtures use the language and .NET only.
- During those runs SMA also asked the probe for
  `System.Management.Automation.dll` by its full path under the app's files
  directory. The probe has no entry by path, so it declined; execution
  continued, and the assembly was already loaded by name. A probe miss is not
  an assembly-resolution failure.
- `UseCurrentThread` puts the runspace and its pipelines on the Android main
  thread; SMA still starts threads of its own. `LocalConnection` keeps a static
  named-pipe listener, whose thread starts during `Open` and logs through
  `libpsl-native`. An exception there escapes every managed entry the host
  calls and aborts the process, so acceptance requires the success marker,
  the process alive after it, and an empty crash buffer. Without
  `libpsl-native.so` in the APK, PowerShell's own native resolver
  (`NativeDllHandler`) threw on that thread, because an assembly served from
  memory has an empty `Location`.
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
- Every gate runs on three backends: x86-64 on the emulator finds the next
  boundary; arm64 on the S23 confirms it on a physical device; arm32 must pass
  before the gate is called portable. Each backend is independent evidence:
  a failure on x86-64 or arm64 may not reproduce on arm32, and an arm32 pass
  does not waive a 64-bit invariant (a misaligned fat method header is fatal
  on 64-bit CoreCLR and passes unchecked on 32-bit). Port each narrow gate to
  arm64 and arm32 as soon as it passes on x86-64, before building the next
  layer; `Profile.ps1` waits until gate 2c passes on all three.
- Compatibility is scoped by the frozen workload, not by namespace. Defining
  `Android.Graphics.Bitmap` obliges exactly the constructors, members, return
  values, lifetime and interactions the frozen script reaches, taken from its
  AST resolved against the pinned Mono.Android metadata and from a traced run
  on the Xamarin baseline. Do not build Java peer tracking, arbitrary Java
  subclassing, type maps or the Java.Interop object model.
- In the Xamarin baseline, CanvasDemo runs on the Android main thread: the host
  runs `Profile.ps1` in a `UseCurrentThread` runspace there, and the script's
  delegates are invoked there. `activity->env` belongs to the main thread; any
  other thread attaches through `activity->vm`. Android's own `Canvas`, `Bitmap`, `Paint` and AGSL
  `RuntimeShader` stay the implementation, reached through JNI on the
  `Surface` from `ANativeWindow_toSurface`; the real `setContentView` is never
  called over `NativeActivity`'s content view.
- Layering. QuickPS Android mechanisms are literal and policy-free: NDK
  exports, JNI function-table dispatch, looper and input primitives, the
  choreographer binding. The Pwsh compatibility assembly owns the
  `[UnmanagedCallersOnly]` callbacks installed in the `NativeActivity`
  callback table and passed to `AChoreographer`, turns them into the
  Xamarin-shaped `Touch`, `KeyPress` and `PostOnAnimation`, and invokes the
  frozen script's delegates where CanvasDemo expects them (in the baseline, on
  the main thread). No hand-written native stub
  sits between the callback and managed code. Only the compatibility
  assembly uses `Android.*` and `Java.*` names.
- Before modifying `Read-ElfImage`, the SysV ELF hash implementation, or the
  emitted ELF hash-table structure, add and pass a permanent multi-bucket hash
  self-test that covers successful chained lookups and missing-symbol lookups.

## Open questions

Verify each on hardware before relying on it.

- The repository has no separate production `Profile.ps1` payload. The frozen
  `scripts/CanvasDemo.ps1` is the real application workload that occupies that
  role. Its exact-byte execution through the gate 2d path is therefore proven at
  gate 2f, after gate 2e provides the required Android compatibility surface.
- Not yet proven: Activity-dependent startup behavior; the compatibility
  surface CanvasDemo requires; the recovery screen; the animation callback;
  exact frozen CanvasDemo execution without Xamarin; the 40 store assemblies no
  proven path has requested, served in place.
- To prove at gate 2c, then promote: QuickPS's function-table call performs
  JNI on Android, shown by `GetVersion`, `FindClass`, `GetMethodID` and one
  `Call*MethodA` with a `jvalue[]`, using slot numbers from a pinned Android 14
  `jni.h`; `QuickPS/src/Native.ps1` runs unchanged under the owned CoreCLR host;
  its `CallingConvention.StdCall` attribute is harmless on arm64, x64 and arm32.
- The exact runtime properties `coreclr_initialize` needs without the .NET for
  Android host.
- Whether `libSystem.Security.Cryptography.Native.Android.so` must be
  initialized with the Java VM before hashing or TLS work.
- How the host resolves the per-install native library directory.
- Whether the ELF32 store library should reserve eight dynamic entries like
  ELF64. Changing it alters proven arm32 bytes, so it needs its own device run.
- A permanent self-test for `Read-ElfImage` hash lookups, including missing
  names that hash into occupied and empty buckets. Every emitted table has one
  bucket, so the build itself never exercises bucket selection.
