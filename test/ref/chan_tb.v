// chan_fir.v fed with in.hex ({I, Q} offset-binary words, one every 24 clocks): prints each
// output word (hex, 4 digits).
module chan_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [15:0] mem [0:65535];
    reg in_valid = 0;
    reg [15:0] in_word = 0;
    wire out_valid;
    wire [15:0] out_word;
    chan_fir dut (.clk(clk), .en(1'b1), .in_valid(in_valid), .in_word(in_word), .out_valid(out_valid), .out_word(out_word));
    integer n, i, g;
    always @(posedge clk) if (out_valid) $display("%04x", out_word);
    initial begin
        if (!$value$plusargs("N=%d", n)) n = 1000;
        $readmemh("in.hex", mem);
        for (i = 0; i < n; i = i + 1) begin
            @(posedge clk) begin in_valid <= 1; in_word <= mem[i]; end
            @(posedge clk) in_valid <= 0;
            for (g = 0; g < 22; g = g + 1) @(posedge clk);
        end
        for (g = 0; g < 40; g = g + 1) @(posedge clk);
        $finish;
    end
endmodule
