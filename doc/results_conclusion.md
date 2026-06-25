# 成果與結論

## 成果

本專案完成一套以 Terasic DE2-115 為平台的 FPGA 錄音與播放系統。系統使用 WM8731 Audio CODEC 進行聲音輸入與輸出，並以 FPGA 控制音訊資料流、SRAM 暫存、FLASH 儲存，以及 LCD、HEX、LEDR 等人機介面。

在音訊處理部分，系統可透過 Line-in 或 Mic-in 輸入聲音，將 WM8731 轉換後的 16-bit PCM 音訊資料接收至 FPGA。錄音資料以 48 kHz 取樣率寫入 SRAM，並以 left channel mono 形式儲存。SRAM 作為即時錄音與播放的高速緩衝區，可降低連續音訊輸出對記憶體存取時序的要求。

在儲存功能部分，系統完成 SRAM 到 FLASH 的永久儲存流程。錄音停止後，使用者可透過 KEY3 觸發儲存，且必須先打開 SW3 作為 FLASH 寫入解鎖，避免誤寫入。FLASH 以 SW[11:10] 選擇 Slot 0 到 Slot 3，讓不同錄音可保存於不同區段。每筆資料包含 header，用於記錄有效標記、取樣率與資料長度，使播放前能判斷 FLASH 內容是否有效。

在播放流程部分，系統採用 `FLASH -> SRAM -> Audio CODEC` 的固定架構。使用者按下 KEY2 後，系統先讀取目前 FLASH slot 的 header，確認資料有效後再將 FLASH 音訊資料載入 SRAM，最後由 SRAM 依照 codec sample tick 送至 DAC 播放。此設計避免直接從 FLASH 串流播放造成音訊時序不穩定。

在人機介面部分，系統完成 KEY、SW、LCD、HEX 與 LEDR 的整合。KEY[1] 負責錄音與停止錄音，KEY[2] 負責載入與播放，KEY[3] 依狀態執行儲存、確認或取消。LCD 顯示系統狀態與操作提示，HEX 顯示模式、狀態、FLASH slot、輸入來源與秒數。LEDR[17:0] 則根據目前音訊振幅顯示音量條，並可由 SW0 開關、SW[7:6] 調整靈敏度。

在驗證與交付部分，專案保留 Quartus II 13.1 工程、top-level RTL、各功能模組、Terasic IP、測試平台與已追蹤的 programming image。測試平台涵蓋主狀態機、LEDR 音量條、HEX 狀態時間顯示與 FLASH 流程，可作為後續回歸測試與硬體驗證的基礎。

## 實作限制

- 本版本不實作 FFT 頻譜分析，也不使用外接 LED 矩陣。
- 錄音儲存採 left channel mono，未實作 stereo 儲存。
- 播放固定先由 FLASH 載入 SRAM，不直接從 FLASH 串流播放。
- 取樣率固定為 48 kHz，若未來更改 WM8731 設定，RTL 參數與文件需同步更新。
- 錄音長度受 SRAM 容量與單一 FLASH slot 容量限制，48 kHz mono 約可錄 21.8 秒。
- 本版本未實作 WAV/MP3 格式、檔案系統、SD card 或 Nios II 軟體控制。

## 結論

本專案成功將音訊輸入輸出、記憶體控制、狀態機、人機介面與顯示功能整合到 DE2-115 FPGA 平台上，完成一個可錄音、可儲存、可載入並可播放的硬體音訊系統。整體架構以 SRAM 承擔即時音訊緩衝，以 FLASH 承擔非揮發性儲存，讓資料流分工清楚，也降低了 FLASH 存取時序對播放連續性的影響。

透過 FLASH 寫入解鎖、四組 slot 選擇、header 檢查與固定的 `FLASH -> SRAM -> playback` 流程，系統在操作安全性與資料有效性上比單純錄放音架構更完整。LCD、HEX 與 LEDR 的加入，也讓使用者能直接觀察目前狀態、錄放秒數、輸入來源、儲存位置與音量變化，提升硬體測試與展示時的可讀性。

整體而言，本專案已達成數位系統設計中「音訊擷取、資料暫存、非揮發儲存、播放輸出與狀態顯示」的主要目標。後續若要擴充，可優先加入 checksum、stereo 儲存、較完整的硬體測試紀錄，或在目前穩定的錄放音架構上再加入頻譜分析等進階顯示功能。
