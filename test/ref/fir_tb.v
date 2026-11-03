// Reference for FMRadio.mpx_fir / audio_fir: fir_dec.v over the samples of in.hex, one every
// 300 clocks (a sum of 224 taps takes 228); prints each output as hex (OW bits).
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg in_valid = 0;
    reg signed [`IW-1:0] x = 0;
    wire out_valid;
    wire signed [`OW-1:0] y;
    fir_dec #(.TAPS(`TAPS), .DEC(`DEC), .PHASE(`PHASE), .IW(`IW), .OW(`OW), .SH(`SH), .SAT(`SAT),
              .AW(`AW), .TABLE(`TABLE))
        dut (.clk(clk), .in_valid(in_valid), .in(x), .out_valid(out_valid), .out(y));
    reg [`IW-1:0] mem [0:65535];
    integer n, i;
    initial $readmemh("in.hex", mem);
    always @(posedge clk) if (out_valid) $display("%h", y);
    initial begin
        if (!$value$plusargs("N=%d", n)) n = 1000;
        repeat (4) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk) begin x = mem[i]; in_valid = 1; end
            @(negedge clk) in_valid = 0;
            repeat (298) @(negedge clk);
        end
        repeat (300) @(posedge clk);
        $finish;
    end
endmodule
