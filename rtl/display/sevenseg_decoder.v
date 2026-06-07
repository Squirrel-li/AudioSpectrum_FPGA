//=============================================================================
// Module: sevenseg_decoder
// Description: BCD-to-7-segment decoder for DE2-115 (active-low outputs).
//              Supports hexadecimal digits 0-E, with 4'hF displaying blank.
//              Segment ordering: seg = {g, f, e, d, c, b, a}
// Target: Cyclone IV E (EP4CE115F29C7)
//=============================================================================

module sevenseg_decoder (
    input  wire [3:0] bcd,
    output reg  [6:0] seg   // active-low: seg = {g,f,e,d,c,b,a}
);

    always @(*) begin
        case (bcd)
            4'h0:    seg = 7'b1000000;  // 0
            4'h1:    seg = 7'b1111001;  // 1
            4'h2:    seg = 7'b0100100;  // 2
            4'h3:    seg = 7'b0110000;  // 3
            4'h4:    seg = 7'b0011001;  // 4
            4'h5:    seg = 7'b0010010;  // 5
            4'h6:    seg = 7'b0000010;  // 6
            4'h7:    seg = 7'b1111000;  // 7
            4'h8:    seg = 7'b0000000;  // 8
            4'h9:    seg = 7'b0010000;  // 9
            4'hA:    seg = 7'b0001000;  // A
            4'hB:    seg = 7'b0000011;  // b
            4'hC:    seg = 7'b1000110;  // C
            4'hD:    seg = 7'b0100001;  // d
            4'hE:    seg = 7'b0000110;  // E
            4'hF:    seg = 7'b1111111;  // blank
            default: seg = 7'b1111111;  // blank
        endcase
    end

endmodule
