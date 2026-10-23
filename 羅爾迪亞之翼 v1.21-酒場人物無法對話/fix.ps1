#Requires -Version 5.1
<#
  羅爾迪亞之翼 v1.21 — 共通事件呼叫名稱修復工具

  獨立修復包：不依賴「遊戲解析」工作區的 scripts/ 或 output/。
  只修改 Data\MapData 下 18 個 .mps 的 23 個「以名稱呼叫共通事件」目標字串；
  不修改 Data\BasicData\CommonEvent.dat。

  選單：
    0 = 取消
    1 = 安裝修復（先 dry-run，再確認）
    2 = 卸載修復（還原安裝前的備份）
    3 = 檢查目前狀態（不改檔）

  非互動用法：
    powershell -File fix.ps1 -GameDir "<GAME_DIR>" -Action dry-run
    powershell -File fix.ps1 -GameDir "<GAME_DIR>" -Action install -Yes
    powershell -File fix.ps1 -GameDir "<GAME_DIR>" -Action uninstall -Yes
    powershell -File fix.ps1 -GameDir "<GAME_DIR>" -Action verify
#>

[CmdletBinding()]
param(
    [string]$GameDir,
    [ValidateSet('menu', 'dry-run', 'install', 'uninstall', 'verify', 'debug')]
    [string]$Action = 'menu',
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------- 常數
$SelfConfig = Join-Path $PSScriptRoot 'fix.config.txt'
if ($env:WOLF_FIX_BACKUP_ROOT) { $BackupRoot = $env:WOLF_FIX_BACKUP_ROOT }
else { $BackupRoot = Join-Path $PSScriptRoot 'backup' }

$ToolTitle = '羅爾迪亞之翼 v1.21 — 共通事件呼叫名稱修復'

# 只處理本次已確認的 18 張地圖；不掃描其他地圖，避免誤改。
$AffectedFiles = @(
    'Map035.mps',
    'Map038_2.mps',
    'Map038_4.mps',
    'Map038_9.mps',
    'Map038_A.mps',
    'Map038_A_1.mps',
    'Map043_A_A_A_A_A_7.mps',
    'Map043_A_A_A_A_A_A_3.mps',
    'Map043_A_A_A_A_A_A_4.mps',
    'Map043_A_A_A_A_A_A_5.mps',
    'Map043_A_A_A_A_A_A_A_A_7.mps',
    'Map050.mps',
    'Map058_1.mps',
    'Map123_2.mps',
    'Map132.mps',
    'Map137_6.mps',
    'Map180.mps',
    'Map201_A.mps'
)

# BAK 缺少時的最後手段：現行名稱 → 原版名稱。
# 正常情況會優先採用 Data\MapData - BAK 的同位置名稱。
$FallbackMap = @{
    '獲得回想'            = 'メモリースフィア入手'
    '蕾4'                 = 'レーン4'
    '蕾2'                 = 'レーン2'
    '獲得回想：賽爾菲娜1' = 'スフィア入手：ゼルフィナ1'
    '蕾設定2'             = 'レーン設定2'
    '獲得回想：蕾'        = 'スフィア入手：レーン'
    '蕾6'                 = 'レーン6'
    '蕾7'                 = 'レーン7'
    '賽爾菲娜設定'        = 'ゼルフィナ設定'
    '回想：使魔初回'      = 'スフィア：使い魔初回'
    '獲得回想：使い魔1'   = 'スフィア入手：使い魔1'
    '蕾1'                 = 'レーン1'
    '蕾3'                 = 'レーン3'
    '蕾5'                 = 'レーン5'
    '伊爾梅亞設定'        = 'イルメイア設定'
    'イリーザ：使魔2'     = 'イリーザ：使い魔2'
    'イリーザ：使魔'      = 'イリーザ：使い魔'
    '獲得回想：賽爾菲娜2' = 'スフィア入手：ゼルフィナ2'
}

$EventSig = [byte[]](0x6f, 0x39, 0x30, 0x00, 0x00)
$PageSig = [byte[]](0x79, 0xff, 0xff, 0xff, 0xff)

# ---------------------------------------------------------------- 基本工具
function Read-U32LE {
    param([byte[]]$Data, [int]$Offset)
    if ($Offset -lt 0 -or $Offset + 4 -gt $Data.Length) { throw "讀取超出範圍: $Offset" }
    return [BitConverter]::ToUInt32($Data, $Offset)
}

function Read-StringAt {
    param([byte[]]$Data, [int]$Offset)
    $len = Read-U32LE -Data $Data -Offset $Offset
    if ($len -lt 1 -or $len -gt 0x10000 -or $Offset + 4 + $len -gt $Data.Length) {
        throw "字串長度不合理: $len @ $Offset"
    }
    $raw = New-Object byte[] ($len - 1)
    if ($len -gt 1) { [Array]::Copy($Data, $Offset + 4, $raw, 0, $len - 1) }
    $text = [System.Text.Encoding]::UTF8.GetString($raw)
    return [PSCustomObject]@{
        Text   = $text
        Next   = $Offset + 4 + $len
        Length = $len
    }
}

function Find-Bytes {
    param([byte[]]$Data, [byte[]]$Pattern, [int]$Start = 0, [int]$End = -1)
    if ($End -lt 0 -or $End -gt $Data.Length) { $End = $Data.Length }
    $last = $End - $Pattern.Length
    for ($i = $Start; $i -le $last; $i++) {
        if ($Data[$i] -ne $Pattern[0]) { continue }
        $ok = $true
        for ($j = 1; $j -lt $Pattern.Length; $j++) {
            if ($Data[$i + $j] -ne $Pattern[$j]) { $ok = $false; break }
        }
        if ($ok) { return $i }
    }
    return -1
}

function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').ToUpper()
}

function Get-Sha256Text {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)) }
    finally { $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').ToUpper()
}

function Write-Manifest {
    param([string]$Path, $Manifest)
    $json = $Manifest | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- 格式解析
function Get-CallSites {
    param([byte[]]$Data)
    $result = New-Object System.Collections.ArrayList
    $i = 0
    $last = $Data.Length - 5
    while ($i -le $last) {
        $b0 = $Data[$i]
        if ($b0 -lt 0x02 -or $b0 -gt 0x0b) { $i++; continue }
        if ($Data[$i + 1] -ne 0x2c -or $Data[$i + 2] -ne 0x01 -or
            $Data[$i + 3] -ne 0x00 -or $Data[$i + 4] -ne 0x00) {
            $i++; continue
        }
        try {
            $sig = ('0x{0:X8}' -f ([uint32]$b0 -shl 24 -bor 0x002c0100))
            $q = $i + 5
            $target = Read-U32LE -Data $Data -Offset $q
            $q += 4
            $argCount = [int]$Data[$q]; $q++
            $options = @([int]$Data[$q], [int]$Data[$q + 1], [int]$Data[$q + 2]); $q += 3
            $numArgs = $argCount -band 0x0f
            $strArgs = $argCount -shr 4
            $q += 4 * ($numArgs + $strArgs)
            if (($options[2] -band 0x01) -ne 0) { $q += 4 }
            $q += 1
            $stringCount = [int]$Data[$q]; $q++
            if ($stringCount -lt 1 -or $stringCount -gt 8) { $i++; continue }
            $firstNameOffset = -1
            $firstName = ''
            $firstNameLength = 0
            for ($k = 0; $k -lt $stringCount; $k++) {
                $nameOffset = $q
                $s = Read-StringAt -Data $Data -Offset $q
                if ($k -eq 0) {
                    $firstNameOffset = $nameOffset
                    $firstName = $s.Text
                    $firstNameLength = $s.Length
                }
                $q = $s.Next
            }
            if ($q -ge $Data.Length -or $Data[$q] -ne 0x00) { $i++; continue }
            if ($firstNameOffset -lt 0) { $i++; continue }
            [void]$result.Add([PSCustomObject]@{
                Offset      = $i
                Signature   = $sig
                Target      = $target
                NameOffset  = $firstNameOffset
                NameLength  = $firstNameLength
                Name        = $firstName
                Index       = $result.Count
            })
        } catch {
            # 不是有效的呼叫命令，繼續找下一個 signature
        }
        $i++
    }
    return $result
}

function Get-CommonEventNames {
    param([byte[]]$Data)
    $magic = [byte[]](0x00, 0x57, 0x00, 0x00, 0x4f, 0x4c, 0x55, 0x46, 0x43, 0x00, 0x90)
    if ($Data.Length -lt 15) { throw 'CommonEvent.dat 太短' }
    for ($i = 0; $i -lt $magic.Length; $i++) {
        if ($Data[$i] -ne $magic[$i]) { throw 'CommonEvent.dat magic 不符' }
    }
    $count = Read-U32LE -Data $Data -Offset 11
    $names = New-Object 'System.Collections.Generic.HashSet[string]'
    $offset = 15
    for ($n = 0; $n -lt $count; $n++) {
        if ($offset -ge $Data.Length -or $Data[$offset] -ne 0x8e) {
            throw "CommonEvent 記錄簽章不符 @ $offset"
        }
        $nameLen = Read-U32LE -Data $Data -Offset ($offset + 16)
        if ($nameLen -lt 1 -or $offset + 20 + $nameLen -gt $Data.Length) {
            throw "CommonEvent 名稱長度不合理 @ $offset"
        }
        $raw = New-Object byte[] ($nameLen - 1)
        if ($nameLen -gt 1) { [Array]::Copy($Data, $offset + 20, $raw, 0, $nameLen - 1) }
        $name = [System.Text.Encoding]::UTF8.GetString($raw)
        [void]$names.Add($name)
        if ($n -eq $count - 1) { break }
        $idx = Find-Bytes -Data $Data -Pattern ([byte[]](0x92, 0x8e)) -Start ($offset + 20 + $nameLen)
        if ($idx -lt 0) { throw "CommonEvent 缺少結束簽章 @ $offset" }
        $offset = $idx + 1
    }
    return $names
}

function Get-EventsFingerprint {
    param([byte[]]$Data)
    $eventOffsets = New-Object System.Collections.ArrayList
    $i = 0
    while ($true) {
        $off = Find-Bytes -Data $Data -Pattern $EventSig -Start $i
        if ($off -lt 0) { break }
        [void]$eventOffsets.Add($off)
        $i = $off + 1
    }
    $lines = New-Object System.Collections.ArrayList
    for ($e = 0; $e -lt $eventOffsets.Count; $e++) {
        $off = [int]$eventOffsets[$e]
        $next = if ($e + 1 -lt $eventOffsets.Count) { [int]$eventOffsets[$e + 1] } else { $Data.Length - 1 }
        try {
            $q = $off + 5
            $id = Read-U32LE -Data $Data -Offset $q; $q += 4
            $evName = Read-StringAt -Data $Data -Offset $q; $q = $evName.Next
            $x = Read-U32LE -Data $Data -Offset $q
            $y = Read-U32LE -Data $Data -Offset ($q + 4)
            $pc = Read-U32LE -Data $Data -Offset ($q + 8)
            $q += 16
            [void]$lines.Add("E|$id|$($evName.Text)|$x|$y|$pc")
            $p = $q
            while ($true) {
                $poff = Find-Bytes -Data $Data -Pattern $PageSig -Start $p -End $next
                if ($poff -lt 0) { break }
                try {
                    $pq = $poff + 5
                    $icon = Read-StringAt -Data $Data -Offset $pq
                    $pq = $icon.Next
                    $trigger = [int]$Data[$pq + 4]
                    $ops = @([int]$Data[$pq + 5], [int]$Data[$pq + 6], [int]$Data[$pq + 7], [int]$Data[$pq + 8])
                    $vars = @()
                    $vals = @()
                    for ($k = 0; $k -lt 4; $k++) {
                        $vars += Read-U32LE -Data $Data -Offset ($pq + 9 + 4 * $k)
                        $vals += Read-U32LE -Data $Data -Offset ($pq + 25 + 4 * $k)
                    }
                    [void]$lines.Add("P|$trigger|$($ops -join ',')|$($vars -join ',')|$($vals -join ',')|$($icon.Text)")
                } catch {
                }
                $p = $poff + 1
            }
        } catch {
        }
    }
    $canonical = (($lines | Sort-Object) -join "`n")
    return Get-Sha256Text -Text $canonical
}

# ---------------------------------------------------------------- 修復計畫
function Get-RepairPlan {
    param([string]$Root)
    $cePath = Join-Path $Root 'Data\BasicData\CommonEvent.dat'
    $names = Get-CommonEventNames -Data ([System.IO.File]::ReadAllBytes($cePath))
    $files = New-Object System.Collections.ArrayList
    $total = 0
    $skipped = 0
    foreach ($file in $AffectedFiles) {
        $curPath = Join-Path $Root ('Data\MapData\' + $file)
        $bakPath = Join-Path $Root ('Data\MapData - BAK\' + $file)
        if (-not (Test-Path -LiteralPath $curPath)) { throw "找不到地圖檔: $curPath" }
        if (-not (Test-Path -LiteralPath $bakPath)) { throw "找不到原版對照: $bakPath" }
        $curData = [System.IO.File]::ReadAllBytes($curPath)
        $bakData = [System.IO.File]::ReadAllBytes($bakPath)
        $curCalls = @(Get-CallSites -Data $curData)
        $bakCalls = @(Get-CallSites -Data $bakData)
        if ($curCalls.Count -ne $bakCalls.Count) {
            throw "$file 的呼叫數與原版不同 (current=$($curCalls.Count) bak=$($bakCalls.Count))；為避免誤改，停止。"
        }
        $changes = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $curCalls.Count; $i++) {
            $call = $curCalls[$i]
            if ($names.Contains($call.Name)) { continue }
            $orig = $null
            $source = ''
            if ($names.Contains($bakCalls[$i].Name)) {
                $orig = $bakCalls[$i].Name
                $source = 'BAK'
            } elseif ($FallbackMap.ContainsKey($call.Name)) {
                $candidate = $FallbackMap[$call.Name]
                if ($names.Contains($candidate)) {
                    $orig = $candidate
                    $source = 'mapping'
                }
            }
            if ($null -eq $orig) {
                $skipped++
                continue
            }
            [void]$changes.Add([PSCustomObject]@{
                File       = $file
                Index      = $i
                Offset     = $call.Offset
                NameOffset = $call.NameOffset
                NameLength = $call.NameLength
                OldName    = $call.Name
                NewName    = $orig
                Source     = $source
            })
        }
        if ($changes.Count -gt 0) {
            [void]$files.Add([PSCustomObject]@{
                File      = $file
                CurPath   = $curPath
                BakPath   = $bakPath
                Changes   = $changes
                CurData   = $curData
                BakData   = $bakData
            })
            $total += $changes.Count
        }
    }
    return [PSCustomObject]@{
        Files     = $files
        Total     = $total
        Skipped   = $skipped
        Names     = $names
    }
}

function Replace-CallName {
    param([byte[]]$Data, [PSCustomObject]$Change, [string]$NewName)
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($NewName + [char]0)
    $oldTotal = 4 + $Change.NameLength
    $newTotal = 4 + $newBytes.Length
    $out = New-Object byte[] ($Data.Length - $oldTotal + $newTotal)
    [Array]::Copy($Data, 0, $out, 0, $Change.NameOffset)
    $lenBytes = [BitConverter]::GetBytes([uint32]$newBytes.Length)
    [Array]::Copy($lenBytes, 0, $out, $Change.NameOffset, 4)
    [Array]::Copy($newBytes, 0, $out, $Change.NameOffset + 4, $newBytes.Length)
    [Array]::Copy($Data, $Change.NameOffset + $oldTotal, $out, $Change.NameOffset + $newTotal,
                  $Data.Length - $Change.NameOffset - $oldTotal)
    return $out
}

# ---------------------------------------------------------------- 顯示
function Show-Header {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host "  $ToolTitle" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  問題：部分地圖事件以「名稱」呼叫共通事件，但呼叫端名稱被翻成中文，' -ForegroundColor Gray
    Write-Host '        CommonEvent.dat 的定義仍是日文；CALL 找不到名稱時會靜默不執行。' -ForegroundColor Gray
    Write-Host '  範圍：18 張地圖、23 個呼叫點（只修這一類；不修原版即缺失的呼叫）。' -ForegroundColor Gray
    Write-Host '  本工具不修改 CommonEvent.dat。' -ForegroundColor Gray
    Write-Host ''
    if ($GameDir) { Write-Host "  遊戲本體: $GameDir" -ForegroundColor DarkGray; Write-Host '' }
}

function Show-Preview {
    param([PSCustomObject]$Plan)
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  Dry-run 預覽（尚未寫入任何檔案）' -ForegroundColor Cyan
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    foreach ($file in $Plan.Files) {
        Write-Host ''
        Write-Host "  $($file.File)  ($($file.Changes.Count) 個呼叫)" -ForegroundColor White
        foreach ($c in $file.Changes) {
            Write-Host ("    @0x{0:X6}  {1}  ->  {2}   [{3}]" -f $c.NameOffset, $c.OldName, $c.NewName, $c.Source) -ForegroundColor Gray
        }
    }
    Write-Host ''
    Write-Host "  合計：$($Plan.Files.Count) 個檔案、$($Plan.Total) 個呼叫點。" -ForegroundColor Green
    if ($Plan.Skipped -gt 0) {
        Write-Host "  另有 $($Plan.Skipped) 個目標不存在、但原版也找不到的呼叫；本工具不處理。" -ForegroundColor DarkYellow
    }
    Write-Host '  以上為預覽，遊戲檔案尚未被修改。' -ForegroundColor Green
    Write-Host ''
}

function Confirm-Action {
    param([string]$Prompt)
    if ($Yes) { return $true }
    $answer = Read-Host $Prompt
    return ($answer -match '^[yY]')
}

# ---------------------------------------------------------------- 安裝
function Install-Repair {
    param([string]$Root)
    $plan = Get-RepairPlan -Root $Root
    if ($plan.Total -eq 0) {
        Write-Host '  [資訊] 沒有需要修復的呼叫點；可能已經修復，或版本不符。' -ForegroundColor Green
        return
    }
    Show-Preview -Plan $plan
    if (-not (Confirm-Action '  是否實際執行安裝修復？輸入 y 繼續，其他字取消')) {
        Write-Host '  [取消] 未做任何變更。' -ForegroundColor Yellow
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $BackupRoot (Join-Path $stamp 'pre-fix')
    $manifestPath = Join-Path $backupDir 'manifest.json'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    # 先把所有要修改的檔案完整備份，並逐一驗證備份雜湊；這一步失敗就不會進到套用。
    $backups = @{}
    $manifestFiles = New-Object System.Collections.ArrayList
    foreach ($file in $plan.Files) {
        $rel = 'Data\MapData\' + $file.File
        $dst = Join-Path $backupDir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $file.CurPath -Destination $dst -Force
        $beforeHash = Get-Sha256 -Path $file.CurPath
        if ((Get-Sha256 -Path $dst) -ne $beforeHash) {
            throw "備份驗證失敗：$($file.File)；尚未修改任何遊戲檔。"
        }
        $backups[$file.File] = $dst

        $changesForManifest = New-Object System.Collections.ArrayList
        foreach ($c in ($file.Changes | Sort-Object -Property NameOffset)) {
            [void]$changesForManifest.Add([PSCustomObject]@{
                offset_hex = ('0x{0:X6}' -f $c.NameOffset)
                old_name   = $c.OldName
                new_name   = $c.NewName
                source     = $c.Source
            })
        }
        [void]$manifestFiles.Add([PSCustomObject]@{
            rel_path      = 'Data/MapData/' + $file.File
            sha256_before = $beforeHash
            sha256_after  = $null
            status        = 'pending'
            changes       = $changesForManifest
        })
    }

    # 在動任何檔案之前先寫 pending manifest；即使程序被強制中斷，卸載仍能從備份還原。
    $manifest = [PSCustomObject]@{
        status       = 'pending'
        installed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        game_dir     = $Root
        tool         = 'fix.ps1'
        files        = $manifestFiles
    }
    Write-Manifest -Path $manifestPath -Manifest $manifest
    Write-Host "  [備份] $backupDir" -ForegroundColor Gray
    Write-Host "  [紀錄] $manifestPath" -ForegroundColor Gray

    $patchedCount = 0
    try {
        foreach ($file in $plan.Files) {
            $entry = $manifestFiles | Where-Object { $_.rel_path -eq ('Data/MapData/' + $file.File) } | Select-Object -First 1
            if ((Get-Sha256 -Path $file.CurPath) -ne $entry.sha256_before) {
                throw "$($file.File): 檔案在備份後被修改，停止（尚未寫入）。"
            }
            $data = [System.IO.File]::ReadAllBytes($file.CurPath)
            $fpBefore = Get-EventsFingerprint -Data $data
            $patched = $data
            foreach ($c in ($file.Changes | Sort-Object -Property NameOffset -Descending)) {
                $patched = Replace-CallName -Data $patched -Change $c -NewName $c.NewName
            }
            if ($patched[$patched.Length - 1] -ne 0x66) {
                throw "$($file.File): 修補後地圖結尾不是 0x66，停止（尚未寫入）。"
            }
            if ((Get-EventsFingerprint -Data $patched) -ne $fpBefore) {
                throw "$($file.File): 修補後事件結構指紋不同，停止（尚未寫入）。"
            }
            [System.IO.File]::WriteAllBytes($file.CurPath, $patched)
            $patchedCount++

            $verifyCalls = @(Get-CallSites -Data ([System.IO.File]::ReadAllBytes($file.CurPath)))
            foreach ($c in $file.Changes) {
                if ($verifyCalls[$c.Index].Name -ne $c.NewName) {
                    throw "$($file.File): 修補後驗證失敗（索引 $($c.Index)）。"
                }
                if (-not $plan.Names.Contains($c.NewName)) {
                    throw "$($file.File): 修補後名稱仍不存在於 CommonEvent.dat：$($c.NewName)"
                }
            }
            $entry.sha256_after = Get-Sha256 -Path $file.CurPath
            $entry.status = 'installed'
            Write-Manifest -Path $manifestPath -Manifest $manifest
            Write-Host "  [完成] $($file.File)  ($($file.Changes.Count) 個呼叫)" -ForegroundColor Green

            if ($env:WOLF_FIX_TEST_STOP_AFTER -and $patchedCount -ge [int]$env:WOLF_FIX_TEST_STOP_AFTER) {
                Write-Host '  [TEST] 模擬中斷（保留 pending manifest，不執行自動還原）' -ForegroundColor DarkYellow
                exit 97
            }
            if ($env:WOLF_FIX_TEST_FAIL_AFTER -and $patchedCount -ge [int]$env:WOLF_FIX_TEST_FAIL_AFTER) {
                throw "[TEST] 模擬套用錯誤（第 $patchedCount 個檔案後）"
            }
        }
        $manifest.status = 'installed'
        Write-Manifest -Path $manifestPath -Manifest $manifest
    } catch {
        Write-Host "  [錯誤] $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '  [還原] 正在把所有備份檔案還原成安裝前狀態...' -ForegroundColor Yellow
        $restoreErrors = 0
        foreach ($entry in $manifestFiles) {
            $name = [System.IO.Path]::GetFileName($entry.rel_path)
            $src = $backups[$name]
            $dst = Join-Path $Root ($entry.rel_path -replace '/', '\')
            try {
                Copy-Item -LiteralPath $src -Destination $dst -Force
                if ((Get-Sha256 -Path $dst) -ne $entry.sha256_before) {
                    throw '還原後雜湊不符'
                }
                Write-Host "    已還原 $name" -ForegroundColor Yellow
            } catch {
                $restoreErrors++
                Write-Host "    [警告] 還原失敗 $name：$($_.Exception.Message)" -ForegroundColor Red
            }
        }
        if ($restoreErrors -eq 0) { $manifest.status = 'rolled_back' }
        else { $manifest.status = 'pending' }
        try { Write-Manifest -Path $manifestPath -Manifest $manifest } catch { }
        if ($restoreErrors -eq 0) {
            Write-Host '  [還原] 全部檔案已回到安裝前狀態。' -ForegroundColor Green
        } else {
            Write-Host "  [警告] 有 $restoreErrors 個檔案還原失敗；備份仍在 $backupDir" -ForegroundColor Red
        }
        throw
    }

    Write-Host ''
    Write-Host "  [完成] 已修復 $($plan.Files.Count) 個檔案、$($plan.Total) 個呼叫點。" -ForegroundColor Green
    Write-Host '  請重新啟動遊戲，確認原本無法對話的偵探已恢復。' -ForegroundColor Cyan
    Write-Host ''
}

# ---------------------------------------------------------------- 卸載
function Uninstall-Repair {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $BackupRoot)) {
        throw "找不到備份目錄：$BackupRoot"
    }
    $backupDir = $null
    $manifest = $null
    $rolledBack = $false
    foreach ($stamp in (Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name -Descending)) {
        $pre = Join-Path $stamp.FullName 'pre-fix'
        $mf = Join-Path $pre 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $status = if ($m.status) { [string]$m.status } else { 'installed' }
        if ($status -eq 'rolled_back') { $rolledBack = $true; break }
        $backupDir = $pre
        $manifest = $m
        break
    }
    if (-not $backupDir) {
        if ($rolledBack) {
            Write-Host '  [資訊] 最近一次安裝已自動回滾，沒有需要卸載的項目。' -ForegroundColor Green
            return
        }
        throw '找不到可用的安裝備份（installed／pending）。'
    }

    $files = @($manifest.files)
    if ($files.Count -eq 0) { throw 'manifest 沒有檔案清單。' }

    # 預檢：所有備份都存在且雜湊正確，才開始覆寫遊戲檔。
    $preflightErrors = New-Object System.Collections.ArrayList
    foreach ($entry in $files) {
        if ($entry.rel_path -notmatch '^Data/MapData/[^/]+\.mps$') {
            [void]$preflightErrors.Add("不合法的 rel_path：$($entry.rel_path)")
            continue
        }
        $rel = $entry.rel_path -replace '/', '\'
        $src = Join-Path $backupDir $rel
        if (-not (Test-Path -LiteralPath $src)) {
            [void]$preflightErrors.Add("備份不存在：$($entry.rel_path)")
            continue
        }
        if ($entry.sha256_before -and (Get-Sha256 -Path $src) -ne $entry.sha256_before) {
            [void]$preflightErrors.Add("備份雜湊不符：$($entry.rel_path)")
        }
    }
    if ($preflightErrors.Count -gt 0) {
        Write-Host '  [中止] 備份預檢失敗，尚未修改任何遊戲檔：' -ForegroundColor Red
        foreach ($e in $preflightErrors) { Write-Host "    - $e" -ForegroundColor Red }
        throw '卸載預檢失敗'
    }

    Write-Host "  使用備份：$backupDir" -ForegroundColor Gray
    Write-Host ''

    # 若遊戲檔在安裝後被其他工具改動，仍然還原成安裝前版本，但先提示。
    foreach ($entry in $files) {
        $dst = Join-Path $Root ($entry.rel_path -replace '/', '\')
        if (Test-Path -LiteralPath $dst) {
            $now = Get-Sha256 -Path $dst
            if ($entry.sha256_after -and $now -ne $entry.sha256_after -and $now -ne $entry.sha256_before) {
                Write-Host "  [注意] $($entry.rel_path) 在安裝後被改動；仍會還原成安裝前版本。" -ForegroundColor DarkYellow
            }
        }
    }

    $count = 0
    $failed = 0
    foreach ($entry in $files) {
        $rel = $entry.rel_path -replace '/', '\'
        $src = Join-Path $backupDir $rel
        $dst = Join-Path $Root $rel
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            if ($entry.sha256_before -and (Get-Sha256 -Path $dst) -ne $entry.sha256_before) {
                throw '還原後雜湊不符'
            }
            $count++
            Write-Host "  [還原] $($entry.rel_path)" -ForegroundColor Green
        } catch {
            $failed++
            Write-Host "  [錯誤] 還原失敗 $($entry.rel_path)：$($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ''
    if ($failed -gt 0) {
        throw "有 $failed 個檔案還原失敗；備份仍在 $backupDir，可再次執行卸載。"
    }
    Write-Host "  [完成] 已還原 $count 個檔案。" -ForegroundColor Green
    Write-Host '  請重新啟動遊戲確認。' -ForegroundColor Cyan
    Write-Host ''
}

# ---------------------------------------------------------------- 檢查
function Verify-Repair {
    param([string]$Root)
    $plan = Get-RepairPlan -Root $Root
    if ($plan.Total -eq 0) {
        Write-Host '  [OK] 沒有發現需要修復的呼叫點。' -ForegroundColor Green
        return
    }
    Write-Host "  [待修] 還有 $($plan.Total) 個呼叫點、$($plan.Files.Count) 個檔案。" -ForegroundColor Yellow
    Show-Preview -Plan $plan
}

# ---------------------------------------------------------------- 路徑
function Read-SavedGameDir {
    if (-not (Test-Path -LiteralPath $SelfConfig)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($SelfConfig, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*GAME_DIR\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Save-GameDir {
    param([string]$Root)
    $text = "# 共通事件呼叫名稱修復工具的設定（由 fix.ps1 自動寫入）`r`n" +
            "# 遊戲本體路徑（工作區之外）`r`n" +
            "GAME_DIR = $Root`r`n"
    [System.IO.File]::WriteAllText($SelfConfig, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-GameDir {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $a = Join-Path $Root 'Data\MapData\Map123_2.mps'
    $b = Join-Path $Root 'Data\BasicData\CommonEvent.dat'
    $c = Join-Path $Root 'Data\MapData - BAK\Map123_2.mps'
    return ((Test-Path -LiteralPath $a) -and (Test-Path -LiteralPath $b) -and (Test-Path -LiteralPath $c))
}

# ---------------------------------------------------------------- 主流程
if ([string]::IsNullOrWhiteSpace($GameDir)) {
    $saved = Read-SavedGameDir
    if (Test-GameDir -Root $saved) {
        $GameDir = $saved
    } elseif ($Action -ne 'menu') {
        throw '非互動模式需要 -GameDir，或先在 fix.config.txt 設定有效的 GAME_DIR。'
    }
}

if (-not [string]::IsNullOrWhiteSpace($GameDir)) {
    $GameDir = $GameDir.Trim().Trim('"')
    if (-not (Test-GameDir -Root $GameDir)) {
        throw "找不到遊戲資料：$GameDir（需要 Data\MapData\Map123_2.mps、Data\BasicData\CommonEvent.dat、Data\MapData - BAK\Map123_2.mps）"
    }
} else {
    Write-Host ''
    Write-Host '[找不到遊戲資料]' -ForegroundColor Yellow
    Write-Host '  請輸入遊戲本體的完整路徑（留空則取消）:' -ForegroundColor Yellow
    $inputPath = Read-Host '  路徑'
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        Write-Host '[取消] 未做任何變更。' -ForegroundColor Yellow
        exit 0
    }
    $GameDir = $inputPath.Trim().Trim('"')
    if (-not (Test-GameDir -Root $GameDir)) {
        throw '該路徑下找不到必要的遊戲資料，請確認後再試。'
    }
    $save = Read-Host '  要記住這個路徑嗎？之後可直接執行 fix.bat [y/N]'
    if ($save -match '^[yY]') { Save-GameDir -Root $GameDir }
}

Show-Header
if ($Action -eq 'menu') {
    Write-Host '  注意：本工具不會自動套用；只有選 1 才會寫入遊戲本體。' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '   0 - 取消，不做任何變更' -ForegroundColor White
    Write-Host '   1 - 安裝修復（還原 18 張地圖的 23 個呼叫名稱）' -ForegroundColor White
    Write-Host '   2 - 卸載修復（還原安裝前的備份）' -ForegroundColor White
    Write-Host '   3 - 檢查目前狀態（不改檔）' -ForegroundColor White
    Write-Host ''
    $choice = Read-Host '  請輸入 0 / 1 / 2 / 3 後按 Enter'
    switch ($choice.Trim()) {
        '0' { Write-Host '[取消] 未做任何變更。' -ForegroundColor Yellow; exit 0 }
        '1' { $Action = 'install' }
        '2' { $Action = 'uninstall' }
        '3' { $Action = 'verify' }
        default { throw "無效的選項：$choice" }
    }
}

switch ($Action) {
    'dry-run'   { $plan = Get-RepairPlan -Root $GameDir; Show-Preview -Plan $plan }
    'verify'    { Verify-Repair -Root $GameDir }
    'install'   { Install-Repair -Root $GameDir }
    'uninstall' { Uninstall-Repair -Root $GameDir }
    'debug' {
        $names = Get-CommonEventNames -Data ([System.IO.File]::ReadAllBytes((Join-Path $GameDir 'Data\BasicData\CommonEvent.dat')))
        foreach ($probe in @('蕾1', '蕾2', '蕾3', '蕾4', '蕾5', '蕾6', '蕾7', '蕾設定2', '獲得回想：賽爾菲娜1', 'レーン1')) {
            Write-Host ("  {0} exists={1}" -f $probe, $names.Contains($probe))
        }
        foreach ($file in $AffectedFiles) {
            $p = Join-Path $GameDir ('Data\MapData\' + $file)
            $calls = @(Get-CallSites -Data ([System.IO.File]::ReadAllBytes($p)))
            Write-Host ("  {0}: calls={1}" -f $file, $calls.Count)
            foreach ($c in $calls) {
                if ($c.Name -match '蕾|獲得回想|賽爾|伊爾|イリーザ') {
                    Write-Host ("     @0x{0:X6} {1}" -f $c.NameOffset, $c.Name)
                }
            }
        }
    }
    default     { throw "未知的 Action：$Action" }
}
exit 0
