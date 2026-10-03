<#
.SYNOPSIS
Converts whitespace-separated columns into objects.
.DESCRIPTION
The first line after -Skip is the header unless -Header is given. Every line is trimmed and split on runs of whitespace; the last column receives the rest of the line. Limitation: a header or a non-final value containing a space misaligns the columns (for example the "Mounted on" header of df); pass -Header with single-word names for such output.
.EXAMPLE
ps -A | ConvertFrom-Table
.NOTES
Ported from github.com/MansfieldPlumbing/subsystem at 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb, src/runspace/scripts/zoo/ConvertFrom-Table.ps1.
Change from the source: InputObject allows empty strings, so blank lines from native command output bind instead of failing (in ConvertFrom-KeyValue they end a record, as documented).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$InputObject,
    
    [Parameter()]
    [string[]]$Header,
    
    [Parameter()]
    [int]$Skip = 0
)

begin {
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        foreach ($line in ($item -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line.Trim())
            }
        }
    }
}

end {
    if ($lines.Count -eq 0) { return }
    
    $startIndex = $Skip
    if ($null -eq $Header -or $Header.Count -eq 0) {
        if ($lines.Count -le $Skip) { return }
        $headerLine = $lines[$Skip]
        $Header = $headerLine -split '\s+'
        $startIndex = $Skip + 1
    }
    
    for ($i = $startIndex; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $parts = $line -split '\s+'
        $obj = [ordered]@{}
        for ($j = 0; $j -lt $Header.Count; $j++) {
            $colName = $Header[$j]
            if ($j -lt $parts.Count) {
                if ($j -eq ($Header.Count - 1)) {
                    # For the last column, if there are remaining parts, join them
                    $obj[$colName] = ($parts[$j..($parts.Count - 1)] -join ' ')
                } else {
                    $obj[$colName] = $parts[$j]
                }
            } else {
                $obj[$colName] = $null
            }
        }
        [pscustomobject]$obj
    }
}
