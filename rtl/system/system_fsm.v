// ============================================================================
// System FSM - Main State Machine for DE2-115 Audio Recorder/Player
// ============================================================================
// Controls recording (Audio→SRAM), saving (SRAM→FLASH), loading (FLASH→SRAM),
// and playback (SRAM→Audio). Manages all memory access and state transitions.
//
// FLASH is 8-bit data bus; each 16-bit word requires two byte operations.
// SRAM is 16-bit, directly controlled (no Avalon-MM).
// ============================================================================

module system_fsm #(
    parameter SAMPLE_RATE_HZ    = 48000,
    parameter SRAM_MAX_ADDR     = 20'hFFFFF,  // 1M words (1,048,575)
    parameter FLASH_HEADER_WORDS = 16,         // 16 words of header
    parameter FLASH_AUDIO_BASE  = 23'd32,      // byte addr = 16 words * 2 bytes
    parameter FLASH_SLOT_MAX_WORDS = 20'hFFFF0, // 2MiB slot - 32-byte header
    parameter CODEC_INIT_WAIT   = 26'd50_000_000, // 1 second @ 50MHz
    parameter LOAD_DONE_WAIT    = 26'd25_000_000  // 0.5 second @ 50MHz
)(
    input  wire        clk,           // 50 MHz system clock
    input  wire        rst_n,
    // KEY one-pulse inputs (active-high, single cycle)
    input  wire        cancel_pulse,  // Back/cancel command; top-level reset key is not routed here
    input  wire        key1_pulse,    // Record / Stop record
    input  wire        key2_pulse,    // Play / Pause
    input  wire        key3_pulse,    // Save to FLASH / Confirm
    // SW inputs
    input  wire [17:0] sw,
    // Audio ADC interface (from AUDIO_ADC module, host clock domain)
    input  wire        adc_empty,
    output reg         adc_read,
    input  wire [31:0] adc_data,     // L[31:16], R[15:0]
    // Audio DAC interface (from AUDIO_DAC module, host clock domain)
    input  wire        dac_full,
    input  wire        dac_sample_tick,
    output reg         dac_write,
    output reg  [31:0] dac_data,
    // Audio FIFO clear
    output reg         audio_fifo_clear,
    // SRAM interface (directly to top-level pins)
    output reg  [19:0] sram_addr,
    output reg  [15:0] sram_wdata,
    input  wire [15:0] sram_rdata,
    output reg         sram_we_n,
    output reg         sram_oe_n,
    output reg         sram_ce_n,
    output reg         sram_ub_n,
    output reg         sram_lb_n,
    output reg         sram_dq_oe,    // 1=drive SRAM_DQ, 0=tri-state
    // FLASH interface (8-bit, directly to top-level pins)
    output wire [22:0] fl_addr,
    output wire [7:0]  fl_wdata,
    input  wire [7:0]  fl_rdata,
    output wire        fl_ce_n,
    output wire        fl_oe_n,
    output wire        fl_we_n,
    output wire        fl_rst_n,
    output wire        fl_wp_n,
    output wire        fl_dq_oe,      // 1=drive FL_DQ, 0=tri-state
    input  wire        fl_ry,         // FLASH ready/busy (active-high = ready)
    // Display outputs
    output wire [3:0]  fsm_state,
    output reg  [7:0]  mode_code,     // HEX7~6 MODE BCD {tens, ones}
    output reg  [7:0]  status_code,   // HEX5~4 STAT BCD {tens, ones}
    // Record/play status
    output reg         record_active,
    output reg         play_active,
    output reg         sample_valid_out,
    output reg  signed [15:0] current_sample,
    output reg         clear_record_time,
    output reg         clear_play_time,
    // Status flags
    output reg         flash_header_valid,
    output reg         sram_full,
    output reg         flash_error,
    // Record length (for time display & header)
    output reg  [19:0] record_length_words
);

// =========================================================================
// FSM State Encoding
// =========================================================================
localparam ST_RESET                 = 4'd0;
localparam ST_CODEC_INIT            = 4'd1;
localparam ST_IDLE                  = 4'd2;
localparam ST_RECORD                = 4'd3;
localparam ST_RECORD_STOP           = 4'd4;
localparam ST_PLAY_SRAM             = 4'd5;
localparam ST_PLAY_PAUSE            = 4'd6;
localparam ST_SAVE_FLASH_ERASE      = 4'd7;
localparam ST_SAVE_FLASH_WRITE_HDR  = 4'd8;
localparam ST_SAVE_FLASH_WRITE_DATA = 4'd9;
localparam ST_SAVE_FLASH_DONE       = 4'd10;
localparam ST_LOAD_FLASH_READ_HDR   = 4'd11;
localparam ST_LOAD_FLASH_TO_SRAM    = 4'd12;
localparam ST_LOAD_FLASH_DONE       = 4'd13;
localparam ST_ERROR                 = 4'd14;
localparam ST_SAVE_FLASH_ERASE_WAIT = 4'd15;

// FLASH Header constants
localparam FLASH_MAGIC      = 16'hA55A;
localparam FLASH_VERSION    = 16'h0001;

    // FLASH AMD command addresses (byte addresses)
    localparam FLASH_UNLOCK1_ADDR = 23'hAAA;
    localparam FLASH_UNLOCK2_ADDR = 23'h555;

// FLASH sub-state machine for byte-level operations
localparam FL_SUB_IDLE          = 4'd0;
localparam FL_SUB_ERASE_SEQ     = 4'd1;
localparam FL_SUB_PROG_SEQ      = 4'd2;
localparam FL_SUB_READ          = 4'd3;
localparam FL_SUB_READ_WAIT     = 4'd4;

// =========================================================================
// Internal registers
// =========================================================================
reg [3:0]  state;
reg [25:0] init_counter;           // Codec init wait counter
reg [19:0] sram_write_ptr;         // SRAM write address (recording)
reg [19:0] sram_read_ptr;          // SRAM read address (playback)
reg        has_record_data;        // SRAM has valid recorded data

// FLASH operation registers
reg [22:0] fl_target_addr;         // Target byte address for current op
reg [7:0]  fl_target_data;         // Data byte for program
reg        fl_op_start_erase;      // Start erase command
reg        fl_op_start_prog;       // Start program command
reg        fl_op_start_read;       // Trigger read command
wire       fl_op_done;             // Sub-state machine done flag from controller
wire [7:0] fl_read_byte;           // Last read byte from FLASH from controller
wire       flash_busy;             // Controller busy signal

// FLASH high-level operation counters
reg [22:0] fl_byte_counter;        // Current byte address in FLASH
reg [3:0]  fl_header_word_idx;     // Header word index (0~15)
reg        fl_byte_phase;          // 0=low byte, 1=high byte
reg [15:0] fl_word_buffer;         // 16-bit word assembly buffer
reg [15:0] header_word_val;        // combinational header word value
reg [19:0] fl_data_word_counter;   // Data word counter for save/load
reg [19:0] flash_audio_length;     // Audio length from FLASH header
reg [31:0] fl_timeout_counter;     // Timeout counter for FLASH ops (32-bit to avoid truncation)
reg [6:0]  erase_sector_idx;       // Sector counter during erase (7 bits for 128 sectors)
reg [1:0]  active_flash_slot;      // Slot latched when a FLASH save/load starts
reg        fl_waiting_for_done;    // 1=waiting for low-level controller done

// SRAM operation timing
reg [2:0]  sram_wait;              // Wait states for SRAM access
reg        sram_op_pending;        // SRAM operation in progress

// Playback control
reg        play_from_sram_ready;   // SRAM loaded, ready for playback
reg        play_direct_sram;       // Flag indicating direct playback from recording

// Pulse stretcher for audio FIFO clear
reg [15:0] fifo_clear_timer;
reg        trigger_fifo_clear;

// SignalTap/JTAG debug counters for memory timing checks.
(* preserve, noprune *) reg [31:0] dbg_sram_pending_cycles;
(* preserve, noprune *) reg [31:0] dbg_sram_last_cycles;
(* preserve, noprune *) reg [31:0] dbg_flash_busy_cycles;
(* preserve, noprune *) reg [31:0] dbg_flash_last_cycles;
(* preserve, noprune *) reg        dbg_sram_op_pending_d;
(* preserve, noprune *) reg        dbg_flash_busy_d;


// SW decode
wire sw_ledr_en       = sw[0];
wire sw_peak_hold     = sw[1];
wire sw_clear_sram    = sw[2];
wire sw_flash_unlock  = sw[3];
wire sw_loop_play     = sw[4];
wire sw_mute          = sw[5];
wire [1:0] sw_sensitivity = sw[7:6];
wire sw_lcd_debug     = sw[8];
wire sw_ledg_debug    = sw[9];
wire [1:0] sw_flash_slot = sw[11:10];

// =========================================================================
// Combinational FLASH header generation
// =========================================================================
always @(*) begin
    case (fl_header_word_idx)
        4'd0:    header_word_val = FLASH_MAGIC;
        4'd1:    header_word_val = FLASH_VERSION;
        4'd2:    header_word_val = SAMPLE_RATE_HZ[15:0];  // Sample rate low
        4'd3:    header_word_val = 16'h0000;              // Format: Mono, Signed PCM
        4'd4:    header_word_val = record_length_words[15:0]; // Length low
        4'd5:    header_word_val = {12'd0, record_length_words[19:16]}; // Length high
        default: header_word_val = 16'h0000;              // Reserved
    endcase
end

// Combinational calculations for multi-sector erase
localparam [19:0] FLASH_SLOT_MAX_ADDR = FLASH_SLOT_MAX_WORDS - 20'd1;
wire [19:0] record_limit_addr = (SRAM_MAX_ADDR < FLASH_SLOT_MAX_ADDR) ?
                                SRAM_MAX_ADDR : FLASH_SLOT_MAX_ADDR;
wire [22:0] sw_flash_slot_base = {sw_flash_slot, 21'd0};
wire [6:0]  sw_flash_slot_sector_base = {sw_flash_slot, 5'd0};
wire [22:0] flash_slot_base = {active_flash_slot, 21'd0};
wire [6:0]  flash_slot_sector_base = {active_flash_slot, 5'd0};
wire [22:0] flash_data_base = flash_slot_base + FLASH_AUDIO_BASE;
wire [22:0] total_bytes_needed = {3'd0, record_length_words, 1'b0} + 23'd32;
wire [22:0] total_bytes_last = total_bytes_needed - 23'd1;
wire [6:0]  last_sector_needed = flash_slot_sector_base + 7'd31;

// =========================================================================
// FSM state register


assign fsm_state = state;

// =========================================================================
// Codec init counter
// =========================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        init_counter <= 26'd0;
    else if (state == ST_CODEC_INIT || state == ST_LOAD_FLASH_DONE)
        init_counter <= init_counter + 26'd1;
    else
        init_counter <= 26'd0;
end

// =========================================================================
// FLASH Controller Instantiation
// =========================================================================
flash_controller flash_ctrl_inst (
    .clk(clk),
    .rst_n(rst_n),
    .cmd_erase(fl_op_start_erase),
    .cmd_write(fl_op_start_prog),
    .cmd_read(fl_op_start_read),
    .cmd_addr(fl_target_addr),
    .cmd_wdata(fl_target_data),
    .cmd_done(fl_op_done),
    .cmd_rdata(fl_read_byte),
    .busy(flash_busy),
    
    // FLASH hardware interface mapped to module wire ports
    .FL_ADDR(fl_addr),
    .FL_CE_N(fl_ce_n),
    .FL_OE_N(fl_oe_n),
    .FL_WE_N(fl_we_n),
    .FL_RST_N(fl_rst_n),
    .FL_WP_N(fl_wp_n),
    .FL_RY(fl_ry),
    .fl_dq_oe(fl_dq_oe),
    .fl_dq_out(fl_wdata),
    .fl_dq_in(fl_rdata)
);

// =========================================================================
// Main FSM - Next State Logic and Datapath Control
// =========================================================================
// Timeout counter for FLASH operations (integrated in main FSM always block to avoid multiple drivers)

// Main FSM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= ST_RESET;
        sram_write_ptr      <= 20'd0;
        sram_read_ptr       <= 20'd0;
        record_length_words <= 20'd0;
        has_record_data     <= 1'b0;
        sram_full           <= 1'b0;
        flash_header_valid  <= 1'b0;
        flash_error         <= 1'b0;
        record_active       <= 1'b0;
        play_active         <= 1'b0;
        sample_valid_out    <= 1'b0;
        current_sample      <= 16'd0;
        clear_record_time   <= 1'b0;
        clear_play_time     <= 1'b0;
        audio_fifo_clear    <= 1'b0;
        fifo_clear_timer    <= 16'd0;
        trigger_fifo_clear  <= 1'b0;
        dbg_sram_pending_cycles <= 32'd0;
        dbg_sram_last_cycles    <= 32'd0;
        dbg_flash_busy_cycles   <= 32'd0;
        dbg_flash_last_cycles   <= 32'd0;
        dbg_sram_op_pending_d   <= 1'b0;
        dbg_flash_busy_d        <= 1'b0;
        mode_code           <= 8'h07;
        status_code         <= 8'h09;
        play_from_sram_ready <= 1'b0;
        play_direct_sram    <= 1'b0;
        fl_timeout_counter  <= 32'd0;  // 32-bit to match declaration
        erase_sector_idx    <= 7'd0;
        active_flash_slot   <= 2'd0;
        fl_waiting_for_done <= 1'b0;
        // SRAM defaults
        sram_addr   <= 20'd0;
        sram_wdata  <= 16'd0;
        sram_we_n   <= 1'b1;
        sram_oe_n   <= 1'b1;
        sram_ce_n   <= 1'b1;
        sram_ub_n   <= 1'b0;
        sram_lb_n   <= 1'b0;
        sram_dq_oe  <= 1'b0;
        sram_wait   <= 3'd0;
        sram_op_pending <= 1'b0;
        // ADC/DAC
        adc_read   <= 1'b0;
        dac_write  <= 1'b0;
        dac_data   <= 32'd0;
        // FLASH high-level
        fl_op_start_erase <= 1'b0;
        fl_op_start_prog  <= 1'b0;
        fl_op_start_read  <= 1'b0;
        fl_target_addr    <= 23'd0;
        fl_target_data    <= 8'd0;
        fl_byte_counter   <= 23'd0;
        fl_header_word_idx <= 4'd0;
        fl_byte_phase     <= 1'b0;
        fl_word_buffer    <= 16'd0;
        fl_data_word_counter <= 20'd0;
        flash_audio_length <= 20'd0;
    end else begin
        // Default timer behavior (including erase wait state)
        if (state == ST_SAVE_FLASH_ERASE || state == ST_SAVE_FLASH_ERASE_WAIT ||
            state == ST_SAVE_FLASH_WRITE_DATA || state == ST_LOAD_FLASH_TO_SRAM) begin
            fl_timeout_counter <= fl_timeout_counter + 32'd1;
        end else begin
            fl_timeout_counter <= 32'd0;
        end

        // Default pulse signals
        sample_valid_out   <= 1'b0;
        clear_record_time  <= 1'b0;
        clear_play_time    <= 1'b0;
        trigger_fifo_clear <= 1'b0;
        if (cancel_pulse) begin
            fl_waiting_for_done <= 1'b0;
        end
        adc_read           <= 1'b0;
        dac_write          <= 1'b0;
        fl_op_start_erase  <= 1'b0;
        fl_op_start_prog   <= 1'b0;
        fl_op_start_read   <= 1'b0;
        sram_we_n          <= 1'b1;
        sram_oe_n          <= 1'b1;
        sram_ub_n          <= 1'b0;
        sram_lb_n          <= 1'b0;
        sram_dq_oe         <= 1'b0;
        
        case (state)
            // ---------------------------------------------------------
            ST_RESET: begin
                mode_code   <= 8'h07;
                status_code <= 8'h09;
                trigger_fifo_clear <= 1'b1;
                state  <= ST_CODEC_INIT;
            end
            
            // ---------------------------------------------------------
            ST_CODEC_INIT: begin
                mode_code   <= 8'h07;
                status_code <= 8'h09;
                if (init_counter >= CODEC_INIT_WAIT) begin
                    state <= ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_IDLE: begin
                mode_code   <= 8'h00;
                status_code <= 8'h00;
                record_active <= 1'b0;
                play_active   <= 1'b0;
                sram_ce_n     <= 1'b1;
                
                if (key1_pulse) begin
                    // Start recording
                    sram_write_ptr <= 20'd0;
                    record_length_words <= 20'd0;
                    sram_full <= 1'b0;
                    clear_record_time <= 1'b1;
                    trigger_fifo_clear <= 1'b1;
                    state <= ST_RECORD;
                end
                else if (key2_pulse) begin
                    // Start play: first load from FLASH
                    flash_header_valid <= 1'b0;
                    flash_error <= 1'b0;
                    fl_header_word_idx <= 4'd0;
                    fl_byte_phase <= 1'b0;
                    active_flash_slot <= sw_flash_slot;
                    fl_byte_counter <= sw_flash_slot_base;
                    clear_play_time <= 1'b1;
                    play_direct_sram <= 1'b0;
                    state <= ST_LOAD_FLASH_READ_HDR;
                end
                else if (key3_pulse && has_record_data) begin
                    // Save SRAM to FLASH
                    if (sw_flash_unlock) begin
                        flash_error <= 1'b0;
                        fl_timeout_counter <= 26'd0;
                        active_flash_slot <= sw_flash_slot;
                        erase_sector_idx <= sw_flash_slot_sector_base;
                        state <= ST_SAVE_FLASH_ERASE;
                    end
                    // If SW3=0, flash is locked - stay in IDLE
                    // LCD will show FLASH LOCKED (handled by LCD controller)
                end
                else if (sw_clear_sram && key3_pulse) begin
                    // Clear SRAM buffer
                    sram_write_ptr <= 20'd0;
                    record_length_words <= 20'd0;
                    has_record_data <= 1'b0;
                    sram_full <= 1'b0;
                    clear_record_time <= 1'b1;
                end
            end
            
            // ---------------------------------------------------------
            ST_RECORD: begin
                mode_code     <= 8'h01;
                status_code   <= 8'h01;
                record_active <= 1'b1;
                play_active   <= 1'b0;
                
                // Read from ADC FIFO if not empty, write to SRAM
                if (!adc_empty && !sram_op_pending) begin
                    adc_read <= 1'b1;
                    sram_op_pending <= 1'b1;
                    sram_wait <= 3'd0;
                end
                
                if (sram_op_pending) begin
                    case (sram_wait)
                        3'd0: begin
                            // ADC data available next cycle after read
                            sram_wait <= 3'd1;
                        end
                        3'd1: begin
                            // Write left channel (mono) to SRAM
                            sram_ce_n  <= 1'b0;
                            sram_we_n  <= 1'b0;
                            sram_oe_n  <= 1'b1;
                            sram_dq_oe <= 1'b1;
                            sram_addr  <= sram_write_ptr;
                            sram_wdata <= adc_data[31:16];  // Left channel
                            current_sample <= adc_data[31:16];
                            sample_valid_out <= 1'b1;
                            // Monitor: 錄音時同步送出 DAC（軟體監聽，取代 Bypass）
                            if (!dac_full) begin
                                dac_data  <= sw_mute ? 32'd0 : {adc_data[31:16], adc_data[31:16]};
                                dac_write <= 1'b1;
                            end
                            sram_wait <= 3'd2;
                        end
                        3'd2: begin
                            // Hold write for one more cycle
                            sram_ce_n  <= 1'b0;
                            sram_we_n  <= 1'b0;
                            sram_dq_oe <= 1'b1;
                            sram_wait <= 3'd3;
                        end
                        3'd3: begin
                            // Complete write
                            sram_we_n  <= 1'b1;
                            sram_ce_n  <= 1'b1;
                            sram_dq_oe <= 1'b0;
                            sram_op_pending <= 1'b0;
                            
                            if (sram_write_ptr >= record_limit_addr) begin
                                // SRAM or selected FLASH slot is full.
                                sram_full <= 1'b1;
                                record_length_words <= sram_write_ptr + 20'd1;
                                has_record_data <= 1'b1;
                                state <= ST_RECORD_STOP;
                            end else begin
                                sram_write_ptr <= sram_write_ptr + 20'd1;
                                record_length_words <= sram_write_ptr + 20'd1;
                            end
                        end
                    endcase
                end
                
                // Stop recording on KEY1
                if (key1_pulse) begin
                    record_length_words <= sram_write_ptr;
                    has_record_data <= (sram_write_ptr > 20'd0);
                    sram_op_pending <= 1'b0;
                    state <= ST_RECORD_STOP;
                end
                
                // Cancel = abort current recording
                if (cancel_pulse) begin
                    sram_op_pending <= 1'b0;
                    state <= ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_RECORD_STOP: begin
                mode_code     <= 8'h02;
                status_code   <= sram_full ? 8'h03 : 8'h02;
                record_active <= 1'b0;
                play_active   <= 1'b0;
                sram_ce_n     <= 1'b1;
                sram_op_pending <= 1'b0;
                
                if (key3_pulse && has_record_data && sw_flash_unlock) begin
                    flash_error <= 1'b0;
                    fl_timeout_counter <= 32'd0;
                    active_flash_slot <= sw_flash_slot;
                    erase_sector_idx <= sw_flash_slot_sector_base;
                    state <= ST_SAVE_FLASH_ERASE;
                end
                else if (key1_pulse) begin
                    // Re-record
                    sram_write_ptr <= 20'd0;
                    record_length_words <= 20'd0;
                    sram_full <= 1'b0;
                    clear_record_time <= 1'b1;
                    trigger_fifo_clear <= 1'b1;
                    state <= ST_RECORD;
                end
                else if (key2_pulse && has_record_data) begin
                    // Direct play from SRAM
                    sram_read_ptr <= 20'd0;
                    clear_play_time <= 1'b1;
                    trigger_fifo_clear <= 1'b1;
                    play_direct_sram <= 1'b1;
                    state <= ST_PLAY_SRAM;
                end
                else if (cancel_pulse) begin
                    state <= ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_SAVE_FLASH_ERASE: begin
                mode_code   <= 8'h03;
                status_code <= 8'h01;
                
                if (!flash_busy && !fl_op_done && !fl_waiting_for_done) begin
                    fl_target_addr <= {erase_sector_idx, 16'd0};  // Erase current sector (64KB boundary)
                    fl_op_start_erase <= 1'b1;
                    fl_waiting_for_done <= 1'b1;
                end
                
                if (fl_op_done && fl_waiting_for_done) begin
                    fl_waiting_for_done <= 1'b0;
                    if (erase_sector_idx == last_sector_needed) begin
                        fl_timeout_counter <= 32'd0;  // Reset timer for erase wait state
                        state <= ST_SAVE_FLASH_ERASE_WAIT;
                    end else begin
                        erase_sector_idx <= erase_sector_idx + 7'd1;
                        fl_timeout_counter <= 32'd0;  // Reset timeout for next sector erase
                    end
                end
                
                // Timeout (10 seconds per sector erase)
                if (fl_timeout_counter >= 32'd500_000_000) begin
                    flash_error <= 1'b1;
                    state <= ST_ERROR;
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_SAVE_FLASH_ERASE_WAIT: begin
                mode_code   <= 8'h03;
                status_code <= 8'h01;
                
                // 1. Wait 100us (5000 cycles) to let Flash 50us erase time-out window expire and fl_ry go low
                // 2. Poll fl_ry until it goes back high (erase complete)
                if (fl_timeout_counter >= 32'd5000) begin
                    if (fl_ry) begin
                        fl_header_word_idx <= 4'd0;
                        fl_byte_phase <= 1'b0;
                        fl_byte_counter <= flash_slot_base;
                        fl_timeout_counter <= 32'd0;
                        state <= ST_SAVE_FLASH_WRITE_HDR;
                    end
                end
                
                // Timeout (30 seconds for entire erase process)
                if (fl_timeout_counter >= 32'd1_500_000_000) begin
                    flash_error <= 1'b1;
                    state <= ST_ERROR;
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_SAVE_FLASH_WRITE_HDR: begin
                mode_code   <= 8'h03;
                status_code <= 8'h01;
                
                if (!flash_busy && !fl_op_done && !fl_waiting_for_done) begin
                    // Program one byte at a time directly from combinational value
                    fl_target_addr <= fl_byte_counter;
                    if (!fl_byte_phase)
                        fl_target_data <= header_word_val[7:0];   // Low byte first
                    else
                        fl_target_data <= header_word_val[15:8];  // High byte
                    fl_op_start_prog <= 1'b1;
                    fl_waiting_for_done <= 1'b1;
                end
                
                if (fl_op_done && fl_waiting_for_done) begin
                    fl_waiting_for_done <= 1'b0;
                    if (!fl_byte_phase) begin
                        // Low byte done, do high byte
                        fl_byte_phase <= 1'b1;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                    end else begin
                        // Both bytes done, next word
                        fl_byte_phase <= 1'b0;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                        fl_header_word_idx <= fl_header_word_idx + 4'd1;
                        
                        if (fl_header_word_idx >= FLASH_HEADER_WORDS - 1) begin
                            // Header complete, start data
                            fl_byte_counter <= flash_data_base;
                            fl_data_word_counter <= 20'd0;
                            fl_byte_phase <= 1'b0;
                            // Setup SRAM read
                            sram_read_ptr <= 20'd0;
                            state <= ST_SAVE_FLASH_WRITE_DATA;
                        end
                    end
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_SAVE_FLASH_WRITE_DATA: begin
                mode_code   <= 8'h03;
                status_code <= 8'h01;
                
                if (!flash_busy && !fl_op_done && !sram_op_pending) begin
                    if (!fl_byte_phase) begin
                        // First: read SRAM word
                        sram_ce_n  <= 1'b0;
                        sram_oe_n  <= 1'b0;
                        sram_we_n  <= 1'b1;
                        sram_dq_oe <= 1'b0;
                        sram_addr  <= sram_read_ptr;
                        sram_op_pending <= 1'b1;
                        sram_wait <= 3'd0;
                    end else if (!fl_waiting_for_done) begin
                        // High byte: program to FLASH
                        fl_target_addr <= fl_byte_counter;
                        fl_target_data <= fl_word_buffer[15:8];
                        fl_op_start_prog <= 1'b1;
                        fl_waiting_for_done <= 1'b1;
                    end
                end
                
                // SRAM read timing
                if (sram_op_pending) begin
                    sram_wait <= sram_wait + 3'd1;
                    if (sram_wait >= 3'd2) begin
                        fl_word_buffer <= sram_rdata;
                        sram_ce_n <= 1'b1;
                        sram_oe_n <= 1'b1;
                        sram_op_pending <= 1'b0;
                        // Now program low byte
                        fl_target_addr <= fl_byte_counter;
                        fl_target_data <= sram_rdata[7:0];
                        fl_op_start_prog <= 1'b1;
                        fl_waiting_for_done <= 1'b1;
                    end
                end
                
                if (fl_op_done && fl_waiting_for_done) begin
                    fl_waiting_for_done <= 1'b0;
                    fl_timeout_counter <= 32'd0;  // Reset watchdog on every byte completion
                    if (!fl_byte_phase) begin
                        fl_byte_phase <= 1'b1;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                    end else begin
                        fl_byte_phase <= 1'b0;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                        fl_data_word_counter <= fl_data_word_counter + 20'd1;
                        sram_read_ptr <= sram_read_ptr + 20'd1;
                        
                        if (fl_data_word_counter + 20'd1 >= record_length_words) begin
                            state <= ST_SAVE_FLASH_DONE;
                        end
                    end
                end
                
                // Timeout (30 seconds for large data)
                if (fl_timeout_counter >= 32'd1_500_000_000) begin
                    flash_error <= 1'b1;
                    state <= ST_ERROR;
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_SAVE_FLASH_DONE: begin
                mode_code   <= 8'h03;
                status_code <= 8'h02;
                sram_ce_n   <= 1'b1;
                
                if (cancel_pulse || key3_pulse) begin
                    state <= ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_LOAD_FLASH_READ_HDR: begin
                mode_code   <= 8'h04;
                status_code <= 8'h01;
                
                if (!flash_busy && !fl_op_done && !fl_waiting_for_done) begin
                    fl_target_addr <= fl_byte_counter;
                    fl_op_start_read <= 1'b1;
                    fl_waiting_for_done <= 1'b1;
                end
                
                if (fl_op_done && fl_waiting_for_done) begin
                    fl_waiting_for_done <= 1'b0;
                    if (!fl_byte_phase) begin
                        fl_word_buffer[7:0] <= fl_read_byte;
                        fl_byte_phase <= 1'b1;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                    end else begin
                        fl_word_buffer[15:8] <= fl_read_byte;
                        fl_byte_phase <= 1'b0;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                        
                        // Process completed header word
                        case (fl_header_word_idx)
                            4'd0: begin
                                if ({fl_read_byte, fl_word_buffer[7:0]} != FLASH_MAGIC) begin
                                    flash_header_valid <= 1'b0;
                                    state <= ST_ERROR;
                                end
                            end
                            4'd4: begin
                                flash_audio_length[15:0] <= {fl_read_byte, fl_word_buffer[7:0]};
                            end
                            4'd5: begin
                                // Word 5: low byte = record_length_words[19:16], high byte = 0x00
                                // fl_word_buffer[7:0] = low byte (has the data), fl_read_byte = high byte (0x00)
                                flash_audio_length[19:16] <= fl_word_buffer[3:0];  // FIX: was fl_read_byte[3:0] which is always 0
                                flash_header_valid <= 1'b1;
                            end
                        endcase
                        
                        fl_header_word_idx <= fl_header_word_idx + 4'd1;
                        
                        if (fl_header_word_idx >= 4'd6) begin
                            // Header reading sufficient, start loading data
                            if (flash_header_valid) begin
                                fl_byte_counter <= flash_data_base;
                                fl_data_word_counter <= 20'd0;
                                fl_byte_phase <= 1'b0;
                                sram_write_ptr <= 20'd0;
                                state <= ST_LOAD_FLASH_TO_SRAM;
                            end
                        end
                    end
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_LOAD_FLASH_TO_SRAM: begin
                mode_code   <= 8'h04;
                status_code <= 8'h01;
                
                if (!flash_busy && !fl_op_done && !sram_op_pending && !fl_waiting_for_done) begin
                    fl_target_addr <= fl_byte_counter;
                    fl_op_start_read <= 1'b1;
                    fl_waiting_for_done <= 1'b1;
                end
                
                if (fl_op_done && fl_waiting_for_done) begin
                    fl_waiting_for_done <= 1'b0;
                    if (!fl_byte_phase) begin
                        fl_word_buffer[7:0] <= fl_read_byte;
                        fl_byte_phase <= 1'b1;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                    end else begin
                        fl_word_buffer[15:8] <= fl_read_byte;
                        fl_byte_phase <= 1'b0;
                        fl_byte_counter <= fl_byte_counter + 23'd1;
                        
                        // Write assembled word to SRAM
                        sram_ce_n  <= 1'b0;
                        sram_we_n  <= 1'b0;
                        sram_oe_n  <= 1'b1;
                        sram_dq_oe <= 1'b1;
                        sram_addr  <= sram_write_ptr;
                        sram_wdata <= {fl_read_byte, fl_word_buffer[7:0]};
                        sram_op_pending <= 1'b1;
                        sram_wait <= 3'd0;
                    end
                end
                
                if (sram_op_pending) begin
                    sram_wait <= sram_wait + 3'd1;
                    if (sram_wait >= 3'd2) begin
                        sram_we_n <= 1'b1;
                        sram_ce_n <= 1'b1;
                        sram_dq_oe <= 1'b0;
                        sram_op_pending <= 1'b0;
                        sram_write_ptr <= sram_write_ptr + 20'd1;
                        fl_data_word_counter <= fl_data_word_counter + 20'd1;
                        fl_timeout_counter <= 32'd0;  // Reset watchdog on each word load completion
                        
                        if (fl_data_word_counter + 20'd1 >= flash_audio_length) begin
                            record_length_words <= flash_audio_length;
                            play_from_sram_ready <= 1'b1;
                            state <= ST_LOAD_FLASH_DONE;
                        end
                    end
                end
                
                // Timeout (30 seconds)
                if (fl_timeout_counter >= 32'd1_500_000_000) begin
                    flash_error <= 1'b1;
                    state <= ST_ERROR;
                end
                
                if (cancel_pulse) state <= ST_IDLE;
            end
            
            // ---------------------------------------------------------
            ST_LOAD_FLASH_DONE: begin
                mode_code   <= 8'h04;
                status_code <= 8'h02;
                sram_ce_n   <= 1'b1;
                
                // Auto-transition to play after brief display
                if (init_counter >= LOAD_DONE_WAIT) begin
                    sram_read_ptr <= 20'd0;
                    clear_play_time <= 1'b1;
                    trigger_fifo_clear <= 1'b1;
                    play_direct_sram <= 1'b0;
                    state <= ST_PLAY_SRAM;
                end
            end
            
            // ---------------------------------------------------------
            ST_PLAY_SRAM: begin
                mode_code   <= 8'h05;
                status_code <= 8'h01;
                record_active <= 1'b0;
                play_active   <= 1'b1;
                
                // Read one SRAM word for each codec DAC sample slot.
                if (dac_sample_tick && !dac_full && !sram_op_pending && !audio_fifo_clear) begin
                    sram_ce_n  <= 1'b0;
                    sram_oe_n  <= 1'b0;
                    sram_we_n  <= 1'b1;
                    sram_dq_oe <= 1'b0;
                    sram_addr  <= sram_read_ptr;
                    sram_op_pending <= 1'b1;
                    sram_wait <= 3'd0;
                end
                
                if (sram_op_pending) begin
                    sram_wait <= sram_wait + 3'd1;
                    if (sram_wait >= 3'd2) begin
                        sram_ce_n <= 1'b1;
                        sram_oe_n <= 1'b1;
                        sram_op_pending <= 1'b0;
                        
                        current_sample <= sram_rdata;
                        sample_valid_out <= 1'b1;
                        
                        // Send to DAC: mono → both L and R
                        if (sw_mute)
                            dac_data <= 32'd0;
                        else
                            dac_data <= {sram_rdata, sram_rdata};  // L=R=mono
                        dac_write <= 1'b1;
                        
                        if (sram_read_ptr >= record_length_words - 20'd1) begin
                            // End of audio
                            if (sw_loop_play) begin
                                sram_read_ptr <= 20'd0;
                                clear_play_time <= 1'b1;
                            end else begin
                                play_active <= 1'b0;
                                state <= play_direct_sram ? ST_RECORD_STOP : ST_IDLE;
                            end
                        end else begin
                            sram_read_ptr <= sram_read_ptr + 20'd1;
                        end
                    end
                end
                
                // Pause
                if (key2_pulse) begin
                    sram_op_pending <= 1'b0;
                    sram_ce_n <= 1'b1;
                    state <= ST_PLAY_PAUSE;
                end
                
                // Stop
                if (cancel_pulse) begin
                    play_active <= 1'b0;
                    sram_op_pending <= 1'b0;
                    state <= play_direct_sram ? ST_RECORD_STOP : ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_PLAY_PAUSE: begin
                mode_code   <= 8'h06;
                status_code <= 8'h08;
                play_active <= 1'b0;
                sram_ce_n   <= 1'b1;
                
                if (key2_pulse) begin
                    play_active     <= 1'b1;
                    sram_wait       <= 3'd0;    // 修復：重置 SRAM wait counter 避免播放無聲
                    sram_op_pending <= 1'b0;    // 確保 pending 旗標乾淨
                    state      <= ST_PLAY_SRAM;
                end
                
                if (cancel_pulse) begin
                    state <= play_direct_sram ? ST_RECORD_STOP : ST_IDLE;
                end
            end
            
            // ---------------------------------------------------------
            ST_ERROR: begin
                mode_code   <= 8'h99;
                if (sram_full)
                    status_code <= 8'h03;
                else if (!flash_header_valid)
                    status_code <= 8'h04;
                else if (flash_error)
                    status_code <= 8'h05;
                else
                    status_code <= 8'h07;
                
                record_active <= 1'b0;
                play_active   <= 1'b0;
                sram_ce_n     <= 1'b1;
                sram_op_pending <= 1'b0;
                
                if (cancel_pulse) begin
                    flash_error <= 1'b0;
                    sram_full <= 1'b0;
                    state <= ST_IDLE;
                end
            end
            
            default: begin
                state <= ST_RESET;
            end
        endcase

        // Pulse stretcher for audio FIFO clear (50,000 cycles = 1 ms)
        if (trigger_fifo_clear) begin
            fifo_clear_timer <= 16'd50_000;
            audio_fifo_clear <= 1'b1;
        end else if (fifo_clear_timer > 16'd0) begin
            fifo_clear_timer <= fifo_clear_timer - 16'd1;
            audio_fifo_clear <= 1'b1;
        end else begin
            audio_fifo_clear <= 1'b0;
        end

        // SignalTap/JTAG timing visibility. Values are in CLOCK_50 cycles.
        dbg_sram_op_pending_d <= sram_op_pending;
        if (sram_op_pending && !dbg_sram_op_pending_d) begin
            dbg_sram_pending_cycles <= 32'd1;
        end else if (sram_op_pending) begin
            dbg_sram_pending_cycles <= dbg_sram_pending_cycles + 32'd1;
        end else begin
            dbg_sram_pending_cycles <= 32'd0;
        end
        if (!sram_op_pending && dbg_sram_op_pending_d) begin
            dbg_sram_last_cycles <= dbg_sram_pending_cycles;
        end

        dbg_flash_busy_d <= flash_busy;
        if (flash_busy && !dbg_flash_busy_d) begin
            dbg_flash_busy_cycles <= 32'd1;
        end else if (flash_busy) begin
            dbg_flash_busy_cycles <= dbg_flash_busy_cycles + 32'd1;
        end else begin
            dbg_flash_busy_cycles <= 32'd0;
        end
        if (!flash_busy && dbg_flash_busy_d) begin
            dbg_flash_last_cycles <= dbg_flash_busy_cycles;
        end

    end
end

endmodule
