//=============================================================================
// Module: hex_status_timer_display
// Description: Controls 8 seven-segment displays:
//              HEX7 = MODE ones digit
//              HEX6 = STATUS ones digit
//              HEX5-HEX4 = FLASH slot as "S0".."S3" ("5" represents S)
//              HEX3-HEX2 = input source, C1 for line-in and b2 for mic-in
//              HEX1-HEX0 = TIME seconds (0-59, converted to 2-digit BCD)
//              Purely combinational — no clock required.
// Target: Cyclone IV E (EP4CE115F29C7)
//=============================================================================

module hex_status_timer_display (
    input  wire [7:0]  mode_code_bcd,    // 2-digit BCD: [7:4]=tens, [3:0]=ones
    input  wire [7:0]  status_code_bcd,  // 2-digit BCD: [7:4]=tens, [3:0]=ones
    input  wire [6:0]  time_seconds,     // 0~59 integer
    input  wire [1:0]  flash_slot,       // FLASH slot selected by SW[11:10]
    input  wire        sw_input_source,  // 0 = Line In, 1 = Mic In
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3,
    output wire [6:0]  HEX4, HEX5, HEX6, HEX7
);

    //=========================================================================
    // Time seconds to BCD conversion (combinational)
    //=========================================================================
    wire [6:0] time_sat;
    assign time_sat = (time_seconds > 7'd59) ? 7'd59 : time_seconds;

    wire [3:0] time_tens;
    wire [3:0] time_ones;
    assign time_tens = time_sat / 10;
    assign time_ones = time_sat % 10;

    //=========================================================================
    // BCD digit assignment for each HEX display
    //=========================================================================
    wire [3:0] dig7, dig6, dig5, dig4, dig3, dig2, dig1, dig0;

    assign dig7 = mode_code_bcd[3:0];    // Mode ones
    assign dig6 = status_code_bcd[3:0];  // Status ones
    assign dig5 = 4'h5;                  // Visual "S" for slot
    assign dig4 = {2'b00, flash_slot};   // Slot 0~3
    assign dig3 = sw_input_source ? 4'hb : 4'hC; // 'b' for Mic board, 'C' for Line Cable
    assign dig2 = sw_input_source ? 4'h2 : 4'h1; // '2' for Mic, '1' for Line
    assign dig1 = time_tens;             // Time tens
    assign dig0 = time_ones;             // Time ones

    //=========================================================================
    // Seven-segment decoder instances
    //=========================================================================
    sevenseg_decoder u_hex0 (
        .bcd (dig0),
        .seg (HEX0)
    );

    sevenseg_decoder u_hex1 (
        .bcd (dig1),
        .seg (HEX1)
    );

    sevenseg_decoder u_hex2 (
        .bcd (dig2),
        .seg (HEX2)
    );

    sevenseg_decoder u_hex3 (
        .bcd (dig3),
        .seg (HEX3)
    );

    sevenseg_decoder u_hex4 (
        .bcd (dig4),
        .seg (HEX4)
    );

    sevenseg_decoder u_hex5 (
        .bcd (dig5),
        .seg (HEX5)
    );

    sevenseg_decoder u_hex6 (
        .bcd (dig6),
        .seg (HEX6)
    );

    sevenseg_decoder u_hex7 (
        .bcd (dig7),
        .seg (HEX7)
    );

endmodule
