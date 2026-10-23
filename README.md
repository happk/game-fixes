# game-fixes

非官方遊戲錯誤修復補丁合輯。每個補丁一個資料夾，可獨立安裝／卸載，不互相依賴。

- [下載](https://github.com/happk/game-fixes/releases/download/v1/game-fix_win.zip)

| 適用遊戲 | 問題標題 | 使用方式 | 注意 |
|---|---|---|---|
| 羅爾迪亞之翼 v1.21（繁中） | [立繪檔名錯誤 — 魯梅爾立繪無法顯示](<羅爾迪亞之翼 v1.21-立繪檔名錯誤/>) | 雙擊 `fix.bat` → `1` 安裝／`2` 卸載 | 修改 `SysDatabase.dat` ；備份存於 `backup/` |
| 羅爾迪亞之翼 v1.21（繁中） | [酒場人物無法對話 — 共通事件呼叫名稱被翻譯](<羅爾迪亞之翼 v1.21-酒場人物無法對話/>) | 雙擊 `fix.bat` → `3` 檢查／`1` 安裝／`2` 卸載 | 修改 18 張地圖的 23 個呼叫點，不改動 `CommonEvent.dat`；備份存於 `backup/` |



## 說明

- 環境：Windows + Windows PowerShell 5.1。
- 各補丁只更動列出的檔案，安裝前會先 dry-run 預覽、先備份，可隨時卸載還原。

