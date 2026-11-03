// From usb-rtl-sdr-tang25k f50cc0c (rtl/).
// iq_pair.v — IQ byte stream (I, Q, I, Q, ... as the RTL-SDR sends them) -> one sample pulse
// for the demodulator (iq_word = {I, Q}). fm_demod needs ~20 clocks between samples, so a
// sample is followed by GAP clocks in which no byte is taken (the stream is far slower on
// average: 240 kS/s against 50 MHz). `en` low drops the pairing state (the next byte is an I).
module iq_pair #(
    parameter GAP = 4
) (
    input  wire        clk,
    input  wire        en,
    input  wire        s_valid,
    input  wire [7:0]  s_data,
    output wire        s_ready,
    output reg         iq_valid = 1'b0,
    output reg  [15:0] iq_word = 16'h0000
);
    reg       have_i = 1'b0;
    reg [7:0] i_byte = 8'h00;
    reg [7:0] gap = 8'd0;               // GAP <= 255
    assign s_ready = en && gap == 8'd0;
    always @(posedge clk) begin
        iq_valid <= 1'b0;
        if (gap != 8'd0) gap <= gap - 8'd1;
        if (!en) begin
            have_i <= 1'b0;
        end else if (s_valid && s_ready) begin
            if (!have_i) begin
                i_byte <= s_data;
                have_i <= 1'b1;
            end else begin
                iq_word  <= {i_byte, s_data};
                iq_valid <= 1'b1;
                have_i   <= 1'b0;
                gap      <= GAP;
            end
        end
    end
endmodule
