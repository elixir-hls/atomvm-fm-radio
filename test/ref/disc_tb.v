// fm_disc.v fed with in.hex ({I, Q} words, one every 24 clocks): prints d (hex, 4 digits) per sample.
module disc_tb;
    reg clk = 0;
    always #5 clk = ~clk;
    reg [15:0] mem [0:65535];
    reg iq_valid = 0;
    reg [15:0] iq_word = 0;
    wire d_valid;
    wire signed [15:0] d;
    fm_disc dut (.clk(clk), .iq_valid(iq_valid), .iq_word(iq_word), .d_valid(d_valid), .d(d));
    integer n, i, g;
    always @(posedge clk) if (d_valid) $display("%04x", d);
    initial begin
        if (!$value$plusargs("N=%d", n)) n = 1000;
        $readmemh("in.hex", mem);
        for (i = 0; i < n; i = i + 1) begin
            @(posedge clk) begin iq_valid <= 1; iq_word <= mem[i]; end
            @(posedge clk) iq_valid <= 0;
            for (g = 0; g < 22; g = g + 1) @(posedge clk);
        end
        for (g = 0; g < 40; g = g + 1) @(posedge clk);
        $finish;
    end
endmodule
