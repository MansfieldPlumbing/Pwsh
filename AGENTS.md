# Pwsh repository contract

Keep this repository narrow and evidence-led.

## Purpose

Pwsh makes an Android device a general-purpose computer: a peer of Windows and
Linux machines, with a scriptable CoreCLR runtime and PowerShell as its shell.
Features are judged by whether a Windows or Linux machine has the equivalent:
remote sessions through PSRP over SSH, a desktop reachable through RDP,
services that run as a server's would, and operation with USB debugging
disabled. The console is one front end of the runtime, not the product. Work
that does not move a device toward that is sidecar work.

## Stance: the rules govern evidence, not technique

These rules exist to keep every claim true. They do not rank techniques.
Emitted machine code, direct system calls, raw kernel interfaces, replacing a
runtime component, and racing a production compiler are all admissible when
the work is:

1. derived from a pinned specification or source at an exact revision;
2. checked by an independent implementation used only as an oracle, never as
   a producer;
3. proven on hardware with a receipt for the same artifact, on every backend
   it claims; and
4. stated with its claim boundary: what it proves and what it does not.

Compilers and runtimes are competitors and oracles, not authorities.
Kokoro-Hexagon's receipts at commit `250e10dc` record a PowerShell-lowered
kernel running 2.21–2.30x faster in DSP ticks than Hexagon Clang 19.0.04
output, bit exact, on SM8550 and SM8635.

When a rule blocks work that meets all four conditions, report the rule and
propose a precise change to it. Do not refuse silently, and do not work around
it silently.

## Execution model: PowerShell orchestrates, lowered code runs hot paths

Pwsh's performance comes from lowering, not from interpreting faster.

- PowerShell running through SMA's dynamic dispatch is the control plane:
  lifecycle, event dispatch, scheduling, composition and damage decisions. It
  is never on a per-frame, per-cell, per-glyph or per-sample path.
- Hot paths are authored in PowerShell and lowered. When lowering happens
  follows from when its inputs are known:
  - At APK build time, when the code and its shapes are fixed then: IL through
    persisted LINQ expression trees, machine code from named encoders
    (`ROADMAP.md` gates N2-N3), or shaders. It costs nothing at startup, is
    checked by the build, and ships signed in the APK.
  - On the device at run time, when the shape depends on what only the device
    knows: the user's scripts, screen and cell metrics, fonts, loaded data.
    PowerShell builds and validates an expression tree and compiles it to IL;
    RyuJIT turns it into machine code once per process. The cost is paid once
    and amortized; the code lives in process memory, not in the signed APK.
  - On the device, persisted: when device-dependent code is stable across
    runs, lower it once, write it as an IL-only managed assembly in the app's
    private storage (`internalDataPath`), admit it by manifest and hash, and
    load it at the next process start. The cost is paid once per change, not
    once per process. Kokoro-Hexagon's `Model.Store.psm1` is the admission
    precedent. Policy supports it: an app reads its own data files
    (`untrusted_app_all.te:27`) and may JIT into executable memory
    (`app.te:199`); system/sepolicy `7595d4f4`.
  - Native machine code is emitted only by the build machine and reaches the
    device only through the package installer: in the APK, or later in a
    signed split APK added with `PackageInstaller.MODE_INHERIT_EXISTING`
    (`PackageInstaller.java:2227`). Installed code lives in `/data/app`
    (`apk_data_file`), which apps may map and execute (`app.te:427`) and may
    never write (`public/app.te:108-110`). The app never writes machine code
    itself: mapping an app-written file as executable is audited
    (`untrusted_app_all.te:28`), `execve` of one is forbidden from target SDK
    29 as a W^X violation (`app_neverallows.te:60-69`), and persisting JIT
    output would re-create ReadyToRun on the device.
- Pwsh updates itself by artifact type. IL: lowered on the device (or
  supplied by the paired PC), stored in private storage, admitted by hash,
  promoted by an atomic active pointer, and loaded at the next process start.
  Machine code: lowered by the paired Windows PC from what the device reports
  (hot paths, timings, ISA), signed there with the release key, which never
  leaves the PC, and installed as a split APK. Emitted IL binds native code by
  function pointer, so neither path needs ReadyToRun.
  - A path fixed at build time is never deferred to run time, and a path that
    depends on device state is never forced into the APK.
- Work that the platform already does well (composition, rasterization on the
  GPU) is handed to it.
- Drawing is damage-driven. A state change records damage; lowered code turns
  damage into pixels; nothing redraws unconditionally or on a timer.
- A new hot path names its lowering target and its measurement before it is
  built.

## Layout

- `ROADMAP.md` is the single implementation roadmap. A checked item names its
  gate or receipt.
- `setup.ps1` is the build. Its steps are nodes in `$script:StepGraph`.
- `lib/` holds pinned inputs only. Every file is listed in `lib/manifest.json`
  with its SHA-256; `setup.ps1` holds only the manifest's digest.
- `setup.ps1 -Debug` writes the intermediates (as `-KeepIntermediates`).
- `docs/` holds forward-looking design, clearly separated from proofs.
- Generated files live only in `build/` at the repository root, which git
  ignores: the signed APK, and the intermediates when `-KeepIntermediates`
  writes them; otherwise intermediates stay in memory. The signing key and the
  package cache never go inside the repository. `setup.ps1` writes only to
  locations in its confirmed write plan and fails if anything outside
  `build/` changes in the repository during a run.

## Rules

- Every input is pinned by SHA-256. Nothing is taken from the machine's
  installed state. A tool may be fetched ephemerally only if it is pinned, and
  only to verify output, never to produce it. The pinned runtime's own JIT is
  the one admitted producer outside `setup.ps1`, under the capture rule below.
- `setup.ps1` builds the APK from pinned NuGet downloads and PowerShell alone.
  Development tools outside the build may be used to author source, such as
  Roslyn from the pinned PowerShell's `$PSHOME` to translate C# to PowerShell
  in a separate repository. Their output enters this repository only as
  reviewed PowerShell that names the source repository and commit, verified by
  comparing its behavior with the original. No development tool becomes a
  build input or ships.
- Every capability claim names a gate and passes it on hardware. Unproven work
  is described as planned, not as done.
- New code must not depend on .NET for Android (Xamarin) types. Android is
  reached through its C APIs or JNI.
- No tick or polling loops. Work is driven by blocking waits on events.
- Native code starts the runtime. Any other native logic enters only through a
  `ROADMAP.md` gate (Emitted native code: N1–N3): emitted by PowerShell,
  decoded back and ABI-checked by the build, and measured against RyuJIT with a
  device receipt on all three backends. Until such a gate passes, logic belongs
  in emitted IL or PowerShell.
- Machine code, if emitted, comes from named instruction encoders, never raw
  hex, and is decoded back and checked by the build.
- Captured JIT output may ship when all of this holds: RyuJIT from the pinned
  runtime pack compiled it, at a recorded tier and ISA, inside the app's own
  process on a `-Debuggable` development build (a process reads its own code;
  no root); the method is a leaf, with no calls, no GC references and no
  absolute runtime addresses; the build decodes every instruction back with its
  independent decoder, finds no reference outside the body, and ABI-checks it;
  the artifact records the method's IL hash, the JIT's SHA-256, tier and ISA;
  it reaches the device only through the package installer; and a device
  receipt compares it with the live JIT on every backend it claims. Code that
  calls, allocates or holds GC references needs the runtime's fixups and stays
  with the device JIT.
- Pushes go through `.githooks/pre-push` (`git config core.hooksPath
  .githooks`), which refuses secrets, key files and personal data.
- Other projects stay in their own repositories: upstream sources, donor code,
  JavaScript-to-PowerShell translation tooling (js2ps), and prototypes in other
  languages. Code ported from them into PowerShell belongs here, with the
  source repository and commit it was ported from.

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
- `Mono.Android.dll` in the pinned `Microsoft.Android.Runtime.37.android`
  37.0.0-rc.1.2257 (built from dotnet/android `b65b55d5`, per its `.nuspec`)
  carries 108,022 `[Register]` attributes: 9,063 Java types and 77,689 members
  with JNI signatures, about 2.3 MB of member names and signatures. It also
  records the API level of 84,486 members, 11,243 `IntDefinition` constant
  mappings and 691 `RequiresPermission` entries. Its binding bodies call
  `Java.Interop` (`ContextWrapper.get_PackageName` is 38 bytes of IL around
  `JniPeerMembers.InstanceMethods.InvokeVirtualObjectMethod`), so the data is
  usable and the IL is not.

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
- The payload is the names in `lib/minimal-assembly-order.txt`, pinned
  by digest; its current length (98) is the assembly count every step checks.
- `libpwsh-host.so` (x86-64, arm64, and arm32 in
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
  (131,709 fat headers in the minimal payload).
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
- The current build candidate includes and imports the Utility, Management and
  Security command assemblies from the in-memory store. Its arm64 build gate
  passes; command execution is not established until the x86-64, arm64 and
  arm32 device receipts exist. Roslyn (`Microsoft.CodeAnalysis.*`) remains
  absent, so `Add-Type -TypeDefinition` and `-MemberDefinition` cannot work on
  device.

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
- Until the .NET for Android path was removed (2026-09-26), `-Debug` compared
  the emitted type-map name and `classes.dex` against a .NET SDK reference
  build.

### Proven on a device or the emulator

- The x86_64 emulator (API 36) runs CellCanvas in-process.
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
- Gate 2e admission prerequisite, 2026-09-26: `RunPowerShell(IntPtr)` receives
  the borrowed `ANativeActivity*` and places it in the runspace as
  `NativeActivityHandle`. Its first build threw `NullReferenceException` on all
  three backends: an `IntPtr` constant became a closure-bound constant that a
  persisted method cannot load (fixed; the build now rejects such constants).
  With the fix, gates 2a-2d pass again on the x86_64 emulator, the S23 and the
  onn 4K Plus (arm32, API 34), with the managed host assembly named
  `Dev.MansfieldPlumbing.Pwsh`: every marker on the main thread, the process
  alive 40 seconds later, the crash buffer empty.
- IL-only store, 2026-09-26: with all 62 ReadyToRun images re-emitted IL-only,
  CoreLib included, gates 2a-2d pass on the x86_64 emulator, the S23 and the
  onn 4K Plus, every marker on the main thread, alive 40 seconds later, no
  crash for the process. Startup (Admit to `RunPowerShell returned`) rose
  from 0.51-0.55 s to 0.97-1.03 s on the S23 and from 3.8-4.0 s to
  6.8-7.2 s on the onn; the JIT now compiles the CoreLib and `System.*` code
  that ran precompiled.
- Without .NET for Android, 2026-09-26: the `-Admission Xamarin` path, the DEX
  and `libxamarin-app` steps, type maps, the `-Debug` reference build,
  `classes.dex`, and `Mono.Android`, `Mono.Android.Runtime`, `Java.Interop`,
  the resource designer and `Probe.dll` are gone; the payload is 91
  assemblies and the managed host assembly is `Dev.MansfieldPlumbing.Pwsh`.
  The build emits the same manifest bytes as before. Gates 2a-2d pass on the
  x86_64 emulator, the S23 and the onn 4K Plus with no crash for the process;
  the arm64 APK is 16,547,569 bytes. CellCanvas does not run until gate 2e.
- Pixels from PowerShell, 2026-09-26: with no rebuild, `scripts/ScreenProbe.ps1`
  placed as `Profile.ps1` in a `-Debuggable` build declares the
  `libandroid` window calls and a callback delegate type with
  `Reflection.Emit` at run time, writes the delegate's function pointer into
  `onNativeWindowCreated` and `onNativeWindowRedrawNeeded` (slots 7 and 9 of
  `ANativeActivityCallbacks`, `native_activity.h`; the table is zeroed by
  `NativeCode`'s constructor, frameworks/base `299fe6f5`
  `android_app_NativeActivity.cpp:121`), selects `WINDOW_FORMAT_RGBA_8888`
  (1, frameworks/native `bfcf7507`), and fills four colored quadrants with
  `ANativeWindow_lock` and `ANativeWindow_unlockAndPost`. `screencap`
  read red, green, blue and white at the four quadrant centers on the x86_64
  emulator (1080x2400), the S23 (2340x1080, stride 2368) and the onn 4K Plus
  (1920x1080; black 2 s after the marker, correct on the next capture); the
  process was alive 20 seconds later with no crash for it. The callbacks
  reach script-block delegates on the main thread; the product's
  `[UnmanagedCallersOnly]` callbacks in the compatibility assembly (Layering)
  are not proven by this.
- JNI and Android `Canvas` from PowerShell, 2026-09-26, no rebuild, on the
  x86_64 emulator, the S23 and the onn 4K Plus under CheckJNI (on in
  `-Debuggable` builds). `scripts/probes/jni/Jni.ps1` binds the
  `JNINativeInterface` slots, all derived from `jni.h` (libnativehelper
  `af5fd77f`, SHA-256 `C88CE2CB…B601A`, 233 entries), as delegates on
  `activity->env`. The JNI probe read `GetVersion` 0x00010006, `SDK_INT` equal to
  `activity->sdkVersion` (36, 36, 34), `getPackageName` through
  `CallObjectMethodA`, and `Integer.toHexString` through
  `CallStaticObjectMethodA` with a `jvalue[]`. The Canvas probe took the window's
  `Surface` with `ANativeWindow_toSurface`, drew with `lockCanvas`, `Paint`,
  `Typeface.MONOSPACE`, `drawText` and `drawRect`, and posted it; `screencap`
  read the eight Campbell ANSI colors exactly across the band and text pixels
  in the text area on every device. Each process was alive afterwards with no
  crash for it. `modules/AndroidCanvas.psm1` packages the same mechanism as
  one importable file (function pointers as delegates, NDK exports, the JNI
  table, Canvas, window callbacks); `scripts/probes/module` drew through it
  with the same color result on all three devices. An exception that escapes a
  window callback aborts the process (seen once, x86_64 emulator), so every
  callback catches everything, including failures of its own error logging.
- QuickPS `src/Native.ps1` at `62747ebf` does not run unchanged in this
  payload: its first `Add-Member` fails, because that cmdlet is in
  `Microsoft.PowerShell.Commands.Utility` (`AddMember.cs`), which is not
  shipped; `ForEach-Object` is in SMA (`InternalCommands.cs`) and resolves.
  With each `Add-Member ScriptMethod` replaced by
  `PSObject.Methods.Add([PSScriptMethod])` and nothing else changed, its
  `GetComCall` on `JNIEnv*` (a pointer to a function table, taking the env as
  its first argument, like a COM object) returned `GetVersion` 0x00010006 on all
  three backends, 2026-09-26.
- Console core on devices, 2026-09-27, no rebuild: `modules/Console.psm1`
  replayed all 63 conformance vectors in the app (`CONSOLE PASS 63 FAIL 0`) on
  the x86_64 emulator, the S23 and the onn 4K Plus, parsing JSON with
  `Newtonsoft.Json` from the payload. Its frame, drawn op by op through
  `AndroidCanvas.psm1`, showed the progress row's Yellow background
  (`F9F1A5`), palette 208 (`FF8700`), truecolor `3A96DD` and empty `0C0C0C` in
  `screencap` on all three. Without an input-queue reader the S23 reported the
  app not responding; with `onInputQueueCreated` attaching the queue to the
  main looper and finishing every event, a session of 12 taps and 249 redraws
  logged no not-responding event. The grid is inset by the system bars
  (`WindowInsets.Type.systemBars`, S23 portrait 98 px top, 45 px bottom), and
  pinch changes the text size and reflows the grid within the visible area:
  89 grid sizes from 63x66 to 25x26 cells, no module error, process alive.
- The 2026-09-27 console receipts used the preceding 91-image payload without
  cmdlet modules, so their profile fixtures use the language and .NET only.
  They do not prove commands in the current payload.
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
- PSLowering output on devices, 2026-10-04, no rebuild beyond `-Debuggable`
  (`fdf4719`): `tools/Build-LoweringProbe.ps1` compiled the 11 fixture
  classes of PSLowering `25427b25` on Windows (PowerShell 7.7.0-preview.4,
  .NET 11.0.0-preview.6), and `scripts/probes/lowering/Profile.ps1`, placed
  with them through `run-as`, loaded each assembly by path from the app's
  private files directory and ran PSLowering's 196 oracle vectors twice: as
  the fixture's PowerShell class under SMA on the device, and as the compiled
  IL. `LOWERING calls 196 divergences 0` on the x86_64 emulator, the arm64
  physical device and the onn 4K Plus (arm32), each on .NET
  11.0.0-rc.1.26425.128, alive 20 seconds later with an empty crash buffer.
  This proves Windows-compiled PSLowering IL runs with PowerShell's meaning
  on all three backends when loaded in a running process; it does not prove
  loading before `Profile.ps1`, hash admission, or persistence across a
  restart (ROADMAP: private-storage assembly load).

- ConsoleHost startup, 2026-10-03: release APKs (`-Startup ConsoleHost`, not
  debuggable) built from `fdf4719` on the x86_64 emulator (API 36), the arm64
  physical device (API 36) and the onn 4K Plus (API 34) started from the
  launcher with no `run-as` step, copied the 7 script assets, logged every
  marker through `CONSOLEHOST START_INVOKE_END` and `RunPowerShell returned
  0x50575348`, drew the banner and prompt, and evaluated `1+2` typed through
  `adb shell input` as `3`; each process was alive 40 seconds later with an
  empty crash buffer and no not-responding event, and the onn drew no frame
  during 10 idle seconds. Not yet accepted: input from the on-screen keyboard,
  a shipped command resolving from `PATH`, and a fresh install.

### Other repositories (their READMEs)

- RyuJitDetach lifts leaf-only RyuJIT bodies into AMD64 Windows PE files; its
  shim owns every call. It does not produce ARM64 or Android code.
- PSLowering (formerly PSPersistence) compiles methods of typed PowerShell
  classes to IL assemblies with its own PowerShell-authored emitter; its
  output references only `System.Private.CoreLib`. It does not produce native
  code.
## Rules for specific changes

- Acceptance workloads are the shipped ConsoleHost console (its acceptance
  list is in `docs/console-host.md`) and the conformance scripts. No
  compatibility surface is built to reproduce a removed framework's API.
- `scripts/CellCanvas.ps1` is frozen (SHA-256
  `8E96992365A72E81B1A1EEB518AE9052020519EA175EC5465BAC4A989928F3B9`) as a
  benchmark of the cell presenters: Android `Canvas` per cell, or one packed
  AGSL `RuntimeShader`. Do not edit it. Its animated fill, 120 fps request and
  `FPS`/`CELL`/`UP`/`SUBMIT`/`TOTAL`/dropped-frame log line measure those
  presenters; they do not establish that the terminal redraws every frame. It
  was renamed from `CanvasDemo.ps1` without changing its bytes, so its own error
  text still names the old file. Gates 2a-2d removed Xamarin; the former gates
  2e and 2f, a Xamarin-shaped compatibility assembly for this script, are
  retired.
- Every gate runs on three backends: x86-64 on the emulator finds the next
  boundary; arm64 on a physical device confirms it; arm32 must pass
  before the gate is called portable. Each backend is independent evidence:
  a failure on x86-64 or arm64 may not reproduce on arm32, and an arm32 pass
  does not waive a 64-bit invariant (a misaligned fat method header is fatal
  on 64-bit CoreCLR and passes unchecked on 32-bit). Port each narrow gate to
  arm64 and arm32 as soon as it passes on x86-64, before building the next
  layer.
- Android APIs are reached through JNI using a binding table extracted at build
  time from the `[Register]` attributes of `Mono.Android.dll` in the pinned
  `Microsoft.Android.Runtime.37.android` package, read as metadata only and
  cross-checked against AOSP `core/api/current.txt` at a pinned commit. Calls
  go by name through the table, or through generated typed wrappers lowered to
  IL where a path is hot. `Mono.Android`, `Java.Interop` and their IL are never
  loaded, executed or shipped. Do not build Java peer tracking, type maps or
  the Java.Interop object model.
- Java classes in the DEX are generated only for manifest components and
  callback bridges: the `NativeActivity` subclass, services, broadcast
  receivers, content providers, widget providers, tile services, the
  `InvocationHandler` behind `java.lang.reflect.Proxy`, and subclasses of
  abstract callback types a workload uses. Each generated class extends its
  framework type, and each overridden method is a `native` method registered to
  a managed callback. Nothing else is written in Java.
- The runspace runs on the Android main thread (`UseCurrentThread`), and the
  window and input callbacks arrive there. `activity->env` belongs to the main
  thread; any other thread attaches through `activity->vm`. Android's own
  `Canvas`, `Bitmap`, `Paint` and AGSL `RuntimeShader` draw, reached through JNI
  on the `Surface` from `ANativeWindow_toSurface`.
- Keep `NativeActivity`'s `NativeContentView` as the content view. Under the
  surface `NativeActivity` takes, `ViewRootImpl` draws no views
  (`ViewRootImpl.java:4838`), input goes to the native queue (`:1450`), and
  `NativeActivity` derives the content rectangle and IME focus from that view
  (`NativeActivity.java:301-335`; frameworks/base `299fe6f5`). Non-drawing
  views, such as the text-input view, may be added with `addContentView`.
  Rendering goes through the window surface; the renderer is chosen
  separately.
- Layering. QuickPS Android mechanisms are literal and policy-free: NDK
  exports, JNI function-table dispatch, looper and input primitives, the
  choreographer binding. Pwsh owns the `[UnmanagedCallersOnly]` callbacks
  installed in the `NativeActivity` callback table, passed to `AChoreographer`
  and registered for generated Java classes, and turns them into events for
  PowerShell on the main thread. No hand-written native stub sits between the
  callback and managed code.
- Code is lowered when it runs per byte, cell, glyph or frame; when it is
  called on a thread other than its runspace's (host interfaces called from a
  pipeline thread, native callbacks); when it must work without SMA (the crash
  guard and Recovery); or when a measurement on the startup path justifies it.
  Decisions made at event rate stay in PowerShell: the lowered core does the
  work and hands decisions to the main thread.
- Before modifying `Read-ElfImage`, the SysV ELF hash implementation, or the
  emitted ELF hash-table structure, add and pass a permanent multi-bucket hash
  self-test that covers successful chained lookups and missing-symbol lookups.

## Open questions

Verify each on hardware before relying on it.

- Not yet proven: Activity re-creation (a second `ANativeActivity_onCreate`
  fails `coreclr_initialize` with 0x80131022 on Google TV); the binding table;
  generated component classes; pseudo-terminal sessions for native programs;
  the crash guard and Recovery; the animation callback; the 40 store
  assemblies no proven path has requested, served in place.
- The console's command runner invokes input with `&`, a child scope, so
  variables and functions defined at the prompt do not persist; it renders
  objects by string conversion rather than the formatting system; and it runs
  on the main thread without a `PSHost` implementation. Its own host replaces
  it.
- A burst of 30 keys injected with `adb shell input text` reached the console
  as 26 characters on the onn 4K Plus; the same keys sent one at a time all
  arrived. Not yet traced.
- Still open for QuickPS: its `CallingConvention.StdCall` attribute was
  harmless for one argument-free call (`GetVersion`) on all three backends;
  calls with arguments through it are untested.
- The exact runtime properties `coreclr_initialize` needs without the .NET for
  Android host.
- Settled 2026-09-26: `libSystem.Security.Cryptography.Native.Android.so`
  needs Java-side loading before any hashing or TLS. Its `GetJNIEnv`
  dereferences a `JavaVM*` that only its `JNI_OnLoad` stores (`pal_jni.c:676`,
  `:689-693`, runtime `ab194157`). Loaded by CoreCLR's P/Invoke, the first
  `SHA256.HashData` faulted at address 0 (x86_64 emulator). Calling its
  `JNI_OnLoad` from managed code then aborted on `GetClassGRef: class
  net/dot/android/crypto/DotnetProxyTrustManager was not found`: `FindClass`
  resolves through the current Java method's class loader, and uses the
  app's loader only inside `Runtime.nativeLoad` (art `3c05e56a`,
  `jni_internal.cc:392-408`). The fix is Java-side `System.loadLibrary` from
  the emitted `NativeActivity` subclass, with the runtime pack's
  `libSystem.Security.Cryptography.Native.Android.dex` packaged.
- How the host resolves the per-install native library directory.
- Whether the ELF32 store library should reserve eight dynamic entries like
  ELF64. Changing it alters proven arm32 bytes, so it needs its own device run.
- A permanent self-test for `Read-ElfImage` hash lookups, including missing
  names that hash into occupied and empty buckets. Every emitted table has one
  bucket, so the build itself never exercises bucket selection.
