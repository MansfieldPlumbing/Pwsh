# Developer notes

What a returning developer (or agent) needs before touching `setup.ps1`.
Rules live in `AGENTS.md`; what the project is lives in `README.md`; where it is
going lives in `docs/roadmap.md`. This file records decisions, proofs and
mechanics that are not obvious from the code.

## 1. The premise

One PowerShell script produces a signed Android APK from pinned, hash-verified
inputs. No MSBuild, no SDK, no NDK, no JDK, no compiler. Every artifact is
emitted from a documented byte format. Scripts are the application layer.

Corollaries that decide arguments before they start:

- No C# is compiled, ever, including "a small helper". Code is written in
  PowerShell or emitted by it: IL through `PersistedAssemblyBuilder`, DEX
  through the DEX writer, ELF through the ELF writers, machine code through
  named instruction encoders that the build decodes back and checks.
- Nothing is taken from the machine's installed state. A tool may be used only
  to verify output, never to produce it, and only under `-Debug`.
- Build output never lands in the repository. The one exception is the signed
  APK beside `setup.ps1`, which git ignores.

## 2. Step graph

`$script:StepGraph` holds 11 nodes, each naming its `DependsOn`.
`Resolve-StepOrder` topologically sorts the requested target and rejects cycles
and unknown edges before anything runs. Every node currently depends on exactly
the one before it, so the graph is a **path**: a DAG that is also a total order.
Call it the step graph; say "path" when the distinction matters. Keep it a path.

1 Verify · 2 Acquire · 3 Inspect · 4 Select · 5 Store · 6 Native · 7 Manifest ·
8 Dex · 9 AppData · 10 Assemble · 11 Sign.

Data passes between steps in memory through `$script:BuildContext`. No step
reads another step's file from disk.

## 3. Where the build writes

Nothing is written before the write plan is shown and confirmed
(`Resolve-WritePlan` / `Show-WritePlan` / `Enable-WritePlan`).

| What | Default |
| --- | --- |
| Signed APK | `<repo>\build\dev.mansfieldplumbing.pwsh.apk` (named after the Android package; `build\` is git-ignored) |
| Intermediates | nothing, unless `-KeepIntermediates`, then `<repo>\build\` |
| Signing key | `%LOCALAPPDATA%\Pwsh\pwsh-signing.pfx`, reused so installed apps stay upgradable |
| Package cache | only with `-Packages Folder` |

Every file goes through `Write-BuildFile`, which refuses paths outside the
confirmed plan and inside the repository, and records a SHA-512. After a run the
build lists what it wrote and fails if anything else in the repository changed.

`-AcceptWritePlan` is required for unattended runs; `-WhatIf` prints the plan
and writes nothing.

## 4. Architecture targets

One facade choice resolves into four separate naming domains. Do not use the
facade name as a path.

| Facade | .NET RID | Android ABI (APK `lib/<abi>`) | ELF class | `e_machine` | Store ABI flag |
| --- | --- | --- | --- | --- | --- |
| `arm64` | `android-arm64` | `arm64-v8a` | ELF64 | `EM_AARCH64` = 183 | `0x00010000`..`0x00040000` per `xamarin-app.hh` |
| `x64` | `android-x64` | `x86_64` | ELF64 | `EM_X86_64` = 62 | same table |
| `arm32` | `android-arm` | `armeabi-v7a` | ELF32 | `EM_ARM` = 40 | same table |

Runtime packs: `Microsoft.NETCore.App.Runtime.android-<rid>` plus
`Microsoft.Android.Runtime.CoreCLR.37.android-<rid>`.

Packages are pinned in `lib/manifest.json` under `packages`: each entry is
an exact id, version, RID (for RID-specific packages) and the SHA-512 of the
`.nupkg`. Step 2 downloads exactly those from NuGet's flat container and
stops on any hash or nuspec-identity mismatch; nothing is resolved at build
time. `tools/Get-AssemblyClosure.ps1` resolves a new set and checks it against
NuGet's catalog when the pins change. Currently .NET `11.0.0-rc.1.26425.128`,
Android `37.0.0-rc.1.2257`, PowerShell `7.7.0-preview.4`.

Status: gates 2a to 2d pass on all three targets (see `AGENTS.md`).

Test devices: an x86_64 emulator (API 36), an arm64 phone (API 36) and an
arm32 streaming device (API 34).

Facts that decide the design:

- **The managed payload is architecture-neutral IL and identical for all three**
  (96 assemblies today, see §5). Only native libraries, the emitted shim and the
  assembly store differ.
- **One APK can carry all three ABIs.** One `.so` cannot: Android selects by
  `lib/<abi>/` folder.
- **Page size is not an architecture property.** Android 15 requires 16 KB page
  compatibility for `arm64-v8a` and `x86_64` alike. 64-bit targets use 16 KB
  LOAD alignment regardless of ISA.
- **x86-64 calling convention** (System V AMD64): integer and pointer arguments
  in RDI, RSI, RDX, RCX, R8, R9; return in RAX; `AL` = number of vector
  arguments for variadic calls, so `syslog` needs `AL = 0`.
- **AArch64:** x18 is reserved by Android (ShadowCallStack). Never use it.
- **ARM32 is ELF32**, not the 64-bit writer with a different machine value. It
  needs its own writer. Proven previously on Android 14 / API 34 with
  `android-arm` + `armeabi-v7a`; see the predecessor project's ARM32 notes.

## 5. Payload

`lib/minimal-assembly-order.txt` is the ordered payload list: **96
assemblies**, IL only, ReadyToRun images rejected by step 4. It shrinks to
**93** when `Mono.Android.dll`, `Mono.Android.Runtime.dll` and
`Java.Interop.dll` leave with the .NET for Android host. The list is
architecture-neutral despite its file name.

A missing facade is not a build error; it is a runtime `FileNotFoundException`
on the device. `System.Numerics.Vectors` was found missing this way on
2026-09-17 while `System.Linq` sorted during script analysis.

## 6. Prior art: the concept is already proven

The owner's predecessor appliance (private repository
`MansfieldPlumbing/AndroidSMA`, still online) runs
`System.Management.Automation` in-process in a real Android application on
physical hardware. It is the proof of concept; this repository does not need
to repeat it.

What it established, from its README and commit history:

- **Admission host.** `MainActivity` opens or reuses **one process-static SMA
  runspace**, publishes `$Activity` and `$PSScriptRoot` (the app's `FilesDir`),
  and dot-sources `FilesDir/Start.ps1`. PowerShell owns everything after
  admission. If the start script is missing or fails, a recovery screen shows
  the source location and message and can import files into `FilesDir`.
- **Host written in PowerShell.** The compiled host is authored as typed CLR
  expression graphs and persisted as an assembly. No authored C#, no maintained
  `.csproj`. This repository's recovery host descends from it.
- **Runtime versus runspace decisions.** One runtime (CoreCLR) per process; the
  runspace is owned by the **process**, not by an Activity, so Activity
  recreation and background/foreground transitions keep session state and
  process death starts a fresh runspace. No foreground service, deliberately.
  A **dedicated UI runspace** separate from the persistent command runspace
  drove the packed-cell canvas.
- **One application, two targets.** ARM64 (Samsung S23) and ARM32 (Google TV,
  Android 14 / API 34, `android-arm` / `armeabi-v7a`). The architecture is a
  build/runtime dependency choice; touch versus D-pad is an input-adapter
  choice. Neither may fork the host.
- **Milestones:** recovery firmware proven on ARM32 and at parity on ARM64
  (2026-09-02); host emitted from PowerShell for both builds (2026-09-03);
  oracle `classes.dex` and `AndroidManifest.xml` eliminated (2026-09-05).

It was still built with the conventional toolchain: an Android workload
materialised from NuGet, a disposable MSBuild packaging project generated under
`build/temp`, and an NDK-built `libpsl-native.so`.

What is unproven, and what this repository is for, is producing that same
appliance **from one PowerShell script with no toolchain**, and then replacing
the .NET for Android host with an owned one. Do not spend time re-demonstrating
that SMA can execute on a device; the open work is build-side and native
architecture correctness.

## 7. Proven on 2026-09-17

Emulator: `pwsh-api36`, Android 16 / API 36, `google_apis` x86_64.

- **PowerShell runs in the app.** The runspace opened, `Profile.ps1` was
  missing, and the host reported `START_MISSING`. With a profile present, the
  script was parsed and analysed.
- **`setup.ps1` emitted its first machine code.** `libpsl-native.so`:
  AArch64 ET_DYN, 21 exports, 4 `libc.so` imports through a GOT with
  `R_AARCH64_GLOB_DAT` and `DT_FLAGS` BIND_NOW, non-executable stack.
  Android's loader accepted it (`nativeloader: Load … libpsl-native.so`).
- **Emitted assemblies round-trip** (Windows, PS 7.7.0-preview.4 / .NET 11
  preview 6): a saved assembly's typed `calli` called a real native function,
  `[UnmanagedCallersOnly]` survived the save, and its function pointer was
  callable. This is what lets the JNI layer be emitted at build time.
- **x64 target, 2026-09-19.** `-Architecture x64` builds a fully x86_64 APK
  (`lib/x86_64/`, an x86-64 `libpsl-native.so`, `R_X86_64_RELATIVE` in
  `libxamarin-app.so`). On the API 36 emulator, with no translation, a profile
  ran and wrote: `pwsh 7.7.0-preview.4 on Android (API level 36) X64`,
  `2 + 40 = 42`, the live `MainActivity`, and 48 available cmdlets. Next gap:
  the Management and Utility module cmdlets (for example `Join-Path`) do not
  autoload, because their module manifests are not in the payload.
- **arm64 on the phone, 2026-09-19,** on the same pinned versions: installs,
  starts, and reaches `START_MISSING` without a crash.
- **Emulator limit:** the x86_64 image aborts inside
  `ndk_translation/arm64_to_x86_64` when RyuJIT-generated ARM code runs. An ARM
  APK cannot be exercised on an x86_64 emulator. This is why the x64 target
  exists.

## 7. libpsl-native

SMA resolves `libpsl-native` by name. Its `ResolvingUnmanagedDll` handler
derives a directory from `assembly.Location`, which is empty for store-loaded
assemblies, so `Path.Combine` throws `ArgumentNullException`. The library must
therefore be found by the loader's default search, before that handler runs.

Exports at SMA v7.7.0-preview.4 (21): 17 from `CorePsPlatform.cs`, 3 from
`SysLogProvider.cs` (`Native_OpenLog`, `Native_SysLog`, `Native_CloseLog`), and
`ForkAndExecProcess` from `RunspaceConnectionInfo.cs`.

Implemented: the three syslog entries forward to bionic (`openlog` with
`LOG_NDELAY | LOG_PID` = `0x9`, `syslog` with a fixed `"%s"` so `%` in messages
is data, `closelog`), and `GetCurrentThreadId` forwards to `gettid`. The rest
report failure and are semantic gaps, not finished work.

The .NET for Android host waits for a Java-side load of any library missing
from its DSO cache, which we emit empty, so the emitted activity calls
`JavaSystem.LoadLibrary("psl-native")` before the runspace opens. That call goes
away with the host.

## 8. Leaving .NET for Android

Decision: build an owned host. `NativeActivity` plus an emitted
`ANativeActivity_onCreate` that starts CoreCLR and nothing else; Android reached
through C APIs, JNI only where no C API exists; callbacks as
`[UnmanagedCallersOnly]` methods.

**No binding types.** Android APIs become data: class name, member name, JNI
descriptor, operation kind. The descriptors are extracted mechanically at build
time from `Mono.Android.dll`'s `[Register]` attributes, so no signature is ever
guessed; then that assembly leaves the payload.

The JNI layer is emitted IL in `Pwsh.Native.dll`, not native code and not
runtime codegen: typed `calli` stubs generated from the pinned `jni.h`, plus
callback entry points. Rules that decide whether it works:

- Cache the `JavaVM*`, never a `JNIEnv*`; `GetEnv`, and `AttachCurrentThread`
  only on `JNI_EDETACHED`; detach only threads we attached.
- `FindClass` on an attached thread uses the system class loader and cannot see
  app classes. Cache the app `ClassLoader` as a global reference and call
  `loadClass` (dotted names) for those.
- `PushLocalFrame`/`PopLocalFrame` around each invocation; promote survivors.
- After every call: `ExceptionCheck`, then `ExceptionOccurred`/`ExceptionClear`.
  Almost nothing else is legal while an exception is pending.
- `RegisterNatives` binds emitted DEX forwarder classes to those callbacks; no
  `Java_pkg_Class_method` exports are needed.

Android integration points are declared in the manifest up front with
`android:enabled="false"` and switched on at run time by script, so the manifest
shape freezes early (see `audit.md` §5.8 for the assistant role).

## 9. Validation oracles (`-Debug` only)

`-Debug` (the common parameter, read from `$PSBoundParameters`) writes the
intermediates and runs validation against an independent producer. Two oracles,
kept separate, both out-of-tree, both optional, neither used to produce shipped
bytes:

1. **Managed oracle, .NET SDK.** Publishes a reference .NET for Android app in a
   temp folder and compares the Java peer package name (`acw-map.txt`) and
   `classes.dex` with what this build derives. Implemented.
2. **Native oracle, NDK/JDK.** Compiles small specimens and compares ELF layout,
   relocations and instruction bytes with the emitted shim. Not implemented.
   This is what replaces MSBuild as the reference once the host is ours: the
   question stops being "does it match Xamarin" and becomes "does it match the
   platform".

The debug menu should offer them separately.

## 10. Testing

```powershell
# build (writes only the APK)
pwsh -NoProfile -File .\setup.ps1 -c -Step 11 -AcceptWritePlan

# emulator
C:\bin\android-sdk\emulator\emulator.exe -avd pwsh-api36
adb install -r .\build\dev.mansfieldplumbing.pwsh.apk
adb shell monkey -p dev.mansfieldplumbing.pwsh -c android.intent.category.LAUNCHER 1
adb logcat -d | Select-String ' Pwsh '
```

A startup script goes to `/data/data/dev.mansfieldplumbing.pwsh/files/Profile.ps1`
(`adb root` first on a `google_apis` image, then `chown` it to the app's uid).

Before believing an x64 build: `ro.product.cpu.abilist` includes `x86_64`, the
APK carries `lib/x86_64/libcoreclr.so`, `libclrjit.so` and `libpsl-native.so`,
the shim is ELF64 `EM_X86_64`, and logcat shows no `berberis` or
`ndk_translation` frames at all.

Before pushing, enable the tracked hook once per clone with
`git config core.hooksPath .githooks`. Its `pre-push` runs
`tools/Test-PendingChanges.ps1 -PrePush`, which scans the added lines of every
commit being pushed for private keys, known token formats, credential
assignments, home-directory paths, email addresses, device identifiers and key
files, and refuses the push on any finding or on any scan failure. Findings name
the rule and `path:line`, never the matched text. Run the script without
`-PrePush` to scan the working tree. GitHub secret scanning with push
protection is enabled on the repository as a second check.

## 11. Open questions

Carried in `audit.md` §8. The ones that block work:

1. Runtime properties `coreclr_initialize` needs without the .NET for Android
   host.
2. Whether the host must call the Android crypto library's `JNI_OnLoad` when it
   is loaded with `dlopen`.
3. Whether `coreclr_initialize` can run on the UI thread inside `onCreate`
   without an ANR.
4. How assemblies load without the XABA store (`AAssetManager` over
   uncompressed APK entries, fed to CoreCLR as its trusted assembly list).
5. Whether every download is verified before use.
6. Why the host's exception for a failed Java callback is masked: the type map
   covers only the emitted assembly, so `JavaProxyThrowable` has no peer.
