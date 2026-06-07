//============================================================================
// Module:      one_pulse
// Description: Rising-edge detector that converts a level signal into a
//              single clock-cycle pulse. Used after key_debounce to generate
//              one-shot button press events.
// Target:      Cyclone IV E (EP4CE115F29C7)
// Tool:        Quartus II 13.1
//============================================================================

module one_pulse (
    input  wire clk,
    input  wire rst_n,
    input  wire trigger,   // level input (active-high)
    output reg  pulse      // single clock-cycle pulse on rising edge of trigger
);

    reg trigger_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trigger_d <= 1'b0;
            pulse     <= 1'b0;
        end else begin
            trigger_d <= trigger;
            pulse     <= trigger & ~trigger_d;
        end
    end

endmodule
