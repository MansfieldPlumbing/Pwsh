# Pwsh roadmap

This is the single implementation roadmap. A checked item names the gate or
receipt that proves it; an unchecked item is planned, not done. Proofs and
their evidence classes live in `AGENTS.md` (Established facts) and
`docs/DEVELOPER.md`; design notes live in `docs/`.

The [implementation plan](docs/implementation-plan.md) sequences the work;
the roadmap owns status, and the separate audit retains source observations.

## Current priorities (2026-10-10)

This is the current queue, superseding earlier dated priority lists. Deliver
useful slices independently; a complete foundation framework is not a shipping
prerequisite. These spikes remain open until exercised on their claimed targets.

1. [ ] **Real console host.** Own `PSHost`, `PSHostUserInterface` and raw UI;
   preserve session state, PowerShell formatting and streams, prompt/input,
   cancellation and on-screen keyboard behavior through the application's host.
2. [ ] **Bindings.** Make native and Android APIs callable from PowerShell for
   real consumers, with argument/return contracts, callback ownership and lifetime.
   Metadata inventories alone do not constitute working bindings.
3. [ ] **PSRP with application lifetime.** Host authenticated remoting in the
   resident application, with session state, cancellation and orderly shutdown.
   Activity recreation or closing the console must not accidentally terminate
   the server; implement the required foreground/background platform lifecycle.
   SMA already provides the endpoint through public API:
   `RemoteSessionNamedPipeServer.CreateCustomNamedPipeServer(name)` serves full PSRP over a
   Unix socket (the `pwsh -CustomPipeName` server path), and
   `RunspaceFactory.CreateRunspace([NamedPipeConnectionInfo]::new(name, timeoutMs))` connects
   to it. SSH transport and authentication sit in front of that.
4. [ ] **musl support.** Establish a runnable musl target, naming its ABI,
   runtime and dependency closure; verify the host and the capabilities claimed
   for that target. Android bionic receipts do not prove musl support.
5. [ ] **Run `pwsh.so`.** Provide an actual invocation/hosting path: the caller,
   entrypoint, payload/dependencies and startup/shutdown ownership. An emitted
   shared library alone is not a runnable-host result.

Pwsh is the upstream general-purpose host. Downstream model or assistant work
does not belong in this queue. A projection server can be authored directly in
PowerShell; archived Subsystem code is optional reference material, not a
dependency or a prerequisite reconstruction project.

- [ ] Rename `setup.ps1`'s `$script:StepGraph` to `$script:BuildSteps`: it is the
  table of build steps, dependencies, labels and actions used by execution and
  the interface. Keep the shared declarations and dependency validation.
  This directive sweep records the rename; it does not change application code.

## Product boundary

Pwsh brings a resident PowerShell/.NET environment to Android. `setup.ps1` is
the build application for that environment: it verifies its pinned inputs,
acquires and checks runtime packages, selects the managed assemblies for the
target, and emits the project's managed host and native libraries. It packs the
assemblies into a store, emits the Android manifest, assembles the APK and signs
it. CoreCLR and PowerShell are reused from verified packages; the project emits
the hosting and packaging code that connects them to Android.

At launch, Android's `NativeActivity` loads `libpwsh-host.so`. The native host
starts CoreCLR, resolves managed assemblies from the packaged store and enters
the managed host, which opens an in-process PowerShell runspace. The selected
startup path runs `Profile.ps1` directly or starts the console, which then runs
the profile. Application scripts execute inside that runtime; native and JNI
bindings connect them to Android APIs. This build-and-host path does not imply
that every application script is compiled to native code.

The current preview contains no DEX. The fixed Java subclasses planned below
are additional Android integration work, gated separately from the existing
native startup path. Console hosting, bindings, remoting and application
lifetime remain subject to the explicit gates in this roadmap.

The current build inputs pin PowerShell 7.7.0-preview.4 and .NET
11.0.0-rc.1.26425.128.

## Verified checkpoints

- [x] ELF `ET_DYN` emission for arm64, x86-64 and arm32; every instruction is
  decoded back by an independent decoder (`Test-ElfCodeLibrary*`).
- [x] Gates 2a–2d on the x86_64 emulator, the Galaxy S23 (arm64) and the arm32
  device: CoreCLR from `ANativeActivity_onCreate`, assemblies served in place
  from the aligned store, a `UseCurrentThread` runspace, and the product's
  `Profile.ps1` path. These runs predate the gate 2e host change below.
- [x] Package pins: 15 packages pinned by id, version, RID and SHA-512; step 2
  selects 13 packages for a target, including its one RID-specific runtime
  pack.
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

- [x] Pixels on screen from PowerShell on all three backends, no rebuild:
  `scripts/ScreenProbe.ps1` as `Profile.ps1` hooks the window callbacks and
  fills the `NativeActivity` window; `screencap` confirmed the colors
  (`AGENTS.md`, Pixels from PowerShell).

## Next work, in order (as of 2026-10-04)

Historical queue; the 2026-10-10 priorities above take precedence. Each item
links to its full entry.
Compiler work happens in [PSLowering](https://github.com/MansfieldPlumbing/PSLowering)
(its own [ROADMAP.md](https://github.com/MansfieldPlumbing/PSLowering/blob/main/ROADMAP.md));
Pwsh takes it at a pinned commit.

1. **Console input defect:** bursts of key events lose characters on the arm32
   device (a 30-key `input text` burst arrived as 26; the same keys one at a
   time all arrived). `modules/AndroidCanvas.psm1:984-1012` drains the input
   queue correctly, so the loss is after it. Trace and fix before any
   acceptance claim about typing (ConsoleHost, below).
2. **ConsoleHost acceptance:** the remaining items of
   [docs/console-host.md](docs/console-host.md#spike-acceptance): on-screen
   keyboard input, a fresh install, a shipped parser resolved from `PATH`.
3. **Activity re-creation:** host re-attach on all three backends (UI and
   platform, below).
4. **Startup breakdown:** time each phase on the arm64 and arm32 test devices
   from the existing markers before any startup optimization (Lowering with
   PSLowering, below).
5. **Adopt PSLowering in `setup.ps1`** for the managed host methods, then the
   console core (Lowering with PSLowering, below).
6. **ADB:** the arm64 handshake failure, then the emulator's TCP transport and
   a binary-safe `exec:`; then move `tools/Invoke-DeviceScript.ps1` and
   `tools/Invoke-HardwareCanvasProbe.ps1` off adb.exe (Optional packaged
   commands and ADB, below).
7. **Housekeeping:** remove or pin `setup.ps1 -Aapt2Path` (it runs an
   installed, unpinned aapt2 as a diagnostic); regenerate the learn site from a
   pushed SHA per [docs/publishing.md](docs/publishing.md).

## Direction and plan (2026-10-08)

Pwsh makes an Android device a general-purpose computer, a peer of Windows
and Linux machines (`AGENTS.md`, Purpose). The organizing milestone is remote
access the way those machines offer it. Every item below names the
foundations it waits on (F1-F6). Nothing here is proven until it names a gate
and a receipt.

### Foundations

- [ ] **F1 Binding table.** Extract `[Register]` rows (Java class, member, JNI
  signature, API level, constants, nullability, permissions, overridable flag)
  from `Mono.Android.dll` in the pinned `Microsoft.Android.Runtime.37.android`
  37.0.0-rc.1.2257 (dotnet/android `b65b55d5`) as metadata, at build time.
  Cross-check against AOSP `core/api/current.txt` at a pinned commit. Drop
  removed APIs and Java SE packages that .NET covers. Ship the table
  compressed (about 2.6 MB uncompressed in full). Tiers: call by name through
  the table; typed wrappers lowered on the device; typed wrappers lowered at
  build time.
- [ ] **F2 Component DEX.** Recover the DEX writer from `0804758`
  (`New-JavaPeerDex`, `Invoke-DexStep`). Generate the `NativeActivity`
  subclass (Java-side load of the crypto library for TLS and hashing;
  `onRequestPermissionsResult`, `onActivityResult`), the foreground service,
  the `InvocationHandler` behind `java.lang.reflect.Proxy` (listener
  interfaces), and subclasses of abstract callback types a workload uses. Each
  overridden method is a `native` method registered to a managed callback.
  Reference for the generator: dotnet/android `b65b55d5` Java callable
  wrappers (MIT).
- [ ] **F3 Resources.** Emit `resources.arsc` and compiled XML resources:
  app shortcuts, the widget provider description and layouts, icons.
- [ ] **F4 Foreground service.** Keeps the runtime alive with the screen off;
  needed by the peer link, widgets, downloads and the socket service.
- [ ] **F5 Lowered console core.** `modules/Console.psm1`: PSLowering's
  admission check compiles 39 of its 70 class methods at `1afabe05`; the rest
  wait on PSLowering item 1.4 (`List` indexing and `foreach` over collections,
  mixed numeric promotion, `if` as a value, conversions without a CLR
  operator). On the Pwsh side, rewrite the remaining scriptblock, hashtable and
  expandable-string uses (`ConsoleDiff.Frames`, `ConsoleModel.StreamStyle`,
  `ConsoleModel.Compose`, `ConsoleFrameRing.AcquireLatest`). Prove parity
  between script and IL on the 63 conformance vectors.
- [ ] **F6 PSLowering requirements** (requests to that project). CoreLib is
  the floor, not the ceiling: (1) declared references above the floor, with a
  check that an assembly declared CoreLib-only stays so; first use, SMA, to
  derive from `PSHost`, `PSHostUserInterface` and `PSHostRawUserInterface`;
  (2) `[UnmanagedCallersOnly]` methods with their function pointers and (3)
  unmanaged `calli`, both PSLowering item 1.2 and in progress; (4) the console
  core gaps of its item 1.4 (39 of 70 `Console.psm1` class methods lower at
  `1afabe05`).

### Remote access (milestone)

- [ ] **Device identity.** A P-256 key pair per device, created on the device
  and never exported (Android Keystore, StrongBox where present). It is the SSH
  host key and the TLS identity for every remote service below.
- [ ] **PSRP over SSH.** Stock `pwsh` reaches the device with `Enter-PSSession
  -HostName` and `Invoke-Command -HostName`. An SSH server written in
  PowerShell with what .NET provides (ECDH and ECDSA on P-256, AES-GCM),
  public-key authentication only, on an unprivileged port. Its `powershell`
  subsystem relays to SMA's own in-process PSRP server: the
  `RemoteSessionNamedPipeServer` every PowerShell process starts (a Unix domain
  socket restricted to the same user) served by `NamedPipeProcessMediator`,
  which does not end the process on error (`OutOfProcServerMediator.cs:510`,
  `RemoteSessionNamedPipe.cs:296`, PowerShell `149ab5cd`; re-read at the
  shipped preview). Sessions run inside the app with access to JNI and the
  binding table. To verify: the listener binds on the device (temp directory,
  socket path length), and how to serve more than one session (the mediator is
  a singleton).
- [ ] **Pairing.** Exchange the device's host key and the client's public key
  once, by a short code (SPAKE2, shared with ADB wireless pairing) or over a
  USB cable. `authorized_keys` and `known_hosts` then pin both sides.
- [ ] **Authorization.** PSRP session configurations restricted per client in
  the style of JEA; a full session is an explicit grant. Every session and
  command is logged with client, command and result.
- [ ] **Projection serving.** HTTP and WebSocket on the device serving views
  as web pages backed by Pwsh commands, reachable from any browser on the LAN
  or tailnet, TLS with the device identity.
- [ ] **RDP host.** The device appears in RDP clients (Windows App) as a
  computer. The session shows Pwsh's own desktop rendered off-screen for that
  session, so it needs neither `MediaProjection` nor an accessibility service.
  Minimal: TLS security, bitmap updates of damaged regions, keyboard and mouse
  input. Later: NLA, the H.264 graphics pipeline from `MediaCodec`, clipboard
  and audio. First implementation: FreeRDP's server library as a native
  extension (license and Android build to verify); a PowerShell server from
  `MS-RDPBCGR` and `MS-RDPEGFX` later.
- [ ] **Reachability.** Listen on LAN and tailnet addresses; Android allows one
  VPN, so Pwsh uses Tailscale rather than its own WireGuard when it runs. A
  device behind carrier NAT without Tailscale dials out to a peer and serves
  requests over that connection.
- [ ] **Server readiness.** Foreground service of type `specialUse`
  (`dataSync` and `mediaProcessing` are time-limited from Android 15), partial
  wake lock and Wi-Fi lock while serving, `BOOT_COMPLETED` restart, battery
  optimization exemption. Acceptance: 24 hours serving with the screen off on
  battery-protected charging, through one reboot, with uptime, temperature and
  throughput recorded.
- [ ] **USB debugging disabled.** Every adb duty replaced: session (PSRP),
  files (over SSH and a `DocumentsProvider`), installs and updates
  (`PackageInstaller`; whether self-updates can skip confirmation is to be
  verified), logs (Pwsh's own log; `READ_LOGS` granted once beforehand),
  recovery (crash guard, Recovery, overlay and split rollback). adb remains
  only for a base APK that cannot start.
- Acceptance: (1) from Windows, `Enter-PSSession -HostName <device>` over the
  LAN; (2) the same over Tailscale from a remote network, starting a download
  on the device and reading its progress; (3) all of it with USB debugging
  off.
- Waits on F1, F2 (crypto for SSH and TLS), F4, the socket service.

### UI that ships

- [ ] **Console.** Lower the core (F5). Cheap fixes first: run input with `.`
  instead of `&` (prompt state is lost today), format through `Out-String
  -Stream`, render every stream. Then an own host: `PSHost`,
  `PSHostUserInterface`, `PSHostRawUserInterface` over `ConsoleModel`,
  pipelines on their own thread with Ctrl+C, decisions handed to the main
  thread. Port progress layout, prompts, choices, secure input, transcription
  (`Start-Transcript` lives in ConsoleHost, not SMA) and the executor pattern
  from PowerShell's ConsoleHost source at the shipped preview, verified by
  comparing rendered output with Microsoft's ConsoleHost.
- [ ] **Recovery.** Drawn on the window surface with the lowered console core,
  free of SMA. Actions: copy diagnostics, set the profile aside, retry, import
  a profile through the document picker (needs F2). The removed generators at
  `0804758` (`Add-RecoveryScreenMethods`, `Add-RecoveryActionMethods`,
  `Add-RecoverySupportMethods`, `Add-DocumentImportMethods`) are the reference
  for the action set.
- [ ] **Crash guard.** The managed host counts starts in private storage before
  SMA loads and resets after a stable interval; at 2 consecutive failures skip
  `Profile.ps1`, at 3 open Recovery and roll back the active IL overlay.
- [ ] **Settings.** `settings.ps1` reached from a launcher shortcut (static
  shortcut, `activity-alias`, gear icon; needs F3) and from
  `ACTION_APPLICATION_PREFERENCES` (manifest only). Visual reference: the
  Fluent-faithful notepad and settings recreations (layered surfaces, settings
  cards, section headers, toggles, honest loading and failure states).
- [ ] **Theme record.** One source of truth for colors, radii and type, read
  by the console palette and graphical panes. Fonts: Selawik and Cascadia Code
  (open licenses to verify); icons: Fluent UI System Icons (MIT, to verify).

### Permissions and first run

- [ ] Generate a protection-level table from AOSP
  `core/res/AndroidManifest.xml` at a pinned commit; declare from it, never by
  hand.
- [ ] Declare all normal permissions; request runtime permissions at first
  use; open special-access screens by deep link; offer development
  permissions (`READ_LOGS`, `WRITE_SECURE_SETTINGS`, `DUMP`,
  `PACKAGE_USAGE_STATS`) as an optional one-time grant from a PC.
- [ ] First-run screen as a status page with one-tap grants, using the
  consent-record pattern (Grant, Revoke) of the reference settings page.
- [ ] Flag script calls that need a permission the app does not hold, from the
  table's `RequiresPermission` rows.

### Terminal sessions for native programs

- [ ] Pseudo-terminal sessions: `posix_openpt`/`grantpt`/`unlockpt`/`ptsname`;
  spawn with a new session and the slave as controlling terminal (verify
  `posix_spawn` on bionic; never `fork` in CoreCLR); `TIOCSWINSZ` on resize;
  exit through `pidfd_open` on the looper.
- [ ] VT coverage for full-screen programs: alternate screen, cursor-key mode,
  scroll regions, insert and delete line and character, save and restore
  cursor, bracketed paste, mouse reports, device attribute and cursor
  position replies.
- [ ] Key encoding to VT input sequences; route native commands typed at the
  prompt to a terminal session.
- [ ] Executables reach the device only through the installer as `lib*.so`.
  First program: Edit, built for `aarch64-linux-android` from pinned source in
  a separate repository (its release ships only a glibc Linux build). Second:
  Codex (`aarch64-unknown-linux-musl`, 74 MB compressed), delivered separately,
  with DNS through the local proxy.

### Services on the device

- [ ] `DownloadManager` commands (`Start-Download`, `Get-Download`): the system
  service does HTTPS, resumes and survives the app; F1 only.
- [ ] Socket service: authenticated loopback HTTP `CONNECT` proxy (secret per
  launch), port forward, Wake-on-LAN. Acceptance: reach a home PC's RDP port
  through the device over Tailscale.
- [ ] Optional Wi-Fi Direct group with the proxy (the TetherFi model).
- [ ] Widgets (F2, F3, F4): an `AppWidgetProvider` whose content is a bitmap
  drawn with the canvas, taps through `PendingIntent` to an alias. Acceptance:
  pin a script's output to the home screen. Measure update latency when the
  runtime is not running.
- [ ] Telemetry without adb: a log file in private storage exportable from
  Recovery; optional TCP over the tailnet; optional `READ_LOGS`. The emitted
  `libpsl-native` syslog exports only reach logcat.

### ADB transports

- [ ] Split `UsbAdbClient`'s protocol core (messages, authentication, streams,
  shell v2, sync) from its WinUSB transport.
- [ ] Transports: WinUSB (Windows); Android USB host through `UsbManager` and
  `USBDEVFS_BULK` on the connection's descriptor (device-to-device over OTG);
  TCP; TCP with TLS and SPAKE2 pairing (wireless debugging, including the
  device's own adbd). Store the adb key in the Android Keystore. Wireless
  debugging requires Wi-Fi and turns off on reboot.
- Acceptance: the arm64 device installs and starts Pwsh on the arm32 device
  over a USB cable.

### Porting tools

- [ ] cs2ps, in its own repository: Roslyn from the pinned PowerShell's
  `$PSHOME` parses C# and, with its semantic model, emits typed PowerShell;
  Xamarin calls become JNI calls through F1. Inputs: PowerShell ConsoleHost
  (progress first), subsystem's Android drivers and cmdlets, dotnet/android's
  wrapper generator. Output enters Pwsh only as reviewed PowerShell naming its
  source repository and commit, verified by comparing behavior.

### Ownership

- Pwsh: the Android integrations and a general native-call mechanism that
  loads third-party `.so` files and binds their exports.
- QuickPS: native bindings and applications built on them (SoundRecorder,
  Calculator, the gallery).
- PSLowering: the compiler, and the Windows counterpart of Pwsh's APK: EXE and
  DLL files made to order, a chassis of CoreCLR and RyuJIT in one executable
  with a deflate-compressed, in-memory assembly store (CoreLib plus the app,
  about 9.2 MB estimated, to be measured).

### Deferred

- Re-pin `System.Security.Cryptography.Pkcs` (11.0.0-preview.6) to
  11.0.0-rc.1.26425.128 and SMA (7.7.0-preview.4) to 7.7.0-preview.5 when
  ready.

### Sidecar work

- [ ] A canvas contract: the 18 `GpuCanvas2D` members the conformance Desktop
  reaches (`BeginFrame`, `EndFrame`, `Pump`, `Dispose`, `SetCursor`,
  `FillRect`, `DrawRect`, `DrawLine`, `DrawText`, `MeasureText`, `DrawShadow`,
  `DrawWireIcon`, `SetOpacity`, `Scale`, `PushClip`, `PopClip`,
  `PushTransform`, `PopTransform`), implemented over Android `Canvas` and over
  QuickPS's Direct2D, replacing the Windows-only C++/CLI
  `DirectPort.PowerShell.dll`.
- [ ] Desktop: on that contract; make `Pump` block without a timeout and wake
  on explicit requests (clock, animation frames) instead of 100 ms and 1 ms
  timeouts. Drawing is already gated on `RenderRequested`.
- [ ] Start: rebuild from the live-tile contract (QuickPS `7023082`
  `docs/TILES-CONTRACT.md`, removed from QuickPS in `f1b1c90`) with `Start.tsx`
  as the visual reference: layout only on reflow, per-frame work limited to the
  closed animation catalogue.
- [ ] Rubiks, Tetris, CanvasDemo: later, each checked against its `.tsx` twin.
- [ ] Remote desktop client with Desktop as the shell and FreeRDP's C library
  as a native extension (license and release to verify).
- [ ] ASP.NET Core on the device: start a bare Kestrel endpoint in Pwsh and
  reach it over Tailscale. If it runs, a .NET server application such as
  Jellyfin becomes a packaging question (its native ffmpeg and SQLite builds
  aside).
- [ ] Task manager over Android process and service data, from the task manager
  recreation (navigation rail, command bar, columns with live totals, details
  pane, startup list).
- [ ] AOA as a pipe for pairing, updates from a paired PC and recovery without
  a network; a PC-side PowerShell module plus Wintun only if a full network
  adapter is ever needed (an app cannot present a USB network function).

## Completed build-unblocking work

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

- [ ] Command payload candidate: preview.4 Utility, Management and Security
  packages are pinned; the ordered payload is 104 IL-only images; the host
  imports the three assemblies from in-memory `Assembly` objects and requires
  `Get-ChildItem`, `ConvertTo-Json` and `ConvertFrom-SecureString` before the
  profile. The preceding 102-image arm64 candidate passed build/store gates,
  but failed Utility import on x86-64. The current candidate adds pinned
  MarkdownRender/Markdig dependencies and disables SMA telemetry before startup.
  [The x86-64 P1 receipt](docs/receipt-hardware-canvas-x64.md) proves imports,
  Get-ChildItem and JSON conversion with extended liveness. Cryptographic
  commands and current arm64/arm32 receipts remain open.
- [ ] Candidate payload refresh to PowerShell preview.5. Explicit version decision required:
  the
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
- [x] Gate 2e, JNI: `GetVersion`, `FindClass`, `GetMethodID`, instance and
  static `Call*MethodA` with `jvalue[]`, slots derived from `jni.h`, on all
  three backends, from `Profile.ps1` without a rebuild; Android `Canvas` text
  and colors on the window surface through the same bindings
  (`scripts/probes/`, `AGENTS.md`). The build does not yet read `jni.h` from
  `lib/`; the probe bindings were generated from the same file and digest.
- [ ] Gate 2e, compatibility: an owned compatibility assembly that satisfies
  exactly the CellCanvas surface, first prototyped live as a dynamic
  assembly from `Profile.ps1`, then emitted by `setup.ps1`.
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

Compilers provide performance and correctness comparisons. The model is
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
- [x] Step 6's title names ELF, not ELF64; the step emits ELF64 and ELF32.
- [ ] Skipped steps print SKIP, not PASS.
- [x] Live device loop without a rebuild: `tools/Invoke-DeviceScript.ps1`
  places a script (or a directory holding `Profile.ps1`) through `run-as` in
  a `-Debuggable` build on every attached device, launches, and reports the
  app's log lines, launch time, liveness and crash lines. Ran
  `ScreenProbe.ps1` on all three devices.
- [ ] Setup deploy step: the same placement as an optional step after signing
  (for example `-Deploy -Profile <path>`), so one command builds, installs
  and runs.

## Command payload and dependency repair

The payload review and cut order are in [the implementation plan, step 2](docs/implementation-plan.md#2-repair-payload-admission-and-reduce-the-payload). The payload is the committed 102 images, Newtonsoft included: SMA reaches it on every start (`ExperimentalFeature.cs:136`, `PSConfiguration.cs:99`). Each cut leaves only with its own receipt. Estimated total, A-E: ~5.0 MB of store and ~2.1 MB of APK per architecture; estimates, not receipts.

- [ ] Freeze the retained command/alias/provider/formatting manifest: discovery/help, object pipelines, formatting, files/providers, variables/history, JSON/CSV/CLIXML, web/REST, dates/random/processes, credentials/secure strings and hashing. Preserve Microsoft/SMA behavior; identify platform exclusions explicitly, including legacy code pages, `Send-MailMessage`, `Test-Connection` and the web cmdlets.
- [ ] 2.1 Remove the six unreferenced images (WebClient, ConfigurationManager, CodeDom, EventLog, ProtectedData, System.Drawing); `-TraceAssemblyProbe` requests none of them. `netstandard` stays (MMI and MarkdownRender reference it). 2026-10-01, 98-image debuggable builds (uncommitted tree), hardware probe passed: x86-64 emulator API 36 (APK `6A5956E7`, 65 probe requests, none removed), arm64 physical device, API 36 (APK `236FB086`); startup returned 0x50575348, window release and recreation, no crash. arm32 open: no device.
- [ ] 2.2 The session exposes exactly the declared command manifest, preserving parameter attributes, aliases, providers, module identity and required initialization. Utility's import needs MarkdownRender until 2.8 (`ConvertFromMarkdownCommand` holds a MarkdownRender enum field).
- [ ] 2.3 Metadata retarget in the IL-only re-emit, proven first on placeholder types: Data.Common, Transactions.Local and Microsoft.Management.Infrastructure leave the payload. The build reads every patched image back.
- [ ] 2.4 ApplicationInsights retargeted to inert implementations.
- [ ] 2.5 JSON core in PowerShell, lowered; `ConvertFrom-Json`, `ConvertTo-Json`, `Test-Json` checked against Microsoft's cmdlets as the reference implementation. The System.Text.Json group leaves unless the web cmdlets are admitted.
- [ ] 2.6 SMA configuration retargeted to the project's JSON assembly; Newtonsoft leaves the payload.
- [ ] 2.7 Microsoft.CSharp: the eight binder members implemented on `System.Dynamic` and retargeted, with comparison vectors for every `dynamic` site.
- [ ] 2.8 Markdown commands rendering to VT for a declared subset; MarkdownRender and Markdig leave the payload.
- [ ] 2.9 Scope decisions, each with its own receipt: legacy code pages, Mail (`[mailaddress]` and CliXml depend on `MailAddress`), Ping, web cmdlets.
- [ ] Record compressed APK and store deltas, dependency inventory/SBOM, absent compiler/analyzer payloads, command regressions, startup and liveness/crash receipts for the same artifact on every claimed backend.
## UI and platform

- The preview implementation follows [the managed UI work order](docs/work-managed-ui.md).
  Its host is designed for graphical and non-visual applications independently
  of the preview's tabbed UI; terminal cells belong only to console panes. P0-P8 below
  are planned gates, with all three backend receipts required for runtime work.
- [ ] **P0 Inputs and contracts:** pin JNI/platform sources and conformance
  inputs; freeze host, pane, session and recovery boundaries against the
  shipped runtime and PowerShell versions.
  JNI, Surface, Canvas and shipped-version telemetry sources are now admitted;
  Step 1 derives and checks all JNI slots. Remaining P0 contracts/inputs stay open.
- [ ] **P1 Hardware Canvas:** owned JNI hardware acquisition, RGBA8888, drawing
  and clipping; acceleration/backend identity, pixels, resize and lifetime
  receipts on x86-64, arm64 and arm32. Software rendering is not a fallback.
  [x86-64 receipt, 2026-10-01](docs/receipt-hardware-canvas-x64.md): host Intel GPU,
  64 independent capture checks, idle/input/resize/window-loss checks and
  40-second post-result liveness pass. Physical backends remain open.
- [ ] **P2 Managed foundation:** emitted IL bindings and callbacks; first
  hardware frame and basic controls work without SMA; preserve gates 2a-2d.
- [ ] **P3 Retained tabs and console:** lower the established console model;
  pass its 63 vectors; retain two terminal panes and an independent graphical
  pane with ordinary UI coordinates and the existing input gestures.
- [ ] **P4 Sessions:** independent worker runspaces, host interaction,
  streamed output/progress, event completion, cancellation and bounded queues;
  the main looper remains responsive during commands.
- [ ] **P5 Java bridge and command gate:** fixed owned DEX, crypto loading,
  InputConnection, document results and safe-start entry; prove the current
  command families through the actual console on all three backends.
- [ ] **P6 Recovery:** persistent startup guard; profile-free shell when SMA
  works; built-in profile export/replacement/rollback and copyable diagnostics
  when it does not; no storage reset or separate recovery screen.
- [ ] **P7 Product and PC loop:** install-time UI/assets, integrated emitters
  in the single setup.ps1 build, and optional Windows-PC run-as deployment and
  repair preserving private data and signing identity.
- [ ] **P8 Release:** reproducible signed non-debug artifact, installed-app
  acceptance, hardware measurements, SBOM, notices and per-backend receipts.

### ConsoleHost implementation tasks within P0-P8

These tasks refine the gates above. `scripts/ConsoleHost.ps1` is the planned PowerShell-authored composition/emission entrypoint; it does not yet exist. Keep `modules/Console.psm1` as the reference during lowering and keep diagnostic Profile fixtures distinct. The process host can run graphical applications or services without creating a console.

- [ ] **P0 Contract:** define pane identity/generation, activation, measure/arrange, input/focus, contributed menu actions, damage and disposal. Define session events and text-offset conversions. Admit reference algorithms/assets only from immutable, digest-checked sources; local mockups remain design observations.
- [ ] **P2 Emission:** implement named typed methods through the existing persisted expression/IL machinery; reject unsupported dynamic call sites and closure constants. Emit platform callbacks and JNI bindings, keep basic UI/recovery independent of SMA, and define safe callback/resource lifetimes.
- [ ] **P3 Retained canvas:** retain a scene tree with stable nodes, ordinary logical bounds, ordered children, clip/transform/opacity, resource ownership and damage. Add text/measurement, rectangles, paths and images; bounded row/column/overlay layouts, focus, hit testing, pointer capture and scrolling. No per-node/per-cell SMA draw dispatch.
- [ ] **P3 Composition:** console content is one pane type. Prove two console panes plus a graphical pane with proportional text and a working control, preserved state across tab switches, menu contributions and correct popup/focus routing. Inactive panes do not draw unconditionally.
- [ ] **P3 Console lowering:** preserve transcript, progress, editor/history, Unicode widths, selection, reflow and existing gestures. Define frame-slot ownership and release/acquire publication; plain aligned reference accesses are not cross-thread ordering proof. Replay admitted reference vectors and add lowering-boundary cases.
- [ ] **P3 Streaming parser:** persist decoder/parser state across writes and split escape/UTF-8 boundaries. Current Write constructs a new parser and implements CSI only for SGR; syntax recognition is not terminal compatibility.
- [ ] **P4 Working console:** replace synchronous probe command execution with worker-owned pipelines, version-matched PSHost services and formatted output/all streams/progress. Implement prompt return, cancellation, interactive reads, bounded event queues and stale-session rejection.
- [ ] **P5 Android seam:** complete InputConnection commit/composition/selection/deletion/batch-edit behavior; system-bar/cutout/IME insets, density/font scaling, clipboard and document results. Scope an accessibility semantic-tree bridge against pinned platform source. Preserve NativeContentView and the fixed auxiliary-view contract.
- [ ] **P3/P6 Settings and editor:** typed settings hierarchy, adaptive navigation, shared theme tokens, terminal palette/font preview and working-copy Save/Discard with atomic persistence. Build a bounded PowerShell-authored editor for profile repair: selection, undo/redo, find, UTF-8 files and dirty-document handling; use SMA parsing/highlighting/completion when available, without making basic recovery depend on SMA.
- [ ] **P7 Build graph:** develop ConsoleHost emission behind setup.ps1, then add a dedicated ManagedUi node after Select/4 and before Store/5, preserving existing public step IDs. Give each generated image one producer; check identities, hashes, closure/order and store admission. Fold emitter functions into the single setup.ps1 release build.
- [ ] **Startup modes:** `setup.ps1 -Startup Profile | ConsoleHost`; `ConsoleHost` starts the shipped console with no `run-as` step. Spike acceptance on the x86-64 emulator, x86-64 Windows Subsystem for Android and an arm64 physical device is in [docs/console-host.md](docs/console-host.md#spike-acceptance), including real on-screen keyboard input. Observed 2026-10-04 with non-debuggable ConsoleHost APKs built from `fdf4719`: on the x86-64 emulator, the arm64 physical device and the arm32 Google TV device the console started from the launcher with every startup marker, `1+2` typed through `adb shell input` printed `3`, and each process was alive at 40 s with an empty crash buffer; the arm32 device drew no frames during 10 s idle. Not yet shown: on-screen keyboard input, a fresh install, a shipped parser from `PATH`. Open defect: bursts of key events lose characters (Next work, item 1). Windows Subsystem for Android is no longer available from Microsoft; the arm32 device stands in as the third backend.
- [ ] **Activity re-creation:** the native host starts CoreCLR on every `ANativeActivity_onCreate`; a second `onCreate` in the same process fails with `coreclr_initialize` 0x80131022. Observed on the arm32 Google TV device (API 34) after `wm size` and after HOME then relaunch (`build/s2.1-arm32-receipt`); the phone and emulator resumed the existing activity instead. Keep the host handle and delegates, skip initialization on re-entry, and call a managed `Reattach(nativeActivity)` that rebinds the existing session (window and input callbacks, redraw). Emitted host code on x86-64, A64 and Thumb-2; receipt on all three including recreation.
- [ ] **Remote-control input (Google TV):** D-pad, Select and Back drive the console and views through the navigation verbs ([docs/views-and-tiles.md](docs/views-and-tiles.md)); the TV on-screen keyboard is part of the R4 input acceptance.
- [ ] **Crash-loop breaker and safe start:** an unfinished profile run makes the next launch start without the profile; a launch option starts without profile or user scripts.
- [ ] **Recovery:** an SMA-free command processor (`Recovery >`) on the lowered console core, in its own assembly the build checks has no SMA reference; a spartan fallback screen stands in until then.
- [ ] **Lowering fix and IL check:** superseded by adopting PSLowering (Lowering with PSLowering, below), which does not use `Write-MicrosoftLambdaToMethodBuilder`. Do this only if adoption slips: re-create the lambda's return label after the IL generator swap; add the `opcode.def`-driven IL stack check after `Add-PersistedMethod` ([docs/lowering.md](docs/lowering.md)). Acceptance: the managed host rebuilds byte-identical and the check reports nothing.
- [ ] **P8 Acceptance:** clean installation -> managed UI -> IME input -> asynchronous command -> formatted output -> prompt returns; graphical pane remains independent of cells; resize/window recreation works; profile failure leaves usable repair/export/clipboard controls. Record the same-artifact receipts on each backend.

Microsoft guidance defines VT behavior, retained scene semantics and Terminal/Fluent interaction. Google guidance defines hardware Surface coverage, JNI thread/reference lifetimes, NativeActivity teardown, InputConnection, density/insets and accessibility. Exact source links and their implementation consequences are in [the work order](docs/work-managed-ui.md#consolehost-naming-and-managed-contract-refinement-2026-10-01). Following those contracts introduces no WinUI/XAML, Xamarin, browser, AndroidX or third-party managed UI dependency.

### Full-screen TUI and optional native application follow-on

These are separate capability gates; the initial operational PowerShell console does not claim complete terminal emulation.

- [ ] **Addressed terminal screen:** implement primary/alternate buffers, cursor/save state, wrapping, scroll margins, erase/insert/delete, declared modes and application input ownership. Keep addressed screens separate from transcript reflow.
- [ ] **TUI protocols:** encode keys/modifiers, mouse and bracketed paste; answer declared cursor/capability/color queries. Publish a supported protocol matrix derived from Microsoft VT guidance and the pinned application workload; add an independent implementation comparison and application receipts.
- [ ] **Native session contract:** versioned C ABI and host-service table for create/run/input/output/resize/cancel/destroy; document buffers, callbacks, thread affinity, process-global effects and error/exit behavior. Route blocking execution off the UI thread and restore console state after session completion. Retain loaded code while any thread or callback can reference it.
- [ ] **Optional Edit .so investigation:** adapt Microsoft Edit at `c470ca59af44c176ea39c672d09b32061c274896` to an Android shared library with explicit session entrypoints. Trace Bionic/ABI, ICU/dependencies, terminal I/O and global state; establish a reproducible build in its own project. Determine required producer/admission policy before adding native logic to Pwsh. No Edit code enters the base APK through this planning item.
- [ ] **Optional installed-code delivery:** define matching-signature split installation and library admission for an in-process experiment; prove library discovery/load/export invocation and lifecycle on all three backends. A copied executable or SO in writable app storage is not the native delivery path. Loading native code shares Pwsh's crash fate; a separate-process/PTY adapter is an independent optional alternative.
- [ ] **Demonstration:** console command starts the optional Edit library, editor receives input/resize and emits the expected screen, cancellation/normal completion restores the prompt; process remains alive with no crash. No completed capability until the same installed artifact passes the declared backends.
- [ ] **Optional script bundle:** choose and admit the small text-parser/diagnostic scripts identified in the separate audit, with explicit opt-in packaging and a defined PC/device transport. Re-express useful host/editor helpers through the shared contract; donor frameworks and local compiled assemblies are not release inputs.
- [ ] The console and composited UI in `docs/ui.md`: a cell-grid VT/ANSI text
  pane with reflow and a tab strip, plus a retained graphical surface with
  density-aware controls, pointer/keyboard/IME input and accessibility.
- [ ] Preview renderer admission (P1-P3): Android hardware Canvas through
  owned JNI bindings, shared by retained controls and console panes; lowered
  managed layout and submission. Full frame coverage on damage-triggered
  submissions. Vulkan is a separate future backend gate.
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
  `onNewIntent` (the base class drops it) and document-picker results, handles
  the safe-start entry before the profile, and hosts a view whose
  `InputConnection` carries soft-keyboard text (the base view has none),
  attached with `addContentView`.
- [ ] Private-storage assembly loader in the host, run before `Profile.ps1`:
  content-addressed `store/<SHA256>.dll`, an `active.tsv` admission list,
  `previous.tsv` rollback; IL-only, hash and identity checks; load from the
  verified bytes; `Import-Module -Assembly`. Prototype passes install, update,
  rollback, tamper and fallback cases on Windows in fresh `CreateDefault2`
  runspaces. On the device it needs the crypto library initialized first.
- [ ] Select a 32-bit window buffer format before drawing; `NativeActivity`
  defaults the window to RGB_565. `ANativeWindow_setBuffersGeometry` with
  format 1 gave RGBA_8888 buffers on all three backends (`ScreenProbe.ps1`);
  the product renderer still has to make that choice.
- [ ] Service slots: one emitted DEX forwarder per Android base class that
  needs one (accessibility, input method, tile, voice interaction) and a
  dispatcher that answers within Android's deadlines.

- [ ] Paired-PC transport candidate: USB accessory mode (AOA). Kokoro-Hexagon
  proved only the `GET_PROTOCOL` handshake (version 2) with an S23
  (`docs/receipts/aoa-protocol-20260924.md`); no re-enumeration or round
  trip yet. Receiving accessories needs a `USB_ACCESSORY_ATTACHED` filter
  and an XML resource, and `New-ResourceTable` emits only the launcher icon.
  Decide at the manifest freeze whether to declare it.

- [x] Console core in PowerShell: `modules/Console.psm1`, ported from the TypeScript reference built to `docs/console-reference.md` (e5426ff), passes all 63 conformance vectors and the ring checks on Windows (`tools/Test-ConsoleVectors.ps1`); width tables regenerated from the pinned Unicode 16.0.0 files match the reference's 122 wide and 368 zero-width ranges. On devices (docs/work-console-on-device.md, both tasks): 63 of 63 vectors on all three backends, the frame drawn and checked by screencap, input consumed, system-bar insets, pinch-to-resize reflow (AGENTS.md).
- [ ] Adaptive launcher icon at the freeze: background color `#107C10` (darker than the artwork's `#20A040`), foreground the current `lib/ic_launcher.png` artwork enlarged to fill the safe zone, one `mipmap-anydpi-v26` XML resource; replaces the legacy icon the launcher shrinks onto a white disc.
- [ ] Fonts for the APK assets at the freeze: Fluent UI System Icons (MIT), `microsoft/fluentui-system-icons` at `a563cf9166f4f91aa617557ed272612b7f0a2f72`, `fonts/FluentSystemIcons-Regular.ttf` SHA-256 `C5DAB901C52362ECC94D3A1D2C88A5C060464EB9EB58BB5B0D64D17066AF4D7F` with its `.json` code-point map (`E4191934…D84B`) and `LICENSE` (`69BC45DC…F52F`); drawn live through `Get-AndroidTypeface` on the emulator and the S23. Cascadia Mono (OFL 1.1) for console text, to pin.
- [ ] The shell surface (`docs/shell.md`): the looper-woken event bus, a
  three-slot frame ring consumed by the local display, a contract stream, RDP
  and video, a general display list shared by retained controls and terminal
  content, and small graphical app modules. Remote consumers remain subsequent
  work beyond the preview's P0-P8 gates.
- [ ] The emitted host (`docs/host.md`): first frame from emitted IL before
  any SMA work, runspaces created behind it, a dispatcher that picks the
  runspace per event, and recovery owned by the host and presented by the
  managed retained UI. The host does not require console state or a renderer.

Design constraints: one event queue, blocking in `ALooper_pollOnce(-1)`, with
lifecycle, input, timers and completions as file descriptors on the looper; no
tick or polling loops.

## Optional packaged commands and ADB

Follow [the optional scripts work order](docs/work-optional-scripts.md). Commands are plain `.ps1` files on `PATH`; SMA's own command search resolves them by name, so there is no registration or catalog. This work does not extend R1-R9.

- [ ] O0: immutable source/digest admission, explicit bundle selection, collision/dependency checks and measured packaging costs.
- [ ] O1: the host copies selected scripts from the signed APK into `PWSH_APP_SCRIPTS` when the installed version changes and puts `PWSH_USER_SCRIPTS` then `PWSH_APP_SCRIPTS` on `PATH` before Profile.ps1 (a user script of the same name wins). Prove bare-name resolution, help, completion and pipelines in a fresh session, user shadowing, an unaffected startup with a broken script, and refresh on APK update. Convenience aliases stay in Profile.ps1.
- Parser bundle: `scripts/commands/Parsers` (four parsers ported from subsystem `2c8dd804`, empty pipeline strings now accepted) passes `tools/Test-Parsers.ps1` through `PATH` on the PC; device receipt pending with O1.
- [ ] O2: optional parser/device-information/action scripts over direct owned JNI/NDK services; capability-specific permissions, worker cancellation and hardware receipts. Clipboard remains a core host/UI service.
- [ ] O3: keep ADB in one directly executable `scripts/adb.ps1`, with command syntax compatible with adb.exe and an object/stream API through `&`. Separate the protocol from transport ownership inside that file when adding Android USB-host and wireless transports. Admit pairing independently and prove actual transport roles, stream bounds and teardown; no adapter or registration layer.
- [ ] O4: a setup.ps1 option (and setup UI picker) that embeds selected `scripts/` bundles in the APK; record selected bundles, compressed APK/store deltas and notices without renumbering established steps.
- [ ] Application content hook: `setup.ps1 -Application <folder>` builds a downstream application (start script, scripts, resources, launcher icon, package name and label) from bounded paths with hashed content, writing only to the caller's build folder. The ConsoleHost console is its first application; a downstream project is its second.
- [x] ADB single-file Windows slice, 2026-10-10: `scripts/adb.ps1` contains the former `UsbAdb.psm1` and CLI implementation. Command/API forms share the connection holder; `-Api` returns objects or raw `byte[]`, and `stream` returns `System.IO.Stream`. On the arm64 S23: devices; shell stdout `pwsh-adb-check`, exit 7; 131,329-byte push/pull and binary `exec-out` matching device-side `sha256sum`, all SHA-256 `14DF727A21A73EDFFDCFB3343EDF8060324BBC8666E6FE920D1B41A6FF1032B7`; `tcp:47373` stream echoed 17 bytes (`pwsh-stream-echo` plus LF) through `toybox nc -l /system/bin/cat`. The arm32 device also returned its ABI and exit 7. One initial arm64 USB request failed, then the named checks passed; the earlier persistent handshake failure did not recur. The existing C# HKDF method was ported inline and matched its original C# on six input sizes under hash-verified PowerShell preview.5; full SPAKE25519 and wireless/loopback pairing remain pending, with CS2PS diagnostics and source hashes in the script. No setup or APK change. This proves synchronous WinUSB operations only; Android USB-host, TCP/wireless transports, concurrent streams and full adb.exe compatibility remain open. Move device tools off adb.exe after their required operations are admitted.

## Processes, native bundles and the broker

Design in [docs/native-extensions.md](docs/native-extensions.md). Each item is its own gate.

- [ ] Process execution: system tools and APK-shipped executables run from PowerShell; app-written binaries are never executed (target SDK 29 policy).
- [ ] `setup.ps1 -NativeLibrary`: user-built `.so` libraries and executables packaged under `lib/<abi>/` with ELF machine, 16 KB alignment and SHA-256 checks, executables renamed `lib*.so` with a name map.
- [ ] Broker: private Unix socket, `SO_PEERCRED` check, `SCM_RIGHTS` descriptor passing, `LD_PRELOAD` shim with path rewriting; no proot.
- [ ] Self-update outside a store: signed full or split APK through `PackageInstaller`; trace the confirmation rules for a self-installed app in pinned source first.
- [ ] Layered loading: `external_assembly_probe` consults a signed, atomically promoted overlay manifest in private storage before the store table (x86-64, A64, Thumb-2); Recovery's `reset` drops the active pointer.
- [ ] On-device build: `setup.ps1` run on the device produces an APK compared byte for byte with the PC build of the same inputs.
- [ ] Private-storage assembly load: an assembly written to private storage loads in the IL-only APK after a process restart and calls through a native binding (receipt on all three backends); prerequisite for layered loading and persisted on-device lowering.
- [ ] Federation: built apps discover each other through `PackageManager` meta-data and `<queries>`, verify the signer, and exchange telemetry over UID-checked sockets ([docs/native-extensions.md](docs/native-extensions.md#a-federation-of-apps)); AppFunctions exposure follows the fixed-Java-class decision.
- [ ] Launch-condition matrix per release candidate: cold start, warm resume, HOME then relaunch, activity re-creation, process death while backgrounded, trim-memory, first install, upgrade with data kept, cleared data, multi-window. Settings changes on a personal device (font scale, dark mode, airplane mode) only with the owner's approval.
- [ ] On-device new package: a script or tile built on the device as its own app (own package name, icon, permissions, Keystore key) installs and runs; needs the proposed native-emission rule change.
- [ ] On-device self-install: blocked on the signing-key decision (Keystore device key or APK Signature Scheme v3 rotation) and the proposed native-emission rule change in [docs/native-extensions.md](docs/native-extensions.md#updating-outside-a-store).

## Lowering with PSLowering

PSLowering compiles typed PowerShell classes to IL with its own emitter and
checks every compiled method against PowerShell itself. It replaces the
hand-built expression trees in `setup.ps1` and is the means for R3 and R6.
Its output matched PowerShell on all three backends for every comparison call of
`25427b2` (AGENTS.md, PSLowering output on devices). Take it from GitHub at a
pinned commit and digest into `build/cache`, never from a local checkout.

### Adoption

- [ ] Managed host: compile `FindProfile` (its typed form is PSLowering's
  `tests/fixtures/PwshFindProfileFixture.ps1`), the script-extraction method and
  the asset bindings with PSLowering instead of `New-FindProfileMethod` and the
  hand-built trees in `New-ManagedHostAssemblyBytes`. Gate: the host behaves the
  same (gates 2a-2d and the ConsoleHost start on all three backends); the
  bytes may differ.
- [ ] Load compiled assemblies from private storage before `Profile.ps1`
  (Private-storage assembly load, below), admitted by hash; the 2026-10-04
  probe loaded them inside a running profile only.
- [ ] R3 console core: compile `Console.psm1`'s parser, cell grid, width table,
  line store, wrap map and frame differ as they become finished; measure
  compiled against interpreted per frame on the arm64 and arm32 devices.
  PSLowering compiles 39 of the 70 class methods today; its ROADMAP lists the
  remaining gaps.
- [ ] R6 Recovery: the console core plus a command loop in an assembly with no
  SMA reference, started without SMA (PSLowering's `-EntryPoint` and
  `Test-DotnetHost` prove the mechanism on Windows).

### The parts bin

Compile a piece when it is hot (per frame, sample, cell, packet or input
event), must run without SMA (before the runspace, in Recovery, or called from
native code), or is used by two or more consumers, and its contract has stopped
changing. Keep orchestration, one-off setup, build-time generators, anything
still being designed, users' scripts and diagnostics in PowerShell.

Candidates, in build order:
1. Native call primitives: callbacks and function-pointer calls (PSLowering
   1.2), then the NDK bindings in `modules/AndroidCanvas.psm1` (window,
   input queue, looper, choreographer) and the JNI table from
   `scripts/probes/jni/Jni.ps1`.
2. Audio: AAudio with a data callback, shared with Kokoro-Hexagon.
3. Console: parser, styles, width table, cell grid, frame differ.
4. Startup: persisted-assembly admission (hash, manifest, active pointer,
   rollback).
5. ADB framing and stream routing from `scripts/commands/Adb/UsbAdb.psm1`.

Each part is its own small assembly with a stable public surface, a version and
a hash; PowerShell loads and wires the parts (the composition root). Deterministic
builds make rebuilds incremental: a part's key is the hash of its source, the
compiler version and its references.

### Measure before optimizing startup

- [ ] Startup breakdown on the arm64 and arm32 test devices from the existing
  markers (`GATE2A` through `RunPowerShell returned`): runtime start, assembly
  load, `CreateDefault2`, `Open`, profile. The IL-only store raised startup from
  0.51-0.55 s to 0.97-1.03 s (arm64) and from 3.8-4.0 s to 6.8-7.2 s (arm32);
  the breakdown decides between persisted IL, precomputed startup state and
  selective native code.
- ReadyToRun stays out of the device build: it ships IL and native code for
  every assembly. Native code returns only where measured, through the captured
  leaf rule in AGENTS.md or a later relocatable form, and only through the
  package installer.

### Dependencies from other ecosystems

Assemblies taken from .NET libraries (for example AI/ML packages) are pinned by
version and digest like every input; a scheduled job may track their channel
and propose new pins, promoted only when the suite and the device gates pass.
Managed wrappers over large native runtimes (ONNX Runtime, TorchSharp) are PC
tools and reference implementations unless their native code passes the same review as any native
code. Nothing third-party enters the parts that must run without SMA unless
audited.

## Optional on-device Morse and V.21

Follow [the device signals work order](docs/work-device-signals.md). These capabilities execute through owned Android APIs, not ADB, and do not extend R1-R9.

- [ ] M0: admit pinned Subsystem reference/specifications, MIT notices, formats and bounds.
- [ ] M1: direct JNI flashlight control and real-device ON/OFF/error/lifecycle receipt.
- [ ] M2: corrected Morse conversion/pulse timing and cancellable torch transmission.
- [ ] M3: event-driven NDK light receive with incremental managed decoding and measured sensor/link limits.
- [ ] V0: PowerShell-authored, managed-IL V.21 DSP with correct rate/timing and independent signal/byte comparisons.
- [ ] V1: complete lossless AAudio output/input, runtime recording admission, cancellation and stream cleanup.
- [ ] V2: measured peer byte transfer; separately framed acknowledgements only after one-way operation is proved.
- [ ] Optional retained controls and explicit module packaging using shared session events; record size and permission costs.
## Release: APK preview finish line

The preview is ready to share when every required item below is checked and linked to evidence for the exact release APK. P0-P8 provide the implementation gates; this list defines the release subset. Unchecked follow-on work elsewhere does not extend this finish line.

### Required before sharing the APK

- [ ] **R1 Payload works:** build without Roslyn/analyzers. Payload cuts follow the step 2 order of the implementation plan; every dependency ships until the sub-step that replaces it passes. Freeze and publish the supported command manifest, preserve its Microsoft/SMA behavior, and prove startup and the retained dependency closure. Optional library reductions are not blockers once every shipped dependency is justified and inventoried.
- [ ] **R2 Installed application:** a clean install includes its startup assets and opens the emitted managed host without run-as injection. First frame and repair controls remain available before profile execution and after a controlled profile failure. Preserve established host/profile behavior and private data across an upgrade.
- [ ] **R3 Console and graphical surface:** hardware-rendered retained tabs support two independent console sessions plus a graphical pane with proportional text and a working control, without console cells. Lower repeated console/layout/hit/drawing work into managed IL; preserve the established console vectors and gestures. Pin shipped fonts/icons and their notices. ConsoleHost emission has one producer and a separate action in setup.ps1's graph.
- [ ] **R4 Real interaction:** Android IME committed/composing text, deletion, selection and clipboard work; pointer/keyboard navigation, focus, system/IME insets, resize and window recreation work. Commands execute asynchronously with formatted output, errors, warning/verbose/debug/information streams, progress, cancellation and prompt return. No idle rendering/polling loop or UI-thread command blocking.
- [ ] **R5 Useful command acceptance:** from the actual installed console, run Get-ChildItem, an object pipeline with formatting, JSON conversion both ways, secure-string conversion, hashing and an HTTPS request. Exercise a long-running cancellable command, a failing command and progress. Record any platform exclusions in the supported-command manifest; do not advertise unproved command families.
- [ ] **R6 Recovery:** startup guard and deliberate profile-free entry work without clearing storage. View/copy diagnostics, edit or replace Profile.ps1, export its contents through Android document storage, and restart with the repaired profile. If SMA admission fails, built-in managed repair remains usable. Recovery does not require a PC; PC run-as repair remains optional.
- [ ] **R7 Same-artifact evidence:** the shipped APK contains every claimed ABI. Run the acceptance workload for that APK on the x86-64 emulator, a physical arm64 device and an arm32 device; include acceleration identity, lifecycle/input checks, post-result liveness and an empty process crash buffer. Record cold start, first frame, idle CPU, input-to-photon latency, APK/store sizes and test conditions. Earlier probe or payload receipts do not substitute.
- [ ] **R8 Reproducible release package:** build through setup.ps1 from a clean checkout with pinned inputs and the permanent signing identity; record source revision, input identities, options, APK SHA-256 and reproducibility evidence. Run the existing build verification/self-tests for that artifact. Produce SBOM and applicable license/third-party notices. Release manifest is non-debuggable, signing key stays outside the repository, and the evidence bundle contains no private data.
- [ ] **R9 Public handoff:** README accurately describes the shipped console, graphical surface, supported commands, limitations, installation and profile recovery. Link the release artifact and matching receipts; complete the project wording/claim hygiene pass.

The concrete product acceptance is: install APK -> managed interface appears -> enter text with the keyboard -> execute Get-ChildItem asynchronously -> formatted output appears -> prompt returns -> switch to an independent graphical pane -> resize/IME remain usable -> repair a failing profile without clearing storage -> process stays alive.

### Explicitly after the first APK preview

Complete addressed-terminal/alternate-screen TUI compatibility, Microsoft Edit .so hosting, task-manager application, full editor parity, a Windows GPU presenter, optional script/PC/AOA bundles, frozen CellCanvas compatibility 2e/2f, Vulkan/private Skia, general desktop/window management, remoting/video and self-updating native/IL capabilities are subsequent work. The first editor scope is profile repair. Core settings cover appearance and essential controls; a complete Fluent settings catalog is not a release prerequisite.

An APK below 20 MB is a size target, not a claim or a substitute for R1-R9. Measure the final release artifact before publishing its size. Additional dependencies require a named requirement, provenance and measured cost; no optional application is bundled by default.
