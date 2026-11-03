// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// stereo_pll.v — 19 kHz pilot PLL and the 38 kHz L-R mixer, on the 240 kS/s MPX.
// Per MPX sample x (same arithmetic and order as eval/stereo_model.py `pll`):
//   idx = theta[31:22]; s1 = SIN[idx]; c1 = SIN[idx + 256]; s2 = SIN[theta[30:21]]   (Q15)
//   pd = x * c1                                       phase detector
//   m  = (x * s2) >>> 14                              L-R (subcarrier sin(2wt) for pilot sin(wt))
//   i_lp += ((x * s1) >>> 15 - i_lp + 2^(LP_SH-1)) >>> LP_SH     pilot in-phase (rounded LPF)
//   q_lp += (pd >>> 15 - q_lp + 2^(LP_SH-1)) >>> LP_SH          pilot quadrature
//   integ += pd >>> KI_SH;  theta += F0 + (pd >>> KP_SH) + integ
// Window of 2^WIN_SH samples: pilot_i = sum(i_lp) >>> WIN_SH, pilot_q = sum(q_lp) >>> WIN_SH,
// pilot_seq increments. Out: m_valid with x_out (the same x) and m, ~8 clocks after x_valid.
// The next x_valid must come >= 10 clocks later.
module stereo_pll #(
    parameter WIN_SH = 14
) (
    input  wire               clk,
    input  wire               x_valid,
    input  wire signed [17:0] x,
    output reg                m_valid = 1'b0,
    output reg  signed [17:0] x_out = 0,
    output reg  signed [19:0] m = 0,
    output reg  signed [15:0] pilot_i = 0,
    output reg  signed [15:0] pilot_q = 0,
    output reg  [7:0]         pilot_seq = 0
);
    localparam [31:0] F0 = 32'h14444444;      // 19 kHz / 240 kHz * 2^32
    localparam KP_SH = 6, KI_SH = 16, LP_SH = 8;

`include "fm_tables.vh"
    reg [9:0]  raddr = 0;
    reg signed [15:0] rq = 0;
    always @(posedge clk) rq <= sin_q15(raddr);

    reg [31:0] theta = 0;
    reg signed [31:0] integ = 0;
    reg signed [17:0] xv = 0;
    reg signed [15:0] s1 = 0, c1 = 0, s2 = 0;
    reg [3:0] st = 0;
    reg signed [33:0] pd = 0, ps = 0, pm = 0;
    reg signed [23:0] i_lp = 0, q_lp = 0;
    reg signed [39:0] si = 0, sq = 0;
    reg [WIN_SH-1:0]  n = 0;

    wire signed [23:0] ps_sh = ps >>> 15;
    wire signed [23:0] pd_sh = pd >>> 15;
    wire signed [23:0] i_new = i_lp + ((ps_sh - i_lp + (1 <<< (LP_SH - 1))) >>> LP_SH);
    wire signed [23:0] q_new = q_lp + ((pd_sh - q_lp + (1 <<< (LP_SH - 1))) >>> LP_SH);
    wire signed [31:0] integ_new = integ + (pd >>> KI_SH);
    wire signed [31:0] pd_kp = pd >>> KP_SH;      // signed shift here: theta is unsigned
    wire signed [39:0] si_new = si + i_new;
    wire signed [39:0] sq_new = sq + q_new;
    wire signed [39:0] si_w = si_new >>> WIN_SH;
    wire signed [39:0] sq_w = sq_new >>> WIN_SH;

    function signed [15:0] sat16(input signed [39:0] v);
        sat16 = (v > 40'sd32767) ? 16'sd32767 : (v < -40'sd32768) ? -16'sd32768 : v[15:0];
    endfunction

    always @(posedge clk) begin
        m_valid <= 1'b0;
        case (st)
        4'd0: if (x_valid) begin
            xv    <= x;
            raddr <= theta[31:22];
            st    <= 4'd1;
        end
        4'd1: begin raddr <= theta[31:22] + 10'd256; st <= 4'd2; end   // rq = s1 next cycle
        4'd2: begin s1 <= rq; raddr <= theta[30:21]; st <= 4'd3; end
        4'd3: begin c1 <= rq; st <= 4'd4; end
        4'd4: begin s2 <= rq; st <= 4'd5; end
        4'd5: begin
            pd <= xv * c1;
            ps <= xv * s1;
            pm <= xv * s2;
            st <= 4'd6;
        end
        4'd6: begin
            m       <= pm >>> 14;
            x_out   <= xv;
            m_valid <= 1'b1;
            i_lp    <= i_new;
            q_lp    <= q_new;
            integ   <= integ_new;
            theta   <= theta + F0 + pd_kp + integ_new;
            n       <= n + 1'b1;
            if (&n) begin
                pilot_i   <= sat16(si_w);
                pilot_q   <= sat16(sq_w);
                pilot_seq <= pilot_seq + 8'd1;
                si <= 0;
                sq <= 0;
            end else begin
                si <= si_new;
                sq <= sq_new;
            end
            st <= 4'd0;
        end
        default: st <= 4'd0;
        endcase
    end
endmodule
