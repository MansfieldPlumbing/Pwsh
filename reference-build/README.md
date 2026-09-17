# Temporary reference build

This project is a disposable MSBuild baseline pinned to PowerShell
`7.7.0-preview.4`. It exists only to resolve and inspect the reference package
closure and to provide comparison artifacts for the autonomous `setup.ps1`
pipeline. It is not part of the final API-to-APK build path.

Build both controlled variants from this directory:

```powershell
dotnet publish .\Terminal.Reference.csproj -c Slim -r android-arm64
dotnet publish .\Terminal.Reference.csproj -c R2R -r android-arm64
```

`Slim` excludes ReadyToRun and is the intended autonomous-pipeline target.
`R2R` changes only the ReadyToRun setting and exists as a comparison baseline.
