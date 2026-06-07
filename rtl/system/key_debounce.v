//============================================================================
// Module:      key_debounce
// Description: Debounce module for DE2-115 push buttons.
//              Converts active-low raw key input to debounced active-high
//              output using a counter-based approach.
// Target:      Cyclone IV E (EP4CE115F29C7)
// Tool:        Quartus II 13.1
//============================================================================

module key_debounce #(
    parameter DEBOUNCE_CYCLES = 1_000_000  // 20ms @ 50MHz
)(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,    // raw key input, active-low (0 = pressed)
    output reg  key_out    // debounced output, active-high (1 = pressed)
);

    //------------------------------------------------------------------------
    // Counter width: 20 bits covers up to ~1M cycles
    //------------------------------------------------------------------------
    reg [19:0] cnt;
    wire       key_inv;

    // Invert active-low input to active-high
    assign key_inv = ~key_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 20'd0;
            key_out <= 1'b0;
        end else begin
            if (key_inv != key_out) begin
                // Input differs from current output — count up
                if (cnt == DEBOUNCE_CYCLES - 1) begin
                    key_out <= key_inv;
                    cnt     <= 20'd0;
                end else begin
                    cnt <= cnt + 20'd1;
                end
            end else begin
                // Input matches output — reset counter
                cnt <= 20'd0;
            end
        end
    end

endmodule
