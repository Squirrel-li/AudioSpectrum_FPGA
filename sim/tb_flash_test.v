`timescale 1ns/1ps

module tb_flash_test;
    reg         clk;
    reg         rst_n;
    reg  [3:0]  key;
    reg  [17:0] sw;
    
    wire [6:0]  hex0, hex1, hex2, hex3;
    wire [6:0]  hex4, hex5, hex6, hex7;
    wire [8:0]  ledg;
    wire [17:0] ledr;
    
    wire [22:0] fl_addr;
    wire        fl_ce_n;
    wire        fl_oe_n;
    wire        fl_we_n;
    wire        fl_rst_n;
    wire        fl_wp_n;
    wire        fl_ry;
    wire [7:0]  fl_dq;
    
    // Instantiate UUT
    flash_test_top uut (
        .CLOCK_50(clk),
        .KEY(key),
        .SW(sw),
        .HEX0(hex0), .HEX1(hex1), .HEX2(hex2), .HEX3(hex3),
        .HEX4(hex4), .HEX5(hex5), .HEX6(hex6), .HEX7(hex7),
        .LEDG(ledg),
        .LEDR(ledr),
        .FL_ADDR(fl_addr),
        .FL_CE_N(fl_ce_n),
        .FL_OE_N(fl_oe_n),
        .FL_WE_N(fl_we_n),
        .FL_RST_N(fl_rst_n),
        .FL_WP_N(fl_wp_n),
        .FL_RY(fl_ry),
        .FL_DQ(fl_dq)
    );
    
    // Instantiate Flash Model
    flash_model flash_inst (
        .FL_ADDR(fl_addr),
        .FL_CE_N(fl_ce_n),
        .FL_OE_N(fl_oe_n),
        .FL_WE_N(fl_we_n),
        .FL_RST_N(fl_rst_n),
        .FL_WP_N(fl_wp_n),
        .FL_RY(fl_ry),
        .FL_DQ(fl_dq)
    );
    
    // Clock generation: 50MHz (20ns period)
    initial clk = 0;
    always #10 clk = ~clk;
    
    initial begin
        $dumpfile("tb_flash_test.vcd");
        $dumpvars(0, tb_flash_test);
        
        rst_n = 1'b0;
        key = 4'b1111;
        sw = 18'd0;
        
        #100;
        rst_n = 1'b1;
        key[0] = 1'b0; // reset
        #100;
        key[0] = 1'b1;
        #200;
        
        $display("[TB] Bypassing key debounce in simulation...");
        @(posedge clk);
        force uut.key1_deb = 1'b1;
        @(posedge clk);
        release uut.key1_deb;
        
        $display("[TB] Test started. Monitoring FSM state...");
        $display("[TB] Writing 24 words: 16 header + 8 audio PCM samples");
        
        // Wait for FSM to reach ST_DONE (state = 5)
        while (uut.state !== 3'd5) begin
            @(posedge clk);
        end
        
        #500;
        
        $display("[TB] Test finished.");
        if (uut.test_pass === 1'b1) begin
            $display("[TB] ==============================");
            $display("[TB] SUCCESS: Audio file format test PASSED!");
            $display("[TB] Header verified: MAGIC=A55A, VER=0001, SR=22400, FMT=Mono");
            $display("[TB] Audio data: 8 PCM samples (half sine wave) verified");
            $display("[TB] Total: 24 words (48 bytes) written and read back correctly");
            $display("[TB] ==============================");
        end else begin
            $display("[TB] ==============================");
            $display("[TB] FAILURE: Audio file format test FAILED!");
            $display("[TB] Mismatch at word index: %d", uut.mismatch_word_index);
            $display("[TB] Expected Word: %h", uut.mismatch_expected_word);
            $display("[TB] Read Word    : %h", uut.mismatch_read_word);
            $display("[TB] ==============================");
        end
        
        $finish;
    end
    
    // Monitor state transitions
    always @(uut.state) begin
        case (uut.state)
            3'd0: $display("[FSM] State: ST_IDLE");
            3'd1: $display("[FSM] State: ST_ERASE");
            3'd2: $display("[FSM] State: ST_ERASE_WAIT");
            3'd3: $display("[FSM] State: ST_WRITE  (24 words to write)");
            3'd4: $display("[FSM] State: ST_READ   (24 words to verify)");
            3'd5: $display("[FSM] State: ST_DONE");
            default: $display("[FSM] State: UNKNOWN");
        endcase
    end
endmodule

module flash_model (
    input  wire [22:0] FL_ADDR,
    input  wire        FL_CE_N,
    input  wire        FL_OE_N,
    input  wire        FL_WE_N,
    input  wire        FL_RST_N,
    input  wire        FL_WP_N,
    output reg         FL_RY,
    inout  wire [7:0]  FL_DQ
);
    // Simple 256-byte internal memory for testing
    reg [7:0] mem [0:255];
    
    // Command FSM
    reg [2:0] cmd_state;
    localparam CMD_IDLE     = 3'd0;
    localparam CMD_UN1      = 3'd1;
    localparam CMD_UN2      = 3'd2;
    localparam CMD_ERASE    = 3'd3;
    localparam CMD_ER_UN1   = 3'd4;
    localparam CMD_ER_UN2   = 3'd5;
    localparam CMD_PROG     = 3'd6;
    
    reg [7:0] dio_out;
    reg       dio_oe;
    assign FL_DQ = dio_oe ? dio_out : 8'hZZ;
    
    integer i;
    initial begin
        FL_RY = 1'b1;
        cmd_state = CMD_IDLE;
        dio_oe = 1'b0;
        dio_out = 8'h00;
        // Pre-fill memory with some garbage, e.g. 0xFF (erased state)
        for (i = 0; i < 256; i = i + 1) begin
            mem[i] = 8'hFF;
        end
    end
    
    // Read operation
    always @(*) begin
        if (!FL_CE_N && !FL_OE_N && FL_WE_N) begin
            dio_out = mem[FL_ADDR[7:0]];
            dio_oe = 1'b1;
        end else begin
            dio_oe = 1'b0;
        end
    end
    
    // Write / Command sequence detection on rising edge of WE_N (when CE_N is low)
    always @(posedge FL_WE_N) begin
        if (!FL_CE_N) begin
            case (cmd_state)
                CMD_IDLE: begin
                    if (FL_ADDR == 23'hAAA && FL_DQ == 8'hAA)
                        cmd_state <= CMD_UN1;
                end
                
                CMD_UN1: begin
                    if (FL_ADDR == 23'h555 && FL_DQ == 8'h55)
                        cmd_state <= CMD_UN2;
                    else
                        cmd_state <= CMD_IDLE;
                end
                
                CMD_UN2: begin
                    if (FL_ADDR == 23'hAAA && FL_DQ == 8'h80)
                        cmd_state <= CMD_ERASE;
                    else if (FL_ADDR == 23'hAAA && FL_DQ == 8'hA0)
                        cmd_state <= CMD_PROG;
                    else
                        cmd_state <= CMD_IDLE;
                end
                
                CMD_ERASE: begin
                    if (FL_ADDR == 23'hAAA && FL_DQ == 8'hAA)
                        cmd_state <= CMD_ER_UN1;
                    else
                        cmd_state <= CMD_IDLE;
                end
                
                CMD_ER_UN1: begin
                    if (FL_ADDR == 23'h555 && FL_DQ == 8'h55)
                        cmd_state <= CMD_ER_UN2;
                    else
                        cmd_state <= CMD_IDLE;
                end
                
                CMD_ER_UN2: begin
                    if (FL_DQ == 8'h30) begin
                        $display("[FLASH MODEL] Sector Erase triggered at Addr: %h", FL_ADDR);
                        FL_RY <= 1'b0;
                        FL_RY <= #1000 1'b1;
                        for (i = 0; i < 256; i = i + 1) begin
                            mem[i] <= #1000 8'hFF;
                        end
                    end
                    cmd_state <= CMD_IDLE;
                end
                
                CMD_PROG: begin
                    $display("[FLASH MODEL] Program byte: Addr=%h, Data=%h", FL_ADDR, FL_DQ);
                    mem[FL_ADDR[7:0]] <= FL_DQ & mem[FL_ADDR[7:0]];
                    FL_RY <= 1'b0;
                    FL_RY <= #200 1'b1;
                    cmd_state <= CMD_IDLE;
                end
                
                default: cmd_state <= CMD_IDLE;
            endcase
        end
    end
    
    // Reset handling
    always @(negedge FL_RST_N) begin
        cmd_state <= CMD_IDLE;
        FL_RY     <= 1'b1;
    end
endmodule
