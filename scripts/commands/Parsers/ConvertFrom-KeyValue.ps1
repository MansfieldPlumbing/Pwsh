<#
.SYNOPSIS
Converts key/value text into objects.
.DESCRIPTION
Accepts "[key]: [value]" lines (getprop), "key: value" and "key=value". A blank line ends a record; each record becomes one object, or one Key/Value object per pair with -AsKeyValuePair. Lines with no separator are ignored; a repeated key in one record keeps the last value.
.EXAMPLE
getprop | ConvertFrom-KeyValue
.NOTES
Ported from github.com/MansfieldPlumbing/subsystem at 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb, src/runspace/scripts/zoo/ConvertFrom-KeyValue.ps1.
Change from the source: InputObject allows empty strings, so blank lines from native command output bind instead of failing (in ConvertFrom-KeyValue they end a record, as documented).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$InputObject,
    
    [Parameter()]
    [switch]$AsKeyValuePair
)

begin {
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $currentBlock = [ordered]@{}
    $hasData = $false
}

process {
    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        foreach ($line in ($item -split "\r?\n")) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($hasData) {
                    if ($AsKeyValuePair) {
                        foreach ($key in $currentBlock.Keys) {
                            $results.Add([pscustomobject]@{ Key = $key; Value = $currentBlock[$key] })
                        }
                    } else {
                        $results.Add([pscustomobject]$currentBlock)
                    }
                    $currentBlock = [ordered]@{}
                    $hasData = $false
                }
                continue
            }
            
            # Match [key]: [value] (e.g. getprop)
            if ($line -match '^\s*\[([^\]]+)\]:\s*\[(.*)\]\s*$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                $currentBlock[$key] = $val
                $hasData = $true
            }
            # Match key: value or key=value
            elseif ($line -match '^\s*([^=:]+?)\s*[:=]\s*(.*)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                $currentBlock[$key] = $val
                $hasData = $true
            }
        }
    }
}

end {
    if ($hasData) {
        if ($AsKeyValuePair) {
            foreach ($key in $currentBlock.Keys) {
                $results.Add([pscustomobject]@{ Key = $key; Value = $currentBlock[$key] })
            }
        } else {
            $results.Add([pscustomobject]$currentBlock)
        }
    }
    $results
}
