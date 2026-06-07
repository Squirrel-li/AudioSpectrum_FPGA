`timescale 1ns/1ps

module tb_hex_status_timer_display;
    reg  [7:0] mode_code_bcd;
    reg  [7:0] status_code_bcd;
    reg  [6:0] time_seconds;
    reg  [1:0] flash_slot;
    reg        sw_input_source;
    wire [6:0] HEX0;
    wire [6:0] HEX1;
    wire [6:0] HEX2;
    wire [6:0] HEX3;
    wire [6:0] HEX4;
    wire [6:0] HEX5;
    wire [6:0] HEX6;
    wire [6:0] HEX7;

    hex_status_timer_display dut (
        .mode_code_bcd(mode_code_bcd),
        .status_code_bcd(status_code_bcd),
        .time_seconds(time_seconds),
        .flash_slot(flash_slot),
        .sw_input_source(sw_input_source),
        .HEX0(HEX0),
        .HEX1(HEX1),
        .HEX2(HEX2),
        .HEX3(HEX3),
        .HEX4(HEX4),
        .HEX5(HEX5),
        .HEX6(HEX6),
        .HEX7(HEX7)
    );

    task expect_seg;
        input [6:0] actual;
        input [6:0] expected;
        input [8*12:1] name;
    begin
        if (actual !== expected) begin
            $display("[TB] ERROR: %0s expected %b got %b", name, expected, actual);
            $finish;
        end
    end
    endtask

    initial begin
        mode_code_bcd = 8'h12;
        status_code_bcd = 8'h34;
        time_seconds = 7'd59;
        sw_input_source = 1'b0;

        flash_slot = 2'd0;
        #1;
        expect_seg(HEX7, 7'b0100100, "HEX7 mode");   // 2
        expect_seg(HEX6, 7'b0011001, "HEX6 status"); // 4
        expect_seg(HEX5, 7'b0010010, "HEX5 S");      // 5 as S
        expect_seg(HEX4, 7'b1000000, "HEX4 slot0");  // 0
        expect_seg(HEX3, 7'b1000110, "HEX3 line");   // C
        expect_seg(HEX2, 7'b1111001, "HEX2 line");   // 1
        expect_seg(HEX1, 7'b0010010, "HEX1 tens");   // 5
        expect_seg(HEX0, 7'b0010000, "HEX0 ones");   // 9

        sw_input_source = 1'b1;
        flash_slot = 2'd3;
        #1;
        expect_seg(HEX4, 7'b0110000, "HEX4 slot3");  // 3
        expect_seg(HEX3, 7'b0000011, "HEX3 mic");    // b
        expect_seg(HEX2, 7'b0100100, "HEX2 mic");    // 2

        $display("[TB] SUCCESS: hex_status_timer_display slot/input mapping passed");
        $finish;
    end
endmodule
