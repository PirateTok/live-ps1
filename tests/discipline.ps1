#!/usr/bin/env pwsh
# Discipline scanner: R1 (800 LOC max per file, 900 for protobuf schema/codec files),
# R2 (no silent error suppression: empty catch, SilentlyContinue, 2>$null).
# Usage: pwsh tests/discipline.ps1   (from the live-ps1 root)

$root = Join-Path $PSScriptRoot '..'
$violations = [System.Collections.Generic.List[string]]::new()
$files = Get-ChildItem -LiteralPath $root -Recurse -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object { $_.FullName -notmatch '[\\/](testdata|\.git)[\\/]' }
foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName
    $rel = $f.FullName.Substring((Resolve-Path $root).Path.Length).TrimStart('\', '/')
    $limit = if ($f.Name -in 'Schemas.ps1', 'Codec.ps1') { 900 } else { 800 }
    if ($lines.Count -gt $limit) { $violations.Add("$rel`: R1 $($lines.Count) lines > $limit") }
    if ($f.Name -eq 'discipline.ps1') { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match 'catch\s*(\[[^\]]+\]\s*)?\{\s*\}') { $violations.Add("$rel`:$($i + 1): R2 empty catch") }
        if ($l -match 'SilentlyContinue|Ignore\b') { $violations.Add("$rel`:$($i + 1): R2 suppressed error action") }
        if ($l -match '2>\s*\$null') { $violations.Add("$rel`:$($i + 1): R2 stderr discarded") }
    }
}
if ($violations.Count -gt 0) { $violations | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host "discipline: all $($files.Count) files pass"
