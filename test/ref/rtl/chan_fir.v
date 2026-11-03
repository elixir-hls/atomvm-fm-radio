// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// chan_fir.v — channel filter on the 960 kS/s IQ, before the discriminator.
//
//   y[n] = (sum_{k=0}^{30} h[k] * x[n-k] + 2^15) >>> 16, saturated to int8      per I and Q
//
// x = uint8 - 128 (x before the start = 0), h = chan_h (Q16, 120 kHz low-pass, symmetric:
// h[k] = h[30-k], only h[0..15] stored), output back to uint8. One multiplier per channel:
// the symmetric pairs are pre-added, 16 products per sample. Same arithmetic as
// eval/stereo_model.py chan_filter. en = 0 passes the samples through (one clock later).
// Timing: out_valid ~20 clocks after in_valid; the next in_valid must come >= 22 clocks later.
module chan_fir (
    input  wire        clk,
    input  wire        en,
    input  wire        in_valid,
    input  wire [15:0] in_word,            // {I, Q} uint8
    output reg         out_valid = 1'b0,
    output reg  [15:0] out_word = 16'h8080
);
`include "fm_tables.vh"

    // newest sample in b?[0]
    reg signed [7:0] bi [0:30];
    reg signed [7:0] bq [0:30];
    integer j;
    initial for (j = 0; j < 31; j = j + 1) begin bi[j] = 0; bq[j] = 0; end

    reg       busy = 1'b0;
    reg [3:0] k = 4'd0;
    always @(posedge clk) begin
        if (in_valid && en) begin
            for (j = 30; j > 0; j = j - 1) begin bi[j] <= bi[j-1]; bq[j] <= bq[j-1]; end
            bi[0] <= in_word[15:8] - 8'd128;
            bq[0] <= in_word[7:0]  - 8'd128;
            busy  <= 1'b1;
            k     <= 4'd0;
        end else if (busy) begin
            k <= k + 4'd1;
            if (k == 4'd15) busy <= 1'b0;
        end
    end

    // pipeline: pre-add (pair k, 30-k; the centre tap alone) -> multiply -> accumulate
    reg signed [8:0]  ai = 0, aq = 0;
    reg signed [17:0] cf = 0;
    reg               v1 = 1'b0, f1 = 1'b0, l1 = 1'b0;
    reg signed [26:0] pi = 0, pq = 0;
    reg               v2 = 1'b0, f2 = 1'b0, l2 = 1'b0;
    reg signed [31:0] acci = 0, accq = 0;
    reg               v3 = 1'b0;
    always @(posedge clk) begin
        if (k == 4'd15) begin
            ai <= bi[15];
            aq <= bq[15];
        end else begin
            ai <= bi[k] + bi[30 - k];
            aq <= bq[k] + bq[30 - k];
        end
        cf <= chan_h(k);
        v1 <= busy;
        f1 <= busy && k == 4'd0;
        l1 <= busy && k == 4'd15;
        pi <= ai * cf;
        pq <= aq * cf;
        v2 <= v1; f2 <= f1; l2 <= l1;
        // two plain assignments (Gowin mis-synthesised a muxed `(first ? 0 : acc) + prod`)
        if (v2) begin
            if (f2) begin acci <= pi;        accq <= pq;        end
            else    begin acci <= acci + pi; accq <= accq + pq; end
        end
        v3 <= v2 && l2;
    end

    function [7:0] to_u8(input signed [31:0] acc);
        reg signed [31:0] y;
        begin
            y = (acc + 32'sd32768) >>> 16;
            to_u8 = (y > 32'sd127) ? 8'd255 : (y < -32'sd128) ? 8'd0 : y[7:0] + 8'd128;
        end
    endfunction

    always @(posedge clk) begin
        out_valid <= en ? v3 : in_valid;
        if (en ? v3 : in_valid)
            out_word <= en ? {to_u8(acci), to_u8(accq)} : in_word;
    end
endmodule
