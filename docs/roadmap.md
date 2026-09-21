# Roadmap

## Working rule

```text
modify setup.ps1
    -> run from the beginning
    -> validate the step's output
    -> stop on any failed contract
    -> advance only after the step is reproducibly verified on hardware
```

Every input is pinned by SHA-256 and chains to `lib/manifest.json`. Nothing is
taken from the machine's installed state.

## Direction

Pwsh stops depending on .NET for Android (Xamarin). The runtime, the window and
the event loop become Pwsh's own; Android is reached through its C APIs, not
through `Mono.Android` bindings.

| Layer | Owner |
| --- | --- |
| Process, runtime, APK | Pwsh |
| Platform building blocks (window, input, Vulkan, audio, logging) | QuickPS `*.Android.ps1` peers, bound through `Native.ps1` |
| Applications | PowerShell scripts |

Design constraints:

- One event queue. The PowerShell thread blocks in `ALooper_pollOnce(-1)`;
  lifecycle, input, GPU completion (sync_fd), timers and service calls are file
  descriptors on that looper. No tick loops, no polling.
- Native callbacks never run PowerShell. Small emitted functions record the
  event and wake the looper.
- Shaders are compiled to SPIR-V on the build machine. No shader compiler ships
  on the device.

## Milestones

1. **Own host.** `android.app.NativeActivity` loads Pwsh's host, which starts
   CoreCLR and runs `Profile.ps1`. First proof: a log line through `liblog`.
   Retires the XABA store wrapper, `libxamarin-app.so`, the acquired
   `classes.dex`, `Mono.Android`, `Java.Interop` and the type map.
2. **Generated bindings.** Emit `Pwsh.Native.dll` from pinned `jni.h`, NDK
   headers and `vk.xml`: explicit-layout structs and `calli` entry points.
3. **Presentation.** Vulkan swapchain on the NativeActivity window, AHB-backed
   shared buffers, the packed cell shader from CanvasDemo.
4. **Service slots.** One emitted DEX forwarder template per Android base class
   (accessibility, input method, tile, voice interaction, …) and one native
   dispatcher that answers synchronously within Android's deadlines.
5. **Numbers.** Cold start, time to first frame, idle CPU, input-to-photon
   latency, measured on hardware and published here.
