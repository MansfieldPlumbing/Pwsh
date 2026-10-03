# Hardware Canvas: x86-64 development receipt

Recorded 2026-10-01 in the local working tree based on
`a6d881f8d19f35efba5dfa9e2e3e532c41879ad0`. This is emulator evidence for P1,
not an immutable release snapshot or an all-backend gate. P0 contracts and
conformance-source admission remain open. P2 managed lowering is not implemented.

## Artifact and inputs

Built only through `setup.ps1 -c -Step 9 -Architecture x64 -Debuggable
-Packages Folder -AcceptWritePlan`. All nine steps pass, including upstream
integrity, decoded native instructions, store alignment, manifest and APK signing.
The final build reports no repository changes during its run.

| Input/artifact | SHA-256 |
| --- | --- |
| Signed APK, 18,244,452 bytes | `5016FB72B1C8C9FE06C969FEF9B11F9C185BC8ED8079E947CDEAEB1B1D455AE6` |
| Build producer `setup.ps1` | `DC5F0194B7FBDFA85B8E42E5546874310EE260E1197C2E5C0FAA782708F99357` |
| Root provenance manifest | `84C0F4B359DEAAC137D9225FBE7AA12F519E609830014F6B9A53DCF3B49EFDB9` |
| Generated managed host | `F46A27547729E2F01C8F911C8AF304433C546AD1CDFAB8C0685216A0B44FCBCB` |
| Diagnostic AndroidCanvas module | `07F4B66B5A460A59790FED83E3A7F394565F07163A68926FAD506F098D69EFCB` |
| Hardware probe profile | `D3A9CD9B9922DA2832FAC7180586C7EFE4A446B7F2511403DFEAA5FDE85837DF` |

JNI is pinned at libnativehelper `af5fd77f9cb6b30654e4812b03d0b49495520a06`.
Step 1 derives its 233 pointer entries and checks every generated probe slot
without executing the module. Surface and Canvas contracts are pinned at
frameworks/base `299fe6f5d6fc6f1af7c3411dcf4e5efdf7217368`; exact file hashes
and paths are in `lib/manifest.json`.

The font is Fluent System Icons at
`microsoft/fluentui-system-icons@a563cf9166f4f91aa617557ed272612b7f0a2f72`,
`fonts/FluentSystemIcons-Regular.ttf`, SHA-256
`C5DAB901C52362ECC94D3A1D2C88A5C060464EB9EB58BB5B0D64D17066AF4D7F`.
Its pinned JSON map has SHA-256
`E4191934F1CD21EF4E88C34084D98E1E8DC1AC2598DA7BD0C66637B23C27D84B`
and maps U+F6AA to `ic_fluent_settings_24_regular`. This receipt proves that
glyph, not console font metrics or shaping. Cascadia Mono admission remains open.

## Platform and result

- x86-64 Android emulator, API 36, launched with `-gpu host`.
- HWUI renderer setting: `skiagl`.
- SurfaceFlinger GLES backend: Google (Intel), Android Emulator OpenGL ES
  Translator (Intel Iris Xe Graphics), OpenGL ES 3.0 (host OpenGL 4.5).
- No Xamarin, DEX or browser renderer. NativeContentView remains the content view.
- Every submitted frame uses `Surface.lockHardwareCanvas`, reports
  `Canvas.isHardwareAccelerated=True`, covers the surface and posts it.
  RGBA8888 geometry is selected; hardware Surface references are reused until
  window destruction and released there. No software acquisition is used.
- 13 hardware frames; zero extra frames during 10 seconds idle; one frame
  after a native input event. Sizes 1080x2400 and 900x1600 both render.
- Window loss/recreation produces a release marker and subsequent valid frames.
- Four independent PNG captures pass 16 checks each: eight palette colors,
  nested translated clipping/restoration, rounded geometry and pinned glyph pixels.
  The decoder is Pillow 12.3.0 from the bundled workspace runtime, not the renderer.
- `Get-ChildItem` finds the staged module; `ConvertTo-Json` and
  `ConvertFrom-Json` round-trip its name. Host command admission and profile
  invocation finish with `RunPowerShell returned 0x50575348`.
- The same process remains alive 40 seconds after resume/result; no app crash
  messages, associated native tombstone records or JNI error messages occur.
- The runner preserves previous profiles in private staging and byte-exact PC
  backups, then restores their original names. The display override is restored.

Local evidence is under `build/p1-x64-104-optout/`: `receipt.json`,
`pixel-check.json`, the retained independent pixel verifier and four PNGs.
These generated files are ignored by Git. The reproducible transport is
`tools/Invoke-HardwareCanvasProbe.ps1`; pass the signed development APK,
the pinned font and `-Resize`.

An arm32 candidate is also built through all nine steps, with the same managed
host hash: 17,233,844 bytes, APK SHA-256
`F5F60421668B6648C47791215F4AEBB40C47DB962F453443835B93F082C44ADD`,
under `build/p1-arm32-candidate/`. No arm32 endpoint was attached at this
observation, so it has build evidence only. Current arm64 device evidence is
also unavailable.

## Baseline and dependency correction

Acquisition/draw/post medians across the 13 diagnostic submissions are
3.409 / 90.455 / 3.648 ms. Ranges are 0.502-73.538 / 28.586-535.228 /
1.576-29.729 ms. These include cold initialization and window recreation.
They measure CPU acquisition, interpreted drawing and posting, not GPU execution
or input-to-photon latency. Production submission must be lowered to managed IL;
this script baseline is not a production performance claim.

The 102-image candidate failed before profile execution because Utility could
not load `Microsoft.PowerShell.MarkdownRender 7.2.1.0`. The pinned Utility
package's AssemblyRef and nuspec identify MarkdownRender 7.2.1 and Markdig.Signed
1.3.2. Both packages match NuGet catalog SHA-512 values recorded in the manifest.

| Added image | Selected DLL bytes |
| --- | ---: |
| `Microsoft.PowerShell.MarkdownRender.dll` | 28,096 |
| `Markdig.Signed.dll` (`net10.0`) | 493,568 |

With the preceding host held unchanged, the signed x86-64 APK grew from
18,035,333 to 18,244,366 bytes: 209,033 bytes (204.13 KiB). The mapped store
library grew by 521,824 bytes (509.59 KiB). The subsequent telemetry guard
changes the final APK to 18,244,452 bytes. Dependency-specific startup and
resident-memory costs were not measured.

A short telemetry-enabled command probe subsequently aborted on the background
Android TLS path. Its initial acceptance was invalidated; a first frame and
short liveness window were insufficient. The host now sets
`POWERSHELL_TELEMETRY_OPTOUT=1` before invoking its SMA entry method. The shipped
SMA's informational version identifies PowerShell commit
`1481b98f0079f979f658e49a7281024cc754049b`; its admitted `Telemetry.cs:178-207`
returns before client creation when opted out. The final fixture verifies both
`CanSendTelemetry=False` and an absent telemetry client.

This does not initialize Android crypto or prove hashing/TLS. Java-side crypto
loading, cryptographic commands, interactive asynchronous sessions, IME,
managed recovery, installed startup and current arm64/arm32 receipts remain open.
The full static closure diagnostic also retains unresolved/optional paths;
this receipt establishes only the commands and runtime paths listed above.
