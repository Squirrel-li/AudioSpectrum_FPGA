# 聲音處理流程

本文依目前 RTL 實作整理聲音從輸入、錄音、暫存、儲存、載入、播放到顯示的完整流程。主要參考模組為 `AudioSpectrum_FPGA`、`system_fsm`、`audio_adc_aligned`、`audio_dac_aligned`、`I2C_AV_Config`、`ledr_volume_meter` 與 `record_time_counter`。

## 1. 整體資料流

系統的聲音資料流分成三條主要路徑：

```text
錄音路徑：
Line-in / Mic-in
    -> WM8731 ADC
    -> I2S serial data
    -> audio_adc_aligned
    -> ADC async FIFO
    -> system_fsm
    -> SRAM mono buffer

儲存路徑：
SRAM mono buffer
    -> system_fsm
    -> flash_controller
    -> FLASH selected slot

播放路徑：
FLASH selected slot
    -> flash_controller
    -> system_fsm
    -> SRAM mono buffer
    -> system_fsm
    -> DAC async FIFO
    -> audio_dac_aligned
    -> I2S serial data
    -> WM8731 DAC
    -> headphone / speaker / line-out
```

錄音時，聲音不會直接寫入 FLASH，而是先寫入 SRAM。使用者確認後，才把 SRAM 內容寫入 FLASH。從 FLASH 播放時，系統也不直接串流 FLASH，而是先將 FLASH 音訊載入 SRAM，再由 SRAM 穩定送出到 DAC。

## 2. Clock 與 WM8731 初始化

系統主時脈為 `CLOCK_50`。音訊 CODEC 使用 `audio_pll` 產生的 `AUD_XCK` 作為外部 master clock。WM8731 透過 `I2C_AV_Config` 初始化，I2C clock 約為 20 kHz。

初始化時，`I2C_AV_Config` 會設定 WM8731 的輸入音量、耳機輸出、analog path、digital path、power、digital audio format、sample control 與 active bit。與聲音流程最直接相關的是：

| 設定 | 作用 |
| --- | --- |
| Analog path `16'h0810` | Line-in 輸入 |
| Analog path `16'h0815` | Mic-in 輸入，含 mic boost |
| Digital path `16'h0A00` | 數位音訊路徑設定 |
| Format `16'h0E42` | WM8731 master mode、16-bit I2S |
| Sample control `16'h1002` | CODEC 取樣控制 |
| Active `16'h1201` | 啟用 digital audio interface |

`SW[17]` 用來選擇 Line-in 或 Mic-in。切換後，analog path 會改寫成 Line-in 或 Mic-in 對應設定。因為 WM8731 設成 master mode，所以 `AUD_BCLK`、`AUD_ADCLRCK`、`AUD_DACLRCK` 由 CODEC 端產生，FPGA 端把這些 clock 當作音訊 serial interface 的時序來源。

## 3. 類比聲音進入 WM8731

聲音可從兩種來源進入：

| 輸入來源 | 控制 | 說明 |
| --- | --- | --- |
| Line-in | `SW[17]=0` | 外部音源由 LINE IN 輸入 |
| Mic-in | `SW[17]=1` | 板上或外部麥克風輸入 |

類比聲音進入 WM8731 後，由 WM8731 ADC 轉成 16-bit signed PCM。左右聲道透過 I2S serial format 送到 FPGA：

```text
AUD_ADCDAT   : ADC serial audio data
AUD_ADCLRCK  : ADC left/right channel clock
AUD_BCLK     : serial bit clock
```

在目前設計中，ADC wrapper 會接收 stereo sample，但後續錄音只保存 left channel，形成 mono 錄音資料。

## 4. ADC serial data 轉成 FPGA 內部 sample

`audio_adc_aligned` 負責把 WM8731 的 I2S serial data 轉成 FPGA 可處理的 32-bit sample。

流程如下：

1. `audio_adc_aligned` 在 `AUD_BCLK` domain 監看 `AUD_ADCLRCK`。
2. `AUD_ADCLRCK` 切換時，代表左右聲道邊界改變。
3. I2S 格式在 LRCK 邊界後延遲一個 bit clock 才開始有效資料，因此模組會等一個 clock 後再收資料。
4. 模組依序從 `AUD_ADCDAT` 收 32 bit，形成 `{left[15:0], right[15:0]}`。
5. 一組 stereo sample 收完後，寫入 `audio_fifo`。
6. FIFO write clock 是 `AUD_BCLK`，read clock 是 `CLOCK_50`，用 async FIFO 完成 clock domain crossing。
7. 每收到一組 sample，模組會 toggle `sample_toggle_bclk`，再同步到 `CLOCK_50` domain，產生 `adc_sample_tick`。

轉換後的資料格式為：

```text
adc_data[31:16] = left channel  signed 16-bit PCM
adc_data[15:0]  = right channel signed 16-bit PCM
```

目前系統錄音只取 `adc_data[31:16]`，也就是 left channel。

## 5. 錄音寫入 SRAM

使用者在 idle 狀態按下 `KEY[1]` 後，`system_fsm` 進入 `ST_RECORD`。

進入錄音時，系統會做幾件事：

1. 清除錄音時間計數器。
2. 清除 audio FIFO，避免前一次殘留 sample 影響本次錄音。
3. 將 `sram_write_ptr` 歸零，從 SRAM address 0 開始寫。
4. 將 `record_length_words` 歸零。
5. 將狀態設為 recording，LCD/HEX 顯示錄音中。

錄音期間，每當 ADC FIFO 不空且 SRAM 沒有操作 pending，FSM 會讀一筆 `adc_data`。讀出後只取 left channel：

```text
sample = adc_data[31:16]
```

接著把這個 16-bit mono sample 寫入 SRAM：

```text
SRAM_ADDR  = sram_write_ptr
SRAM_DQ    = sample
SRAM_CE_N  = 0
SRAM_WE_N  = 0
SRAM_OE_N  = 1
SRAM_UB_N  = 0
SRAM_LB_N  = 0
```

SRAM 寫入流程使用簡單 wait state：

1. 發出 ADC FIFO read。
2. 下一個 cycle 取得 `adc_data`。
3. 對 SRAM 放 address 與 data，拉低 write enable。
4. 多保持一個 cycle。
5. 拉高 write enable，結束此次 SRAM write。
6. `sram_write_ptr` 加一。
7. `record_length_words` 更新為目前已錄下的 word 數。

錄音資料在 SRAM 中的格式很單純：

```text
SRAM[0] = 第 0 筆 left-channel mono sample
SRAM[1] = 第 1 筆 left-channel mono sample
SRAM[2] = 第 2 筆 left-channel mono sample
...
```

每筆 sample 是 16-bit signed PCM。因為目前取樣率固定為 48 kHz mono，SRAM 1,048,576 words 理論上約可容納：

```text
1,048,576 / 48,000 = 21.8 秒
```

實際錄音上限會取 SRAM 容量與單一 FLASH slot 容量兩者中較小者，確保錄完的資料可以被儲存到目前 slot。

## 6. 錄音時的即時監聽

錄音期間，FSM 除了把 left channel 寫入 SRAM，也會把同一筆 sample 送到 DAC FIFO，作為即時監聽輸出。

資料格式為：

```text
dac_data = {sample, sample}
```

也就是把 mono sample 複製到左右聲道。若 `SW[5]` 為 1，系統改送：

```text
dac_data = 32'd0
```

這只會讓 DAC 輸出靜音，不會停止錄音、不會停止 SRAM write，也不會停止錄音秒數。

## 7. 錄音停止與暫存資料

錄音可由兩種情況停止：

| 停止原因 | 結果 |
| --- | --- |
| 使用者再次按 `KEY[1]` | 停止錄音，進入 `ST_RECORD_STOP` |
| SRAM 或可儲存 slot 容量到達上限 | 自動停止，設 `sram_full` |

停止後，`record_length_words` 會鎖定本次錄音長度，`has_record_data` 表示 SRAM 中有有效暫存資料。此時資料仍只在 SRAM，尚未永久保存。

在 `ST_RECORD_STOP` 狀態可做三件事：

| 操作 | 流程 |
| --- | --- |
| `KEY[1]` | 重新錄音，覆蓋 SRAM 暫存 |
| `KEY[2]` | 直接播放目前 SRAM 暫存內容 |
| `KEY[3]` 且 `SW[3]=1` | 儲存 SRAM 內容到 FLASH |

這裡的 `KEY[2]` 是錄音後預聽 SRAM 暫存資料；idle 狀態下按 `KEY[2]` 則是從 FLASH slot 載入後播放。

## 8. 音量顯示流程

LEDR 音量條不是另外取音訊資料，而是使用 FSM 輸出的目前 sample。

錄音時：

```text
current_sample = adc_data[31:16]
sample_valid_out = 1
```

播放時：

```text
current_sample = sram_rdata
sample_valid_out = 1
```

`ledr_volume_meter` 收到 sample 後會進行以下處理：

1. 將 signed PCM 轉成絕對值：

```text
abs_sample = sample_in < 0 ? -sample_in : sample_in
```

2. 使用簡單 IIR 平滑，避免 LEDR 抖動太明顯：

```text
smooth_amp = smooth_amp - (smooth_amp >> 3) + (abs_sample >> 3)
```

3. 依 `SW[7:6]` 放大靈敏度：

| `SW[7:6]` | 靈敏度 |
| --- | --- |
| `00` | 1x |
| `01` | 2x |
| `10` | 4x |
| `11` | 8x |

4. 將振幅換算成 0 到 18 顆 LED：

```text
bars = min((smooth_amp << sensitivity) * 18 / 32768, 18)
```

5. 產生 thermometer code：

```text
bars = 0  -> LEDR[17:0] = 18'b0
bars = 1  -> LEDR[0]    = 1
bars = 2  -> LEDR[1:0]  = 2'b11
...
bars = 18 -> LEDR[17:0] = all on
```

若 `SW[0]=0`，LEDR 音量條關閉並全暗，但錄音、儲存、播放資料流不受影響。

## 9. 錄音與播放秒數

`record_time_counter` 不用 FSM cycle 數估計時間，而是用 codec sample tick 計算。

錄音秒數：

```text
record_active && adc_sample_tick
```

播放秒數：

```text
play_active && dac_sample_tick
```

每累積 `SAMPLE_RATE_HZ = 48000` 個 sample tick，秒數加一。顯示秒數飽和在 59 秒，避免 HEX 顯示超出兩位數。

## 10. SRAM 儲存到 FLASH

錄音停止後，使用者按 `KEY[3]` 且 `SW[3]=1` 時，系統進入 FLASH 儲存流程。`SW[3]` 是 FLASH 寫入解鎖；若未打開，FSM 不會進入 erase/program 流程。

儲存開始時，系統會鎖定目前 `SW[11:10]` 選到的 slot：

| `SW[11:10]` | Slot | FLASH base |
| --- | --- | --- |
| `00` | Slot 0 | `23'h000000` |
| `01` | Slot 1 | `23'h200000` |
| `10` | Slot 2 | `23'h400000` |
| `11` | Slot 3 | `23'h600000` |

slot 一旦在儲存流程開始時鎖定，中途切換 `SW[11:10]` 不會改變本次操作目標。

FLASH 儲存分三階段：

```text
ST_SAVE_FLASH_ERASE
    -> ST_SAVE_FLASH_WRITE_HDR
    -> ST_SAVE_FLASH_WRITE_DATA
    -> ST_SAVE_FLASH_DONE
```

### 10.1 Erase

FLASH 寫入前必須先 erase。FSM 會根據本次錄音長度計算需要覆蓋的 sector 範圍，從選定 slot 的 sector base 開始 erase。低階 `flash_controller` 使用 AMD-style command sequence，並用 `FL_RY` 判斷 erase/program 是否完成。

若 erase 超時，FSM 設定 `flash_error` 並進入 `ST_ERROR`。

### 10.2 Header

erase 完成後，系統先寫入 16 個 16-bit header word，共 32 bytes。音訊資料從：

```text
flash_data_base = slot_base + 32
```

開始寫入。

header 內容如下：

| Word offset | 欄位 | 目前內容 |
| ---: | --- | --- |
| 0 | MAGIC | `16'hA55A` |
| 1 | VERSION | `16'h0001` |
| 2 | SAMPLE_RATE | `48000` 的低 16 bit |
| 3 | FORMAT | `16'h0000`，代表 mono signed PCM |
| 4 | LENGTH_LO | `record_length_words[15:0]` |
| 5 | LENGTH_HI | `record_length_words[19:16]` |
| 6~15 | RESERVED | `16'h0000` |

每個 16-bit word 會拆成兩個 byte 寫入 FLASH，順序是低位元組先寫、高位元組後寫：

```text
FLASH[addr + 0] = word[7:0]
FLASH[addr + 1] = word[15:8]
```

### 10.3 Audio data

header 寫完後，FSM 從 SRAM address 0 開始讀出錄音資料。每讀出一個 16-bit sample，就拆成兩個 byte 寫入 FLASH：

```text
FLASH[flash_data_base + n*2 + 0] = SRAM[n][7:0]
FLASH[flash_data_base + n*2 + 1] = SRAM[n][15:8]
```

寫入 word 數達到 `record_length_words` 後，儲存完成並進入 `ST_SAVE_FLASH_DONE`。

目前 RTL 寫入 VERSION、SAMPLE_RATE 與 FORMAT 供資料追溯，但播放載入時主要檢查 MAGIC 與 LENGTH；尚未用 sample rate 或 format mismatch 阻擋播放。

## 11. FLASH 載入到 SRAM

在 idle 狀態按下 `KEY[2]` 時，系統不會直接播放目前 SRAM，而是從選定 FLASH slot 載入資料。

流程如下：

```text
ST_LOAD_FLASH_READ_HDR
    -> ST_LOAD_FLASH_TO_SRAM
    -> ST_LOAD_FLASH_DONE
    -> ST_PLAY_SRAM
```

### 11.1 Read header

FSM 先鎖定目前 `SW[11:10]` 選到的 slot，從 slot base 開始逐 byte 讀 header。每兩個 byte 組回一個 16-bit word：

```text
word = {high_byte, low_byte}
```

讀到 word 0 時，檢查 MAGIC 是否為 `16'hA55A`。若 MAGIC 不正確，代表該 slot 沒有有效音訊，系統進入錯誤狀態。

讀到 word 4 與 word 5 時，組出音訊長度：

```text
flash_audio_length[15:0]  = LENGTH_LO
flash_audio_length[19:16] = LENGTH_HI[3:0]
```

header 有效後，FSM 把 FLASH byte pointer 移到 `slot_base + 32`，準備載入音訊資料。

### 11.2 Load audio data

載入時，FSM 每次從 FLASH 讀兩個 byte，組回一個 16-bit sample：

```text
sample = {high_byte, low_byte}
```

再寫入 SRAM：

```text
SRAM[sram_write_ptr] = sample
```

每寫入一筆，`sram_write_ptr` 與 `fl_data_word_counter` 加一。當載入 word 數達到 `flash_audio_length`，系統更新：

```text
record_length_words = flash_audio_length
play_from_sram_ready = 1
```

然後進入 `ST_LOAD_FLASH_DONE`。短暫顯示 load done 後，自動進入 `ST_PLAY_SRAM` 播放。

若 FLASH 讀取或載入超時，FSM 設定 `flash_error` 並進入 `ST_ERROR`。

## 12. SRAM 播放到 DAC

所有正式播放最後都走 `ST_PLAY_SRAM`。來源可能有兩種：

| 來源 | 進入方式 |
| --- | --- |
| 錄音後 SRAM 暫存 | `ST_RECORD_STOP` 按 `KEY[2]` |
| FLASH 已儲存資料 | idle 按 `KEY[2]`，先 FLASH -> SRAM，再播放 |

播放時，FSM 不用 `CLOCK_50` 速度連續讀 SRAM，而是等待 `dac_sample_tick`。這個 tick 來自 `audio_dac_aligned`，對齊 WM8731 DAC 的 sample 時序。這樣 SRAM 每次只在 DAC 需要下一筆 sample 時讀一筆資料，播放速度會跟著 CODEC 的實際音訊時序走。

播放每一筆 sample 的流程：

1. 等待 `dac_sample_tick`。
2. 若 DAC FIFO 未滿且 SRAM 沒有 pending 操作，發起 SRAM read。
3. 設定 `SRAM_ADDR = sram_read_ptr`，拉低 `SRAM_CE_N` 與 `SRAM_OE_N`。
4. 等待 SRAM read data 穩定。
5. 讀出 `sram_rdata`。
6. 將 `sram_rdata` 複製成 stereo：

```text
dac_data = {sram_rdata, sram_rdata}
```

7. 若 `SW[5]=1`，改送 `32'd0` 靜音。
8. 對 DAC FIFO 發出 `dac_write`。
9. `sram_read_ptr` 加一。
10. 若已讀到 `record_length_words - 1`，依 `SW[4]` 決定停止或循環。

循環播放規則：

| `SW[4]` | 播放到結尾 |
| --- | --- |
| 0 | 停止播放 |
| 1 | `sram_read_ptr` 回到 0，重新播放 |

播放中按 `KEY[2]` 會進入 pause，再按 `KEY[2]` 繼續。取消或停止時，如果是錄音後預聽，返回 `ST_RECORD_STOP`；如果是 FLASH 載入播放，返回 idle。

## 13. DAC sample 轉回 I2S serial data

`audio_dac_aligned` 負責把 FPGA 內部的 32-bit `{left, right}` sample 送回 WM8731。

流程如下：

1. `system_fsm` 在 `CLOCK_50` domain 寫入 `dac_data` 到 DAC async FIFO。
2. DAC FIFO write clock 是 `CLOCK_50`，read clock 依 `AUD_DACLRCK` 的 channel 邊界。
3. `audio_dac_aligned` 在新的 stereo frame 開始時，若 FIFO 不空，就取出一筆 32-bit sample；若 FIFO 空，就輸出 0，避免送出舊資料。
4. 模組在 `AUD_BCLK` 負緣依序 shift 出 32 bit 到 `AUD_DACDAT`。
5. WM8731 DAC 接收 serial data 後轉回類比聲音。

目前播放資料是 mono 複製到左右聲道，因此：

```text
left output  = SRAM sample
right output = SRAM sample
```

## 14. 顯示與狀態同步

聲音流程同時驅動顯示介面：

| 顯示 | 資料來源 | 用途 |
| --- | --- | --- |
| LCD | `fsm_state`、秒數、錯誤旗標、輸入來源 | 顯示目前操作狀態 |
| HEX | `mode_code`、`status_code`、slot、input source、seconds | 顯示模式、狀態、slot、來源、秒數 |
| LEDR | `current_sample`、`sample_valid_out` | 顯示音量條 |
| LEDG | debug/status flags | 顯示 PLL lock、FLASH header、SRAM full、錯誤與 FSM state |

因此聲音資料不是只被送去記憶體或 DAC，也同時被抽出振幅與狀態資訊，用來讓使用者確認系統正在錄音、儲存、載入或播放。

## 15. 錯誤與保護機制

聲音流程中有幾個保護點：

| 保護點 | 目的 |
| --- | --- |
| `SW[3]` FLASH unlock | 避免未確認時誤寫 FLASH |
| slot latch | 避免儲存/載入中途切換 slot 造成位址錯亂 |
| FLASH MAGIC check | 避免播放無效 FLASH 內容 |
| SRAM/slot 容量限制 | 避免錄音超出可儲存範圍 |
| FLASH erase/write/load timeout | 避免記憶體操作卡死 |
| DAC FIFO empty output zero | 避免 FIFO 空時播放舊資料 |
| `SW[5]` mute | 靜音輸出但不中斷資料流 |

這些保護讓系統在硬體展示時比較容易判斷問題來源，也避免把無效資料當成音訊播放。

## 16. 一句話流程總結

本專案的聲音處理核心是：WM8731 將類比聲音轉成 16-bit I2S sample，FPGA 以 async FIFO 跨時脈接收後只取 left channel 寫入 SRAM，使用者確認後再把 SRAM mono PCM 以 header 加資料的格式寫入 FLASH；播放時先驗證 FLASH header 並載入 SRAM，再依 DAC sample tick 從 SRAM 讀出 mono sample、複製成左右聲道送回 WM8731，LEDR、HEX 與 LCD 同步顯示音量、時間與系統狀態。
