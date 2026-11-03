// Reference for FMRadio.pilot_pll |> stereo_tap |> stereo_out: the stereo end of fm_stereo.v
// (stereo_pll -> fir_dec x 2 -> stereo_out, blend 256, de-emphasis on) over the MPX samples
// of in.hex, one every 60 clocks (fir_dec: 224 taps every 5th sample; stereo_pll: >= 10);
// prints each output frame as {R, L} hex and each pilot window as "P <pilot_q><pilot_i> <seq>".
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg x_valid = 0;
    reg signed [17:0] x = 0;
    wire m_valid;
    wire signed [17:0] xm;
    wire signed [19:0] m;
    wire signed [15:0] pi, pq;
    wire [7:0] pseq;
    stereo_pll pll (.clk(clk), .x_valid(x_valid), .x(x), .m_valid(m_valid), .x_out(xm), .m(m),
        .pilot_i(pi), .pilot_q(pq), .pilot_seq(pseq));
    wire s_valid, d_valid;
    wire signed [21:0] s, d;
    fir_dec #(.TAPS(224), .DEC(5), .PHASE(4), .IW(18), .OW(22), .SH(17), .SAT(0), .AW(8), .TABLE(2))
        fs (.clk(clk), .in_valid(m_valid), .in(xm), .out_valid(s_valid), .out(s));
    fir_dec #(.TAPS(224), .DEC(5), .PHASE(4), .IW(20), .OW(22), .SH(17), .SAT(0), .AW(8), .TABLE(2))
        fd (.clk(clk), .in_valid(m_valid), .in(m), .out_valid(d_valid), .out(d));
    wire out_valid;
    wire signed [15:0] left, right;
    stereo_out so (.clk(clk), .deemph(1'b1), .g(9'd256), .in_valid(s_valid), .s(s), .d(d),
        .out_valid(out_valid), .left(left), .right(right));
    always @(posedge clk) if (out_valid) $display("%04x%04x", right, left);
    reg [7:0] pseq_d = 0;
    always @(posedge clk) begin
        pseq_d <= pseq;
        if (pseq != pseq_d) $display("P %04x%04x %02x", pq, pi, pseq);
    end
    reg [17:0] mem [0:262143];
    integer n, i;
    initial $readmemh("in.hex", mem);
    initial begin
        if (!$value$plusargs("N=%d", n)) n = 1000;
        repeat (4) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk) begin x = mem[i]; x_valid = 1; end
            @(negedge clk) x_valid = 0;
            repeat (58) @(negedge clk);
        end
        repeat (600) @(posedge clk);
        $finish;
    end
endmodule
