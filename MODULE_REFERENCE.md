# Module Reference And Maintenance Notes

This file records the purpose, usage, and important traits of the Verilog
modules in this project. Update this file whenever a module interface,
behavior, clocking assumption, or instantiation changes.

## Maintenance Rule

- Every RTL or IP-facing module change must update this document in the same
  work session.
- Record changes to ports, parameters, clock/reset behavior, bus timing,
  state-machine semantics, and testbench coverage.
- Prefer adding project-owned wrappers under `rtl/` instead of editing Terasic
  IP under `ip/`. If IP must be edited, document why and how to validate it.
- `.bak` files are historical backups and are not authoritative.

## Top Level

### `AudioSpectrum_FPGA`

- File: `rtl/audio_spectrum_top.v`
- Role: DE2-115 top entity. Wires reset, PLL, WM8731 audio path, I2C codec
  initialization, SRAM, FLASH, LCD, HEX, and LED status logic.
- Clock/reset:
  - Uses `CLOCK_50` as the main system clock.
  - `KEY[0]` is active-low board reset only.
  - `audio_pll` drives `AUD_XCK`.
- Audio:
  - Treats `AUD_BCLK`, `AUD_ADCLRCK`, and `AUD_DACLRCK` as codec-generated
    inputs.
  - Uses project-owned `audio_adc_aligned` and `audio_dac_aligned` instead of
    directly instantiating Terasic `AUDIO_ADC`/`AUDIO_DAC`.
- Controls:
  - `KEY[1]`: record/stop.
  - `KEY[2]`: play/pause.
  - `KEY[3]`: save/confirm/cancel depending on FSM state.
  - `SW[3]`: FLASH write unlock.
  - `SW[5]`: mute.
  - `SW[17]`: line-in/mic source selection.

## Project-Owned Audio Modules

### `audio_adc_aligned`

- File: `rtl/audio/audio_adc_aligned.v`
- Role: Captures WM8731 serial ADC data into a 32-bit async FIFO.
- Clock/reset:
  - `bclk` is the write clock for serial capture/FIFO write.
  - `clk` is the host FIFO read clock.
  - `reset` and `clear` reset/clear active state.
- Behavior:
  - Uses WM8731 LRCK directly in the BCLK domain, matching the DE2-115 Audio
    demo timing style; no 50 MHz debounce.
  - Packs left/right 16-bit samples into `{left, right}`.
  - `sample_tick` toggles into `clk` domain once per captured stereo sample.
- Reason for existence:
  - Avoids modifying Terasic IP and avoids LRCK debounce bit-shift artifacts.

### `audio_dac_aligned`

- File: `rtl/audio/audio_dac_aligned.v`
- Role: Reads 32-bit host samples from an async FIFO and serializes to WM8731.
- Clock/reset:
  - `clk` is the host FIFO write clock.
  - `bclk` is the FIFO read/serial output clock.
  - `reset` and `clear` reset/clear active state.
- Behavior:
  - Uses WM8731 LRCK directly for the FIFO read clock, matching the DE2-115
    Audio demo timing style; no 50 MHz debounce.
  - Emits I2S serial data on `dacdat`.
  - `sample_tick` toggles into `clk` domain once per codec DAC sample slot.

## System Control

### `system_fsm`

- File: `rtl/system/system_fsm.v`
- Role: Main controller for record, stop, SRAM playback, save to FLASH, load
  from FLASH to SRAM, and playback.
- Parameters:
  - `SAMPLE_RATE_HZ`: header metadata and default timing reference.
  - `SRAM_MAX_ADDR`: highest SRAM word address.
  - `FLASH_HEADER_WORDS`: number of 16-bit header words.
  - `FLASH_AUDIO_BASE`: byte address where audio data begins.
  - `CODEC_INIT_WAIT`: startup wait cycles.
  - `LOAD_DONE_WAIT`: post-load display wait cycles.
- Inputs:
  - `cancel_pulse` is the back/cancel command. Do not route board reset here.
  - `key1_pulse`, `key2_pulse`, `key3_pulse` are debounced one-cycle commands.
  - Directly drives SRAM pins and instantiates `flash_controller`.
- Important behavior:
  - Records left channel samples to SRAM.
  - During SRAM playback, reads one SRAM word per `dac_sample_tick` so playback
    speed follows the codec LRCK/sample rate instead of the 50 MHz FSM speed.
  - Saves 16-bit SRAM words to 8-bit FLASH low byte first.
  - Loads FLASH header, validates magic, restores length, then loads audio.
  - `SW[3]` must be high before save can start.
- JTAG/SignalTap debug:
  - Preserved counters expose SRAM/FLASH operation timing in `CLOCK_50` cycles:
    `dbg_sram_pending_cycles`, `dbg_sram_last_cycles`,
    `dbg_flash_busy_cycles`, `dbg_flash_last_cycles`.

### `flash_controller`

- File: `rtl/system/flash_controller.v`
- Role: Low-level AMD-style byte command controller for FLASH erase, program,
  and read.
- Interface:
  - Commands: `cmd_erase`, `cmd_write`, `cmd_read`.
  - Status: `busy`, `cmd_done`, `cmd_rdata`.
  - Direct FLASH pins: address, CE/OE/WE/RST/WP, RY, DQ OE/data.
- Timing:
  - Uses `clk` for command sequencing.
  - Polls `FL_RY` for erase/program completion.

### `key_debounce`

- File: `rtl/system/key_debounce.v`
- Role: Debounces active-low DE2-115 buttons.
- Output: active-high pressed level.

### `one_pulse`

- File: `rtl/system/one_pulse.v`
- Role: Converts a debounced active-high level into a one-clock pulse.

### `flash_test_top`

- File: `rtl/system/flash_test_top.v`
- Role: Standalone FLASH format test top, not part of main qsf build.
- Use only for FLASH controller bench/debug.

## Display And Status

### `record_time_counter`

- File: `rtl/display/record_time_counter.v`
- Role: Counts record/play seconds.
- Behavior:
  - `record_seconds` increments from `record_sample_tick`.
  - `play_seconds` increments from `play_sample_tick`.
  - This intentionally uses codec-side sample ticks, not FSM write speed.

### `ledr_volume_meter`

- File: `rtl/display/ledr_volume_meter.v`
- Role: Drives LEDR volume bar from signed PCM sample magnitude.

### `hex_status_timer_display`

- File: `rtl/display/hex_status_timer_display.v`
- Role: Multiplexes mode/status/time/input-source values to HEX displays.

### `sevenseg_decoder`

- File: `rtl/display/sevenseg_decoder.v`
- Role: Converts a 4-bit value to active-low seven-segment output.

### `lcd_status_controller`

- File: `rtl/display/lcd_status_controller.v`
- Role: Generates LCD status messages and drives `LCD_Controller`.
- Behavior:
  - Refreshes the 16x2 LCD continuously after initialization.
  - Idle screen labels `KEY[2]` as FLASH load/play.
  - Record-stop screen shows the captured `record_seconds` value so hardware
    testing can confirm that the recorded length was updated.
- Note: Current LCD path writes only; `LCD_RW` is held low through the lower
  level controller.

## Terasic IP And Generated Blocks

### `audio_fifo`

- File: `ip/terasic_audio/audio_fifo.v`
- Role: Async FIFO used by audio ADC/DAC paths.
- Keep as IP. Project-owned audio wrappers instantiate it directly.

### `AUDIO_ADC` / `AUDIO_DAC`

- Files: `ip/terasic_audio/AUDIO_ADC.v`, `ip/terasic_audio/AUDIO_DAC.v`
- Role: Terasic-style audio serial wrappers.
- Status: Kept available but not used by the main top. Main design uses
  `audio_adc_aligned` and `audio_dac_aligned`.
- Do not modify unless there is a project decision to fork Terasic IP.

### `AUDIO_IF`

- File: `ip/terasic_audio/AUDIO_IF.v`
- Role: Terasic audio interface IP. Not currently instantiated by main top.

### `I2C_AV_Config`

- File: `ip/terasic_i2c/I2C_AV_Config.v`
- Role: Initializes WM8731 codec registers and supports input source switching.
- Current audio config:
  - Analog path selects line-in or mic via `SW[17]`.
  - Digital path and format are fixed by LUT values.
  - Digital audio interface format is `16'h0E42`: WM8731 master mode,
    16-bit I2S. This matches the DE2-115 Audio demo and must match
    `audio_adc_aligned`,
    `audio_dac_aligned`, and the fact that `AUD_BCLK`, `AUD_ADCLRCK`, and
    `AUD_DACLRCK` are top-level inputs.
  - Sample rate follows codec/register configuration.
- Maintenance note:
  - This IP-style file is edited because WM8731 register programming is part
    of the project behavior. Revalidate audio clocking/noise after changing
    `SET_FORMAT` or `SAMPLE_CTRL`.

### `I2C_Controller`

- File: `ip/terasic_i2c/I2C_Controller.v`
- Role: Low-level I2C command shifter used by `I2C_AV_Config`.

### `Reset_Delay`

- File: `ip/terasic_clock/Reset_Delay.v`
- Role: Generates staged reset release from `KEY[0]`.

### `audio_pll`

- File: `ip/terasic_clock/audio_pll.v`
- Role: Generates WM8731 master clock `AUD_XCK`.

### `PLL`

- File: `ip/terasic_clock/PLL.v`
- Role: Terasic PLL IP. Not currently the active audio PLL in main top.

### `LCD_Controller`

- File: `ip/terasic_lcd/LCD_Controller.v`
- Role: Low-level LCD write controller.

### `LCD`

- File: `ip/terasic_lcd/LCD.V`
- Role: Terasic LCD module. Not currently instantiated by main top.

### `SEG7_IF`

- File: `ip/terasic_seg7/SEG7_IF.v`
- Role: Terasic seven-segment IP. Main top uses project-owned HEX logic.

### `TERASIC_SRAM`

- File: `ip/terasic_sram/TERASIC_SRAM.v`
- Role: Terasic SRAM helper. Main top directly controls SRAM pins instead.

## Simulation Modules

### `tb_system_fsm`

- File: `sim/tb_system_fsm.v`
- Role: Behavioral smoke test for reset, record, SRAM playback, FLASH save
  gate, cancel, save, load, and playback.

### `system_flash_model`

- File: `sim/tb_system_fsm.v`
- Role: Simple FLASH model used by `tb_system_fsm`.

### `tb_flash_test`

- File: `sim/tb_flash_test.v`
- Role: Legacy FLASH format testbench for `flash_test_top`.
- Note: It compiles under Icarus but currently times out in this environment.

### `flash_model`

- File: `sim/tb_flash_test.v`
- Role: Legacy FLASH model used by `tb_flash_test`.
