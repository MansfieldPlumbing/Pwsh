# Owned Android facade

This is the gate 2e implementation boundary, not a claim of device execution.
The repository contract and frozen CellCanvas take precedence over earlier
Vulkan/console-thread proposals in `xamarin-inventory.md`.

## Layers

1. Native startup starts CoreCLR and passes the borrowed `ANativeActivity*` to
   `NativeHost.RunPowerShell(IntPtr)`. It does not implement UI policy.
2. Literal binding mechanisms load NDK exports and dispatch JNI function-table
   calls. QuickPS `src/Native.ps1` demonstrates delegate emission, function
   pointer binding and table dispatch; its Windows calling convention is not
   Android evidence. Pin Android `jni.h`, derive slots, and prove `GetVersion`,
   `FindClass`, `GetMethodID` and a `Call*MethodA` with `jvalue[]` on every ABI.
3. The owned compatibility assembly supplies only CellCanvas's reached
   `Android.*` and `Java.*` shapes. It owns managed UCO callbacks, explicit JNI
   reference lifetimes, Java exception translation and main-thread dispatch.
4. Application state and navigation sit above this facade.

The build-time `scripts/Get-CellCanvasReferences.ps1` validates the frozen hash, parses without
execution, and returns every Android/Java type and every member site with its
location and argument count. Dynamic receivers remain explicitly unresolved.
Resolve those sites against pinned Mono.Android metadata and a Xamarin baseline
trace before treating the inventory as a complete compatibility specification.

## Frozen workload obligations

| Boundary | Required behavior |
| --- | --- |
| Activity | RunOnUiThread, Window query, GetSystemService, SetContentView adaptation |
| SurfaceView | dimensions, insets/cutout, focus, keep-screen-on, attachment, Touch/KeyPress events, PostOnAnimation |
| Surface/holder | validity, LockHardwareCanvas, UnlockCanvasAndPost, frame-rate request |
| Graphics | Color, Paint/typeface/font metrics/text bounds, Rect, Canvas text/rect/paint, Bitmap allocation/pixels/buffer upload, BitmapShader, RuntimeShader uniforms/input shaders |
| Java wrappers | direct ByteBuffer allocation/clear/put/rewind and Action-backed Runnable |
| Input | motion action/pointers/coordinates, key action/keycode, handled disposition |
| Diagnostics/hints | logging, API level, thread ID, optional performance hint session |
| Callback bridge | RecoveryProgram.SetAnimationCallback/RunAnimationCallback |

Keep Android Canvas and AGSL as the renderer. Obtain the Java Surface using
`ANativeWindow_toSurface`; do not replace NativeActivity's framework content view
with a SurfaceView. The compatibility SetContentView binds the owned surface
adapter. The Android main thread owns the runspace and script delegate calls.
Attach other JNI threads through JavaVM; never reuse `activity->env` there.
Every successful canvas lock must have exactly one unlock/post, including failure.
Window destruction must cancel presentation and release owned references before
the borrowed window expires. Callback exceptions must not cross unmanaged frames.

## Additional proof obligations

These are additional acceptance requirements, not inferred CellCanvas coverage.

| Boundary | Minimum contract and proof |
| --- | --- |
| Multiple Activities | per-instance identity/generation, create/start/resume/pause/stop/destroy and saved state; launch/back/finish; destroy one Activity without corrupting another; rotate/recreate without stale callbacks |
| Surface | creation, replacement, resize, content bounds and destruction; drawing only while current surface is live |
| Text input | Android text editor/IME connection, composing text, committed Unicode text, selection and keyboard visibility; key events alone are insufficient. Resolve a minimal Android editor bridge without replacing NativeActivity's content view. |
| Audio | explicit playback stream format, start/stop, bounded transfer, underrun/disconnect handling, device change and deterministic close; microphone permission/capture only if selected for the proof |

No process-global current Activity.

## First implemented prerequisite and next proof

`setup.ps1` passes the saved Activity pointer in x0 (AAPCS64), r0 (AAPCS32), or
rdi (SysV AMD64) to `RunPowerShell(IntPtr)`. The managed entry rejects null and
places the pointer in that invocation's runspace as `NativeActivityHandle` before
the profile executes. `Admit()` retains its existing constant-result invariant.
This is borrowed admission only: it does not implement lifecycle revocation,
JNI, surfaces, multiple-Activity runtime reentry, or gate 2e.

Local verification on 2026-09-25: both scripts parse; the inventory records 31
Android/Java type names and 513 total member sites, including 80 static
Android/Java sites. The frozen workload hash matches. A NativeActivity x64
Step 6 build was attempted, but stopped during Step 1 with the build's network
failure report. No emission, ABI-check pass, or device execution is claimed for
this change. The pre-change setup script is retained outside the repository.

Evidence: pinned `lib/native_activity.h` (manifest URL commit
`bfcf75076e562945bae131a4929f29a90d0d2481`) defines pointer ownership and the
main-thread environment/callback contract. Existing per-ISA emitter/ABI checks
in `setup.ps1` define the call sites. Build and device checks must pass before
promoting this new admission path. Next: pin JNI source, prove the four-call JNI
smoke on all three backends, then implement one Paint/Bitmap/Canvas readback
slice with cleanup. Expand to window callbacks only after those pass.
