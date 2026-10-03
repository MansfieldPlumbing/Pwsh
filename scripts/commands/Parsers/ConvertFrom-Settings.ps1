<#
.SYNOPSIS
Converts "key=value" lines into Key/Value objects.
.DESCRIPTION
Splits each line at its first "=". Lines without "=" or with an empty key are ignored. Intended for "settings list <namespace>" output.
.EXAMPLE
settings list system | ConvertFrom-Settings
.NOTES
Ported from github.com/MansfieldPlumbing/subsystem at 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb, src/runspace/scripts/zoo/ConvertFrom-Settings.ps1.
Change from the source: InputObject allows empty strings, so blank lines from native command output bind instead of failing (in ConvertFrom-KeyValue they end a record, as documented).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$InputObject
)

begin {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
}

process {
    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        foreach ($line in ($item -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $idx = $line.IndexOf('=')
            if ($idx -gt 0) {
                $key = $line.Substring(0, $idx).Trim()
                $val = $line.Substring($idx + 1).Trim()
                $results.Add([pscustomobject]@{ Key = $key; Value = $val })
            }
        }
    }
}

end {
    $results
}
