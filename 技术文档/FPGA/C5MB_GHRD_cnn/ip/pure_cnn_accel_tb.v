`timescale 1ns/1ps

module pure_cnn_accel_tb;

reg clk = 1'b0;
reg reset = 1'b1;
always #5 clk = ~clk;

reg [7:0] avs_address = 8'd0;
reg avs_write = 1'b0;
reg avs_read = 1'b0;
reg [31:0] avs_writedata = 32'd0;
wire [31:0] avs_readdata;
wire avs_waitrequest;

wire [31:0] activation_address;
wire activation_read;
wire [7:0] activation_byteenable;
wire [4:0] activation_burstcount;
reg [63:0] activation_readdata = 64'd0;
reg activation_readdatavalid = 1'b0;
reg activation_waitrequest = 1'b0;

wire [31:0] parameter_address;
wire parameter_read;
wire [7:0] parameter_byteenable;
wire [4:0] parameter_burstcount;
reg [63:0] parameter_readdata = 64'd0;
reg parameter_readdatavalid = 1'b0;
reg parameter_waitrequest = 1'b0;

wire [31:0] output_address;
wire output_write;
wire [63:0] output_writedata;
wire [7:0] output_byteenable;
wire [4:0] output_burstcount;
reg output_waitrequest = 1'b0;
wire irq;

reg [63:0] activation_memory [0:1023];
reg [63:0] parameter_memory [0:4095];
reg [63:0] output_memory [0:1023];

reg activation_pending = 1'b0;
reg [31:0] activation_latched_address = 32'd0;
reg parameter_pending = 1'b0;
reg [31:0] parameter_latched_address = 32'd0;

integer lane;
integer timeout;
integer errors = 0;

pure_cnn_accel dut (
    .clk(clk),
    .reset(reset),
    .avs_address(avs_address),
    .avs_write(avs_write),
    .avs_read(avs_read),
    .avs_writedata(avs_writedata),
    .avs_readdata(avs_readdata),
    .avs_waitrequest(avs_waitrequest),
    .activation_avm_address(activation_address),
    .activation_avm_read(activation_read),
    .activation_avm_byteenable(activation_byteenable),
    .activation_avm_burstcount(activation_burstcount),
    .activation_avm_readdata(activation_readdata),
    .activation_avm_readdatavalid(activation_readdatavalid),
    .activation_avm_waitrequest(activation_waitrequest),
    .parameter_avm_address(parameter_address),
    .parameter_avm_read(parameter_read),
    .parameter_avm_byteenable(parameter_byteenable),
    .parameter_avm_burstcount(parameter_burstcount),
    .parameter_avm_readdata(parameter_readdata),
    .parameter_avm_readdatavalid(parameter_readdatavalid),
    .parameter_avm_waitrequest(parameter_waitrequest),
    .output_avm_address(output_address),
    .output_avm_write(output_write),
    .output_avm_writedata(output_writedata),
    .output_avm_byteenable(output_byteenable),
    .output_avm_burstcount(output_burstcount),
    .output_avm_waitrequest(output_waitrequest),
    .irq(irq)
);

always @(posedge clk) begin
    activation_readdatavalid <= 1'b0;
    if (activation_pending) begin
        activation_readdata <=
            activation_memory[(activation_latched_address - 32'h1000) >> 3];
        activation_readdatavalid <= 1'b1;
        activation_pending <= 1'b0;
    end
    if (activation_read && !activation_waitrequest) begin
        activation_latched_address <= activation_address;
        activation_pending <= 1'b1;
    end

    parameter_readdatavalid <= 1'b0;
    if (parameter_pending) begin
        parameter_readdata <= parameter_memory[parameter_latched_address >> 3];
        parameter_readdatavalid <= 1'b1;
        parameter_pending <= 1'b0;
    end
    if (parameter_read && !parameter_waitrequest) begin
        parameter_latched_address <= parameter_address;
        parameter_pending <= 1'b1;
    end

    if (output_write && !output_waitrequest)
        output_memory[(output_address - 32'h2000) >> 3] <= output_writedata;
end

task write_register;
    input [7:0] address;
    input [31:0] value;
    begin
        @(negedge clk);
        avs_address = address;
        avs_writedata = value;
        avs_write = 1'b1;
        @(negedge clk);
        avs_write = 1'b0;
        avs_address = 8'd0;
        avs_writedata = 32'd0;
    end
endtask

task program_slot;
    input [7:0] base_register;
    input [31:0] input_address;
    input [31:0] output_address_value;
    input [31:0] sequence;
    begin
        write_register(base_register + 0, input_address);
        write_register(base_register + 1, output_address_value);
        write_register(base_register + 2, 32'h0000_3000);
        write_register(base_register + 3, 32'h0000_4000);
        write_register(base_register + 4, 32'h0000_5000);
        write_register(base_register + 5, 32'h0010_0401); // 1x1x1 block
        write_register(base_register + 6, 32'h0010_0401); // 1x1x1 block
        write_register(base_register + 7, 32'h0000_0110); // conv, k=1, s=1
        write_register(base_register + 8, 32'd0);
        write_register(base_register + 9, sequence);
    end
endtask

initial begin
    for (lane = 0; lane < 1024; lane = lane + 1) begin
        activation_memory[lane] = 64'd0;
        output_memory[lane] = 64'd0;
    end
    for (lane = 0; lane < 4096; lane = lane + 1)
        parameter_memory[lane] = 64'd0;

    activation_memory[0] = 64'h0807_0605_0403_0201;
    activation_memory[32] = 64'h100f_0e0d_0c0b_0a09;

    // One 8x8 identity matrix in the accelerator's cached weight layout.
    for (lane = 0; lane < 8; lane = lane + 1)
        parameter_memory[(32'h3000 >> 3) + lane] = 64'd1 << (lane * 8);

    // Four packed bias words are already zero. Each quant record performs
    // identity scaling and clamps to signed INT8.
    for (lane = 0; lane < 8; lane = lane + 1)
        parameter_memory[(32'h5000 >> 3) + lane] =
            64'h7f80_0000_0000_0001;

    repeat (8) @(posedge clk);
    reset = 1'b0;
    repeat (4) @(posedge clk);

    if (avs_readdata !== 32'h5043_4e4e) begin
        $display("ERROR: unexpected core ID %h", avs_readdata);
        errors = errors + 1;
    end

    program_slot(8'h10, 32'h0000_1000, 32'h0000_2000, 32'h0000_0001);
    write_register(8'h04, 32'h0000_0001);

    timeout = 0;
    while (!dut.busy && timeout < 100) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    // Program and submit pong while ping is actively executing.
    program_slot(8'h20, 32'h0000_1100, 32'h0000_2100, 32'h0000_0002);
    write_register(8'h04, 32'h0000_0002);

    timeout = 0;
    while (!(dut.done0 && dut.done1) && timeout < 20000) begin
        @(posedge clk);
        timeout = timeout + 1;
    end

    if (timeout >= 20000) begin
        $display("ERROR: ping-pong jobs timed out, state=%0d", dut.state);
        errors = errors + 1;
    end
    if (dut.error_flag) begin
        $display("ERROR: accelerator error code %h", dut.last_error);
        errors = errors + 1;
    end
    if (output_memory[0] !== 64'h0807_0605_0403_0201) begin
        $display("ERROR: ping output %h", output_memory[0]);
        errors = errors + 1;
    end
    if (output_memory[32] !== 64'h100f_0e0d_0c0b_0a09) begin
        $display("ERROR: pong output %h", output_memory[32]);
        errors = errors + 1;
    end
    if (dut.completed_sequence0 !== 32'd1 ||
        dut.completed_sequence1 !== 32'd2) begin
        $display("ERROR: sequence IDs %0d %0d",
                 dut.completed_sequence0, dut.completed_sequence1);
        errors = errors + 1;
    end

    if (errors == 0)
        $display("PASS pure_cnn_accel ping-pong identity test");
    else
        $display("FAIL pure_cnn_accel errors=%0d", errors);
    $finish;
end

endmodule
