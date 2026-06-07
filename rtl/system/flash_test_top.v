// ============================================================================
// Standalone FLASH Audio Header + PCM Data Read/Write Test for DE2-115
// Tests writing a complete audio file format (header + data) via 8-bit bus
// Header: MAGIC, VERSION, SAMPLE_RATE, FORMAT, LENGTH, CHECKSUM, RESERVED
// Data:   8 x 16-bit PCM samples (half sine wave)
// ============================================================================
module flash_test_top (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,
    input  wire [17:0] SW,
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3,
    output wire [6:0]  HEX4, HEX5, HEX6, HEX7,
    output reg  [8:0]  LEDG,
    output reg  [17:0] LEDR,
    // FLASH interface
    output wire [22:0] FL_ADDR,
    output wire        FL_CE_N,
    output wire        FL_OE_N,
    output wire        FL_WE_N,
    output wire        FL_RST_N,
    output wire        FL_WP_N,
    input  wire        FL_RY,
    inout  wire [7:0]  FL_DQ
);

    // =========================================================================
    // Debounce and Key Pulses
    // =========================================================================
    wire rst_n = KEY[0]; // KEY0 acts as active-low reset
    
    // KEY1 starts the test
    reg [19:0] key1_deb_cnt;
    reg        key1_deb;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            key1_deb_cnt <= 20'd0;
            key1_deb     <= 1'b0;
        end else begin
            if (KEY[1] == 1'b0) begin
                if (key1_deb_cnt < 20'd1_000_000)
                    key1_deb_cnt <= key1_deb_cnt + 20'd1;
                else
                    key1_deb <= 1'b1;
            end else begin
                key1_deb_cnt <= 20'd0;
                key1_deb     <= 1'b0;
            end
        end
    end
    
    reg key1_deb_d;
    wire start_test = key1_deb && !key1_deb_d;
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n)
            key1_deb_d <= 1'b0;
        else
            key1_deb_d <= key1_deb;
    end

    // =========================================================================
    // FSM States
    // =========================================================================
    localparam ST_IDLE            = 3'd0;
    localparam ST_ERASE           = 3'd1;
    localparam ST_ERASE_WAIT      = 3'd2;
    localparam ST_WRITE           = 3'd3;
    localparam ST_READ            = 3'd4;
    localparam ST_DONE            = 3'd5;

    // Audio file layout constants
    localparam TOTAL_WORDS        = 5'd24;   // 16 header + 8 audio = 24 words
    localparam LAST_WORD_INDEX    = 5'd23;
    localparam HEADER_WORDS       = 5'd16;
    localparam AUDIO_SAMPLES      = 5'd8;

    // FLASH sub-states
    localparam FL_SUB_IDLE        = 3'd0;
    localparam FL_SUB_ERASE_SEQ   = 3'd1;
    localparam FL_SUB_PROG_SEQ    = 3'd2;
    localparam FL_SUB_READ        = 3'd3;
    localparam FL_SUB_READ_WAIT   = 3'd4;

    // FLASH command unlock addresses (byte addresses)
    localparam FLASH_UNLOCK1_ADDR = 23'hAAA;
    localparam FLASH_UNLOCK2_ADDR = 23'h555;

    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [2:0]  state;
    reg [4:0]  test_word_index;        // 0 to 23 index for writing/reading 24 words
    reg        word_write_phase;       // 0 for high byte, 1 for low byte
    reg        word_read_phase;        // 0 for high byte, 1 for low byte
    reg        test_pass;              // Test status: 1 = pass, 0 = fail
    reg        mismatch_detect;        // Mismatch flag
    reg [4:0]  mismatch_word_index;    // Word index of first mismatch
    reg [15:0] read_word_buf;          // Holds last read 16-bit word
    reg [15:0] mismatch_expected_word; // Expected 16-bit word at mismatch
    reg [15:0] mismatch_read_word;     // Read 16-bit word at mismatch

    // FLASH low-level control registers managed by controller
    wire        flash_busy;
    wire        fl_op_done;             // Operation done pulse from controller
    wire [7:0]  fl_read_byte;           // Assembled byte from read from controller
    reg  [22:0] fl_target_addr;         // Target address for controller
    reg  [7:0]  fl_target_data;         // Target data for controller
    reg        fl_op_start_erase;      // Trigger erase
    reg        fl_op_start_prog;       // Trigger program
    reg        fl_op_start_read;       // Trigger read
    reg [31:0] fl_timeout_counter;     // Watchdog timer (32-bit)

    // =========================================================================
    // FLASH Controller Instantiation
    // =========================================================================
    wire        fl_dq_oe;
    wire [7:0]  fl_dq_out;
    assign FL_DQ = fl_dq_oe ? fl_dq_out : 8'hZZ;
    wire [7:0]  fl_dq_in = FL_DQ;

    flash_controller flash_ctrl_inst (
        .clk(CLOCK_50),
        .rst_n(rst_n),
        .cmd_erase(fl_op_start_erase),
        .cmd_write(fl_op_start_prog),
        .cmd_read(fl_op_start_read),
        .cmd_addr(fl_target_addr),
        .cmd_wdata(fl_target_data),
        .cmd_done(fl_op_done),
        .cmd_rdata(fl_read_byte),
        .busy(flash_busy),
        
        // FLASH hardware interface
        .FL_ADDR(FL_ADDR),
        .FL_CE_N(FL_CE_N),
        .FL_OE_N(FL_OE_N),
        .FL_WE_N(FL_WE_N),
        .FL_RST_N(FL_RST_N),
        .FL_WP_N(FL_WP_N),
        .FL_RY(FL_RY),
        .fl_dq_oe(fl_dq_oe),
        .fl_dq_out(fl_dq_out),
        .fl_dq_in(fl_dq_in)
    );

    // =========================================================================
    // Expected pattern lookup — Audio Header + PCM Data
    // =========================================================================
    // Header layout (word offsets 0-15):
    //   0: MAGIC        = 0xA55A
    //   1: VERSION      = 0x0001
    //   2: SAMPLE_RATE  = 22400 (0x5780)
    //   3: FORMAT       = 0x0000 (Mono, Signed PCM)
    //   4: LENGTH_LO    = 8 (number of audio samples)
    //   5: LENGTH_HI    = 0
    //   6: CHECKSUM_LO  = 0x0000 (not used)
    //   7: CHECKSUM_HI  = 0x0000 (not used)
    //   8-15: RESERVED  = 0x0000
    // Audio data (word offsets 16-23): half sine wave 16-bit signed PCM
    reg [15:0] expected_word;
    always @(*) begin
        case (test_word_index)
            // ---- Header ----
            5'd0:  expected_word = 16'hA55A;  // MAGIC
            5'd1:  expected_word = 16'h0001;  // VERSION
            5'd2:  expected_word = 16'h5780;  // SAMPLE_RATE = 22400
            5'd3:  expected_word = 16'h0000;  // FORMAT: Mono, Signed PCM
            5'd4:  expected_word = 16'h0008;  // LENGTH_LO = 8 samples
            5'd5:  expected_word = 16'h0000;  // LENGTH_HI
            5'd6:  expected_word = 16'h0000;  // CHECKSUM_LO (unused)
            5'd7:  expected_word = 16'h0000;  // CHECKSUM_HI (unused)
            5'd8:  expected_word = 16'h0000;  // RESERVED
            5'd9:  expected_word = 16'h0000;  // RESERVED
            5'd10: expected_word = 16'h0000;  // RESERVED
            5'd11: expected_word = 16'h0000;  // RESERVED
            5'd12: expected_word = 16'h0000;  // RESERVED
            5'd13: expected_word = 16'h0000;  // RESERVED
            5'd14: expected_word = 16'h0000;  // RESERVED
            5'd15: expected_word = 16'h0000;  // RESERVED
            // ---- Audio PCM Data (half sine wave) ----
            5'd16: expected_word = 16'h0000;  // sin(0)       =  0.000 -> 0x0000
            5'd17: expected_word = 16'h30FB;  // sin(pi/8)    = +0.383 -> 0x30FB
            5'd18: expected_word = 16'h5A82;  // sin(pi/4)    = +0.707 -> 0x5A82
            5'd19: expected_word = 16'h7641;  // sin(3*pi/8)  = +0.924 -> 0x7641
            5'd20: expected_word = 16'h7FFF;  // sin(pi/2)    = +1.000 -> 0x7FFF
            5'd21: expected_word = 16'h7641;  // sin(5*pi/8)  = +0.924 -> 0x7641
            5'd22: expected_word = 16'h5A82;  // sin(3*pi/4)  = +0.707 -> 0x5A82
            5'd23: expected_word = 16'h30FB;  // sin(7*pi/8)  = +0.383 -> 0x30FB
            default: expected_word = 16'h0000;
        endcase
    end

    // =========================================================================
    // Main FSM State and Datapath Control
    // =========================================================================
    always @(posedge CLOCK_50 or negedge rst_n) begin
        if (!rst_n) begin
            state                  <= ST_IDLE;
            test_word_index        <= 5'd0;
            word_write_phase       <= 1'b0;
            word_read_phase        <= 1'b0;
            test_pass              <= 1'b0;
            mismatch_detect        <= 1'b0;
            mismatch_word_index    <= 5'd0;
            read_word_buf          <= 16'd0;
            fl_op_start_erase      <= 1'b0;
            fl_op_start_prog       <= 1'b0;
            fl_op_start_read       <= 1'b0;
            fl_target_addr         <= 23'd0;
            fl_target_data         <= 8'd0;
            LEDG                   <= 9'd0;
            LEDR                   <= 18'd0;
            fl_timeout_counter     <= 32'd0;
            mismatch_expected_word <= 16'd0;
            mismatch_read_word     <= 16'd0;
        end else begin
            // Default timer behavior
            if (state == ST_ERASE || state == ST_ERASE_WAIT || state == ST_WRITE || state == ST_READ) begin
                fl_timeout_counter <= fl_timeout_counter + 32'd1;
            end else begin
                fl_timeout_counter <= 32'd0;
            end

            // Pulse defaults
            fl_op_start_erase <= 1'b0;
            fl_op_start_prog  <= 1'b0;
            fl_op_start_read  <= 1'b0;
            
            case (state)
                ST_IDLE: begin
                    test_word_index        <= 5'd0;
                    word_write_phase       <= 1'b0;
                    word_read_phase        <= 1'b0;
                    test_pass              <= 1'b0;
                    mismatch_detect        <= 1'b0;
                    mismatch_word_index    <= 5'd0;
                    mismatch_expected_word <= 16'd0;
                    mismatch_read_word     <= 16'd0;
                    LEDG                   <= 9'd0;
                    LEDR                   <= 18'd0;
                    
                    if (start_test) begin
                        state <= ST_ERASE;
                    end
                end
                
                ST_ERASE: begin
                    LEDR[0] <= 1'b1; // Erasing indicator
                    if (!flash_busy && !fl_op_done) begin
                        fl_target_addr <= 23'd0; // Sector 0
                        fl_op_start_erase <= 1'b1;
                    end
                    
                    if (fl_op_done) begin
                        fl_timeout_counter <= 32'd0;
                        state <= ST_ERASE_WAIT;
                    end
                    
                    if (fl_timeout_counter >= 32'd150_000_000) begin
                        LEDR <= 18'h3FFFF;
                        state <= ST_DONE;
                    end
                end
                
                ST_ERASE_WAIT: begin
                    LEDR[1] <= 1'b1; // Erase Wait indicator
                    if (fl_timeout_counter >= 32'd5000) begin
                        if (FL_RY) begin
                            test_word_index  <= 5'd0;
                            word_write_phase <= 1'b0;
                            fl_timeout_counter <= 32'd0;
                            state            <= ST_WRITE;
                        end
                    end
                    
                    if (fl_timeout_counter >= 32'd1_500_000_000) begin
                        LEDR <= 18'h3FFFF;
                        state <= ST_DONE;
                    end
                end
                
                ST_WRITE: begin
                    LEDR[2] <= 1'b1; // Writing indicator
                    // Show progress on LEDR[17:4]: light up proportionally
                    LEDR[17:4] <= (14'h3FFF >> (14 - ((test_word_index * 14) / TOTAL_WORDS)));
                    
                    if (!flash_busy && !fl_op_done) begin
                        if (word_write_phase == 1'b0) begin
                            fl_target_addr <= {17'd0, test_word_index, 1'b0}; // Even byte (high byte)
                            fl_target_data <= expected_word[15:8];
                        end else begin
                            fl_target_addr <= {17'd0, test_word_index, 1'b1}; // Odd byte (low byte)
                            fl_target_data <= expected_word[7:0];
                        end
                        fl_op_start_prog <= 1'b1;
                    end
                    
                    if (fl_op_done) begin
                        if (word_write_phase == 1'b0) begin
                            word_write_phase <= 1'b1;
                        end else begin
                            word_write_phase <= 1'b0;
                            if (test_word_index == LAST_WORD_INDEX) begin
                                test_word_index <= 5'd0;
                                word_read_phase <= 1'b0;
                                state           <= ST_READ;
                            end else begin
                                test_word_index <= test_word_index + 5'd1;
                            end
                        end
                    end
                    
                    if (fl_timeout_counter >= 32'd150_000_000) begin
                        LEDR <= 18'h3FFFF;
                        state <= ST_DONE;
                    end
                end
                
                ST_READ: begin
                    LEDR[3] <= 1'b1; // Reading indicator
                    LEDR[17:4] <= (14'h3FFF >> (14 - ((test_word_index * 14) / TOTAL_WORDS)));
                    
                    if (!flash_busy && !fl_op_done) begin
                        if (word_read_phase == 1'b0) begin
                            fl_target_addr <= {17'd0, test_word_index, 1'b0};
                        end else begin
                            fl_target_addr <= {17'd0, test_word_index, 1'b1};
                        end
                        fl_op_start_read <= 1'b1;
                    end
                    
                    if (fl_op_done) begin
                        if (word_read_phase == 1'b0) begin
                            read_word_buf[15:8] <= fl_read_byte;
                            word_read_phase     <= 1'b1;
                        end else begin
                            word_read_phase <= 1'b0;
                            read_word_buf[7:0]  <= fl_read_byte;
                            
                            if ({read_word_buf[15:8], fl_read_byte} != expected_word) begin
                                if (!mismatch_detect) begin
                                    mismatch_word_index    <= test_word_index;
                                    mismatch_expected_word <= expected_word;
                                    mismatch_read_word     <= {read_word_buf[15:8], fl_read_byte};
                                end
                                mismatch_detect <= 1'b1;
                            end
                            
                            if (test_word_index == LAST_WORD_INDEX) begin
                                state <= ST_DONE;
                            end else begin
                                test_word_index <= test_word_index + 5'd1;
                            end
                        end
                    end
                    
                    if (fl_timeout_counter >= 32'd150_000_000) begin
                        LEDR <= 18'h3FFFF;
                        state <= ST_DONE;
                    end
                end
                
                ST_DONE: begin
                    if (!mismatch_detect && LEDR != 18'h3FFFF) begin
                        test_pass <= 1'b1;
                        LEDG <= 9'h1FF; // Green PASS
                        LEDR <= 18'd0;
                    end else begin
                        test_pass <= 1'b0;
                        LEDR <= 18'h3FFFF; // Red FAIL
                    end
                    
                    if (start_test) begin
                        state <= ST_IDLE;
                    end
                end
                
                default: state <= ST_IDLE;
            endcase
        end
    end

    // =========================================================================
    // 7-segment display logic
    // =========================================================================
    // Outputs segment bits for 7-segment display (active-low)
    // 0 -> segments ON, 1 -> segments OFF
    // Format: {g,f,e,d,c,b,a}
    
    function [6:0] lut_char;
        input [7:0] ascii;
        case (ascii)
            "I": lut_char = 7'b1001111; // Capital I
            "d": lut_char = 7'b0100001; // d
            "L": lut_char = 7'b1000111; // L
            "E": lut_char = 7'b0000110; // E
            "r": lut_char = 7'b0101111; // r
            "A": lut_char = 7'b0001000; // A
            "S": lut_char = 7'b0010010; // S
            "U": lut_char = 7'b1000001; // Capital U
            "t": lut_char = 7'b0000111; // t
            "P": lut_char = 7'b0001100; // P
            "F": lut_char = 7'b0001110; // F
            "o": lut_char = 7'b0100011; // o
            "n": lut_char = 7'b0101011; // n
            "W": lut_char = 7'b1011100; // W (looks like bottom half)
            "u": lut_char = 7'b0011100; // u
            "i": lut_char = 7'b1111001; // i / 1
            "l": lut_char = 7'b1110001; // l
            "-": lut_char = 7'b0111111; // dash
            default: lut_char = 7'b1111111; // blank
        endcase
    endfunction

    function [6:0] lut_hex;
        input [3:0] nibble;
        case (nibble)
            4'h0: lut_hex = 7'b1000000; // 0
            4'h1: lut_hex = 7'b1111001; // 1
            4'h2: lut_hex = 7'b0100100; // 2
            4'h3: lut_hex = 7'b0110000; // 3
            4'h4: lut_hex = 7'b0011001; // 4
            4'h5: lut_hex = 7'b0010010; // 5
            4'h6: lut_hex = 7'b0000010; // 6
            4'h7: lut_hex = 7'b1111000; // 7
            4'h8: lut_hex = 7'b0000000; // 8
            4'h9: lut_hex = 7'b0010000; // 9
            4'hA: lut_hex = 7'b0001000; // A
            4'hb: lut_hex = 7'b0000011; // b
            4'hC: lut_hex = 7'b1000110; // C
            4'hd: lut_hex = 7'b0100001; // d
            4'hE: lut_hex = 7'b0000110; // E
            4'hF: lut_hex = 7'b0001110; // F
            default: lut_hex = 7'b1111111; // blank
        endcase
    endfunction

    reg [6:0] h7, h6, h5, h4, h3, h2, h1, h0;
    always @(*) begin
        h7 = lut_char(" ");
        h6 = lut_char(" ");
        h5 = lut_char(" ");
        h4 = lut_char(" ");
        h3 = lut_char(" ");
        h2 = lut_char(" ");
        h1 = lut_char(" ");
        h0 = lut_char(" ");
        
        case (state)
            ST_IDLE: begin
                // "  Audio" -> "Au IdLE"
                h7 = lut_char("A"); h6 = lut_char("u");
                h3 = lut_char("I"); h2 = lut_char("d"); h1 = lut_char("L"); h0 = lut_char("E");
            end
            ST_ERASE: begin
                h3 = lut_char("E"); h2 = lut_char("r"); h1 = lut_char("A"); h0 = lut_char("S");
            end
            ST_ERASE_WAIT: begin
                h3 = lut_char("E"); h2 = lut_char("r"); h1 = lut_char("-"); h0 = lut_char("W");
            end
            ST_WRITE: begin
                // "Ur  XX" — show word index on HEX1-HEX0
                h7 = lut_char("U"); h6 = lut_char("r");
                h3 = lut_char("i"); h2 = lut_char("t");
                h1 = lut_hex({3'b0, test_word_index[4]});
                h0 = lut_hex(test_word_index[3:0]);
            end
            ST_READ: begin
                // "rd  XX" — show word index on HEX1-HEX0
                h7 = lut_char("r"); h6 = lut_char("d");
                h3 = lut_char("E"); h2 = lut_char("A");
                h1 = lut_hex({3'b0, test_word_index[4]});
                h0 = lut_hex(test_word_index[3:0]);
            end
            ST_DONE: begin
                if (test_pass) begin
                    // PASS: HEX7-4 show "A55A" (MAGIC), HEX3-0 show "PASS"
                    h7 = lut_hex(4'hA); h6 = lut_hex(4'h5);
                    h5 = lut_hex(4'h5); h4 = lut_hex(4'hA);
                    h3 = lut_char("P"); h2 = lut_char("A"); h1 = lut_char("S"); h0 = lut_char("S");
                end else begin
                    // FAIL: HEX7-4 = expected, HEX3-0 = actual read
                    h7 = lut_hex(mismatch_expected_word[15:12]);
                    h6 = lut_hex(mismatch_expected_word[11:8]);
                    h5 = lut_hex(mismatch_expected_word[7:4]);
                    h4 = lut_hex(mismatch_expected_word[3:0]);
                    h3 = lut_hex(mismatch_read_word[15:12]);
                    h2 = lut_hex(mismatch_read_word[11:8]);
                    h1 = lut_hex(mismatch_read_word[7:4]);
                    h0 = lut_hex(mismatch_read_word[3:0]);
                end
            end
        endcase
    end

    assign HEX0 = h0;
    assign HEX1 = h1;
    assign HEX2 = h2;
    assign HEX3 = h3;
    assign HEX4 = h4;
    assign HEX5 = h5;
    assign HEX6 = h6;
    assign HEX7 = h7;

endmodule
