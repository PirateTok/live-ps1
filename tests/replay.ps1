#!/usr/bin/env pwsh
# Replay test: run binary WSS captures through the full decode pipeline and assert every
# value in the manifest (counts, sub-routing, like accumulator, gift streaks).
# Missing testdata is a failure. Roots: $env:PIRATETOK_TESTDATA, testdata/, ../live-testdata
# (manifests in manifests/ or captures/manifests/).
# Usage: pwsh tests/replay.ps1   (from the live-ps1 root)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../PirateTok.Live.psd1') -Force
$module = Get-Module PirateTok.Live

function Find-Capture([string]$Name, [string]$Suffix) {
    $roots = @($env:PIRATETOK_TESTDATA, 'testdata', '../live-testdata') | Where-Object { $_ }
    foreach ($root in $roots) {
        $cap = Join-Path $root "captures/$Name$Suffix.bin"
        foreach ($dir in 'manifests', 'captures/manifests') {
            $man = Join-Path $root "$dir/$Name.json"
            if ((Test-Path -LiteralPath $cap) -and (Test-Path -LiteralPath $man)) { return @($cap, $man) }
        }
    }
    return $null
}

function Read-Capture([string]$Path) {
    $data = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path))
    $frames = [System.Collections.Generic.List[byte[]]]::new()
    $pos = 0
    while ($pos + 4 -le $data.Length) {
        $len = [BitConverter]::ToUInt32($data, $pos); $pos += 4
        if ($pos + $len -gt $data.Length) { throw "truncated frame at offset $($pos - 4)" }
        $frame = [byte[]]::new($len); [Array]::Copy($data, $pos, $frame, 0, $len); $pos += $len
        $frames.Add($frame)
    }
    return , $frames.ToArray()
}

function Add-Count([hashtable]$Map, [string]$Key) { $Map[$Key] = 1 + [int]$Map[$Key] }

function Invoke-Replay([byte[][]]$Frames) {
    & $module {
        param($Frames)
        $r = @{ frame_count = $Frames.Count; message_count = 0; event_count = 0; decode_failures = 0
            decompress_failures = 0; payload_types = @{}; message_types = @{}; event_types = @{}; unknown_types = @{}
            sub = @{ follow = 0; share = 0; join = 0; live_ended = 0 }; likes = [System.Collections.Generic.List[object]]::new()
            gifts = [ordered]@{}; combo = 0; non_combo = 0; finals = 0; negative = 0 }
        $likeAcc = New-TikTokLikeAccumulator
        $tracker = New-TikTokGiftStreakTracker
        $subKey = @{ Follow = 'follow'; Share = 'share'; Join = 'join'; LiveEnded = 'live_ended' }
        foreach ($raw in $Frames) {
            try { $frame = ConvertFrom-TikTokProto 'WebcastPushFrame' $raw }
            catch [System.Management.Automation.MethodInvocationException] { $r.decode_failures++; continue }
            $ptype = "$($frame.payload_type)"
            $r.payload_types[$ptype] = 1 + [int]$r.payload_types[$ptype]
            if ($ptype -ne 'msg') { continue }
            try { $payload = Expand-TikTokGzip $frame.payload }
            catch [System.Management.Automation.MethodInvocationException] { $r.decompress_failures++; continue }
            try { $resp = ConvertFrom-TikTokProto 'PsWebcastResponse' $payload }
            catch [System.Management.Automation.MethodInvocationException] { $r.decode_failures++; continue }
            foreach ($msg in $resp.messages) {
                $r.message_count++
                $r.message_types[$msg.type] = 1 + [int]$r.message_types[$msg.type]
                foreach ($evt in (ConvertTo-TikTokEvents -Method $msg.type -Payload $msg.payload)) {
                    $r.event_count++
                    $r.event_types[$evt.Type] = 1 + [int]$r.event_types[$evt.Type]
                    if ($subKey.ContainsKey($evt.Type)) { $r.sub[$subKey[$evt.Type]]++ }
                    if ($evt.Type -eq 'Unknown') { $r.unknown_types[$evt.Method] = 1 + [int]$r.unknown_types[$evt.Method] }
                    if ($evt.Type -eq 'Like') {
                        $s = $likeAcc.Process($evt.Data)
                        $r.likes.Add(@{ wire_count = [long]$evt.Data.count; wire_total = [long]$evt.Data.total
                            acc_total = $s.TotalLikeCount; accumulated = $s.AccumulatedCount; went_backwards = $s.WentBackwards })
                    }
                    if ($evt.Type -eq 'Gift') {
                        $g = $evt.Data
                        if (Test-TikTokComboGift $g) { $r.combo++ } else { $r.non_combo++ }
                        $s = $tracker.Process($g)
                        if ($s.IsFinal) { $r.finals++ }
                        if ($s.EventGiftCount -lt 0) { $r.negative++ }
                        $key = "$($g.group_id)"
                        if (-not $r.gifts.Contains($key)) { $r.gifts[$key] = [System.Collections.Generic.List[object]]::new() }
                        $r.gifts[$key].Add(@{ gift_id = [long]$g.gift_id; repeat_count = [long]$g.repeat_count
                            delta = $s.EventGiftCount; is_final = $s.IsFinal; diamond_total = $s.TotalDiamondCount })
                    }
                }
            }
        }
        return $r
    } $Frames
}

$script:failures = [System.Collections.Generic.List[string]]::new()
$script:assertions = 0
function Assert-Eq($Got, $Expected, [string]$Label) {
    $script:assertions++
    if ("$Got" -ne "$Expected") { $script:failures.Add("$Label`: got $Got, expected $Expected") }
}
function Assert-MapEq([hashtable]$Got, $Expected, [string]$Label) {
    $exp = @{}; foreach ($p in $Expected.PSObject.Properties) { $exp[$p.Name] = $p.Value }
    foreach ($k in $exp.Keys) { Assert-Eq $Got[$k] $exp[$k] "$Label[$k]" }
    foreach ($k in $Got.Keys) { if (-not $exp.ContainsKey($k)) { $script:failures.Add("$Label`: unexpected key $k = $($Got[$k])") } }
}

function Test-Replay($r, $m, [string]$n) {
    foreach ($f in 'frame_count', 'message_count', 'event_count', 'decode_failures', 'decompress_failures') { Assert-Eq $r[$f] $m.$f "$n`: $f" }
    Assert-MapEq $r.payload_types $m.payload_types "$n`: payload_types"
    Assert-MapEq $r.message_types $m.message_types "$n`: message_types"
    Assert-MapEq $r.event_types $m.event_types "$n`: event_types"
    foreach ($k in 'follow', 'share', 'join', 'live_ended') { Assert-Eq $r.sub[$k] $m.sub_routed.$k "$n`: sub_routed.$k" }
    Assert-MapEq $r.unknown_types $m.unknown_types "$n`: unknown_types"

    $ml = $m.like_accumulator
    Assert-Eq $r.likes.Count $ml.event_count "$n`: like event_count"
    Assert-Eq @($r.likes | Where-Object { $_.went_backwards }).Count $ml.backwards_jumps "$n`: like backwards_jumps"
    if ($r.likes.Count -gt 0) {
        Assert-Eq $r.likes[-1].acc_total $ml.final_max_total "$n`: like final_max_total"
        Assert-Eq $r.likes[-1].accumulated $ml.final_accumulated "$n`: like final_accumulated"
    }
    $accMono = $true; $sumMono = $true
    for ($i = 1; $i -lt $r.likes.Count; $i++) {
        if ($r.likes[$i].acc_total -lt $r.likes[$i - 1].acc_total) { $accMono = $false }
        if ($r.likes[$i].accumulated -lt $r.likes[$i - 1].accumulated) { $sumMono = $false }
    }
    Assert-Eq $accMono $ml.acc_total_monotonic "$n`: like acc_total_monotonic"
    Assert-Eq $sumMono $ml.accumulated_monotonic "$n`: like accumulated_monotonic"
    Assert-Eq $r.likes.Count @($ml.events).Count "$n`: like events length"
    for ($i = 0; $i -lt [Math]::Min($r.likes.Count, @($ml.events).Count); $i++) {
        $got = $r.likes[$i]; $exp = $ml.events[$i]
        foreach ($f in 'wire_count', 'wire_total', 'acc_total', 'accumulated', 'went_backwards') { Assert-Eq $got[$f] $exp.$f "$n`: like[$i].$f" }
    }

    $mg = $m.gift_streaks
    Assert-Eq ($r.combo + $r.non_combo) $mg.event_count "$n`: gift event_count"
    Assert-Eq $r.combo $mg.combo_count "$n`: gift combo_count"
    Assert-Eq $r.non_combo $mg.non_combo_count "$n`: gift non_combo_count"
    Assert-Eq $r.finals $mg.streak_finals "$n`: gift streak_finals"
    Assert-Eq $r.negative $mg.negative_deltas "$n`: gift negative_deltas"
    $groups = @($mg.groups.PSObject.Properties)
    Assert-Eq $r.gifts.Count $groups.Count "$n`: gift groups count"
    foreach ($gid in $r.gifts.Keys) {
        $exp = $mg.groups.$gid
        if ($null -eq $exp) { $script:failures.Add("$n`: missing gift group $gid in manifest"); continue }
        Assert-Eq $r.gifts[$gid].Count @($exp).Count "$n`: gift group $gid length"
        for ($i = 0; $i -lt [Math]::Min($r.gifts[$gid].Count, @($exp).Count); $i++) {
            foreach ($f in 'gift_id', 'repeat_count', 'delta', 'is_final', 'diamond_total') {
                Assert-Eq $r.gifts[$gid][$i][$f] $exp[$i].$f "$n`: gift[$gid][$i].$f"
            }
        }
    }
}

$pass = 0; $fail = 0
foreach ($suffix in '', '_raw') {
    foreach ($name in 'calvinterest6', 'happyhappygaltv', 'fox4newsdallasfortworth') {
        $label = "$name$suffix"
        $paths = Find-Capture $name $suffix
        if (-not $paths) { Write-Host "FAIL $label`: no testdata (set PIRATETOK_TESTDATA or clone live-testdata)"; $fail++; continue }
        Write-Host "LOAD $label <- $($paths[0]) + $($paths[1])"
        $script:failures.Clear(); $script:assertions = 0
        $manifest = Get-Content -LiteralPath $paths[1] -Raw | ConvertFrom-Json
        $result = Invoke-Replay (Read-Capture $paths[0])
        Test-Replay $result $manifest $label
        if ($script:failures.Count -eq 0) { Write-Host "OK   $label ($script:assertions assertions)"; $pass++ }
        else { $script:failures | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }; Write-Host "FAIL $label ($($script:failures.Count) failures)"; $fail++ }
    }
}
Write-Host "`n--- $pass passed, $fail failed ---"
if ($fail -gt 0 -or $pass -eq 0) { exit 1 }
