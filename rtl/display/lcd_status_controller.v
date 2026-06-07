//============================================================================
// Module: lcd_status_controller
// Description: Manages the 16x2 LCD display on the DE2-115 board.
//              Shows different text content based on the current system FSM
//              state. Uses LCD_Controller.v as the low-level write engine.
//
// Target:  Cyclone IV E (EP4CE115F29C7) — Quartus II 13.1
// Author:  Auto-generated
// Date:    2026-06-07
//============================================================================

module lcd_status_controller (
    input  wire        clk,           // 50 MHz
    input  wire        rst_n,
    input  wire [3:0]  fsm_state,     // current system FSM state
    input  wire [6:0]  record_seconds,
    input  wire [6:0]  play_seconds,
    input  wire        sram_full,
    input  wire        flash_error,
    input  wire        flash_header_valid,
    input  wire        sw_input_source, // 0 = Line In, 1 = Mic In
    input  wire        sw_flash_unlock, // SW3: 1 = Flash unlocked
    // LCD hardware pins
    output wire [7:0]  LCD_DATA,
    output wire        LCD_RW,
    output wire        LCD_EN,
    output wire        LCD_RS
);

    //========================================================================
    // FSM State Encoding (matches system_fsm.v)
    //========================================================================
    localparam ST_RESET                  = 4'd0;
    localparam ST_CODEC_INIT             = 4'd1;
    localparam ST_IDLE                   = 4'd2;
    localparam ST_RECORD                 = 4'd3;
    localparam ST_RECORD_STOP            = 4'd4;
    localparam ST_PLAY_SRAM              = 4'd5;
    localparam ST_PLAY_PAUSE             = 4'd6;
    localparam ST_SAVE_FLASH_ERASE       = 4'd7;
    localparam ST_SAVE_FLASH_WRITE_HDR   = 4'd8;
    localparam ST_SAVE_FLASH_WRITE_DATA  = 4'd9;
    localparam ST_SAVE_FLASH_DONE        = 4'd10;
    localparam ST_LOAD_FLASH_READ_HDR    = 4'd11;
    localparam ST_LOAD_FLASH_TO_SRAM     = 4'd12;
    localparam ST_LOAD_FLASH_DONE        = 4'd13;
    localparam ST_ERROR                  = 4'd14;
    localparam ST_SAVE_FLASH_ERASE_WAIT = 4'd15;

    //========================================================================
    // LCD Refresh FSM States
    //========================================================================
    localparam LCD_INIT_0       = 5'd0;   // Function set (0x38)
    localparam LCD_INIT_1       = 5'd1;   // Display ON, cursor OFF (0x0C)
    localparam LCD_INIT_2       = 5'd2;   // Clear display (0x01)
    localparam LCD_INIT_3       = 5'd3;   // Entry mode set (0x06)
    localparam LCD_SET_ADDR_L1  = 5'd4;   // Set DDRAM address line 1 (0x80)
    localparam LCD_WRITE_L1     = 5'd5;   // Write line 1 characters
    localparam LCD_SET_ADDR_L2  = 5'd6;   // Set DDRAM address line 2 (0xC0)
    localparam LCD_WRITE_L2     = 5'd7;   // Write line 2 characters
    localparam LCD_WAIT_DONE    = 5'd8;   // Wait for LCD_Controller oDone
    localparam LCD_DELAY        = 5'd9;   // Inter-command delay
    localparam LCD_REFRESH_IDLE = 5'd10;  // Brief pause before next cycle

    //========================================================================
    // ASCII Constants
    //========================================================================
    localparam SPACE = 8'h20;  // ' '

    //========================================================================
    // Display Buffer — 32 bytes: line1[0:15], line2[0:15]
    //========================================================================
    reg [7:0] line1 [0:15];
    reg [7:0] line2 [0:15];

    //========================================================================
    // Content Generator — wires for the desired display content
    //========================================================================
    reg [7:0] new_line1 [0:15];
    reg [7:0] new_line2 [0:15];

    // Seconds to ASCII conversion
    wire [3:0] rec_tens  = record_seconds / 10;
    wire [3:0] rec_ones  = record_seconds % 10;
    wire [7:0] rec_tens_ascii = {4'h3, rec_tens};
    wire [7:0] rec_ones_ascii = {4'h3, rec_ones};

    wire [3:0] play_tens  = play_seconds / 10;
    wire [3:0] play_ones  = play_seconds % 10;
    wire [7:0] play_tens_ascii = {4'h3, play_tens};
    wire [7:0] play_ones_ascii = {4'h3, play_ones};

    // Helper task to set line from a string (16 chars)
    // We use an integer loop and individual assignments in the always block.

    //------------------------------------------------------------------------
    // Combinational content selection
    //------------------------------------------------------------------------
    // Using a generate-friendly approach: a single always block
    // that fills new_line1/new_line2 arrays based on fsm_state.
    //------------------------------------------------------------------------
    integer i;
    always @(*) begin
        // Default: fill with spaces
        for (i = 0; i < 16; i = i + 1) begin
            new_line1[i] = SPACE;
            new_line2[i] = SPACE;
        end

        case (fsm_state)
            ST_RESET: begin
                // "SYSTEM RESET   "
                new_line1[ 0] = "S"; new_line1[ 1] = "Y"; new_line1[ 2] = "S";
                new_line1[ 3] = "T"; new_line1[ 4] = "E"; new_line1[ 5] = "M";
                new_line1[ 6] = SPACE;
                new_line1[ 7] = "R"; new_line1[ 8] = "E"; new_line1[ 9] = "S";
                new_line1[10] = "E"; new_line1[11] = "T";
                // "PLEASE WAIT    "
                new_line2[ 0] = "P"; new_line2[ 1] = "L"; new_line2[ 2] = "E";
                new_line2[ 3] = "A"; new_line2[ 4] = "S"; new_line2[ 5] = "E";
                new_line2[ 6] = SPACE;
                new_line2[ 7] = "W"; new_line2[ 8] = "A"; new_line2[ 9] = "I";
                new_line2[10] = "T";
            end

            ST_CODEC_INIT: begin
                // "CODEC INIT     "
                new_line1[ 0] = "C"; new_line1[ 1] = "O"; new_line1[ 2] = "D";
                new_line1[ 3] = "E"; new_line1[ 4] = "C"; new_line1[ 5] = SPACE;
                new_line1[ 6] = "I"; new_line1[ 7] = "N"; new_line1[ 8] = "I";
                new_line1[ 9] = "T";
                // "PLEASE WAIT    "
                new_line2[ 0] = "P"; new_line2[ 1] = "L"; new_line2[ 2] = "E";
                new_line2[ 3] = "A"; new_line2[ 4] = "S"; new_line2[ 5] = "E";
                new_line2[ 6] = SPACE;
                new_line2[ 7] = "W"; new_line2[ 8] = "A"; new_line2[ 9] = "I";
                new_line2[10] = "T";
            end

            ST_IDLE: begin
                // "AUDIO: LINE-IN " or "AUDIO: MIC-IN  "
                new_line1[ 0] = "A"; new_line1[ 1] = "U"; new_line1[ 2] = "D";
                new_line1[ 3] = "I"; new_line1[ 4] = "O"; new_line1[ 5] = ":";
                new_line1[ 6] = SPACE;
                if (!sw_input_source) begin
                    new_line1[ 7] = "L"; new_line1[ 8] = "I"; new_line1[ 9] = "N";
                    new_line1[10] = "E"; new_line1[11] = "-"; new_line1[12] = "I";
                    new_line1[13] = "N";
                end else begin
                    new_line1[ 7] = "M"; new_line1[ 8] = "I"; new_line1[ 9] = "C";
                    new_line1[10] = "-"; new_line1[11] = "I"; new_line1[12] = "N";
                end
                // "K1 REC K2 LOAD "
                new_line2[ 0] = "K"; new_line2[ 1] = "1"; new_line2[ 2] = SPACE;
                new_line2[ 3] = "R"; new_line2[ 4] = "E"; new_line2[ 5] = "C";
                new_line2[ 6] = SPACE;
                new_line2[ 7] = "K"; new_line2[ 8] = "2"; new_line2[ 9] = SPACE;
                new_line2[10] = "L"; new_line2[11] = "O"; new_line2[12] = "A";
                new_line2[13] = "D";
            end

            ST_RECORD: begin
                // "REC: LINE-IN   " or "REC: MIC-IN    "
                new_line1[ 0] = "R"; new_line1[ 1] = "E"; new_line1[ 2] = "C";
                new_line1[ 3] = ":"; new_line1[ 4] = SPACE;
                if (!sw_input_source) begin
                    new_line1[ 5] = "L"; new_line1[ 6] = "I"; new_line1[ 7] = "N";
                    new_line1[ 8] = "E"; new_line1[ 9] = "-"; new_line1[10] = "I";
                    new_line1[11] = "N";
                end else begin
                    new_line1[ 5] = "M"; new_line1[ 6] = "I"; new_line1[ 7] = "C";
                    new_line1[ 8] = "-"; new_line1[ 9] = "I"; new_line1[10] = "N";
                end
                // "T=XXs SRAM     "
                new_line2[ 0] = "T"; new_line2[ 1] = "=";
                new_line2[ 2] = rec_tens_ascii;
                new_line2[ 3] = rec_ones_ascii;
                new_line2[ 4] = "s"; new_line2[ 5] = SPACE;
                new_line2[ 6] = "S"; new_line2[ 7] = "R"; new_line2[ 8] = "A";
                new_line2[ 9] = "M";
            end

            ST_RECORD_STOP: begin
                // "REC DONE XXs   "
                new_line1[ 0] = "R"; new_line1[ 1] = "E"; new_line1[ 2] = "C";
                new_line1[ 3] = SPACE;
                new_line1[ 4] = "D"; new_line1[ 5] = "O"; new_line1[ 6] = "N";
                new_line1[ 7] = "E"; new_line1[ 8] = SPACE;
                new_line1[ 9] = rec_tens_ascii;
                new_line1[10] = rec_ones_ascii;
                new_line1[11] = "s";
                if (sw_flash_unlock) begin
                    // "REC:1 PL:2 SAV:3 "
                    new_line2[ 0] = "R"; new_line2[ 1] = "E"; new_line2[ 2] = "C";
                    new_line2[ 3] = ":"; new_line2[ 4] = "1"; new_line2[ 5] = SPACE;
                    new_line2[ 6] = "P"; new_line2[ 7] = "L"; new_line2[ 8] = ":";
                    new_line2[ 9] = "2"; new_line2[10] = SPACE;
                    new_line2[11] = "S"; new_line2[12] = "A"; new_line2[13] = "V";
                    new_line2[14] = ":"; new_line2[15] = "3";
                end else begin
                    // "SW3 UNLK TO SAVE"
                    new_line2[ 0] = "S"; new_line2[ 1] = "W"; new_line2[ 2] = "3";
                    new_line2[ 3] = SPACE;
                    new_line2[ 4] = "U"; new_line2[ 5] = "N"; new_line2[ 6] = "L";
                    new_line2[ 7] = "K"; new_line2[ 8] = SPACE;
                    new_line2[ 9] = "T"; new_line2[10] = "O"; new_line2[11] = SPACE;
                    new_line2[12] = "S"; new_line2[13] = "A"; new_line2[14] = "V";
                    new_line2[15] = "E";
                end
            end

            ST_PLAY_SRAM: begin
                // "PLAYING AUDIO  "
                new_line1[ 0] = "P"; new_line1[ 1] = "L"; new_line1[ 2] = "A";
                new_line1[ 3] = "Y"; new_line1[ 4] = "I"; new_line1[ 5] = "N";
                new_line1[ 6] = "G"; new_line1[ 7] = SPACE;
                new_line1[ 8] = "A"; new_line1[ 9] = "U"; new_line1[10] = "D";
                new_line1[11] = "I"; new_line1[12] = "O";
                // "T=XXs SRAM     "
                new_line2[ 0] = "T"; new_line2[ 1] = "=";
                new_line2[ 2] = play_tens_ascii;
                new_line2[ 3] = play_ones_ascii;
                new_line2[ 4] = "s"; new_line2[ 5] = SPACE;
                new_line2[ 6] = "S"; new_line2[ 7] = "R"; new_line2[ 8] = "A";
                new_line2[ 9] = "M";
            end

            ST_PLAY_PAUSE: begin
                // "PLAY PAUSE     "
                new_line1[ 0] = "P"; new_line1[ 1] = "L"; new_line1[ 2] = "A";
                new_line1[ 3] = "Y"; new_line1[ 4] = SPACE;
                new_line1[ 5] = "P"; new_line1[ 6] = "A"; new_line1[ 7] = "U";
                new_line1[ 8] = "S"; new_line1[ 9] = "E";
                // "K2 RESUME      "
                new_line2[ 0] = "K"; new_line2[ 1] = "2"; new_line2[ 2] = SPACE;
                new_line2[ 3] = "R"; new_line2[ 4] = "E"; new_line2[ 5] = "S";
                new_line2[ 6] = "U"; new_line2[ 7] = "M"; new_line2[ 8] = "E";
            end

            ST_SAVE_FLASH_ERASE, ST_SAVE_FLASH_ERASE_WAIT: begin
                // "ERASE FLASH    "
                new_line1[ 0] = "E"; new_line1[ 1] = "R"; new_line1[ 2] = "A";
                new_line1[ 3] = "S"; new_line1[ 4] = "E"; new_line1[ 5] = SPACE;
                new_line1[ 6] = "F"; new_line1[ 7] = "L"; new_line1[ 8] = "A";
                new_line1[ 9] = "S"; new_line1[10] = "H";
                // "PLEASE WAIT    "
                new_line2[ 0] = "P"; new_line2[ 1] = "L"; new_line2[ 2] = "E";
                new_line2[ 3] = "A"; new_line2[ 4] = "S"; new_line2[ 5] = "E";
                new_line2[ 6] = SPACE;
                new_line2[ 7] = "W"; new_line2[ 8] = "A"; new_line2[ 9] = "I";
                new_line2[10] = "T";
            end

            ST_SAVE_FLASH_WRITE_HDR: begin
                // "SAVING FLASH   "
                new_line1[ 0] = "S"; new_line1[ 1] = "A"; new_line1[ 2] = "V";
                new_line1[ 3] = "I"; new_line1[ 4] = "N"; new_line1[ 5] = "G";
                new_line1[ 6] = SPACE;
                new_line1[ 7] = "F"; new_line1[ 8] = "L"; new_line1[ 9] = "A";
                new_line1[10] = "S"; new_line1[11] = "H";
                // "WRITE HEADER   "
                new_line2[ 0] = "W"; new_line2[ 1] = "R"; new_line2[ 2] = "I";
                new_line2[ 3] = "T"; new_line2[ 4] = "E"; new_line2[ 5] = SPACE;
                new_line2[ 6] = "H"; new_line2[ 7] = "E"; new_line2[ 8] = "A";
                new_line2[ 9] = "D"; new_line2[10] = "E"; new_line2[11] = "R";
            end

            ST_SAVE_FLASH_WRITE_DATA: begin
                // "SAVING FLASH   "
                new_line1[ 0] = "S"; new_line1[ 1] = "A"; new_line1[ 2] = "V";
                new_line1[ 3] = "I"; new_line1[ 4] = "N"; new_line1[ 5] = "G";
                new_line1[ 6] = SPACE;
                new_line1[ 7] = "F"; new_line1[ 8] = "L"; new_line1[ 9] = "A";
                new_line1[10] = "S"; new_line1[11] = "H";
                // "SRAM->FLASH    "
                new_line2[ 0] = "S"; new_line2[ 1] = "R"; new_line2[ 2] = "A";
                new_line2[ 3] = "M"; new_line2[ 4] = "-"; new_line2[ 5] = ">";
                new_line2[ 6] = "F"; new_line2[ 7] = "L"; new_line2[ 8] = "A";
                new_line2[ 9] = "S"; new_line2[10] = "H";
            end

            ST_SAVE_FLASH_DONE: begin
                // "SAVE DONE      "
                new_line1[ 0] = "S"; new_line1[ 1] = "A"; new_line1[ 2] = "V";
                new_line1[ 3] = "E"; new_line1[ 4] = SPACE;
                new_line1[ 5] = "D"; new_line1[ 6] = "O"; new_line1[ 7] = "N";
                new_line1[ 8] = "E";
                // "DATA IN FLASH  "
                new_line2[ 0] = "D"; new_line2[ 1] = "A"; new_line2[ 2] = "T";
                new_line2[ 3] = "A"; new_line2[ 4] = SPACE;
                new_line2[ 5] = "I"; new_line2[ 6] = "N"; new_line2[ 7] = SPACE;
                new_line2[ 8] = "F"; new_line2[ 9] = "L"; new_line2[10] = "A";
                new_line2[11] = "S"; new_line2[12] = "H";
            end

            ST_LOAD_FLASH_READ_HDR: begin
                // "CHECK FLASH    "
                new_line1[ 0] = "C"; new_line1[ 1] = "H"; new_line1[ 2] = "E";
                new_line1[ 3] = "C"; new_line1[ 4] = "K"; new_line1[ 5] = SPACE;
                new_line1[ 6] = "F"; new_line1[ 7] = "L"; new_line1[ 8] = "A";
                new_line1[ 9] = "S"; new_line1[10] = "H";
                // "READ HEADER    "
                new_line2[ 0] = "R"; new_line2[ 1] = "E"; new_line2[ 2] = "A";
                new_line2[ 3] = "D"; new_line2[ 4] = SPACE;
                new_line2[ 5] = "H"; new_line2[ 6] = "E"; new_line2[ 7] = "A";
                new_line2[ 8] = "D"; new_line2[ 9] = "E"; new_line2[10] = "R";
            end

            ST_LOAD_FLASH_TO_SRAM: begin
                // "LOADING FLASH  "
                new_line1[ 0] = "L"; new_line1[ 1] = "O"; new_line1[ 2] = "A";
                new_line1[ 3] = "D"; new_line1[ 4] = "I"; new_line1[ 5] = "N";
                new_line1[ 6] = "G"; new_line1[ 7] = SPACE;
                new_line1[ 8] = "F"; new_line1[ 9] = "L"; new_line1[10] = "A";
                new_line1[11] = "S"; new_line1[12] = "H";
                // "FLASH->SRAM    "
                new_line2[ 0] = "F"; new_line2[ 1] = "L"; new_line2[ 2] = "A";
                new_line2[ 3] = "S"; new_line2[ 4] = "H"; new_line2[ 5] = "-";
                new_line2[ 6] = ">"; new_line2[ 7] = "S"; new_line2[ 8] = "R";
                new_line2[ 9] = "A"; new_line2[10] = "M";
            end

            ST_LOAD_FLASH_DONE: begin
                // "LOAD DONE      "
                new_line1[ 0] = "L"; new_line1[ 1] = "O"; new_line1[ 2] = "A";
                new_line1[ 3] = "D"; new_line1[ 4] = SPACE;
                new_line1[ 5] = "D"; new_line1[ 6] = "O"; new_line1[ 7] = "N";
                new_line1[ 8] = "E";
                // "PLAY FROM SRAM "
                new_line2[ 0] = "P"; new_line2[ 1] = "L"; new_line2[ 2] = "A";
                new_line2[ 3] = "Y"; new_line2[ 4] = SPACE;
                new_line2[ 5] = "F"; new_line2[ 6] = "R"; new_line2[ 7] = "O";
                new_line2[ 8] = "M"; new_line2[ 9] = SPACE;
                new_line2[10] = "S"; new_line2[11] = "R"; new_line2[12] = "A";
                new_line2[13] = "M";
            end

            ST_ERROR: begin
                if (sram_full) begin
                    // "SRAM FULL      "
                    new_line1[ 0] = "S"; new_line1[ 1] = "R"; new_line1[ 2] = "A";
                    new_line1[ 3] = "M"; new_line1[ 4] = SPACE;
                    new_line1[ 5] = "F"; new_line1[ 6] = "U"; new_line1[ 7] = "L";
                    new_line1[ 8] = "L";
                    // "REC STOP       "
                    new_line2[ 0] = "R"; new_line2[ 1] = "E"; new_line2[ 2] = "C";
                    new_line2[ 3] = SPACE;
                    new_line2[ 4] = "S"; new_line2[ 5] = "T"; new_line2[ 6] = "O";
                    new_line2[ 7] = "P";
                end
                else if (flash_error) begin
                    // "SAVE ERROR     "
                    new_line1[ 0] = "S"; new_line1[ 1] = "A"; new_line1[ 2] = "V";
                    new_line1[ 3] = "E"; new_line1[ 4] = SPACE;
                    new_line1[ 5] = "E"; new_line1[ 6] = "R"; new_line1[ 7] = "R";
                    new_line1[ 8] = "O"; new_line1[ 9] = "R";
                    // "CHECK FLASH    "
                    new_line2[ 0] = "C"; new_line2[ 1] = "H"; new_line2[ 2] = "E";
                    new_line2[ 3] = "C"; new_line2[ 4] = "K"; new_line2[ 5] = SPACE;
                    new_line2[ 6] = "F"; new_line2[ 7] = "L"; new_line2[ 8] = "A";
                    new_line2[ 9] = "S"; new_line2[10] = "H";
                end
                else if (!flash_header_valid) begin
                    // "NO FLASH DATA  "
                    new_line1[ 0] = "N"; new_line1[ 1] = "O"; new_line1[ 2] = SPACE;
                    new_line1[ 3] = "F"; new_line1[ 4] = "L"; new_line1[ 5] = "A";
                    new_line1[ 6] = "S"; new_line1[ 7] = "H"; new_line1[ 8] = SPACE;
                    new_line1[ 9] = "D"; new_line1[10] = "A"; new_line1[11] = "T";
                    new_line1[12] = "A";
                    // "K1 REC FIRST   "
                    new_line2[ 0] = "K"; new_line2[ 1] = "1"; new_line2[ 2] = SPACE;
                    new_line2[ 3] = "R"; new_line2[ 4] = "E"; new_line2[ 5] = "C";
                    new_line2[ 6] = SPACE;
                    new_line2[ 7] = "F"; new_line2[ 8] = "I"; new_line2[ 9] = "R";
                    new_line2[10] = "S"; new_line2[11] = "T";
                end
                else begin
                    // "ERROR          "
                    new_line1[ 0] = "E"; new_line1[ 1] = "R"; new_line1[ 2] = "R";
                    new_line1[ 3] = "O"; new_line1[ 4] = "R";
                    // "CHECK MEMORY   "
                    new_line2[ 0] = "C"; new_line2[ 1] = "H"; new_line2[ 2] = "E";
                    new_line2[ 3] = "C"; new_line2[ 4] = "K"; new_line2[ 5] = SPACE;
                    new_line2[ 6] = "M"; new_line2[ 7] = "E"; new_line2[ 8] = "M";
                    new_line2[ 9] = "O"; new_line2[10] = "R"; new_line2[11] = "Y";
                end
            end

            default: begin
                // "AUDIO PLAYER   "
                new_line1[ 0] = "A"; new_line1[ 1] = "U"; new_line1[ 2] = "D";
                new_line1[ 3] = "I"; new_line1[ 4] = "O"; new_line1[ 5] = SPACE;
                new_line1[ 6] = "P"; new_line1[ 7] = "L"; new_line1[ 8] = "A";
                new_line1[ 9] = "Y"; new_line1[10] = "E"; new_line1[11] = "R";
                // "K1 REC K2 LOAD "
                new_line2[ 0] = "K"; new_line2[ 1] = "1"; new_line2[ 2] = SPACE;
                new_line2[ 3] = "R"; new_line2[ 4] = "E"; new_line2[ 5] = "C";
                new_line2[ 6] = SPACE;
                new_line2[ 7] = "K"; new_line2[ 8] = "2"; new_line2[ 9] = SPACE;
                new_line2[10] = "L"; new_line2[11] = "O"; new_line2[12] = "A";
                new_line2[13] = "D";
            end
        endcase
    end

    //========================================================================
    // State change detection & display buffer update
    //========================================================================
    reg [3:0]  fsm_state_prev;
    reg        sw_input_source_prev;
    reg        sw_flash_unlock_prev;
    reg        state_changed;
    reg        buffer_needs_update;

    // For dynamic content (record/play seconds), update every cycle in those
    // states so the seconds counter is kept current.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fsm_state_prev       <= 4'd0;
            sw_input_source_prev <= 1'b0;
            sw_flash_unlock_prev <= 1'b0;
            state_changed        <= 1'b0;
            buffer_needs_update  <= 1'b1;  // force update at reset
        end else begin
            fsm_state_prev       <= fsm_state;
            sw_input_source_prev <= sw_input_source;
            sw_flash_unlock_prev <= sw_flash_unlock;
            // Detect state change OR input source change OR flash unlock change
            if ((fsm_state != fsm_state_prev) || 
                (sw_input_source != sw_input_source_prev) ||
                (sw_flash_unlock != sw_flash_unlock_prev))
                state_changed <= 1'b1;
            else
                state_changed <= 1'b0;

            // Mark buffer update needed on state change or input source change or flash unlock change
            if ((fsm_state != fsm_state_prev) || 
                (sw_input_source != sw_input_source_prev) ||
                (sw_flash_unlock != sw_flash_unlock_prev))
                buffer_needs_update <= 1'b1;
            else if (buf_updated)
                buffer_needs_update <= 1'b0;
        end
    end

    //========================================================================
    // Buffer update — copy new content into registered display buffer
    //========================================================================
    reg buf_updated;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_updated <= 1'b0;
            for (j = 0; j < 16; j = j + 1) begin
                line1[j] <= SPACE;
                line2[j] <= SPACE;
            end
        end else begin
            buf_updated <= 1'b0;
            // Always update buffer content (allows dynamic seconds to refresh)
            for (j = 0; j < 16; j = j + 1) begin
                line1[j] <= new_line1[j];
                line2[j] <= new_line2[j];
            end
            if (buffer_needs_update)
                buf_updated <= 1'b1;
        end
    end

    //========================================================================
    // LCD_Controller Instance
    //========================================================================
    reg  [7:0] lcd_data_reg;
    reg        lcd_rs_reg;
    reg        lcd_start;
    wire       lcd_done;

    LCD_Controller u_lcd_ctrl (
        .iDATA    (lcd_data_reg),
        .iRS      (lcd_rs_reg),
        .iStart   (lcd_start),
        .oDone    (lcd_done),
        .iCLK     (clk),
        .iRST_N   (rst_n),
        .LCD_DATA (LCD_DATA),
        .LCD_RW   (LCD_RW),
        .LCD_EN   (LCD_EN),
        .LCD_RS   (LCD_RS)
    );

    //========================================================================
    // LCD Refresh FSM
    //========================================================================
    reg [4:0]  lcd_state;
    reg [4:0]  lcd_return_state;  // state to return to after WAIT_DONE/DELAY
    reg [3:0]  char_index;        // 0..15 character position
    reg [17:0] delay_cnt;         // delay counter (up to 262143 = ~5.2ms)
    reg [17:0] delay_target;      // target delay value
    reg        init_done;         // LCD initialization complete flag
    reg [1:0]  init_cmd_idx;      // which init command (0-3)

    // Init command lookup
    reg [7:0] init_cmd_data;
    always @(*) begin
        case (init_cmd_idx)
            2'd0: init_cmd_data = 8'h38;  // Function set: 8-bit, 2 lines, 5x8
            2'd1: init_cmd_data = 8'h0C;  // Display ON, cursor OFF, blink OFF
            2'd2: init_cmd_data = 8'h01;  // Clear display
            2'd3: init_cmd_data = 8'h06;  // Entry mode: increment, no shift
            default: init_cmd_data = 8'h38;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcd_state       <= LCD_INIT_0;
            lcd_return_state <= LCD_INIT_0;
            lcd_data_reg    <= 8'h00;
            lcd_rs_reg      <= 1'b0;
            lcd_start       <= 1'b0;
            char_index      <= 4'd0;
            delay_cnt       <= 18'd0;
            delay_target    <= 18'd0;
            init_done       <= 1'b0;
            init_cmd_idx    <= 2'd0;
        end else begin
            // Default: de-assert start pulse (single-cycle pulse)
            lcd_start <= 1'b0;

            case (lcd_state)
                //------------------------------------------------------------
                // INIT SEQUENCE: Send 4 init commands with delays
                //------------------------------------------------------------
                LCD_INIT_0: begin
                    lcd_data_reg  <= init_cmd_data;
                    lcd_rs_reg    <= 1'b0;  // command mode
                    lcd_start     <= 1'b1;
                    lcd_return_state <= LCD_INIT_1;
                    lcd_state     <= LCD_WAIT_DONE;
                end

                LCD_INIT_1: begin
                    // After sending init command, add delay
                    // Clear display (cmd 0x01) needs ~1.52ms, others ~40us
                    // Use ~5ms for all init commands for safety
                    delay_target  <= 18'd262143;  // ~5.2ms at 50MHz
                    if (init_cmd_idx < 2'd3) begin
                        init_cmd_idx  <= init_cmd_idx + 2'd1;
                        lcd_return_state <= LCD_INIT_0;
                    end else begin
                        init_done     <= 1'b1;
                        lcd_return_state <= LCD_SET_ADDR_L1;
                    end
                    lcd_state     <= LCD_DELAY;
                end

                //------------------------------------------------------------
                // NORMAL REFRESH CYCLE
                //------------------------------------------------------------
                LCD_SET_ADDR_L1: begin
                    lcd_data_reg  <= 8'h80;  // DDRAM address = 0x00 (line 1)
                    lcd_rs_reg    <= 1'b0;   // command
                    lcd_start     <= 1'b1;
                    char_index    <= 4'd0;
                    lcd_return_state <= LCD_WRITE_L1;
                    lcd_state     <= LCD_WAIT_DONE;
                end

                LCD_WRITE_L1: begin
                    lcd_data_reg  <= line1[char_index];
                    lcd_rs_reg    <= 1'b1;   // data mode
                    lcd_start     <= 1'b1;
                    if (char_index < 4'd15) begin
                        char_index    <= char_index + 4'd1;
                        lcd_return_state <= LCD_WRITE_L1;
                    end else begin
                        lcd_return_state <= LCD_SET_ADDR_L2;
                    end
                    lcd_state     <= LCD_WAIT_DONE;
                end

                LCD_SET_ADDR_L2: begin
                    lcd_data_reg  <= 8'hC0;  // DDRAM address = 0x40 (line 2)
                    lcd_rs_reg    <= 1'b0;   // command
                    lcd_start     <= 1'b1;
                    char_index    <= 4'd0;
                    lcd_return_state <= LCD_WRITE_L2;
                    lcd_state     <= LCD_WAIT_DONE;
                end

                LCD_WRITE_L2: begin
                    lcd_data_reg  <= line2[char_index];
                    lcd_rs_reg    <= 1'b1;   // data mode
                    lcd_start     <= 1'b1;
                    if (char_index < 4'd15) begin
                        char_index    <= char_index + 4'd1;
                        lcd_return_state <= LCD_WRITE_L2;
                    end else begin
                        lcd_return_state <= LCD_REFRESH_IDLE;
                    end
                    lcd_state     <= LCD_WAIT_DONE;
                end

                //------------------------------------------------------------
                // WAIT FOR LCD_Controller oDone
                //------------------------------------------------------------
                LCD_WAIT_DONE: begin
                    if (lcd_done) begin
                        // Small inter-write delay (~50us = 2500 cycles)
                        delay_target <= 18'd2500;
                        lcd_state    <= LCD_DELAY;
                    end
                end

                //------------------------------------------------------------
                // DELAY STATE
                //------------------------------------------------------------
                LCD_DELAY: begin
                    if (delay_cnt >= delay_target) begin
                        delay_cnt <= 18'd0;
                        lcd_state <= lcd_return_state;
                    end else begin
                        delay_cnt <= delay_cnt + 18'd1;
                    end
                end

                //------------------------------------------------------------
                // REFRESH IDLE — brief pause then restart
                //------------------------------------------------------------
                LCD_REFRESH_IDLE: begin
                    // Small delay before starting next refresh cycle
                    delay_target     <= 18'd250000;  // ~5ms pause between cycles
                    lcd_return_state <= LCD_SET_ADDR_L1;
                    lcd_state        <= LCD_DELAY;
                end

                default: begin
                    lcd_state <= LCD_INIT_0;
                end
            endcase

            // On state change, restart the refresh from the address-set step
            // (only if init is already done)
            if (state_changed && init_done) begin
                lcd_state    <= LCD_SET_ADDR_L1;
                char_index   <= 4'd0;
                delay_cnt    <= 18'd0;
            end
        end
    end

endmodule
