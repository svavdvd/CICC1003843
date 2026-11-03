// Eight-lane signed INT8 dot product used by the pure-Verilog CNN engine.
module cnn_dot8 (
    input      [63:0] activation,
    input      [63:0] weight,
    output signed [18:0] sum
);

wire signed [7:0] a0 = activation[7:0];
wire signed [7:0] a1 = activation[15:8];
wire signed [7:0] a2 = activation[23:16];
wire signed [7:0] a3 = activation[31:24];
wire signed [7:0] a4 = activation[39:32];
wire signed [7:0] a5 = activation[47:40];
wire signed [7:0] a6 = activation[55:48];
wire signed [7:0] a7 = activation[63:56];

wire signed [7:0] w0 = weight[7:0];
wire signed [7:0] w1 = weight[15:8];
wire signed [7:0] w2 = weight[23:16];
wire signed [7:0] w3 = weight[31:24];
wire signed [7:0] w4 = weight[39:32];
wire signed [7:0] w5 = weight[47:40];
wire signed [7:0] w6 = weight[55:48];
wire signed [7:0] w7 = weight[63:56];

wire signed [15:0] p0 = a0 * w0;
wire signed [15:0] p1 = a1 * w1;
wire signed [15:0] p2 = a2 * w2;
wire signed [15:0] p3 = a3 * w3;
wire signed [15:0] p4 = a4 * w4;
wire signed [15:0] p5 = a5 * w5;
wire signed [15:0] p6 = a6 * w6;
wire signed [15:0] p7 = a7 * w7;

wire signed [16:0] s01 = p0 + p1;
wire signed [16:0] s23 = p2 + p3;
wire signed [16:0] s45 = p4 + p5;
wire signed [16:0] s67 = p6 + p7;
wire signed [17:0] s03 = s01 + s23;
wire signed [17:0] s47 = s45 + s67;

assign sum = s03 + s47;

endmodule
