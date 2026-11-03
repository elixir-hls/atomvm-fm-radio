// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// fm_stereo.v — FM stereo decoder, IQ 960 kS/s in, L / R 48 kHz out (docs/design.md §10).
//
//   chan_fir (channel filter, 31 taps, 120 kHz; chan_en = 0 bypasses it)
//   -> fm_disc (CORDIC phase difference, 75 kHz = 5120)
//   -> FIR1 32 taps, /4 -> MPX x 240 kS/s (75 kHz = 20480)
//   -> stereo_pll (pilot PLL, L-R m = x * sin(2 theta), pilot measurement)
//   -> FIR2 224 taps, /5, on x (L+R) and on m (L-R) -> 48 kHz
//   -> stereo_out (DC block, blend g, matrix, de-emphasis) -> left / right
// Bit-exact model: eval/stereo_model.py `decode` (checked by sim/run_fm_stereo.py).
// Input rate: iq_valid >= 26 clocks apart (iq_pair GAP 24); the FIRs and the PLL keep up
// with 960 kS/s on a 50 MHz clock (FIR2: 224 clocks per 5 MPX samples = 20 IQ samples).
module fm_stereo #(
    parameter WIN_SH = 14
) (
    input  wire               clk,
    input  wire               deemph,
    input  wire               chan_en,
    input  wire [8:0]         blend,          // 0 = mono .. 256 = full stereo
    input  wire               iq_valid,
    input  wire [15:0]        iq_word,
    output wire               audio_valid,
    output wire signed [15:0] left,
    output wire signed [15:0] right,
    output wire signed [15:0] pilot_i,
    output wire signed [15:0] pilot_q,
    output wire [7:0]         pilot_seq,
    // bring-up: the latest value at each stage
    output reg  signed [15:0] dbg_d = 0,
    output reg  signed [17:0] dbg_x = 0,
    output reg  signed [21:0] dbg_s = 0
);
    wire        c_valid;
    wire [15:0] c_word;
    chan_fir chan (.clk(clk), .en(chan_en), .in_valid(iq_valid), .in_word(iq_word),
        .out_valid(c_valid), .out_word(c_word));

    wire               d_valid;
    wire signed [15:0] d;
    fm_disc disc (.clk(clk), .iq_valid(c_valid), .iq_word(c_word), .d_valid(d_valid), .d(d));

    wire               x_valid;
    wire signed [17:0] x;
    fir_dec #(.TAPS(32), .DEC(4), .PHASE(3), .IW(16), .OW(18), .SH(15), .SAT(1), .AW(6),
              .TABLE(1))
        fir1 (.clk(clk), .in_valid(d_valid), .in(d), .out_valid(x_valid), .out(x));

    wire               m_valid;
    wire signed [17:0] xm;
    wire signed [19:0] m;
    stereo_pll #(.WIN_SH(WIN_SH))
        pll (.clk(clk), .x_valid(x_valid), .x(x), .m_valid(m_valid), .x_out(xm), .m(m),
             .pilot_i(pilot_i), .pilot_q(pilot_q), .pilot_seq(pilot_seq));

    wire               s_valid, dd_valid;
    wire signed [21:0] s, dd;
    fir_dec #(.TAPS(224), .DEC(5), .PHASE(4), .IW(18), .OW(22), .SH(17), .SAT(0), .AW(8),
              .TABLE(2))
        fir2s (.clk(clk), .in_valid(m_valid), .in(xm), .out_valid(s_valid), .out(s));
    fir_dec #(.TAPS(224), .DEC(5), .PHASE(4), .IW(20), .OW(22), .SH(17), .SAT(0), .AW(8),
              .TABLE(2))
        fir2d (.clk(clk), .in_valid(m_valid), .in(m), .out_valid(dd_valid), .out(dd));

    always @(posedge clk) begin
        if (d_valid) dbg_d <= d;
        if (x_valid) dbg_x <= x;
        if (s_valid) dbg_s <= s;
    end

    stereo_out out (.clk(clk), .deemph(deemph), .g(blend), .in_valid(s_valid), .s(s), .d(dd),
        .out_valid(audio_valid), .left(left), .right(right));
endmodule
