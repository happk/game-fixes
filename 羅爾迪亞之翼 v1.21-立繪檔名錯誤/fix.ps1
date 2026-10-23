#Requires -Version 5.1
<#
  羅爾迪亞之翼 v1.21 - 立繪檔名修復工具（互動選單）

  選單： 0 = 取消、1 = 安裝修復、2 = 卸載修復
  選 1 或 2 都會先 dry-run 預覽，再詢問是否實際執行。

  本檔為 UTF-8 With BOM。中文與日文訊息全部集中在這裡，
  批次檔 fix.bat 只保留純 ASCII，避免 cmd.exe 用系統 OEM 碼頁
  讀批次檔而把中文行拆成爛指令。

  遊戲本體路徑來源（依序）：
    1. 命令列第一個參數
    2. 本工具自己的 fix.config.txt（與分析層的 config.txt 無關）
    3. 都沒有時直接詢問使用者，並詢問是否要記到 fix.config.txt
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

# 本工具自成一套：路徑設定與備份都放在自己所在的資料夾，
# 不依賴外層工作區的任何檔案（要發布給別人時，整個資料夾直接複製即可）。
$SelfConfig = Join-Path $PSScriptRoot 'fix.config.txt'
if ($env:WOLF_FIX_BACKUP_ROOT) { $BackupRoot = $env:WOLF_FIX_BACKUP_ROOT }
else { $BackupRoot = Join-Path $PSScriptRoot 'backup' }
$OldText    = 'Picture/N魯梅爾1.png'
$NewText    = 'Picture/Nルメル1.png'
$TargetRel  = 'Data\BasicData\SysDatabase.dat'

# ---------------------------------------------------------------- 工具函式

function Find-Pattern {
    param([byte[]]$Data, [byte[]]$Pattern)
    for ($i = 0; $i -le $Data.Length - $Pattern.Length; $i++) {
        if ($Data[$i] -ne $Pattern[0]) { continue }
        $same = $true
        for ($j = 1; $j -lt $Pattern.Length; $j++) {
            if ($Data[$i + $j] -ne $Pattern[$j]) { $same = $false; break }
        }
        if ($same) { return $i }
    }
    return -1
}

function Replace-Pattern {
    param([byte[]]$Data, [int]$Index, [int]$Length, [byte[]]$Replacement)
    $out = New-Object byte[] $Data.Length
    [Array]::Copy($Data, 0, $out, 0, $Index)
    [Array]::Copy($Replacement, 0, $out, $Index, $Replacement.Length)
    [Array]::Copy($Data, $Index + $Length, $out, $Index + $Replacement.Length,
                  $Data.Length - $Index - $Length)
    return $out
}

function Get-Sha256 {
    param([string]$Path)
    # 不用 Get-FileHash：部分環境未載入 Microsoft.PowerShell.Utility 模組
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($fs) } finally { $fs.Dispose(); $sha.Dispose() }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').ToUpper()
}

function Read-SavedGameDir {
    # 本工具自己的路徑記錄檔（與分析層的 config.txt 無關）
    if (-not (Test-Path -LiteralPath $SelfConfig)) { return '' }
    foreach ($line in [System.IO.File]::ReadAllLines($SelfConfig, [System.Text.Encoding]::UTF8)) {
        if ($line -match '^\s*GAME_DIR\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Save-GameDir {
    # 記住使用者選定的路徑，下次免再輸入
    $text = "# 立繪檔名修復工具的設定（由 fix.ps1 自動寫入）`r`n" +
            "# 遊戲本體路徑（工作區之外）`r`n" +
            "GAME_DIR = $GameDir`r`n"
    [System.IO.File]::WriteAllText($SelfConfig, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

function Test-GameDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path $TargetRel))
}

function New-Backup {
    param([string]$Source, [string]$Tag = 'pre-fix')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $BackupRoot (Join-Path $stamp $Tag)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $copy = Join-Path $dir (Split-Path -Leaf $Source)
    Copy-Item -LiteralPath $Source -Destination $copy -Force
    return @{ Dir = $dir; File = $copy }
}

function Get-ManifestDirs {
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return @() }
    $out = @()
    foreach ($stamp in (Get-ChildItem -LiteralPath $BackupRoot -Directory | Sort-Object Name)) {
        $pre = Join-Path $stamp.FullName 'pre-fix'
        if (Test-Path -LiteralPath $pre) { $out += $pre }
    }
    return $out
}

# ---------------------------------------------------------------- 顯示區塊

function Show-Header {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  羅爾迪亞之翼 v1.21   立繪檔名修復工具' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  遊戲本體: $GameDir" -ForegroundColor Gray
    Write-Host ''
}

function Show-Preview {
    param([string]$Target, [byte[]]$Data, [string]$OldBytes, [string]$NewBytes)
    $old = [System.Text.Encoding]::UTF8.GetBytes($OldBytes)
    $new = [System.Text.Encoding]::UTF8.GetBytes($NewBytes)
    $iOld = Find-Pattern -Data $Data -Pattern $old
    $iNew = Find-Pattern -Data $Data -Pattern $new
    Write-Host "  目標檔案 : $Target"
    Write-Host "  檔案大小 : $($Data.Length) bytes"
    Write-Host "  舊字串   : $OldBytes  （出現 $iOld 位置的位元組串）"
    Write-Host "  新字串   : $NewBytes  （出現 $iNew 位置的位元組串）"
    if ($iOld -ge 0) { Write-Host "  舊字串位置: 0x$('{0:X8}' -f $iOld)" -ForegroundColor DarkGray }
    if ($iNew -ge 0) { Write-Host "  新字串位置: 0x$('{0:X8}' -f $iNew)" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host '  兩串的位元組長度相同，因此 .dat 內的字串長度欄位不需要重建，' -ForegroundColor DarkGray
    Write-Host '  這是等長就地替換，檔案大小不會改變。' -ForegroundColor DarkGray
    Write-Host ''
}

# ---------------------------------------------------------------- 主流程

$GameDir = $args[0]
if ($args.Count -ge 1 -and $GameDir) {
    # 明確指定了路徑：若無效就直接報錯，**不**回退到其他路徑
    # （回退會讓「打錯的參數」變成「對另一個目錄動手」，風險太高）
    if (-not (Test-GameDir $GameDir)) {
        Write-Host ''
        Write-Host "[錯誤] 指定的路徑下找不到 $TargetRel ：" -ForegroundColor Red
        Write-Host "        $GameDir" -ForegroundColor Red
        Write-Host '        請確認路徑後再試。' -ForegroundColor Red
        exit 1
    }
} else {
    $saved = Read-SavedGameDir
    if (Test-GameDir $saved) {
        $GameDir = $saved
    } else {
        Write-Host ''
        Write-Host '[找不到遊戲資料]' -ForegroundColor Yellow
        if ($saved) { Write-Host "  上次記錄的路徑: $saved" }
        Write-Host '  請輸入遊戲本體的完整路徑（留空則取消）:' -ForegroundColor Yellow
        $input = Read-Host '  路徑'
        if ([string]::IsNullOrWhiteSpace($input)) {
            Write-Host '[取消] 未做任何變更。' -ForegroundColor Yellow
            exit 0
        }
        $GameDir = $input.Trim()
        if (-not (Test-GameDir $GameDir)) {
            Write-Host "[錯誤] 該路徑下找不到 $TargetRel ，請確認後再試。" -ForegroundColor Red
            exit 1
        }
        $save = Read-Host '  要記住這個路徑嗎？之後可直接執行 fix.bat [y/N]'
        if ($save -match '^[yY]') {
            Save-GameDir | Out-Null
            Write-Host "  已記到 $SelfConfig" -ForegroundColor Green
        }
    }
}

$Target = Join-Path $GameDir $TargetRel
if (-not (Test-Path -LiteralPath $Target)) {
    Write-Host "[錯誤] 找不到目標檔案: $Target" -ForegroundColor Red
    exit 1
}

Show-Header
Write-Host '   0 - 取消，不做任何變更' -ForegroundColor White
Write-Host '   1 - 安裝修復 - 把 SysDatabase.dat 該筆的檔名欄由中文改回日文' -ForegroundColor White
Write-Host '   2 - 卸載修復 - 還原成安裝修復之前的原樣' -ForegroundColor White
Write-Host ''
$choice = if ($args.Count -ge 2 -and $args[1]) { $args[1] } else { Read-Host '  請輸入 0 / 1 / 2 後按 Enter' }
$confirm = if ($args.Count -ge 3 -and $args[2]) { $args[2] } else { '' }
Write-Host ''

$action = ''
switch ($choice.Trim()) {
    '0' { Write-Host '[取消] 未做任何變更。' -ForegroundColor Yellow; exit 0 }
    '1' { $action = '安裝修復' }
    '2' { $action = '卸載修復' }
    default { Write-Host "[錯誤] 無效的選項: $choice" -ForegroundColor Red; exit 1 }
}

$data = [System.IO.File]::ReadAllBytes($Target)
$old = [System.Text.Encoding]::UTF8.GetBytes($OldText)
$new = [System.Text.Encoding]::UTF8.GetBytes($NewText)
$iOld = Find-Pattern -Data $data -Pattern $old
$iNew = Find-Pattern -Data $data -Pattern $new

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "  $action   第一步: dry-run 預覽，不會寫入任何檔案" -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Show-Preview -Target $Target -Data $data -OldBytes $OldText -NewBytes $NewText

if ($action -eq '安裝修復') {
    if ($iOld -lt 0 -and $iNew -ge 0) {
        Write-Host '[資訊] 這個檔案已經是修復後的狀態，不需重複套用（保持原樣）。' -ForegroundColor Green
        exit 0
    }
    if ($iOld -lt 0) {
        Write-Host '[中止] 檔案狀態不是預期的「原始中文檔名」，為避免誤改已停止。' -ForegroundColor Red
        exit 1
    }
} else {
    if ($iNew -lt 0 -and $iOld -ge 0) {
        Write-Host '[資訊] 這個檔案本來就是未修復的狀態，無需還原（保持原樣）。' -ForegroundColor Green
        exit 0
    }
    if ($iNew -lt 0) {
        Write-Host '[中止] 檔案狀態不是預期的「已修復」，為避免覆蓋其他變更而停止。' -ForegroundColor Red
        exit 1
    }
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  以上為預覽結果，遊戲檔案尚未被修改。' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$answer = if ($confirm) {
    # 非互動模式必須明確給出 YES 令牌，避免被誤觸或參數誤傳時就動到檔案
    if ($confirm -ceq 'YES') { 'y' } else { 'n' }
} else {
    Read-Host "  是否實際執行 $action ? 輸入 y 繼續，其他字取消"
}
Write-Host ''
if ($confirm -and $confirm -cne 'YES') {
    Write-Host '  [提示] 非互動模式必須以 YES 明確確認才算同意。' -ForegroundColor DarkGray
}

if ($answer.Trim() -notmatch '^[yY]') {
    Write-Host '[取消] 未實際執行，遊戲檔案沒有任何變更。' -ForegroundColor Yellow
    exit 0
}

if ($action -eq '安裝修復') {
    Write-Host '--- 開始執行: 安裝修復 ---' -ForegroundColor Green
    $backup = New-Backup -Source $Target -Tag 'pre-fix'
    $patched = Replace-Pattern -Data $data -Index $iOld -Length $old.Length -Replacement $new
    [System.IO.File]::WriteAllBytes($Target, $patched)
    $manifest = [ordered]@{
        installed_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        target       = $Target
        sha256_before = (Get-Sha256 $backup.File)
        sha256_after  = (Get-Sha256 $Target)
        backup        = $backup.File
        old_text      = $OldText
        new_text      = $NewText
        offset        = $iOld
        bytes         = $old.Length
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup.Dir 'manifest.json') -Encoding UTF8
    Write-Host "  [備份] $($backup.File)"
    Write-Host "  [紀錄] solutions/backup/$((Split-Path -Leaf $backup.Dir))/manifest.json"
    Write-Host "  [完成] 已寫入 $Target"
    Write-Host "  [驗證] 檔案大小 $($data.Length) → $((Get-Item -LiteralPath $Target).Length)；"
    Write-Host "         舊字串殘留 $((Find-Pattern -Data ([System.IO.File]::ReadAllBytes($Target)) -Pattern $old)) 位置、新字串 $((Find-Pattern -Data ([System.IO.File]::ReadAllBytes($Target)) -Pattern $new)) 位置"
    Write-Host ''
    Write-Host '  請重新啟動遊戲，進入會顯示該角色立繪的場景確認是否已恢復正常。' -ForegroundColor Cyan
    Write-Host '  遊戲的 Game_ErrorLog.txt 會覆寫舊紀錄，建議先保留既有日誌。' -ForegroundColor DarkGray
} else {
    Write-Host '--- 開始執行: 卸載修復 ---' -ForegroundColor Green
    $restored = $null
    $source = ''
    foreach ($dir in (Get-ManifestDirs)) {
        $mf = Join-Path $dir 'manifest.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try { $m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $m.backup -or -not (Test-Path -LiteralPath $m.backup)) { continue }
        $hash = (Get-Sha256 $m.backup)
        if ($m.sha256_before -and $hash -eq $m.sha256_before) {
            $restored = [System.IO.File]::ReadAllBytes($m.backup)
            $source = "安裝時的備份 $($m.backup)（SHA256 與 manifest 相符）"
            break
        }
    }
    if ($null -eq $restored) {
        $restored = Replace-Pattern -Data $data -Index $iNew -Length $new.Length -Replacement $old
        $source = '等長反向替換（把日文檔名換回中文檔名）'
    }
    Write-Host "  還原方式: $source"
    [System.IO.File]::WriteAllBytes($Target, $restored)
    $after = [System.IO.File]::ReadAllBytes($Target)
    Write-Host "  [完成] 已還原 $Target"
    Write-Host "  [驗證] 檔案大小 $($after.Length) bytes；SHA256 = $((Get-Sha256 $Target))"
    Write-Host "         舊字串位置 $((Find-Pattern -Data $after -Pattern $old))、新字串位置 $((Find-Pattern -Data $after -Pattern $new))（預期：舊 1 位置、新 -1）"
    Write-Host ''
    Write-Host '  請重新啟動遊戲確認。' -ForegroundColor Cyan
}
exit 0
