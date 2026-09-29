# Optional add-ons

This directory is the admission boundary for optional host-side capabilities.
An add-on is not part of the APK, the minimal PowerShell payload or the build
graph merely because its source is present here.

Each admitted add-on gets its own directory and must provide:

- a PowerShell entry point and a narrow capability description;
- immutable upstream provenance and SHA-256 pins for every imported file;
- its applicable license and third-party notices;
- tests that do not require the add-on to be enabled in a normal build; and
- an explicit `$script:StepGraph` node before `setup.ps1` invokes it.

Add-ons must not compile or load embedded C# through `Add-Type`, depend on an
unvetted executable from the machine, print device identifiers, or silently
broaden the APK's permissions. Native access follows the same pinned-source,
named-encoder and hardware-receipt gates as the rest of Pwsh.

Planned candidates are a direct USB ADB host client and USB accessory-mode
transport. Their source remains external until the exact reviewed bytes exist
at an immutable pushed revision.
