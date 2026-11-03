`timescale 1ns/1ps

module sort_control_tb;
reg clk = 1'b0;
reg reset = 1'b1;
reg [5:0] address = 6'd0;
reg read = 1'b0;
wire [31:0] readdata;
reg write = 1'b0;
reg [31:0] writedata = 32'd0;
reg [3:0] byteenable = 4'hF;
integer errors = 0;

sort_control dut (
    .clk(clk), .reset(reset), .avs_address(address), .avs_read(read),
    .avs_readdata(readdata), .avs_write(write), .avs_writedata(writedata),
    .avs_byteenable(byteenable)
);

always #10 clk = ~clk;

task bus_write;
    input [5:0] addr;
    input [31:0] value;
    begin
        @(negedge clk);
        address = addr;
        writedata = value;
        write = 1'b1;
        @(negedge clk);
        write = 1'b0;
        writedata = 32'd0;
    end
endtask

task expect_reg;
    input [5:0] addr;
    input [31:0] mask;
    input [31:0] expected;
    begin
        @(negedge clk);
        address = addr;
        read = 1'b1;
        #1;
        if ((readdata & mask) !== expected) begin
            $display("FAIL addr=%02x got=%08x mask=%08x expected=%08x", addr, readdata, mask, expected);
            errors = errors + 1;
        end
        @(negedge clk);
        read = 1'b0;
    end
endtask

task start_event;
    input [31:0] event_id;
    input [31:0] flags;
    begin
        bus_write(6'h04, event_id);
        bus_write(6'h05, flags);
        bus_write(6'h07, 32'h1);
    end
endtask

task push_candidate;
    input [7:0] class_id;
    input [15:0] score_q16;
    begin
        bus_write(6'h06, {score_q16, 8'd0, class_id});
        bus_write(6'h07, 32'h2);
    end
endtask

task ack_event;
    input [31:0] event_id;
    begin
        bus_write(6'h04, event_id);
        bus_write(6'h07, 32'h8);
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    reset = 1'b0;

    expect_reg(6'h00, 32'hFFFF_FFFF, 32'h534F5254);
    bus_write(6'h02, 32'h1);
    expect_reg(6'h03, 32'h1, 32'h1);

    start_event(32'd1, 32'h3);
    push_candidate(8'd4, 16'd52428);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd1);
    expect_reg(6'h09, 32'h7, 32'd1);
    expect_reg(6'h0A, 32'h1, 32'd0);
    ack_event(32'd1);

    start_event(32'd2, 32'h3);
    push_candidate(8'd4, 16'd58981);
    push_candidate(8'd3, 16'd19661);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd2);
    expect_reg(6'h09, 32'h7, 32'd2);
    expect_reg(6'h0A, 32'h1, 32'd1);
    ack_event(32'd2);

    start_event(32'd3, 32'h3);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd0);
    expect_reg(6'h09, 32'h7, 32'd0);
    ack_event(32'd3);

    bus_write(6'h02, 32'h5);
    start_event(32'd4, 32'h3);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd1);
    expect_reg(6'h09, 32'h7, 32'd1);
    ack_event(32'd4);

    bus_write(6'h02, 32'h9);
    expect_reg(6'h02, 32'hD, 32'h9);

    start_event(32'd5, 32'h3);
    push_candidate(8'd4, 16'd52428);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd1);
    expect_reg(6'h09, 32'h7, 32'd2);
    expect_reg(6'h0A, 32'h1, 32'd0);
    ack_event(32'd5);

    start_event(32'd6, 32'h3);
    push_candidate(8'd0, 16'd52428);
    bus_write(6'h07, 32'h4);
    expect_reg(6'h08, 32'h7, 32'd2);
    expect_reg(6'h09, 32'h7, 32'd1);
    expect_reg(6'h0A, 32'h1, 32'd1);
    ack_event(32'd6);

    start_event(32'd6, 32'h3);
    expect_reg(6'h1E, 32'hFFFF_FFFF, 32'd1);

    start_event(32'd7, 32'h3);
    push_candidate(8'd0, 16'd52428);
    bus_write(6'h07, 32'h4);
    bus_write(6'h04, 32'd8);
    bus_write(6'h07, 32'h8);
    expect_reg(6'h0E, 32'hF, 32'd6);

    if (errors == 0)
        $display("PASS sort_control_tb");
    else
        $display("FAIL sort_control_tb errors=%0d", errors);
    $finish;
end

endmodule
