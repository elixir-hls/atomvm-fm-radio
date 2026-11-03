// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// stereo_out.v — L+R / L-R (48 kHz) to L / R: DC block, blend, matrix, de-emphasis.
// Same arithmetic and order as eval/stereo_model.py `decode` (48 kHz part):
//   dc += (s - dc + 2^(DC_SH-1)) >>> DC_SH;  s' = s - dc          (rounded: no DC left over)
//   dg = (d * g) >>> 8                        g = 0 (mono) .. 256 (full stereo)
//   L = s' + dg,  R = s' - dg
//   de-emphasis (deemph = 1): y += ((v << 8) - y) * 87 >>> 8 per channel (50 us at 48 kHz),
//   out = y >>> 8;  saturated to 16 bit
module stereo_out (
    input  wire               clk,
    input  wire               deemph,
    input  wire [8:0]         g,
    input  wire               in_valid,
    input  wire signed [21:0] s,
    input  wire signed [21:0] d,
    output reg                out_valid = 1'b0,
    output reg  signed [15:0] left = 0,
    output reg  signed [15:0] right = 0
);
    localparam DC_SH = 10;
    localparam signed [8:0] DEEMPH = 9'sd87;

    reg signed [21:0] dc = 0, sv = 0, dv = 0, sp = 0;
    reg signed [31:0] dg = 0;
    reg signed [23:0] l = 0, r = 0;
    reg signed [39:0] yl = 0, yr = 0;
    reg [3:0] v = 0;

    function signed [15:0] sat16(input signed [39:0] x);
        sat16 = (x > 40'sd32767) ? 16'sd32767 : (x < -40'sd32768) ? -16'sd32768 : x[15:0];
    endfunction

    wire signed [21:0] dc_new = dc + ((sv - dc + (1 <<< (DC_SH - 1))) >>> DC_SH);
    wire signed [39:0] l40 = l, r40 = r;
    wire signed [39:0] dl = (l40 <<< 8) - yl;
    wire signed [39:0] dr = (r40 <<< 8) - yr;
    wire signed [39:0] yl_new = yl + ((dl * DEEMPH) >>> 8);
    wire signed [39:0] yr_new = yr + ((dr * DEEMPH) >>> 8);

    always @(posedge clk) begin
        v <= {v[2:0], in_valid};
        out_valid <= 1'b0;
        if (in_valid) begin                  // 1: latch
            sv <= s;
            dv <= d;
        end
        if (v[0]) begin                      // 2: DC estimate, blend product
            dc <= dc_new;
            sp <= sv - dc_new;
            dg <= (dv * $signed({1'b0, g})) >>> 8;
        end
        if (v[1]) begin                      // 3: matrix
            l <= sp + dg;
            r <= sp - dg;
        end
        if (v[2]) begin                      // 4: de-emphasis, output
            if (deemph) begin
                yl    <= yl_new;
                yr    <= yr_new;
                left  <= sat16(yl_new >>> 8);
                right <= sat16(yr_new >>> 8);
            end else begin
                yl    <= l40 <<< 8;
                yr    <= r40 <<< 8;
                left  <= sat16(l40);
                right <= sat16(r40);
            end
            out_valid <= 1'b1;
        end
    end
endmodule
