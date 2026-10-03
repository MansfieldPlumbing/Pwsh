<#
.SYNOPSIS
Converts indented dumpsys output into nested objects.
.DESCRIPTION
Indentation defines nesting. A line "name: value" or "name=value" becomes a property; a node whose children are all plain lines becomes a string array; repeated names become an array. Limitation: a line holding several pairs ("a=1 b=2") becomes one property named after the first key, with the rest of the line as its value.
.EXAMPLE
dumpsys deviceidle | ConvertFrom-DumpsysTree
.NOTES
Ported from github.com/MansfieldPlumbing/subsystem at 2c8dd80454a46db0174fe5d6cf5cec4e64e1d9fb, src/runspace/scripts/zoo/ConvertFrom-DumpsysTree.ps1.
Change from the source: InputObject allows empty strings, so blank lines from native command output bind instead of failing (in ConvertFrom-KeyValue they end a record, as documented).
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
    [AllowEmptyString()]
    [string[]]$InputObject
)

begin {
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($item in $InputObject) {
        if ($null -eq $item) { continue }
        foreach ($line in ($item -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $lines.Add($line)
            }
        }
    }
}

end {
    if ($lines.Count -eq 0) { return }

    # Define Node class-like structure using Hashtables
    # Node = @{ Indent = int; Name = string; Value = string; IsKeyValue = bool; RawText = string; Children = List }
    
    $root = [ordered]@{
        Indent = -1
        Name = 'Root'
        Value = $null
        IsKeyValue = $false
        RawText = ''
        Children = [System.Collections.Generic.List[object]]::new()
    }

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($root)

    foreach ($line in $lines) {
        # Calculate indentation
        $line -match '^(\s*)' | Out-Null
        $indent = $Matches[1].Length
        $trimmed = $line.Trim()

        # Parse key-value structure
        $name = $trimmed
        $value = $null
        $isKeyValue = $false

        if ($trimmed -match '^([^=:]+?)\s*[:=]\s*(.*)$') {
            $name = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            $isKeyValue = $true
        }

        $node = [ordered]@{
            Indent = $indent
            Name = $name
            Value = $value
            IsKeyValue = $isKeyValue
            RawText = $trimmed
            Children = [System.Collections.Generic.List[object]]::new()
        }

        # Pop from stack until the top item has less indentation than current node
        while ($stack.Count -gt 0 -and $stack.Peek().Indent -ge $indent) {
            [void]$stack.Pop()
        }

        # Add current node as child of top item on stack
        if ($stack.Count -gt 0) {
            [void]$stack.Peek().Children.Add($node)
        }

        $stack.Push($node)
    }

    # Recursive function to build PSObjects from Nodes
    function Build-OutputNode($n) {
        if ($n.Children.Count -eq 0) {
            if ($n.IsKeyValue) {
                return $n.Value
            } else {
                return $n.RawText
            }
        }

        # Check if all children have no sub-children and are NOT key-values (a simple string list)
        $isSimpleList = $true
        foreach ($child in $n.Children) {
            if ($child.Children.Count -gt 0 -or $child.IsKeyValue) {
                $isSimpleList = $false
                break
            }
        }

        if ($isSimpleList) {
            $arr = [System.Collections.Generic.List[string]]::new()
            foreach ($child in $n.Children) {
                [void]$arr.Add($child.RawText)
            }
            return $arr.ToArray()
        }

        # Build as a nested object
        $obj = [ordered]@{}
        foreach ($child in $n.Children) {
            $childVal = Build-OutputNode $child
            $childKey = if ($child.Children.Count -gt 0) { $child.RawText.TrimEnd(':') } else { $child.Name }
            
            # If the property already exists, handle it (e.g. merge into an array)
            if ($obj.Contains($childKey)) {
                $existing = $obj[$childKey]
                if ($existing -is [System.Collections.ArrayList]) {
                    [void]$existing.Add($childVal)
                } else {
                    $list = [System.Collections.ArrayList]::new()
                    [void]$list.Add($existing)
                    [void]$list.Add($childVal)
                    $obj[$childKey] = $list
                }
            } else {
                $obj[$childKey] = $childVal
            }
        }
        return [pscustomobject]$obj
    }

    # Build and emit from root's children
    $finalObj = Build-OutputNode $root
    $finalObj
}
