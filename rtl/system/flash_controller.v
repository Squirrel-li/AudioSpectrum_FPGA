// ============================================================================
// Low-Level FLASH Memory Controller for DE2-115
// Handles Sector Erase, Byte Program, and Byte Read CFI commands
// with proper setup, write-pulse, and hold timings for 50MHz (20ns clock).
// ============================================================================
module flash_controller (
    input  wire        clk,
    input  wire        rst_n,
    
    // Command interface
    input  wire        cmd_erase,      // Start sector erase pulse
    input  wire        cmd_write,      // Start program byte pulse
    input  wire        cmd_read,       // Start read byte pulse
    input  wire [22:0] cmd_addr,       // Flash byte address
    input  wire [7:0]  cmd_wdata,      // Byte data to program
    
    output reg         cmd_done,       // Pulse when current operation is done
    output reg  [7:0]  cmd_rdata,      // Read byte data (valid when cmd_done is high after cmd_read)
    output reg         busy,           // Controller is busy
    
    // Hardware pins to FLASH chip
    output reg  [22:0] FL_ADDR,
    output reg         FL_CE_N,
    output reg         FL_OE_N,
    output reg         FL_WE_N,
    output reg         FL_RST_N,
    output reg         FL_WP_N,
    input  wire        FL_RY,
    output wire        fl_dq_oe,       // Drive enable (1=output, 0=tri-state/input)
    output wire [7:0]  fl_dq_out,      // Data to output
    input  wire [7:0]  fl_dq_in        // Data read in
);

    // Controller states
    localparam ST_CTRL_IDLE       = 3'd0;
    localparam ST_CTRL_ERASE      = 3'd1;
    localparam ST_CTRL_WRITE      = 3'd2;
    localparam ST_CTRL_READ       = 3'd3;
    localparam ST_CTRL_READ_WAIT  = 3'd4;

    // Command unlock addresses (byte addresses)
    localparam FLASH_UNLOCK1_ADDR = 23'hAAA;
    localparam FLASH_UNLOCK2_ADDR = 23'h555;

    // Internal registers
    reg [2:0] state;
    reg [15:0] counter;         // Timing counter for wait loops
    reg [2:0] write_step;      // Step inside program/erase sequences (0~5)
    reg [2:0] write_timer;     // Write setup/pulse/hold timer (0~7, 160ns total)
    reg       fl_dq_oe_reg;    // Output enable register
    reg [7:0] fl_dq_reg;       // Data to drive onto FL_DQ

    // Map control signals to output ports
    assign fl_dq_oe  = fl_dq_oe_reg;
    assign fl_dq_out = fl_dq_reg;
    wire [7:0] fl_rdata = fl_dq_in;

    // Low-level command sequence decoder
    reg [22:0] cur_write_addr;
    reg [7:0]  cur_write_data;
    always @(*) begin
        cur_write_addr = 23'd0;
        cur_write_data = 8'd0;
        if (state == ST_CTRL_ERASE) begin
            case (write_step)
                3'd0: begin cur_write_addr = FLASH_UNLOCK1_ADDR; cur_write_data = 8'hAA; end
                3'd1: begin cur_write_addr = FLASH_UNLOCK2_ADDR; cur_write_data = 8'h55; end
                3'd2: begin cur_write_addr = FLASH_UNLOCK1_ADDR; cur_write_data = 8'h80; end
                3'd3: begin cur_write_addr = FLASH_UNLOCK1_ADDR; cur_write_data = 8'hAA; end
                3'd4: begin cur_write_addr = FLASH_UNLOCK2_ADDR; cur_write_data = 8'h55; end
                3'd5: begin cur_write_addr = cmd_addr;           cur_write_data = 8'h30; end
                default: begin cur_write_addr = 23'd0; cur_write_data = 8'd0; end
            endcase
        end else if (state == ST_CTRL_WRITE) begin
            case (write_step)
                3'd0: begin cur_write_addr = FLASH_UNLOCK1_ADDR; cur_write_data = 8'hAA; end
                3'd1: begin cur_write_addr = FLASH_UNLOCK2_ADDR; cur_write_data = 8'h55; end
                3'd2: begin cur_write_addr = FLASH_UNLOCK1_ADDR; cur_write_data = 8'hA0; end
                3'd3: begin cur_write_addr = cmd_addr;           cur_write_data = cmd_wdata; end
                default: begin cur_write_addr = 23'd0; cur_write_data = 8'd0; end
            endcase
        end
    end

    // Sequential timing and state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_CTRL_IDLE;
            counter      <= 16'd0;
            cmd_done     <= 1'b0;
            cmd_rdata    <= 8'd0;
            busy         <= 1'b0;
            
            FL_ADDR      <= 23'd0;
            fl_dq_reg    <= 8'd0;
            FL_CE_N      <= 1'b1;
            FL_OE_N      <= 1'b1;
            FL_WE_N      <= 1'b1;
            FL_RST_N     <= 1'b1;
            FL_WP_N      <= 1'b1;
            fl_dq_oe_reg <= 1'b0;
            write_step   <= 3'd0;
            write_timer  <= 3'd0;
        end else begin
            cmd_done <= 1'b0; // default single cycle pulse
            
            case (state)
                ST_CTRL_IDLE: begin
                    FL_CE_N      <= 1'b1;
                    FL_OE_N      <= 1'b1;
                    FL_WE_N      <= 1'b1;
                    fl_dq_oe_reg <= 1'b0;
                    FL_WP_N      <= 1'b1;
                    FL_RST_N     <= 1'b1;
                    busy         <= 1'b0;
                    
                    if (cmd_erase) begin
                        state       <= ST_CTRL_ERASE;
                        write_step  <= 3'd0;
                        write_timer <= 3'd0;
                        counter     <= 16'd0;
                        busy        <= 1'b1;
                    end else if (cmd_write) begin
                        state       <= ST_CTRL_WRITE;
                        write_step  <= 3'd0;
                        write_timer <= 3'd0;
                        counter     <= 16'd0;
                        busy        <= 1'b1;
                    end else if (cmd_read) begin
                        state       <= ST_CTRL_READ;
                        counter     <= 16'd0;
                        busy        <= 1'b1;
                    end
                end
                
                ST_CTRL_ERASE: begin
                    if (write_step <= 3'd5) begin
                        FL_CE_N      <= 1'b0;
                        FL_OE_N      <= 1'b1;
                        fl_dq_oe_reg <= 1'b1;
                        FL_ADDR      <= cur_write_addr;
                        fl_dq_reg    <= cur_write_data;
                        
                        if (write_timer == 3'd0 || write_timer == 3'd1) begin
                            FL_WE_N <= 1'b1; // Setup
                        end else if (write_timer >= 3'd2 && write_timer <= 3'd4) begin
                            FL_WE_N <= 1'b0; // Write pulse (60ns)
                        end else begin
                            FL_WE_N <= 1'b1; // Hold
                        end
                        
                        if (write_timer == 3'd7) begin
                            write_timer <= 3'd0;
                            write_step  <= write_step + 3'd1;
                        end else begin
                            write_timer <= write_timer + 3'd1;
                        end
                    end else begin
                        // Step 6: wait for erase complete
                        FL_CE_N      <= 1'b0;
                        FL_OE_N      <= 1'b1;
                        FL_WE_N      <= 1'b1;
                        fl_dq_oe_reg <= 1'b0;
                        counter      <= counter + 16'd1;
                        if (counter >= 16'd1000) begin // Wait 20us to ensure FL_RY has gone low
                            if (FL_RY) begin
                                FL_CE_N    <= 1'b1;
                                cmd_done   <= 1'b1;
                                state      <= ST_CTRL_IDLE;
                            end
                        end
                    end
                end
                
                ST_CTRL_WRITE: begin
                    if (write_step <= 3'd3) begin
                        FL_CE_N      <= 1'b0;
                        FL_OE_N      <= 1'b1;
                        fl_dq_oe_reg <= 1'b1;
                        FL_ADDR      <= cur_write_addr;
                        fl_dq_reg    <= cur_write_data;
                        
                        if (write_timer == 3'd0 || write_timer == 3'd1) begin
                            FL_WE_N <= 1'b1; // Setup
                        end else if (write_timer >= 3'd2 && write_timer <= 3'd4) begin
                            FL_WE_N <= 1'b0; // Write pulse (60ns)
                        end else begin
                            FL_WE_N <= 1'b1; // Hold
                        end
                        
                        if (write_timer == 3'd7) begin
                            write_timer <= 3'd0;
                            write_step  <= write_step + 3'd1;
                        end else begin
                            write_timer <= write_timer + 3'd1;
                        end
                    end else begin
                        // Step 4: wait for program complete
                        FL_CE_N      <= 1'b0;
                        FL_OE_N      <= 1'b1;
                        FL_WE_N      <= 1'b1;
                        fl_dq_oe_reg <= 1'b0;
                        counter      <= counter + 16'd1;
                        if (counter >= 16'd500) begin // Wait 10us to ensure FL_RY has gone low
                            if (FL_RY) begin
                                FL_CE_N    <= 1'b1;
                                cmd_done   <= 1'b1;
                                state      <= ST_CTRL_IDLE;
                            end
                        end
                    end
                end
                
                ST_CTRL_READ: begin
                    FL_CE_N      <= 1'b0;
                    FL_OE_N      <= 1'b0;
                    FL_WE_N      <= 1'b1;
                    fl_dq_oe_reg <= 1'b0;
                    FL_ADDR      <= cmd_addr;
                    counter      <= counter + 16'd1;
                    state        <= ST_CTRL_READ_WAIT;
                end
                
                ST_CTRL_READ_WAIT: begin
                    counter <= counter + 16'd1;
                    if (counter >= 16'd7) begin // Wait 7 cycles (140ns) for 90ns access time
                        cmd_rdata <= fl_rdata;
                        FL_CE_N   <= 1'b1;
                        FL_OE_N   <= 1'b1;
                        cmd_done  <= 1'b1;
                        state     <= ST_CTRL_IDLE;
                    end
                end
                
                default: begin
                    state <= ST_CTRL_IDLE;
                end
            endcase
        end
    end

endmodule
