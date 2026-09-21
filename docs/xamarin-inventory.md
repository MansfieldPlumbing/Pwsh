# Xamarin inventory

Xamarin (.NET for Android) currently provides two different things:
application capabilities and bootstrap infrastructure. Most of the bootstrap
infrastructure should be deleted, not reimplemented. Only application
capabilities observed in execution are candidates for replacement.

This inventory was taken from what runs today, working inward: the host that
`setup.ps1` emits (`New-AndroidHostTypes` and its phases), the six-opcode
`OnCreate` shim, `Profile.ps1`, and CanvasDemo as a workload. CanvasDemo is
evidence of required capabilities, not an architecture to reproduce.

Every **proposed replacement** below is a candidate. None has crossed the
evidence boundary until its removal gate passes on hardware.

## How the app starts today

`mono.MonoRuntimeProvider` (acquired `classes.dex`) → `libmonodroid.so` →
`coreclr_initialize` with properties from `libxamarin-app.so` → assemblies from
the XABA store → Java peer `MainActivity` (`classes2.dex`) → JNI-registered
`n_onCreate` → `Mono.Android` `Activity.OnCreate` → the six-opcode shim →
`AdmitActivity` → runspace → `Profile.ps1`.

Everything above `AdmitActivity` exists because Xamarin is the host.

## Classifications

- **KEEP**: the capability stays and already has no Xamarin in it.
- **REPLACE**: the capability stays; the mechanism changes.
- **MOVE TO SCRIPT**: belongs in a script, not the host.
- **RECOVERY-ONLY**: needed only by the recovery screen.
- **DELETE**: exists only because Xamarin is the host.

Mechanisms: C API, JNI, owned emitted DEX forwarder, CoreCLR/runtime,
PowerShell.

## 1. Admission and lifetime

| Capability | Today | Proposed replacement | Mechanism | Class | Threading | Removal gate |
| --- | --- | --- | --- | --- | --- | --- |
| Process and runtime start | `MonoRuntimeProvider` → `libmonodroid` → `coreclr_initialize` | emitted host `.so` exporting `ANativeActivity_onCreate`, calling `coreclr_initialize` and `coreclr_create_delegate` | C API + runtime | REPLACE | main thread, once per process | gates 1 and 2 below |
| Activity | Java peer `MainActivity` (`classes2.dex`), `n_onCreate` via RegisterNatives | `android.app.NativeActivity`, a framework class; no DEX | C API | REPLACE | NativeActivity callbacks on main | app launches with no DEX |
| Managed entry | six-opcode `OnCreate` shim → `AdmitActivity(Activity)` | `[UnmanagedCallersOnly]` entry taking `ANativeActivity*`, reached by `coreclr_create_delegate` | runtime | REPLACE | main thread | host reaches the runspace |
| Runspace and `Profile.ps1` | `CreateDefault2`, `UseCurrentThread`, `Open`, `ExternalScript` | the same SMA calls on a dedicated PowerShell thread blocking in `ALooper_pollOnce` | PowerShell + C API | KEEP | runspace thread, never main | `Profile.ps1` runs on all three targets |
| `JavaSystem.LoadLibrary("psl-native")` | required only because monodroid waits for a Java-side load | dropped; default `dlopen` probing | none | DELETE | none | SMA startup logging works without it |

## 2. Files and identity

| Capability | Today | Proposed replacement | Mechanism | Class | Removal gate |
| --- | --- | --- | --- | --- | --- |
| HOME / files directory | `Context.FilesDir.AbsolutePath` | `ANativeActivity->internalDataPath` | C API | REPLACE | `Profile.ps1` resolves and runs |
| Package identity | `Context.PackageName` | build-time constant; `setup.ps1` emits the manifest | none | REPLACE | recovery text shows it |
| Device facts | `Build.Manufacturer`, `Model`, `VERSION.Release`, `SdkInt`, `SupportedAbis` | `__system_property_get`, `ANativeActivity->sdkVersion` | C API | RECOVERY-ONLY | diagnostic text matches today's |
| Native library directory | resolved by monodroid | candidate: `dladdr` on a host symbol. Unproven: with APK-backed loading the path may name the APK, not a directory of sibling libraries | C API | REPLACE | the path the host derives loads `libpsl-native` and the runtime libraries on all three targets |
| Logging | `Android.Util.Log` (host and CanvasDemo) | `__android_log_write` through emitted `calli` stubs in `Pwsh.Native.dll` | C API | KEEP | log lines appear under the same tag |

## 3. Console surface (CanvasDemo as evidence)

| Capability | CanvasDemo today | Proposed replacement | Mechanism | Class | Threading | Removal gate |
| --- | --- | --- | --- | --- | --- | --- |
| Window | `SurfaceView`, `SurfaceHolder`, `SetContentView`, `RunOnUiThread` | `ANativeWindow` from `onNativeWindowCreated` / `onNativeWindowDestroyed` | C API | REPLACE | callbacks on main; drawing on the console thread | console draws on all three targets |
| Rendering | `LockHardwareCanvas`, AGSL `RuntimeShader`, `Bitmap`, `ByteBuffer` | Vulkan on the `ANativeWindow`; the packed-cell shader as SPIR-V compiled at build time | C API | REPLACE | console thread | grid output matches CanvasDemo |
| Glyph atlas | `Typeface` and `Paint` rasterize glyphs into a bitmap | `AFont` / `ASystemFontIterator` locate the font; rasterizing has no NDK C API | JNI at startup only, or an owned rasterizer | REPLACE | once before the first frame | atlas bytes match today's |
| Frame pacing | `PostOnAnimation`, `Java.Lang.Runnable`, `RecoveryProgram` animation callback | `AChoreographer_postFrameCallback64` | C API | REPLACE | console thread's looper | stable frame loop |
| Frame rate | `Surface.SetFrameRate`, `RequestedFrameRate` (API 35) | `ANativeWindow_setFrameRate` | C API | REPLACE | console thread | request accepted in the log |
| Performance hint | `PerformanceHintManager.CreateHintSession` | `APerformanceHint_*` (API 33) | C API | REPLACE (optional) | console thread | hint session created |
| Touch and keys | `SurfaceView` `Touch` and `KeyPress` events | `AInputQueue` from `onInputQueueCreated`, attached to the console looper; `AMotionEvent`, `AKeyEvent` | C API | REPLACE | console thread via looper fd | CanvasDemo's input modes work |
| Resize and insets | `WindowInsets`, `DisplayCutout`, content bounds | `onContentRectChanged`, `onNativeWindowResized`; cutout detail has no C API | C API; JNI only if cutouts matter | REPLACE | main → looper | resize reports the correct grid |
| Keep screen on | `KeepScreenOn` | `ANativeActivity_setWindowFlags(AWINDOW_FLAG_KEEP_SCREEN_ON)` | C API | REPLACE | main thread | screen stays on |
| Thread id | `Process.MyTid` | `gettid` (already in `libpsl-native`) | C API | REPLACE | — | — |

## 4. Recovery only

| Capability | Today | Proposal | Mechanism | Class |
| --- | --- | --- | --- | --- |
| Recovery screen | `LinearLayout`, `TextView`, `Button`, `ScrollView`, colors, dp | draw recovery text on the console surface; logcat if the surface itself fails | C API | RECOVERY-ONLY |
| Toast | `Toast.MakeText` | drop; the message goes on screen and to logcat | none | RECOVERY-ONLY |
| Copy to clipboard | `ClipboardManager`, `ClipData` | no C API | JNI, or a script command later | RECOVERY-ONLY / MOVE TO SCRIPT |
| Import file | `ACTION_OPEN_DOCUMENT`, `StartActivityForResult`, `OnActivityResult`, `ContentResolver` | `NativeActivity` has no native `onActivityResult`, so this needs a one-method subclass | owned DEX forwarder | RECOVERY-ONLY |
| Case-insensitive profile lookup; distress beacon | .NET IO; `Log.Error` | unchanged; `liblog` | PowerShell / C API | KEEP |

## 5. Deleted with Xamarin

| Item | Size or role | Class |
| --- | --- | --- |
| `classes.dex` (acquired) | 402 KB | DELETE |
| `mono.MonoRuntimeProvider` provider in the manifest | runtime bootstrap | DELETE |
| `classes2.dex` Java peer (`crc64` name, `n_onCreate`) | 1.7 KB | DELETE, unless reused as the import forwarder |
| `libmonodroid.so` | 1.2 MB per ABI | DELETE; the emitted host replaces it |
| `libxamarin-app.so`: application config, runtime properties, type map, DSO cache | 1.18 MB | DELETE |
| `Mono.Android.dll`, `Mono.Android.Runtime.dll`, `Java.Interop.dll`, `_Microsoft.Android.Resource.Designer.dll` | four payload assemblies | DELETE |
| `RuntimeFeature` switches, JNIEnv init tokens, type-map lookups | host-only data | DELETE |
| `libassembly-store.so` (XABA, read by monodroid) | the store format | KEEP if the owned host can serve it through `external_assembly_probe`; open question 1 |

## What the admission boundary already provides

`ANativeActivity_onCreate` receives an `ANativeActivity*` that the framework has
populated (`lib/native_activity.h`):

- `JavaVM* vm` (line 64): the Java VM for any later JNI work.
- `JNIEnv* env` (lines 67-71): usable only on the main thread. A PowerShell or
  console thread that needs JNI must attach through `vm`.
- `internalDataPath` (line 88): the candidate for HOME, without JNI.
- `sdkVersion` (line 98) and `AAssetManager* assetManager` (line 111).
- Callbacks (lines 123-124) run on the main thread and are all NULL until set,
  so an entry point that installs none is valid.

## Gate 1 result

Passed on all three targets with `-Admission NativeActivity`: the framework
`android.app.NativeActivity` loaded the emitted `libpwsh-host.so` and it logged
`GATE1 ANativeActivity_onCreate` on the main thread (Samsung Galaxy S23 arm64,
x86_64 emulator, arm32 device). The APK has four entries and no application DEX,
no `MonoRuntimeProvider`, and no Xamarin libraries.
## Gate 2a result

Passed on the x86_64 emulator with `-Admission NativeActivity`: the emitted
`libpwsh-host.so` started CoreCLR through its own `host_runtime_contract`,
served `System.Private.CoreLib.dll` and `Pwsh.dll` from the mapped store through
`external_assembly_probe`, and logged `GATE2A Admit returned 0x50575348`. The
APK carries no DEX, `libmonodroid` or `libxamarin-app`. arm64, arm32, SMA and
the full payload are the next gates.

## Open questions

1. **Who owns assembly resolution at CoreCLR startup, and which runtime
   properties and callbacks are required?** Answered for gate 2a on x86_64: the
   owned contract with `external_assembly_probe` over the existing store and the
   three properties the pinned host sets (`HOST_RUNTIME_CONTRACT`,
   `RUNTIME_IDENTIFIER`, `APP_CONTEXT_BASE_DIRECTORY`) suffice; the rest of this
   item is the background. Extraction to disk is not forced:
   the pinned host contract (`lib/host_runtime_contract.h`,
   v11.0.0-rc.1.26425.128) has `external_assembly_probe`, which returns a
   pointer and size for an assembly from memory the host owns. Candidate
   shapes:
   - loose assemblies listed in `TRUSTED_PLATFORM_ASSEMBLIES`;
   - a hybrid of files on disk and a store;
   - an owned `HOST_RUNTIME_CONTRACT` whose `external_assembly_probe` serves
     assemblies from the existing XABA store, mapped by `dlopen` of
     `libassembly-store.so` and `_assembly_store`.

   The third keeps the store proven on three architectures and deletes
   `libmonodroid` and `libxamarin-app`. Rule it out before accepting the
   first-run writes and duplicate storage that extraction costs. The current
   .NET for Android CoreCLR host is the oracle for the minimal property set.
   This decides milestone gate 2.
2. **`libSystem.Security.Cryptography.Native.Android.so` and the Java VM.** A
   `dlopen` from CoreCLR does not run `JNI_OnLoad`; the host may have to pass
   `activity->vm` explicitly before hashing or TLS work.
3. **The emitted host `.so` is real code.** It builds argument arrays and calls
   `coreclr_initialize`; its structure needs a design before the encoders grow.
4. **Glyph rasterization.** JNI to `Paint` once at startup, or an owned
   rasterizer.
5. **`Get-ChildItem` and `Get-Process`.** Unrelated to Xamarin: they need
   `Microsoft.PowerShell.Commands.Management`, and
   `Microsoft.PowerShell.Commands.Utility` for formatting. A payload decision.

## First executable gates

Milestone 1 is split so that a failure points at one layer:

1. `NativeActivity` → emitted host `.so` → `liblog`. Proves admission without
   Xamarin or any DEX.
2. `NativeActivity` → emitted host `.so` → CoreCLR → the smallest managed
   entry. Proves runtime ownership. Needs open question 1 decided first.

Gate 1 is deliberately minimal: `android:hasCode="false"`, the framework
`android.app.NativeActivity`, `android.app.lib_name` naming the host library,
an exported `ANativeActivity_onCreate` that makes one `__android_log_write`
call through `DT_NEEDED liblog.so` and returns. It passes only if the APK also
proves absence: no `.dex` entries, no `MonoRuntimeProvider`, no
`libmonodroid.so` or `libxamarin-app.so`. It is a separate build mode; the
Xamarin build stays the oracle until gate 1 holds on all three targets.
