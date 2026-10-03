# Optional packaged PowerShell commands

Status: proposed work, 2026-10-01. Source inspection establishes candidates, not device capabilities. This work does not extend the APK preview's R1-R9 requirements.

## Contract

Keep command policy in PowerShell, use SMA for parsing, binding, pipelines, errors, help and completion, and lower measured hot paths to managed IL. Package explicitly selected scripts as signed APK assets. Device services use owned JNI/NDK bindings; PC ADB remains a separate transport option. A script may contribute commands, a retained pane, or a service without depending on a cell grid.

An advanced function is a supported PowerShell command implementation, not a substitute language or a simulated binary cmdlet. Preserve typed object output, pipeline parameters, validation, common parameters, error records and cancellation. Avoid shadowing existing Microsoft commands. Do not port donor command registries, record hierarchies or UI engines merely to reproduce a small wrapper.

## Candidate selection

| Bundle | Candidates | Required seam / priority |
| --- | --- | --- |
| Text parsing | ConvertFrom-Table, ConvertFrom-Settings, ConvertFrom-KeyValue, ConvertFrom-DumpsysTree | Existing PowerShell candidates; validate malformed/bounded input and object contracts first. |
| Device information | Get-AndroidBattery, Get-AndroidDevice, Get-AndroidStorage, Get-AndroidMemory, Get-AndroidSensor, Get-AndroidNetwork, Get-AndroidDisplay | BatteryManager, Build, StatFs, ActivityManager, SensorManager, ConnectivityManager and display bindings. Return structured data; distinguish unavailable data from zero/default values. Sensor inventory is separate from sensor streaming. |
| Device actions | Set-Flashlight, Invoke-Vibration, Get/Set-AndroidVolume, Invoke-Beep | Direct camera/vibrator/audio services; availability, bounds, permissions and lifecycle. Flashlight precedes Morse. |
| Application integration | Start-AndroidIntent, Show-Toast, Send-AndroidNotification, Get-InstalledApp | Resolve intents and service contracts; runtime notification permission/channels and package visibility constrain results. Do not request broad permissions merely to increase inventory. |
| Speech | Out-Speech and stop/status commands | Android TextToSpeech initialization, listener callbacks, cancellation and shutdown; system engine availability remains a device property. Listener class emission is additional work, not supplied by a .ps1 alone. |
| Signals | Morse conversion/transmit/receive; V.21 | Follow work-device-signals.md; codecs and signal hot paths need declared lowering and measurements. |
| Paired diagnostics | Existing Get-AndroidAlarm/Activity/Cpu/DeviceIdle/Gfx/Job/Service/Setting/Thermal and related dumpsys readers | Require an explicitly selected authenticated ADB connection. Parsers remain useful independently; these readers are not ordinary application-UID platform access. |
| Later platform components | Cross-app screenshot/tap/swipe, notification reading, wallpaper integration | Donor screenshot/input uses an accessibility service; notification reading uses service state. Separate component/consent/lifetime gates; do not bundle by default. |

Clipboard belongs in the shared host/UI contract, with optional command wrappers; it must work for recovery and text entry independently of profile imports. ParserState, ANSI highlighting, command-help metadata and session lifecycle belong in the console/host work orders. Reuse SMA's AST, completion and command metadata rather than carrying another parser or session manager.

Subsystem's shell settings script is a useful small settings-state/TUI example; adapt its state to the retained settings contract rather than copying its draw loop. Its remoting bootstrap shows why each runspace needs the same selected command catalog. Its WebSocket client module assumes donor endpoints and model/agent services and is not a first bundle. Generic shell aliases can use existing Microsoft commands; installer/download/bootstrap helpers need separate provenance and transport admission.

The donor Invoke-Strings loads a PE executable; its name does not establish a portable text extractor. If useful, implement a separately specified streaming byte/string scanner, with a lowered scan for large inputs. Build scripts, tests, WIP browser/agent/model tools, WebDrive, card HTML helpers and donor registry/database commands are not initial payload candidates.

## O0: provenance and selection

Acquire actual port inputs from pushed immutable revisions, verify digests, preserve applicable notices, and keep all products inside this repository's build plan. Local inspection is design evidence only. Select bundles explicitly; validate exported-command collisions, platform requirements, permissions and dependency closure before packaging. Proposed catalog fields: bundle identity/version, relative asset path, SHA-256, exported command names, platform, capability requirements, source revision and notices. Convenience aliases belong in Profile.ps1, not in the packaged-command catalog.

Report source bytes, compressed APK delta, any emitted assembly/store delta, native/DEX cost and startup/import memory/time separately. Optional scripts do not automatically require additional managed libraries. Android services and listener classes can cost more than the command wrapper. Do not infer APK size from source size.

Exit: reproducible selected catalog and no implicit import of excluded bundles; pinned inputs and notices are reviewable.

## O1: command discovery and immutable assets

Decided 2026-10-02: commands are plain `.ps1` files on `PATH`. There is no registration, catalog, manifest or function import; SMA's own command search resolves a bare name to a script file (PowerShell `149ab5cd`, `CommandSearcher.cs:1310` onward, to be rechecked against the admitted package).

- Selected bundles live in the repository's `scripts/` folder and are copied into the APK as assets by a `setup.ps1` option. The APK signature covers them.
- The host sets two environment variables before `Profile.ps1`: `PWSH_USER_SCRIPTS`, the user's own directory (in private app storage by default; a public directory if the user chooses one), and `PWSH_APP_SCRIPTS`, a directory in app-private storage. Both are put on `PATH` with `PWSH_USER_SCRIPTS` first, so a user script with the same name as a shipped one wins; the shipped one stays callable by full path.
- When the installed APK version differs from the one that last populated `PWSH_APP_SCRIPTS`, the host recopies the assets there. That directory is writable by the app UID; it is refreshed from the signed APK, not claimed tamper-proof.
- Nothing is loaded at startup, so a broken script fails only when it is called and cannot prevent the host or recovery controls from starting. Convenience aliases go in `Profile.ps1` with ordinary `Set-Alias` (for example `Set-Alias adb Invoke-Adb`).
- Open, for users who choose a public directory: which one Android lets the app read for files placed by the user or a PC under scoped storage. Trace it in pinned frameworks source before choosing.

Exit: each selected script resolves by bare name in a fresh console session with help, completion, pipelines and errors from SMA; a user script shadows a shipped one of the same name; a broken script leaves startup unaffected; an APK update refreshes `PWSH_APP_SCRIPTS`.

## O2: device command ports

Start with parsers and device information, then flashlight/vibration/volume/intents. Port wrapper policy to advanced functions over shared platform services. Bind only reached Android APIs; do not import Xamarin or donor assemblies. Route UI-affine calls to the main looper, keep blocking work on workers, and return structured completion events. Cancellation and teardown are part of each API contract. Grant permissions only for selected capabilities; optional features do not silently widen the baseline manifest.

Exit: narrow command receipts on all claimed backends with object/error behavior, lifecycle cleanup, liveness, crash status and measured APK cost. Real torch/light/audio link evidence requires physical devices.

## O3: ADB protocol and transports

A PowerShell ADB prototype exists as adb.ps1 (7,500 bytes) and UsbAdb.psm1 (42,447 bytes). AST parsing found no errors; the pair has a rough gzip size of 11,803 bytes. That is an inspection estimate, not an APK or performance measurement. It is not yet under version control, so an immutable pushed source and license/provenance admission come before any of it is ported.

The Windows prototype implements direct WinUSB discovery, RSA authentication, ADB messages, shell_v2 and SYNC push/pull without adb.exe or a local port-5037 server. Its native type is emitted through Reflection.Emit. It also calls Get-PnpDevice, which is outside the currently packaged command set. Registry/WinUSB discovery is Windows-specific. Tests exist but were not executed; source comments reporting tests are not receipts for this project.

Required adaptation:

- Separate structured PowerShell APIs (for example Get-AdbDevice, Invoke-AdbShell, Send-AdbFile, Receive-AdbFile) from CLI formatting and native transport. Keep stdout/stderr/remote exit status distinct; ordinary remote failure must not call SetShouldExit on the enclosing application host.
- Standard global selector syntax is missing: the prototype places -s after shell/push/pull and selects an index or friendly-name/instance pattern. Define exact device identity separately from convenience selectors and support `Invoke-Adb -s $serial shell ...` with an explicit token parser. Profile.ps1 supplies Set-Alias adb Invoke-Adb so the same adapter is available as `adb -s $serial shell ...` . PowerShell quoting/tokenization remains PowerShell syntax.
- Replace per-message shell decoding with a bounded incremental shell_v2 parser across ADB message boundaries; preserve UTF-8 decoder state, channel IDs, declared lengths, remote stream IDs and connection state. Do not allocate a subpacket from an unchecked length. Stream output to the host instead of accumulating the entire command result.
- Stream file transfers instead of ReadAllBytes/whole-file MemoryStream. Bound SYNC lengths, path encoding, transfer sizes and protocol transitions. Handle partial native reads/writes, detach, authentication rejection and cancellation with owned handle cleanup. Replace retry sleeps with bounded event-driven scheduling. Protocol loops that block on incoming events are distinct from polling loops.
- Keep key material private, record authentication identity without key disclosure, and trace the token-signing/public-key format against pinned AOSP source and independent vectors. Header bounds already exist; they do not prove nested protocol handling or transport correctness.

Windows uses the WinUSB adapter. Android USB host uses UsbManager permission/enumeration/interface/bulk-transfer APIs through JNI on a worker, with detach/cancel handling; the Windows adapter cannot be packaged unchanged as an Android implementation. This is a phone acting as USB host for a peer. A PC controlling this phone over USB is the opposite role; USB accessory/AOA is a separate transport contract.

The C# collection also contains TCP/TLS connection, discovery, pairing and a managed SPAKE25519 implementation. Android portions use Java/JNI wrapper types and donor diagnostics. Source comments claiming agreement on a device are not portable receipts. Port the protocol/transport contracts, not their object framework. Wireless ADB needs explicit pairing/identity, TLS client-certificate and exporter behavior, bounded state, cancellation, and an independently checked key-agreement implementation. Existing Windows BCL transport is not evidence that Android TLS behaves identically. Do not bundle both transport stacks merely because source is present.

Exit: pinned AOSP protocol/authentication oracles, Windows transport receipt first, then Android transport receipts for their actual roles. Prove standard CLI selection, non-ASCII commands/output, split packets, errors, large bounded transfers, cancellation, detach and prompt restoration. Pairing/TLS is a separately admitted milestone. No ADB route substitutes for direct flashlight or other ordinary Android APIs.

## O4: build graph integration

After individual ports pass, make optional-script selection/catalog generation a named setup.ps1 graph action feeding packaging and the managed host's registration data. Reuse source admission, APK assets/signing, notices and the confirmed write plan. Do not change established step numbers or introduce another build system. Hot paths ship through the existing managed emission/store boundary. Record selected bundle identities in the release evidence; default APK preview requirements remain R1-R9.

## Evidence and official guidance

Subsystem observations at commit 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb: src/runspace/scripts, Pwsh/Cmdlets, Device/Android/Readers.cs, Surfaces.cs, Actuators.cs, Services/SpeechOutput.cs and src/shell/{cli,home}. Broad inventory found 128 .ps1/.psm1 paths (33 under src, 47 tests, 48 WIP). Filenames are an inventory, not an audit of all WIP behavior. The ADB prototype observations are unversioned working-tree evidence; nothing from either project was built or run.

Immutable SMA source trace: PowerShell 149ab5cd6cad34869177f86ef9a3da8414f85dc6, src/System.Management.Automation/engine/CommandSearcher.cs:1310 onward, ConstructSearchPatternsFromName adds .ps1 for ExternalScript commands before the Windows-only PATHEXT block; InitialSessionState.cs, SessionStateFunctionEntry constructors accept named definitions, while SessionStateScriptEntry accepts a path. This inspected revision must still be checked against the admitted 7.7.0-preview.4 package's exact source before implementation claims.

Microsoft: [advanced functions](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced?view=powershell-7.6), [command precedence](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_command_precedence?view=powershell-7.6), [aliases](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_aliases?view=powershell-7.6), [function registration](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.sessionstatefunctionentry.-ctor?view=powershellsdk-7.4.0). Google: [USB host roles, permission and transfers](https://developer.android.com/develop/connectivity/usb/host), [JNI threading/lifetimes](https://developer.android.com/ndk/guides/jni-tips).
