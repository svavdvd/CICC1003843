// 512 x 64-bit single-port cache. The synchronous read template and ramstyle
// attribute force Quartus to use Cyclone V M10K blocks instead of registers.
module cnn_weight_cache (
    input               clk,
    input       [8:0]   address,
    input               write_enable,
    input       [63:0]  write_data,
    output reg  [63:0]  read_data
);

(* ramstyle = "M10K" *) reg [63:0] memory [0:511];

always @(posedge clk) begin
    if (write_enable)
        memory[address] <= write_data;
    read_data <= memory[address];
end

endmodule
