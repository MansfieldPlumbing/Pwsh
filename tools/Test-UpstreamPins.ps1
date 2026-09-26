#requires -Version 7.0
<#
.SYNOPSIS
Checks that every pinned upstream address in lib/manifest.json still serves
the bytes its digest names.

.DESCRIPTION
Run when a pin is added or changed. For each source with a url, fetches the
address (decoding gitiles' base64 transport), hashes the bytes, and compares
them with the pinned SHA-256. Writes nothing.

Exit code 0: every address served its pinned bytes.
Exit code 1: at least one address served different bytes (a provenance failure).
Exit code 2: no mismatch, but at least one address could not be reached, so
             those pins are unverified, not failed.

.EXAMPLE
pwsh -NoProfile -File tools/Test-UpstreamPins.ps1
#>
[CmdletBinding()]
param([int]$TimeoutSeconds = 30)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $root 'lib/manifest.json') -Raw | ConvertFrom-Json -Depth 32
if ([int]$manifest.schemaVersion -ne 1) { throw "Unsupported manifest schema version $($manifest.schemaVersion)." }

$rows = foreach ($pin in @($manifest.sources | Where-Object { $null -ne $_.url })) {
    $url = [string]$pin.url
    if (-not $url.StartsWith('https://', [StringComparison]::Ordinal)) { throw "Source '$($pin.path)' declares a non-HTTPS address." }
    $transport = if ($pin.PSObject.Properties['transport']) { [string]$pin.transport } else { '' }
    if ($transport -and ($transport -cne 'gitiles-base64' -or -not $url.StartsWith('https://android.googlesource.com/', [StringComparison]::Ordinal))) {
        throw "Source '$($pin.path)' declares transport '$transport', allowed only as 'gitiles-base64' for android.googlesource.com."
    }
    $status = 'Unavailable'; $detail = ''
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec $TimeoutSeconds
        if ([int]$response.StatusCode -ne 200) {
            $detail = "HTTP $([int]$response.StatusCode)"
        } else {
            $bytes = $response.RawContentStream.ToArray()
            if ($transport -ceq 'gitiles-base64') { $bytes = [Convert]::FromBase64String([Text.Encoding]::ASCII.GetString($bytes).Trim()) }
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
            if ($hash -ceq [string]$pin.sha256) { $status = 'Pass' } else { $status = 'Mismatch'; $detail = "served $hash" }
        }
    } catch {
        $detail = $_.Exception.Message.Split("`n")[0]
    }
    [pscustomobject]@{ Status = $status; Path = [string]$pin.path; Detail = $detail }
}

$rows | Format-Table -AutoSize | Out-String -Width 200
$counts = $rows | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
"Checked=$(@($rows).Count) $($counts -join ' ')"
if (@($rows | Where-Object Status -eq 'Mismatch').Count) { exit 1 }
if (@($rows | Where-Object Status -eq 'Unavailable').Count) { exit 2 }
exit 0
