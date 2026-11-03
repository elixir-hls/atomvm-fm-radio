// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// fm_disc.v — FM discriminator: phase of each IQ sample (CORDIC) and the difference to the
// previous one (instantaneous frequency). Factored out of fm_demod.v, same arithmetic.
//
//   phase[n] = atan2(Q, I)       CORDIC, vectoring mode, 15 iterations, 2^16 units per turn
//   d[n]     = phase[n] - phase[n-1]   (16-bit wrap = the difference taken mod 2*pi)
// Scale: d * fs / 65536 Hz (at 960 kS/s, 75 kHz = 5120). One sample takes ~18 clocks; the
// next iq_valid must come >= 20 clocks later. Model: eval/fm_model.py cordic_phase.
module fm_disc (
    input  wire        clk,
    input  wire        iq_valid,          // one-cycle pulse, >= 20 clocks apart
    input  wire [15:0] iq_word,           // {I, Q}, uint8 offset binary (rtl_sdr order)
    output reg         d_valid = 1'b0,
    output reg  signed [15:0] d = 16'sd0
);
    localparam XW = 21;                   // CORDIC x/y: 8-bit input << 9, growth 1.65 * sqrt(2)

    function [15:0] atan_tab(input [3:0] i);
        case (i)
            4'd0: atan_tab = 16'd8192;  4'd1: atan_tab = 16'd4836;  4'd2: atan_tab = 16'd2555;
            4'd3: atan_tab = 16'd1297;  4'd4: atan_tab = 16'd651;   4'd5: atan_tab = 16'd326;
            4'd6: atan_tab = 16'd163;   4'd7: atan_tab = 16'd81;    4'd8: atan_tab = 16'd41;
            4'd9: atan_tab = 16'd20;    4'd10: atan_tab = 16'd10;   4'd11: atan_tab = 16'd5;
            4'd12: atan_tab = 16'd3;    4'd13: atan_tab = 16'd1;    4'd14: atan_tab = 16'd1;
            default: atan_tab = 16'd0;
        endcase
    endfunction

    // ---- CORDIC: atan2(Q, I) ----
    wire signed [8:0] i_in = $signed({1'b0, iq_word[15:8]}) - 9'sd128;
    wire signed [8:0] q_in = $signed({1'b0, iq_word[7:0]})  - 9'sd128;
    reg signed [XW-1:0] x = 0, y = 0;
    reg [15:0] z = 16'd0;
    reg [3:0]  it = 4'd0;
    reg        busy = 1'b0;
    reg        ph_valid = 1'b0;
    reg [15:0] ph_prev = 16'd0;
    always @(posedge clk) begin
        ph_valid <= 1'b0;
        if (iq_valid) begin
            // pre-rotation into the right half plane (x >= 0)
            if (i_in < 0) begin
                x <= -($signed({{(XW-9){i_in[8]}}, i_in}) <<< 9);
                y <= -($signed({{(XW-9){q_in[8]}}, q_in}) <<< 9);
                z <= 16'h8000;
            end else begin
                x <= $signed({{(XW-9){i_in[8]}}, i_in}) <<< 9;
                y <= $signed({{(XW-9){q_in[8]}}, q_in}) <<< 9;
                z <= 16'h0000;
            end
            it   <= 4'd0;
            busy <= 1'b1;
        end else if (busy) begin
            if (y >= 0) begin
                x <= x + (y >>> it);
                y <= y - (x >>> it);
                z <= z + atan_tab(it);
            end else begin
                x <= x - (y >>> it);
                y <= y + (x >>> it);
                z <= z - atan_tab(it);
            end
            it <= it + 4'd1;
            if (it == 4'd14) begin
                busy     <= 1'b0;
                ph_valid <= 1'b1;            // z holds the phase in the next cycle
            end
        end
        if (ph_valid) begin
            d       <= $signed(z - ph_prev);
            ph_prev <= z;
        end
    end
    always @(posedge clk) d_valid <= ph_valid;
endmodule
