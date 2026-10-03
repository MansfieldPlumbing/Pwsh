# Developer guide

This guide describes the current 1.0-preview repository. Project rules live in
`AGENTS.md`, the public capability boundary lives in `README.md`, and all future
work belongs in `ROADMAP.md`.

## 1. Build premise

`setup.ps1` produces a signed Android APK from pinned, hash-verified inputs.
PowerShell is the only required installed build tool. The script does not use
MSBuild, the .NET SDK, the Android SDK, the NDK, a JDK, Roslyn, `aapt2`, `d8`,
`zipalign` or `apksigner` to produce the artifact.

The implementation follows three rules:

- authored application and build logic is PowerShell;
- managed code is emitted as IL through persisted expression trees;
- native code is emitted by named per-ISA encoders, decoded back and
  ABI-checked before packaging.

External tools may be diagnostic oracles under the gates in `AGENTS.md`; they
never produce shipped bytes.

## 2. Step graph

`$script:StepGraph` contains nine nodes. Each node names its dependencies, and
`Resolve-StepOrder` rejects unknown nodes and cycles before execution. The
current graph is a path:

| Step | Key | Result |
| ---: | --- | --- |
| 1 | Verify | verify every pinned specification and source |
| 2 | Acquire | download and hash the pinned NuGet packages |
| 3 | Inspect | classify package payloads |
| 4 | Select | choose the 98 assemblies and re-emit R2R images as IL-only |
| 5 | Store | emit and verify the aligned assembly store |
| 6 | Native | emit the store library, native host and SMA native library |
| 7 | Manifest | emit and read back binary Android XML |
| 8 | Assemble | write and independently read back the unsigned APK |
| 9 | Sign | apply and re-verify APK Signature Scheme v2 |

Intermediate state remains in `$script:BuildContext`. A step does not consume
another step's intermediate file from disk.

## 3. Write boundary

Nothing is written before the build displays and confirms its write plan.
`-AcceptWritePlan` is required for unattended execution, and `-WhatIf` displays
the plan without writing.

| Output | Default location |
| --- | --- |
| Signed APK | `build\dev.mansfieldplumbing.pwsh.apk` |
| Intermediates | memory; `build\` only with `-KeepIntermediates` or `-Debug` |
| Signing key | the platform's per-user application-data location |
| Package cache | the platform's per-user cache; memory unless `-Packages Folder` |

`Write-BuildFile` enforces the confirmed plan. After the run, the build lists
every file it wrote with its SHA-512 and fails if an unplanned repository path
changed. Generated repository files are confined to the git-ignored `build\`
directory. Signing keys and package caches never belong in the repository.

## 4. Pinned inputs

`lib/manifest.json` is the root input manifest. `setup.ps1` holds only its
digest; every other source address, package identity, revision and digest is
read from the verified manifest.

The current manifest contains 18 package entries. A target selects 16 of them,
including its one RID-specific runtime pack. Current release inputs are:

- .NET runtime `11.0.0-rc.1.26425.128`;
- Android build metadata `37.0.0-rc.1.2257`;
- PowerShell and SMA `7.7.0-preview.4`.

`docs/assembly-audit.md` and `docs/powershell-load-behavior.md` study a possible
PowerShell preview.5 payload. They are not the current release manifest.

## 5. Targets

| CLI target | Runtime RID | APK ABI | ELF class | Machine |
| --- | --- | --- | --- | --- |
| `arm64` | `android-arm64` | `arm64-v8a` | ELF64 | `EM_AARCH64` |
| `x64` | `android-x64` | `x86_64` | ELF64 | `EM_X86_64` |
| `arm32` | `android-arm` | `armeabi-v7a` | ELF32 | `EM_ARM` |

The managed payload is architecture-neutral. Native libraries, relocation
types, pointer-sized store fields and emitted instructions differ per target.
The build checks SysV AMD64, AAPCS64 and AAPCS32 control flow independently.

ARM32 has two deliberate distinctions: the host is Thumb-2 while
`libpsl-native.so` remains A32, and its store version word carries no 64-bit
flag. Do not normalize either difference away.

## 6. Current APK and startup

The preview APK contains no DEX and no .NET for Android components. Its
application has `android:hasCode="false"` and uses the framework
`android.app.NativeActivity` with `android.app.lib_name` set to `pwsh-host`.

Startup is:

1. Android loads `libpwsh-host.so` and calls `ANativeActivity_onCreate`.
2. The host starts the pinned CoreCLR and supplies the assembly probe.
3. The probe serves the 98 IL-only assemblies from the read-only mapped store.
4. `Dev.MansfieldPlumbing.Pwsh.NativeHost` opens a Full Language,
   `UseCurrentThread` runspace on the Android main thread.
5. The host loads the Utility, Management and Security command assemblies by
   identity, imports them from their in-memory `Assembly` objects, and verifies
   a cmdlet from each family.
6. The host publishes the borrowed `ANativeActivity*` as
   `NativeActivityHandle`, locates `Profile.ps1` case-insensitively and invokes
   it as an external script.

Full Language Mode is required because the application layer performs managed
reflection, delegate construction and native interop. It is not a claim that
untrusted scripts are safe to execute.

The exact frozen `scripts/CellCanvas.ps1` workload does not run yet. Gate 2e
still needs the owned compatibility assembly, and gate 2f must run the frozen
bytes on all three backends.

## 7. Payload and native outputs

`lib/minimal-assembly-order.txt` is the ordered 98-image payload. It contains
CoreCLR and SMA dependencies plus `Microsoft.PowerShell.Commands.Utility`,
`.Commands.Management` and `.Security`, and MarkdownRender and Markdig, which
Utility's import needs until step 2.8 of the implementation plan; Roslyn remains
absent, so source-compiling `Add-Type` remains outside the supported payload.
The command import path has debuggable receipts on the x86-64 emulator and an
arm64 phone; arm32 remains open.

Step 4 removes every ReadyToRun body while preserving IL, metadata, resources
and field data. Step 5 rejects any image that still has a ReadyToRun header or
lacks the IL-only flag. Every image in the NativeActivity store begins on a
16-byte boundary.

Step 6 emits:

- `libassembly-store.so`, containing the aligned store;
- `libpwsh-host.so`, which starts CoreCLR and enters the managed host;
- `libpsl-native.so`, which provides the 21 SMA native exports admitted by the
  build.

Every emitted instruction is decoded by an independent reader. ELF headers,
program headers, dynamic entries, relocations, symbols, hash tables, memory
permissions and ABI control flow are checked before packaging.

## 8. Evidence boundary

Gates 2a through 2d pass on the x86-64 emulator, the arm64 phone and the arm32
device. The same three backends have receipts for JNI calls, Android `Canvas`
text and color, the 63-vector console model, input consumption and resize
reflow. `AGENTS.md` records the exact claim boundaries and receipt dates.

These receipts do not prove the remaining compatibility assembly, exact frozen
CellCanvas execution, the integrated terminal, recovery UI, production startup
lifecycle, all 98 store images, the command-assembly import path, hashing/TLS initialization, or release
performance. Unchecked `ROADMAP.md` items remain planned.

## 9. Build and device checks

Build the signed artifact:

```powershell
pwsh -NoProfile -File .\setup.ps1 -c -Step 9 -AcceptWritePlan
```

For a debuggable build already installed on an attached device, run a profile
without rebuilding:

```powershell
pwsh -NoProfile -File .\tools\Invoke-DeviceScript.ps1 `
  -Path .\scripts\ScreenProbe.ps1 `
  -Device emulator
```

The device runner uses `run-as`, never prints device serials, waits for the host
completion marker, checks process liveness and reports matching crash-buffer
lines. Directory input places `Profile.ps1` and its companion files together.

Before pushing, enable the tracked hook once per clone:

```powershell
git config core.hooksPath .githooks
```

The hook runs `tools/Test-PendingChanges.ps1 -PrePush` and refuses secrets, key
files, credential assignments, personal paths and device identifiers without
printing matched values.

## 10. Downstream consumption

Another repository must consume Pwsh only from an immutable Git commit and a
pinned digest. It must not read this working tree, depend on uncommitted changes
or copy build output. If it imports selected helpers from `setup.ps1`, it must
verify the admitted file before parsing or invoking them and record the source
commit in its own receipt.

The build remains the producer. Independent implementations may decode,
disassemble, load or execute emitted artifacts as oracles, but they do not
replace a build gate or produce bytes that ship.

## 11. Where to continue

- `ROADMAP.md`: ordered implementation and release gates.
- `AGENTS.md`: repository rules and established facts.
- `docs/android-facade.md`: gate 2e compatibility boundary.
- `docs/host.md`: planned host lifecycle and runspace dispatch.
- `docs/shell.md`: planned event, frame and remote-consumer contracts.
- `docs/ui.md`: terminal and composited-UI design.
- `docs/assembly-audit.md`: candidate payload study, not current release state.
- `audit.md` and `docs/xamarin-inventory.md`: historical migration records.
