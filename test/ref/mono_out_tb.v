// Reference for FMRadio.deemphasis: stereo_out.v (blend 0, de-emphasis on) over the samples of
// in.hex (one s22 per line), one sample every 8 clocks; prints each left output as hex.
module tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg in_valid = 0;
    reg signed [21:0] s = 0;
    wire out_valid;
    wire signed [15:0] left, right;
    stereo_out dut (.clk(clk), .deemph(1'b1), .g(9'd0), .in_valid(in_valid), .s(s), .d(22'sd0),
                    .out_valid(out_valid), .left(left), .right(right));
    reg [21:0] mem [0:65535];
    integer n, i;
    initial begin
        $readmemh("in.hex", mem);
    end
    always @(posedge clk) if (out_valid) $display("%h", left);
    initial begin
        if (!$value$plusargs("N=%d", n)) n = 1000;
        repeat (4) @(posedge clk);
        for (i = 0; i < n; i = i + 1) begin
            @(negedge clk) begin s = mem[i]; in_valid = 1; end
            @(negedge clk) in_valid = 0;
            repeat (6) @(negedge clk);
        end
        repeat (10) @(posedge clk);
        $finish;
    end
endmodule
