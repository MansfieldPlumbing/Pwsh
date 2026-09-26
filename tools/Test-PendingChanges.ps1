#requires -Version 7.0
<#
.SYNOPSIS
Refuses changes that add secrets, key files or personal data.

.DESCRIPTION
Scans only added lines. With no switch it scans the working tree against HEAD
plus untracked files. With -PrePush it reads git's pre-push lines from standard
input and scans every commit being pushed, one commit at a time, so content
added and later removed inside the pushed range is still caught.

Findings name the rule and path:line only; the matched text is never printed.
Exit code 1 means at least one finding.

.EXAMPLE
pwsh -NoProfile -File tools/Test-PendingChanges.ps1
#>
[CmdletBinding()]
param([switch]$PrePush)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Any failure refuses: a scan that did not run is not a pass.
trap { [Console]::Error.WriteLine("Refused: the scan failed: $_"); exit 1 }
Set-Location (git rev-parse --show-toplevel)

$rules = [ordered]@{
    PrivateKey = '-----BEGIN [A-Z ]*PRIVATE KEY'
    KnownToken = '\b(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_\w{20,}|xox[abpr]-[\w-]{10,}|sk-[A-Za-z0-9_-]{20,}|AIza[\w-]{35})'
    Assignment = '(?i)\b(password|passwd|pwd|secret|api[_-]?key|token|storepass|keypass)\b\s*[:=]\s*[''"][^''"$]{4,}'
    HomePath   = '(?i)\b[A-Z]:[\\/]+Users[\\/]+(?!Public\b)[^\\/\s''"]+|/home/[a-z_][\w-]*|/Users/(?!Shared\b)[A-Za-z][\w-]*'
    Email      = '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}'
    DeviceId   = '(?i)(adb\s+-s\s+(?![$\[])\S+|ro\.serialno|android[_]id|\bimei\b|iphone[s]ubinfo)'   # classes keep the rule from matching itself
    Base64Blob = '[A-Za-z0-9+/]{60,}={0,2}'
}
$keyFile = '(?i)\.(pfx|p12|jks|keystore|pem|key|snk|apk)$'
$findings = [System.Collections.Generic.List[string]]::new()

function Test-Line([string]$Where, [string]$Text) {
    foreach ($name in $rules.Keys) {
        if ($Text -notmatch $rules[$name]) { continue }
        # SHA digests are hex; they are pinned inputs, not secrets.
        if ($name -eq 'Base64Blob' -and $Matches[0] -match '^[0-9A-Fa-f]+$') { continue }
        $findings.Add("$name $Where")
    }
}

# Walks unified diff text (-U0) and tests each added line.
function Test-Diff([string[]]$Lines, [string]$Prefix) {
    $file = $null; $line = 0; $commit = $Prefix
    foreach ($l in $Lines) {
        if ($l -match '^commit ([0-9a-f]{40})$') { $commit = $Matches[1].Substring(0, 12) + ' '; continue }
        if ($l -match '^\+\+\+ (?:b/(.+)|/dev/null)$') {
            $file = $Matches[1]
            if ($file -and $file -match $keyFile) { $findings.Add("KeyFile $commit$file") }
            continue
        }
        if ($l -match '^Binary files .* and b/(.+) differ$' -and $Matches[1] -match $keyFile) {
            $findings.Add("KeyFile $commit$($Matches[1])"); continue
        }
        if ($l -match '^@@ -\S+ \+(\d+)') { $line = [int]$Matches[1]; continue }
        if ($file -and $l.StartsWith('+')) { Test-Line "$commit${file}:$line" $l.Substring(1); $line++ }
    }
}

$zero = '0' * 40
if ($PrePush) {
    # git writes one line per ref to standard input.
    foreach ($ref in [Console]::In.ReadToEnd().Split("`n", [StringSplitOptions]'RemoveEmptyEntries,TrimEntries')) {
        $local, $localSha, $remote, $remoteSha = -split $ref
        if (-not $localSha -or $localSha -eq $zero) { continue }   # branch deletion
        $range = @(if ($remoteSha -and $remoteSha -ne $zero) { "$remoteSha..$localSha" } else { $localSha; '--not'; '--remotes' })
        Test-Diff (git log -p -U0 --no-color --no-ext-diff --format='commit %H' @range) ''
    }
} else {
    Test-Diff (git diff HEAD -U0 --no-color --no-ext-diff) ''
    foreach ($path in (git ls-files --others --exclude-standard)) {
        if ($path -match $keyFile) { $findings.Add("KeyFile $path"); continue }
        $n = 0
        foreach ($text in [IO.File]::ReadLines((Join-Path $PWD $path))) { $n++; Test-Line "${path}:$n" $text }
    }
}

if ($findings.Count) {
    [Console]::Error.WriteLine("Refused: $($findings.Count) finding(s). Remove them, or bypass once with git push --no-verify after review.")
    $findings | Sort-Object -Unique | ForEach-Object { [Console]::Error.WriteLine("  $_") }
    exit 1
}
'No findings.'
