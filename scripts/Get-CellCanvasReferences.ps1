#requires -Version 7.0
[CmdletBinding()]
param()

# Parse the frozen workload without executing it or loading Xamarin. This is
# the syntactic admission list; metadata resolution and baseline tracing are
# separate evidence gates, especially for members reached through $edge.
$path = Join-Path $PSScriptRoot 'CellCanvas.ps1'
$expected = '8E96992365A72E81B1A1EEB518AE9052020519EA175EC5465BAC4A989928F3B9'
$actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
if ($actual -cne $expected) { throw 'CellCanvas differs from the frozen workload.' }
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'The frozen workload did not parse.' }

$types = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.TypeExpressionAst] -or
    $node -is [Management.Automation.Language.TypeConstraintAst]
}, $true) | Where-Object { $_.TypeName.FullName -match '^(Android|Java)\.' } |
    ForEach-Object { $_.TypeName.FullName } | Sort-Object -Unique)

$members = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.MemberExpressionAst]
}, $true) | ForEach-Object {
    $node = $_
    $type = if ($node.Expression -is [Management.Automation.Language.TypeExpressionAst]) {
        $node.Expression.TypeName.FullName
    } else { $null }
    [pscustomobject][ordered]@{
        Line = $node.Extent.StartLineNumber
        Column = $node.Extent.StartColumnNumber
        Receiver = $node.Expression.Extent.Text
        Member = if ($node.Member -is [Management.Automation.Language.StringConstantExpressionAst]) {
            $node.Member.Value
        } else { $null }
        StaticType = $type
        Kind = if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) { 'Call' } else { 'Member' }
        ArgumentCount = if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
            $node.Arguments.Count
        } else { $null }
        Resolution = if ($type -match '^(Android|Java)\.') { 'RequiresMetadata' } else { 'RequiresReceiverAnalysis' }
    }
})

[pscustomobject][ordered]@{
    SchemaVersion = 1
    Workload = 'scripts/CellCanvas.ps1'
    Sha256 = $actual
    Evidence = 'Parsed syntax only; not overload resolution or execution coverage.'
    Types = $types
    # Include all receiver chains rather than silently dropping members whose
    # Android origin is hidden by PowerShell objects and mutable state.
    MemberSites = $members
}
