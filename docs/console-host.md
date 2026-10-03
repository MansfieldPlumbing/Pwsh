# Console host, startup and Recovery

Status: design, 2026-10-02. Nothing here is proven until its receipt exists.
The console core it builds on is specified in
[console-reference.md](console-reference.md); the gates are in
[implementation-plan.md](implementation-plan.md) and
[work-managed-ui.md](work-managed-ui.md).

## Names

A program that implements `PSHost` and runs an interactive console is a
**console host**; Microsoft's is `ConsoleHost` in
`Microsoft.PowerShell.ConsoleHost.dll`. Ours is
`Dev.MansfieldPlumbing.Pwsh.ConsoleHost` once lowered. Until then the console
host is the PowerShell console module running in the app. The setup option
keeps its name; only what stands behind it changes.

## Startup modes

`setup.ps1 -Startup Profile | ConsoleHost` (also in the setup UI).

| Mode | What starts | Use |
| --- | --- | --- |
| `Profile` | The host runs `Profile.ps1` found in the app's files directory, as proven at gate 2d; a `-Debuggable` build lets `run-as` place it | Development and probes |
| `ConsoleHost` | The console starts by itself from scripts shipped in the APK; no `run-as`, no debuggable flag. A user `Profile.ps1`, if present, runs inside the console session like any PowerShell profile | The product |

Shipped scripts reach the device as described in
[work-optional-scripts.md](work-optional-scripts.md): copied from the signed
APK into `PWSH_APP_SCRIPTS` when the installed version changes, with
`PWSH_USER_SCRIPTS` ahead of it on `PATH` so a user script of the same name
wins.

## Failure paths

The rule: user content may live anywhere the user chooses, including private
app storage, but **the way back into it never depends on user content**.

| Failure | What happens |
| --- | --- |
| No `Profile.ps1` | The console starts. A missing profile is not an error. |
| `Profile.ps1` throws | The console shows PowerShell's own error record (file, line, column, message) and stays usable. Fix it with ordinary commands: rename, replace from `PWSH_USER_SCRIPTS`, or `Set-Content`; later with the editor. |
| `Profile.ps1` crashes the process or hangs before the console draws | **Crash-loop breaker:** the host writes a marker before running the profile and clears it after. A marker left by the previous launch means that launch did not finish, so this one starts without the profile and says why. An exception escaping a window callback aborts the process (seen on the x86-64 emulator), which is why this cannot be left to the console. |
| The user asks for it | **Safe start**: the shipped console with no profile and no user scripts on `PATH`, reached from a launch option (for example an app-icon shortcut "Start without profile"; the shortcut needs reading the launch intent through JNI, to be checked against the no-DEX constraint). |
| SMA cannot load or the runspace will not open | **Recovery** (below). |
| CoreCLR cannot start or the store will not load | Not user-caused: the store is signed APK content, so this is a build defect that receipts catch before release. The native host logs it; reinstalling is the fix. |

## Recovery

Recovery is a command processor with no PowerShell in it, for the one case the
console cannot cover: SMA itself failing to start. Its prompt is
`Recovery >`.

- It runs on the lowered console core (rendering, input, buffer), which does
  not depend on SMA.
- It lives in its own assembly that references only CoreLib and the console
  core. If any of its types named an SMA type, loading it could pull SMA in and
  fail with the thing it recovers from, so the build checks its references and
  fails if SMA appears.
- A fixed set of verbs, no scripting, no variables, no arbitrary execution,
  paths confined to the app's own storage: `help`, `ls`, `cat`, `mv`, `cp`,
  `rm` (with confirmation), `log` (the last startup error), `noprofile`
  (restart PowerShell without the profile), `reset` (drop the active overlay
  and refresh `PWSH_APP_SCRIPTS` from the APK, see
  [native-extensions.md](native-extensions.md#layered-loading)), `export`,
  `restart`.
- Managed, not native: every failure a user can cause happens after CoreCLR
  and the managed host are running, so a native recovery would only guard a
  layer that receipts already protect, at the cost of emitted machine code
  gated on three instruction sets.

Until the console core is lowered, a spartan fallback screen stands in for
Recovery: the error, plus three actions (start without profile, reset app
scripts, show the log). It replaces the earlier project's green recovery
screen, whose remaining jobs (show a profile error, import a new profile) the
console now does itself.

## Private storage

Private app storage is the right home for a user's collection: other apps
cannot read it and Android protects it. Keeping it reachable does not require
moving it:

1. Safe start and the crash-loop breaker always reach a PowerShell prompt over
   private storage unless SMA itself is broken.
2. Recovery operates on private storage without SMA.
3. Getting files out: Android's own backup (Auto Backup, device-to-device
   transfer) covers private storage when the manifest enables it, which is a
   deliberate opt-in because it copies scripts to the user's cloud account;
   Recovery and the console can also export a copy to a location the user
   picks.

## Spike acceptance

The first `ConsoleHost` spike is accepted on the x86-64 emulator, x86-64
Windows Subsystem for Android and an arm64 physical device when, on a fresh
install:

- the prompt appears on a cold start with no `run-as` step;
- typing `1+2` with the on-screen keyboard prints `3` (key events through
  `ANativeActivity_showSoftInput`; so far only adb-injected key events have
  been checked, so this is the spike's main risk, and failing it moves the
  text-input bridge ahead of everything else);
- a shipped parser such as `ConvertFrom-KeyValue` resolves from `PATH`;
- no frames are presented while idle;
- the process is alive afterwards with no crash for it.
