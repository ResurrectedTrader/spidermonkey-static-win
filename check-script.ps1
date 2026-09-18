<#
.SYNOPSIS
  Static check of a build script: does it parse, and does every command it calls
  actually exist?

.DESCRIPTION
  A PowerShell script only fails on a misspelled or non-existent function when
  that line runs. In a build script the interesting lines run deep into an hour
  of work on a CI runner, which is an expensive place to discover a typo. This
  walks the AST instead and reports any command that is neither defined in the
  file nor resolvable on this machine.

  Commands invoked through a variable (`& $python`) carry no name in the AST and
  are skipped - nothing can be checked about them statically.

.PARAMETER Path
  The script to check.

.PARAMETER Known
  External tools that legitimately are not installed yet when the check runs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string[]]$Known = @()
)

$errors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $Path).Path, [ref]$tokens, [ref]$errors)

if ($errors) {
    Write-Host "does not parse:" -ForegroundColor Red
    $errors | ForEach-Object { Write-Host ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    exit 1
}

$defined = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    ForEach-Object { $_.Name }

$calls = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.CommandAst] }, $true)

$bad = @()
foreach ($c in $calls) {
    $name = $c.GetCommandName()
    if (-not $name)                { continue }
    if ($defined -contains $name)  { continue }
    if ($Known   -contains $name)  { continue }
    if (Get-Command $name -ErrorAction SilentlyContinue) { continue }
    $bad += "  line {0}: {1}" -f $c.Extent.StartLineNumber, $name
}

if ($bad) {
    Write-Host "calls commands that do not exist:" -ForegroundColor Red
    $bad | Sort-Object -Unique | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host ("{0}: parses, {1} functions, {2} command names all resolve" -f `
    (Split-Path $Path -Leaf), $defined.Count, $calls.Count) -ForegroundColor Green
