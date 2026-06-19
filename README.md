# DE2-115 Audio Recorder / Player

DE2-115 FPGA audio recorder and player built with Quartus II 13.1. The design records WM8731 audio input into SRAM, saves recordings to FLASH on user confirmation, loads FLASH data back into SRAM before playback, and uses LEDR as a live volume meter.

## Hardware

- Board: Terasic DE2-115
- FPGA: Cyclone IV E `EP4CE115F29C7`
- Audio codec: WM8731
- Memory: on-board SRAM and FLASH
- Main outputs: LEDR volume bar, LEDG debug/status, HEX display, LCD 16x2

## Project Files

- Quartus project: `quartus/AudioSpectrum_FPGA.qpf`
- Top entity: `AudioSpectrum_FPGA`
- Top RTL: `rtl/audio_spectrum_top.v`
- Project-owned RTL: `rtl/`
- Terasic/generated IP: `ip/`
- Testbenches: `sim/`
- Full project spec: `DE2_115_AUDIO_SPEC.md`
- Module notes: `MODULE_REFERENCE.md`

## Controls

| Input | Function |
| --- | --- |
| `KEY[0]` | Board reset |
| `KEY[1]` | Record / stop |
| `KEY[2]` | Play / pause |
| `KEY[3]` | Save / confirm / cancel, depending on FSM state |
| `SW[0]` | Enable LEDR volume meter |
| `SW[3]` | Unlock FLASH write |
| `SW[4]` | Loop playback |
| `SW[5]` | Mute audio output |
| `SW[7:6]` | LEDR sensitivity: 1x, 2x, 4x, 8x |
| `SW[11:10]` | FLASH slot select, slot 0 to 3 |
| `SW[17]` | Line-in / mic input source |

`SW[1]`, `SW[2]`, `SW[8]`, `SW[9]`, and `SW[16:12]` are not part of the current user-facing flow.

## Build

Open `quartus/AudioSpectrum_FPGA.qpf` in Quartus II 13.1, or compile from a terminal:

```bat
cd quartus
"E:\altera\13.1\quartus\bin64\quartus_sh.exe" --flow compile AudioSpectrum_FPGA
```

If the installation is 32-bit, use `E:\altera\13.1\quartus\bin\quartus_sh.exe`.

The tracked programming image is `quartus/AudioSpectrum_FPGA.pof`.

## Simulation

Behavioral smoke tests are under `sim/`:

- `tb_system_fsm.v`
- `tb_ledr_volume_meter.v`
- `tb_hex_status_timer_display.v`
- `tb_flash_test.v`

Run them with the simulator available in your local setup. `tb_flash_test.v` is legacy and may timeout in some environments.

## Notes

- Do not recreate the Quartus project or overwrite existing pin assignments.
- Keep project-owned wrappers under `rtl/`; avoid editing Terasic IP in `ip/` unless the module notes are updated.
- Playback intentionally follows `FLASH -> SRAM -> audio codec`; direct FLASH streaming is not part of this version.
- License: GPL-3.0, see `LICENSE`.
