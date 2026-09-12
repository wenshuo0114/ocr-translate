# ASCII-only launcher. Windows PowerShell 5.1 reads this file as ANSI safely.
# Then it loads OcrTranslate.ps1 as UTF-8, so Chinese UI does not break.
$ErrorActionPreference = "Stop"
$p = Join-Path $PSScriptRoot "OcrTranslate.ps1"
if (-not (Test-Path -LiteralPath $p)) { throw "Missing OcrTranslate.ps1" }
$body = Get-Content -LiteralPath $p -Encoding UTF8 -Raw
$prefix = @"
`$PSScriptRoot = '$($PSScriptRoot.Replace("'","''"))'
`$PSCommandPath = '$($p.Replace("'","''"))'
"@
& ([ScriptBlock]::Create($prefix + "`r`n" + $body))
