# The Pwsh host (design, not proven)

In PowerShell's terms the host is the component that creates runspaces and
owns their lifecycle. In Pwsh the host is emitted: `setup.ps1` lowers it from
LINQ expression trees into `Dev.MansfieldPlumbing.Pwsh.dll`, and the native
`libpwsh-host.so` only starts CoreCLR and calls it. This document is planned
design; `ROADMAP.md` names the gates that will prove it.

## Startup order

Measured 2026-09-26 with `tools/Invoke-DeviceScript.ps1` and
`scripts/ScreenProbe.ps1` (logcat time of each host marker), everything today
runs inside `onCreate` before Android can show a frame:

| Phase | S23 | onn 4K Plus | x86_64 emulator |
| --- | ---: | ---: | ---: |
| Runtime and assembly resolution | 72 ms | 475 ms | 546 ms |
| `CreateDefault2` | 153 ms | 1,483 ms | 1,611 ms |
| `Open` | 519 ms | 2,732 ms | 3,142 ms |
| First script (a literal) | 190 ms | 1,743 ms | 1,565 ms |
| `Profile.ps1` (probe setup) | 229 ms | 1,969 ms | 1,473 ms |
| To `RunPowerShell returned` | 1.19 s | 8.57 s | 8.50 s |

The cost is first-use JIT of SMA and CoreLib. The planned order:

1. `onCreate` returns after CoreCLR starts and the window and input callbacks
   are installed.
2. The terminal draws at once from emitted IL: cell grid, glyphs, damage. It
   touches no SMA. Device metrics (screen, cell size, font) are read at run
   time; the code shape is fixed at build time.
3. The host then creates the runspaces behind the first frame, runs
   `Profile.ps1`, and shows the prompt. Keystrokes typed meanwhile are queued.
4. If a runspace or the profile fails, the same terminal shows the error with
   Retry, Copy and Import. Recovery is a state of the host, not a separate
   screen; the host that creates the runspaces is the one that recovers them.

## Runspaces and dispatch

Traced in PowerShell `v7.7.0-preview.5` (commit `149ab5cd6c`):

- A script block converted to a delegate runs against the calling thread's
  `Runspace.DefaultRunspace`, looked up at each invocation
  (`scriptblock.cs:821`, `LocalPipeline.cs` `GetExecutionContextFromTLS`).
  `DefaultRunspace` is `[ThreadStatic]` (`Connection.cs:500`). No affinity to
  the opening thread is checked.
- After `Open`, `ThreadOptions` may change only to `ReuseThread`
  (`LocalConnection.cs:150-156`), so a runspace cannot be opened on one thread
  and switched to `UseCurrentThread` on another.

Planned shape: the host holds several runspaces, and a dispatcher chooses the
target runspace for each event by setting `DefaultRunspace` around the
delegate call and restoring it afterwards. A runspace has one executing
thread at a time; when its owner is busy, the event waits in the looper
queue. Typical roles: an app runspace on the main thread (`UseCurrentThread`)
for `Profile.ps1`, input and damage; a shell runspace on its own thread for
commands that may run long, whose results return to the main thread as looper
events. The second runspace opens after the first, with the JIT already warm.

## Isolation

Traced in the runtime at `ab19415702aa` and PowerShell at `149ab5cd6c`:

- One AppDomain: `AppDomain.CreateDomain` throws
  `PlatformNotSupportedException` (`AppDomain.cs:116-120`); the VM's
  `DefaultDomain()` returns the current domain (`appdomain.hpp:1601`).
- One GC heap. `AssemblyLoadContext` separates type identity and statics per
  load, and can unload collectible contexts, but objects from every context
  share the heap.
- One copy of SMA: `PowerShellAssemblyLoadContext` adds resolve handlers to the
  default context (`CorePsAssemblyLoadContext.cs:98-105`), so SMA's statics are
  shared by every runspace. Runspaces separate session state, variables and
  functions; .NET objects passed between them are shared references, and
  environment variables, `[Environment]::CurrentDirectory` and static fields
  are process-wide.

Isolation between runspaces is therefore the dispatcher's rule, not the
runtime's. Hard isolation is a separate Android process (`android:process` on
a component), with its own CoreCLR, heap and JIT; it is a manifest decision for
the freeze.

A second process would not duplicate the store. On the S23 the store library
(`extractNativeLibs` true) is mapped read-only from its file: 19.6 MB of its
34.4 MB mapping resident, no private dirty pages, 2026-09-26. Clean
file-backed pages are shareable between processes; sharing itself is
unproven until two processes are measured. Each process would pay its own
JIT, heap and startup.
