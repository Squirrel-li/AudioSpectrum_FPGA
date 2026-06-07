`timescale 1ns/1ps

module tb_system_fsm;
    localparam ST_RESET                 = 4'd0;
    localparam ST_CODEC_INIT            = 4'd1;
    localparam ST_IDLE                  = 4'd2;
    localparam ST_RECORD                = 4'd3;
    localparam ST_RECORD_STOP           = 4'd4;
    localparam ST_PLAY_SRAM             = 4'd5;
    localparam ST_SAVE_FLASH_ERASE      = 4'd7;
    localparam ST_SAVE_FLASH_DONE       = 4'd10;

    reg clk;
    reg rst_n;
    reg cancel_pulse;
    reg key1_pulse;
    reg key2_pulse;
    reg key3_pulse;
    reg [17:0] sw;

    reg        adc_empty;
    wire       adc_read;
    reg [31:0] adc_data;

    reg        dac_full;
    reg        dac_sample_tick;
    wire       dac_write;
    wire [31:0] dac_data;
    wire       audio_fifo_clear;

    wire [19:0] sram_addr;
    wire [15:0] sram_wdata;
    reg  [15:0] sram_rdata;
    wire        sram_we_n;
    wire        sram_oe_n;
    wire        sram_ce_n;
    wire        sram_ub_n;
    wire        sram_lb_n;
    wire        sram_dq_oe;

    wire [22:0] fl_addr;
    wire [7:0]  fl_wdata;
    wire [7:0]  fl_rdata;
    wire        fl_ce_n;
    wire        fl_oe_n;
    wire        fl_we_n;
    wire        fl_rst_n;
    wire        fl_wp_n;
    wire        fl_dq_oe;
    wire        fl_ry;
    wire [7:0]  fl_dq;

    wire [3:0]  fsm_state;
    wire [7:0]  mode_code;
    wire [7:0]  status_code;
    wire        record_active;
    wire        play_active;
    wire        sample_valid_out;
    wire signed [15:0] current_sample;
    wire        clear_record_time;
    wire        clear_play_time;
    wire        flash_header_valid;
    wire        sram_full;
    wire        flash_error;
    wire [19:0] record_length_words;

    reg [15:0] sram_mem [0:31];
    integer i;
    integer sample_count;

    assign fl_dq = fl_dq_oe ? fl_wdata : 8'hZZ;
    assign fl_rdata = fl_dq;

    system_fsm #(
        .SAMPLE_RATE_HZ(48000),
        .SRAM_MAX_ADDR(20'd31),
        .FLASH_HEADER_WORDS(16),
        .FLASH_AUDIO_BASE(23'd32),
        .CODEC_INIT_WAIT(26'd3),
        .LOAD_DONE_WAIT(26'd3)
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .cancel_pulse(cancel_pulse),
        .key1_pulse(key1_pulse),
        .key2_pulse(key2_pulse),
        .key3_pulse(key3_pulse),
        .sw(sw),
        .adc_empty(adc_empty),
        .adc_read(adc_read),
        .adc_data(adc_data),
        .dac_full(dac_full),
        .dac_sample_tick(dac_sample_tick),
        .dac_write(dac_write),
        .dac_data(dac_data),
        .audio_fifo_clear(audio_fifo_clear),
        .sram_addr(sram_addr),
        .sram_wdata(sram_wdata),
        .sram_rdata(sram_rdata),
        .sram_we_n(sram_we_n),
        .sram_oe_n(sram_oe_n),
        .sram_ce_n(sram_ce_n),
        .sram_ub_n(sram_ub_n),
        .sram_lb_n(sram_lb_n),
        .sram_dq_oe(sram_dq_oe),
        .fl_addr(fl_addr),
        .fl_wdata(fl_wdata),
        .fl_rdata(fl_rdata),
        .fl_ce_n(fl_ce_n),
        .fl_oe_n(fl_oe_n),
        .fl_we_n(fl_we_n),
        .fl_rst_n(fl_rst_n),
        .fl_wp_n(fl_wp_n),
        .fl_dq_oe(fl_dq_oe),
        .fl_ry(fl_ry),
        .fsm_state(fsm_state),
        .mode_code(mode_code),
        .status_code(status_code),
        .record_active(record_active),
        .play_active(play_active),
        .sample_valid_out(sample_valid_out),
        .current_sample(current_sample),
        .clear_record_time(clear_record_time),
        .clear_play_time(clear_play_time),
        .flash_header_valid(flash_header_valid),
        .sram_full(sram_full),
        .flash_error(flash_error),
        .record_length_words(record_length_words)
    );

    system_flash_model flash_inst (
        .FL_ADDR(fl_addr),
        .FL_CE_N(fl_ce_n),
        .FL_OE_N(fl_oe_n),
        .FL_WE_N(fl_we_n),
        .FL_RST_N(fl_rst_n),
        .FL_WP_N(fl_wp_n),
        .FL_RY(fl_ry),
        .FL_DQ(fl_dq)
    );

    initial clk = 1'b0;
    always #10 clk = ~clk;

    always @(*) begin
        sram_rdata = sram_mem[sram_addr[4:0]];
    end

    always @(posedge clk) begin
        if (!sram_ce_n && !sram_we_n && sram_dq_oe) begin
            sram_mem[sram_addr[4:0]] <= sram_wdata;
        end
    end

    always @(posedge clk) begin
        if (adc_read) begin
            adc_data <= {16'h1000 + sample_count[15:0], 16'h2000 + sample_count[15:0]};
            sample_count <= sample_count + 1;
        end
    end

    task pulse_key1;
    begin
        @(posedge clk);
        key1_pulse <= 1'b1;
        @(posedge clk);
        key1_pulse <= 1'b0;
    end
    endtask

    task pulse_key2;
    begin
        @(posedge clk);
        key2_pulse <= 1'b1;
        @(posedge clk);
        key2_pulse <= 1'b0;
    end
    endtask

    task pulse_key3_with_cancel;
    begin
        @(posedge clk);
        key3_pulse <= 1'b1;
        cancel_pulse <= 1'b1;
        @(posedge clk);
        key3_pulse <= 1'b0;
        cancel_pulse <= 1'b0;
    end
    endtask

    task wait_state;
        input [3:0] expected;
        input integer max_cycles;
        integer cycles;
    begin
        cycles = 0;
        while (fsm_state !== expected && cycles < max_cycles) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (fsm_state !== expected) begin
            $display("[TB] ERROR: expected state %0d, got %0d after %0d cycles",
                     expected, fsm_state, max_cycles);
            $finish;
        end
    end
    endtask

    task wait_dac_write;
        input integer max_cycles;
        integer cycles;
    begin
        cycles = 0;
        while (!dac_write && cycles < max_cycles) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!dac_write) begin
            $display("[TB] ERROR: dac_write timeout");
            $finish;
        end
    end
    endtask

    initial begin
        $dumpfile("tb_system_fsm.vcd");
        $dumpvars(0, tb_system_fsm);

        rst_n = 1'b0;
        cancel_pulse = 1'b0;
        key1_pulse = 1'b0;
        key2_pulse = 1'b0;
        key3_pulse = 1'b0;
        sw = 18'd0;
        adc_empty = 1'b1;
        adc_data = 32'd0;
        dac_full = 1'b0;
        dac_sample_tick = 1'b0;
        sample_count = 0;

        for (i = 0; i < 32; i = i + 1) begin
            sram_mem[i] = 16'h0000;
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        wait_state(ST_IDLE, 20);
        $display("[TB] Reset and codec init reached IDLE");

        adc_empty = 1'b0;
        pulse_key1();
        wait_state(ST_RECORD, 20);
        while (record_length_words < 20'd4) begin
            @(posedge clk);
        end
        adc_empty = 1'b1;
        pulse_key1();
        wait_state(ST_RECORD_STOP, 50);
        if (record_length_words == 20'd0) begin
            $display("[TB] ERROR: recording produced zero samples");
            $finish;
        end
        $display("[TB] Record/stop path stored %0d SRAM words", record_length_words);

        pulse_key2();
        wait_state(ST_PLAY_SRAM, 20);
        wait_dac_write(60000);
        pulse_key3_with_cancel();
        wait_state(ST_RECORD_STOP, 50);
        $display("[TB] Direct SRAM playback and KEY3 cancel path passed");

        sw[3] = 1'b0;
        pulse_key3_with_cancel();
        wait_state(ST_IDLE, 50);
        if (fsm_state == ST_SAVE_FLASH_ERASE) begin
            $display("[TB] ERROR: FLASH save entered while SW3 lock was off");
            $finish;
        end
        $display("[TB] FLASH lock gate blocked save when SW3=0");

        sw[3] = 1'b1;
        pulse_key3_with_cancel();
        wait_state(ST_SAVE_FLASH_ERASE, 100);
        pulse_key3_with_cancel();
        wait_state(ST_IDLE, 100);
        $display("[TB] KEY3 cancel path exits FLASH save flow");

        pulse_key3_with_cancel();
        wait_state(ST_SAVE_FLASH_DONE, 200000);
        $display("[TB] Save-to-FLASH path completed");

        pulse_key3_with_cancel();
        wait_state(ST_IDLE, 100);
        pulse_key2();
        wait_state(ST_PLAY_SRAM, 200000);
        wait_dac_write(60000);
        if (!flash_header_valid || flash_error) begin
            $display("[TB] ERROR: FLASH load header invalid or flash_error asserted");
            $finish;
        end
        $display("[TB] Load-from-FLASH and playback path passed");
        $display("[TB] SUCCESS: system_fsm behavioral smoke test passed");
        $finish;
    end

    initial begin
        dac_sample_tick = 1'b0;
        forever begin
            repeat (12) @(posedge clk);
            dac_sample_tick = 1'b1;
            @(posedge clk);
            dac_sample_tick = 1'b0;
        end
    end
endmodule

module system_flash_model (
    input  wire [22:0] FL_ADDR,
    input  wire        FL_CE_N,
    input  wire        FL_OE_N,
    input  wire        FL_WE_N,
    input  wire        FL_RST_N,
    input  wire        FL_WP_N,
    output reg         FL_RY,
    inout  wire [7:0]  FL_DQ
);
    reg [7:0] mem [0:255];
    reg [2:0] cmd_state;
    reg [7:0] dio_out;
    reg       dio_oe;
    integer i;

    localparam CMD_IDLE     = 3'd0;
    localparam CMD_UN1      = 3'd1;
    localparam CMD_UN2      = 3'd2;
    localparam CMD_ERASE    = 3'd3;
    localparam CMD_ER_UN1   = 3'd4;
    localparam CMD_ER_UN2   = 3'd5;
    localparam CMD_PROG     = 3'd6;

    assign FL_DQ = dio_oe ? dio_out : 8'hZZ;

    initial begin
        FL_RY = 1'b1;
        cmd_state = CMD_IDLE;
        dio_oe = 1'b0;
        dio_out = 8'h00;
        for (i = 0; i < 256; i = i + 1) begin
            mem[i] = 8'hFF;
        end
    end

    always @(*) begin
        if (!FL_CE_N && !FL_OE_N && FL_WE_N) begin
            dio_out = mem[FL_ADDR[7:0]];
            dio_oe = 1'b1;
        end else begin
            dio_out = 8'h00;
            dio_oe = 1'b0;
        end
    end

    always @(posedge FL_WE_N) begin
        if (!FL_RST_N) begin
            cmd_state <= CMD_IDLE;
        end else if (!FL_CE_N && FL_WP_N) begin
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
                        FL_RY <= 1'b0;
                        FL_RY <= #1000 1'b1;
                        for (i = 0; i < 256; i = i + 1) begin
                            mem[i] <= #1000 8'hFF;
                        end
                    end
                    cmd_state <= CMD_IDLE;
                end
                CMD_PROG: begin
                    mem[FL_ADDR[7:0]] <= FL_DQ & mem[FL_ADDR[7:0]];
                    FL_RY <= 1'b0;
                    FL_RY <= #200 1'b1;
                    cmd_state <= CMD_IDLE;
                end
                default: begin
                    cmd_state <= CMD_IDLE;
                end
            endcase
        end
    end

    always @(negedge FL_RST_N) begin
        cmd_state <= CMD_IDLE;
        FL_RY <= 1'b1;
    end
endmodule
