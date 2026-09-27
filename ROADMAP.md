# Pwsh roadmap

This is the single implementation roadmap. A checked item names the gate or
receipt that proves it; an unchecked item is planned, not done. Proofs and
their evidence classes live in `AGENTS.md` (Established facts) and
`docs/DEVELOPER.md`; design notes live in `docs/`.

## Product boundary

Pwsh turns a PowerShell script into an Android app and owns every byte in
between. `setup.ps1` emits the IL, DEX, manifest, ELF libraries, machine code
and signed APK from pinned, hash-verified inputs. On the device an owned native
host starts CoreCLR and runs PowerShell; Android is reached through its C APIs
or JNI bound from pinned headers. Applications are PowerShell scripts.

Ship versions are locked: PowerShell 7.7.0-preview.5 and .NET
11.0.0-rc.1.26425.128.

## Verified checkpoints

- [x] ELF `ET_DYN` emission for arm64, x86-64 and arm32; every instruction is
  decoded back by an independent decoder (`Test-ElfCodeLibrary*`).
- [x] Gates 2a–2d on the x86_64 emulator, the Galaxy S23 (arm64) and the arm32
  device: CoreCLR from `ANativeActivity_onCreate`, assemblies served in place
  from the aligned store, a `UseCurrentThread` runspace, and the product's
  `Profile.ps1` path. These runs predate the gate 2e host change below.
- [x] Package pins: 18 packages pinned by id, version, RID and SHA-512; step 2
  yields the same 14 packages per target, byte for byte, as the resolver it
  replaced.
- [x] All generated output under the git-ignored `build/`; the write guard
  refuses any other repository path.
- [x] Pre-push scan for secrets, key files and personal data
  (`tools/Test-PendingChanges.ps1`, `.githooks/pre-push`), tested end to end.
- [x] Upstream pin check (`tools/Test-UpstreamPins.ps1`): all 22 pinned
  addresses serve their pinned bytes.
- [x] Step 1 verifies every upstream pin on every build without a web view:
  `git-v2` pins read a file at a pinned commit through git's smart-HTTP
  protocol v2 using `Invoke-WebRequest` alone, one object per request, each
  checked against its git object id from the pinned commit down to the file.
  `android.googlesource.com` returned 503 for its web view while serving this
  protocol; `log.h` and `native_activity.h` verify byte for byte.

## Next: unblock the build

- [x] Byte-identical APK proof of the 2026-09-26 refactor (package pins,
  `build/` output, renames, `git-v2` transport): every target under both
  admissions, built from the frozen `build/baseline-src/` and from `168ffb0`
  with the same pinned packages and signing key, produced identical APKs
  (SHA-256 prefixes: arm64 `28AE42E2` NativeActivity, `F4FA8243` Xamarin;
  x64 `6D4E624B`, `059DBF79`; arm32 `E6198AEA`, `EFC0587C`). The baseline ran
  from a copy whose googlesource fetch used `git-v2`, which changes how step 1
  reaches upstream, not the admitted bytes. The baseline already contains the
  gate 2e host change, so this proof does not cover that change.
- [x] The gate 2e host change (`RunPowerShell(IntPtr)`, `NativeActivityHandle`)
  passes gates 2a-2d on the x86_64 emulator, the S23 and the onn 4K Plus
  (arm32) after its bound-constant fix; the managed host assembly is
  `Dev.MansfieldPlumbing.Pwsh`.

## Payload

- [ ] Stage 2 pins (preview.5, rc.1). Owner decision first: the
  `Microsoft.PowerShell.SDK` package or SMA plus the Utility, Management and
  Security packages.
- [ ] Reconcile `docs/assembly-audit.md` with
  `docs/powershell-load-behavior.md`; freeze a payload from the device-traced
  startup set (`-TraceAssemblyProbe`) plus supported features; add
  `Microsoft.Management.Infrastructure.Runtime.Unix` to the probe explicitly.
- [x] ReadyToRun removed. Step 4 re-emits every selected R2R image (62 of
  96) as an IL-only PE32 image: IL bodies, field data, metadata and resources
  kept, native code, R2R header and exception, relocation, debug and import
  data dropped, MethodDef and FieldRVA RVAs rewritten (`Tables.cs:431`,
  `:1811`). Step 5 refuses any store image with an R2R header or without the
  IL-only flag (`pedecoder.cpp:1228` CheckILOnly). Checked offline on all
  three packs: every IL body, field blob, resource blob and metadata byte
  identical apart from the RVA columns; Windows CoreCLR loads all 61
  non-CoreLib images. Gates 2a-2d pass on the x86_64 emulator, the S23 and the
  onn 4K Plus. The arm64 APK went from 40,967,652 to 25,872,787 bytes.
- [ ] Startup cost of IL-only, measured Admit to `RunPowerShell returned`:
  S23 0.51-0.55 s to 0.97-1.03 s; onn 3.8-4.0 s to 6.8-7.2 s; emulator
  2.0 s to 3.5-4.1 s (cold 3.3 s to 11.2 s). On the emulator's cold run,
  `CreateDefault2` took 4.5 s and `Open` 4.2 s of 11.2 s. Next: a leaner
  initial session state, measured on all three devices.
- [ ] Store compression. The store is about 111 MB uncompressed; `zstd.h` is
  pinned and unused.

## Leaving .NET for Android

- [ ] Pin `jni.h` as a `git-v2` source: AOSP `libnativehelper` at
  `android-14.0.0_r1` (commit `af5fd77f`), `include_jni/jni.h`, SHA-256
  `C88CE2CB6CE10378CD4C706A3A2AD017794AEDB9314DDCC341E39B470CDB601A`. Its
  `JNINativeInterface` has 233 entries; `GetVersion` is slot 4, `FindClass` 6,
  `GetMethodID` 33, `CallObjectMethodA` 36, `RegisterNatives` 215,
  `ExceptionCheck` 228. The build derives slots from the header, never from a
  table typed by hand.
- [ ] Gate 2e: JNI function-table calls (`GetVersion`, `FindClass`,
  `GetMethodID`, one `Call*MethodA` with `jvalue[]`) from the pinned `jni.h`
  on all three backends, then an owned compatibility assembly that satisfies
  exactly the CellCanvas surface.
- [ ] Gate 2f: the frozen `scripts/CellCanvas.ps1` bytes run with Mono.Android,
  Mono.Android.Runtime, Java.Interop, libmonodroid, libxamarin-app, Xamarin DEX
  and type maps absent.
- [x] .NET for Android removed: the `-Admission Xamarin` path, the DEX and
  `libxamarin-app` steps (the build is 9 steps), type maps, the `-Debug`
  reference build, `classes.dex` and the Xamarin fixture, the three
  `Microsoft.Android.Runtime.CoreCLR` pins, and `Mono.Android`,
  `Mono.Android.Runtime`, `Java.Interop`, the resource designer and `Probe.dll`
  from the payload (96 to 91). `Microsoft.Android.Runtime.37.android` stays
  pinned as build-time metadata for the gate 2e compatibility surface; it is
  never packaged. Same manifest bytes; gates 2a-2d pass on all three devices;
  arm64 APK 16,547,569 bytes.

## Emitted native code: racing RyuJIT

Compilers are competitors and oracles, not authorities. The model is
Kokoro-Hexagon's receipts at commit `250e10dc`: its PowerShell-lowered R0Sub0
kernel ran 2.21–2.30x faster in DSP ticks than Hexagon Clang 19.0.04 output, bit
exact, on SM8550 and SM8635 (`r0sub0-lowered-vs-llvm-20260924.md`,
`r0sub0-cross-soc-20260924.md`), after an earlier head-to-head lost at 0.865x.
The win came from specialization to known shapes and layout.

- [ ] **N1 Profile.** Profile CellCanvas on the S23 and name the hottest CPU
  loop, or show that the time is in JNI and `Canvas` calls instead.
- [ ] **N2 Emit.** Emit that loop as A64 into an ELF `.so` from named
  encoders, decoded back and AAPCS64-checked by the build; call it from
  emitted IL through an unmanaged function pointer (`calli`). The code is
  file-mapped by the system loader: no JIT time, no copied R2R image, never
  writable and executable at once.
- [ ] **N3 Race.** Compare against RyuJIT Tier-1 compiling the same logic:
  bit-exact output, counterbalanced cold and warm runs, device-side timing.
  Repeat on x86-64 and arm32. The claim covers that kernel on those devices
  only.
- [ ] **N4 Lower.** Where SMA's dynamic dispatch dominates, lower a restricted
  PowerShell subset to IL at build time (Kokoro-Hexagon's managed-lowering
  receipt is the precedent) before reaching for native code.
- [ ] **N5 Self-update.** IL: a device-lowered, IL-only assembly written to
  private storage, admitted by hash, promoted by an atomic active pointer and
  loaded at the next start; prove admission, tamper rejection and rollback on
  all three backends. Machine code: the device reports hot paths, timings and
  ISA; the paired Windows PC lowers them with the named encoders, signs a
  split APK and installs it with `MODE_INHERIT_EXISTING`; prove that the
  split's `.so` loads and is called from emitted IL. To verify first: whether
  an adb partial install (`install-multiple -p`) needs on-device confirmation,
  and what an app-initiated session requires.

## Build hygiene

- [x] Rename the managed host assembly to `Dev.MansfieldPlumbing.Pwsh.dll`; derive the native
  host's assembly-name literal from `$script:ManagedNamespace`.
- [ ] Step 6's title says ELF64 but the step also emits ELF32.
- [ ] Skipped steps print SKIP, not PASS.

## UI and platform

- [ ] The console and composited UI in `docs/ui.md`: a cell-grid VT/ANSI text
  area with reflow and a tab strip, plus a dp-based UI; tap only, 24–44 dp
  targets.
- [ ] Renderer decision (owner): Android `Canvas` and AGSL through JNI, which
  gate 2e/2f requires for CellCanvas, or a Vulkan swapchain on the
  `NativeActivity` window with SPIR-V compiled on the build machine.
- [ ] Intents: declare nearly every intent in the manifest, disabled and
  pointing at script stubs, then freeze the manifest; scripts enable
  components at runtime with `DONT_KILL_APP`. Own-package changes need no
  permission (`docs/ui.md`, traced to `PackageManagerService`).
- [ ] One emitted DEX subclass of `android.app.NativeActivity`, needed before
  the APK freezes. It loads `System.Security.Cryptography.Native.Android`
  with `System.loadLibrary` before `super.onCreate`, so its `JNI_OnLoad` runs
  with the app's class loader (required for any hashing or TLS; see
  `AGENTS.md` open questions), and ships with the runtime pack's
  `libSystem.Security.Cryptography.Native.Android.dex`. It forwards
  `onNewIntent` (the base class drops it) and hosts a view whose
  `InputConnection` carries soft-keyboard text (the base view has none),
  attached with `addContentView`.
- [ ] Private-storage assembly loader in the host, run before `Profile.ps1`:
  content-addressed `store/<SHA256>.dll`, an `active.tsv` admission list,
  `previous.tsv` rollback; IL-only, hash and identity checks; load from the
  verified bytes; `Import-Module -Assembly`. Prototype passes install, update,
  rollback, tamper and fallback cases on Windows in fresh `CreateDefault2`
  runspaces. On the device it needs the crypto library initialized first.
- [ ] Select a 32-bit window buffer format before drawing; `NativeActivity`
  defaults the window to RGB_565.
- [ ] Service slots: one emitted DEX forwarder per Android base class that
  needs one (accessibility, input method, tile, voice interaction) and a
  dispatcher that answers within Android's deadlines.

Design constraints: one event queue, blocking in `ALooper_pollOnce(-1)`, with
lifecycle, input, timers and completions as file descriptors on the looper; no
tick or polling loops.

## Release

- [ ] Numbers measured on hardware and published: cold start, time to first
  frame, idle CPU, input-to-photon latency, APK and store size.
- [ ] A reproducible manifest, SBOM and signed APK, with per-backend receipts.
