// Pure-Verilog INT8 CNN accelerator for Cyclone V SoC.
//
// Tensor layout is NHWC8: channels are padded to groups of eight and each
// 64-bit DDR word contains one signed INT8 channel vector. The engine exposes
// two descriptor banks so software can prepare the pong job while the ping job
// is running. Standard/pointwise convolution computes eight output channels
// in parallel with an 8x8 MAC array; depthwise and pooling operate lane-wise.
module pure_cnn_accel (
    input               clk,
    input               reset,

    input       [7:0]   avs_address,
    input               avs_write,
    input               avs_read,
    input       [31:0]  avs_writedata,
    output reg  [31:0]  avs_readdata,
    output              avs_waitrequest,

    output reg  [31:0]  activation_avm_address,
    output reg          activation_avm_read,
    output      [7:0]   activation_avm_byteenable,
    output      [4:0]   activation_avm_burstcount,
    input       [63:0]  activation_avm_readdata,
    input               activation_avm_readdatavalid,
    input               activation_avm_waitrequest,

    output reg  [31:0]  parameter_avm_address,
    output reg          parameter_avm_read,
    output      [7:0]   parameter_avm_byteenable,
    output      [4:0]   parameter_avm_burstcount,
    input       [63:0]  parameter_avm_readdata,
    input               parameter_avm_readdatavalid,
    input               parameter_avm_waitrequest,

    output reg  [31:0]  output_avm_address,
    output reg          output_avm_write,
    output reg  [63:0]  output_avm_writedata,
    output      [7:0]   output_avm_byteenable,
    output      [4:0]   output_avm_burstcount,
    input               output_avm_waitrequest,

    output              irq
);

localparam [31:0] CORE_ID      = 32'h50434e4e; // "PCNN"
localparam [31:0] CORE_VERSION = 32'h0001_0000;

localparam [2:0] OP_CONV       = 3'd0;
localparam [2:0] OP_DEPTHWISE  = 3'd1;
localparam [2:0] OP_MAXPOOL    = 3'd2;
localparam [2:0] OP_GLOBAL_AVG = 3'd3;

localparam [7:0] S_IDLE             = 8'd0;
localparam [7:0] S_LATCH_DESC       = 8'd1;
localparam [7:0] S_VALIDATE         = 8'd2;
localparam [7:0] S_BIAS_REQ         = 8'd3;
localparam [7:0] S_BIAS_WAIT        = 8'd4;
localparam [7:0] S_QUANT_REQ        = 8'd5;
localparam [7:0] S_QUANT_WAIT       = 8'd6;
localparam [7:0] S_WEIGHT_REQ       = 8'd7;
localparam [7:0] S_WEIGHT_WAIT      = 8'd8;
localparam [7:0] S_INIT_PIXEL       = 8'd9;
localparam [7:0] S_SAMPLE_PREP      = 8'd10;
localparam [7:0] S_ACT_REQ          = 8'd11;
localparam [7:0] S_ACT_WAIT         = 8'd12;
localparam [7:0] S_MAC              = 8'd13;
localparam [7:0] S_GLOBAL_PREP      = 8'd14;
localparam [7:0] S_GLOBAL_ACT_REQ   = 8'd15;
localparam [7:0] S_GLOBAL_ACT_WAIT  = 8'd16;
localparam [7:0] S_GLOBAL_MAC       = 8'd17;
localparam [7:0] S_REQUANT          = 8'd18;
localparam [7:0] S_POOL_PACK        = 8'd19;
localparam [7:0] S_OUTPUT_REQ       = 8'd20;
localparam [7:0] S_FINISH_BLOCK     = 8'd21;
localparam [7:0] S_JOB_DONE         = 8'd22;
localparam [7:0] S_JOB_ERROR        = 8'd23;
localparam [7:0] S_CACHE_WAIT       = 8'd24;
localparam [7:0] S_CACHE_ADDR       = 8'd25;
localparam [7:0] S_ACT_PIXEL        = 8'd26;
localparam [7:0] S_ACT_VECTOR       = 8'd27;
localparam [7:0] S_ACT_ADDRESS      = 8'd28;
localparam [7:0] S_GLOBAL_PIXEL     = 8'd29;
localparam [7:0] S_GLOBAL_VECTOR    = 8'd30;
localparam [7:0] S_GLOBAL_ADDRESS   = 8'd31;
localparam [7:0] S_OUTPUT_INDEX     = 8'd32;
localparam [7:0] S_OUTPUT_ADDRESS   = 8'd33;
localparam [7:0] S_RQ_MAGNITUDE     = 8'd34;
localparam [7:0] S_RQ_ROUND         = 8'd35;
localparam [7:0] S_RQ_SHIFT         = 8'd36;
localparam [7:0] S_RQ_SIGN          = 8'd37;
localparam [7:0] S_RQ_TRANSLATE     = 8'd38;
localparam [7:0] S_RQ_CLAMP         = 8'd39;
localparam [7:0] S_VALIDATE_CACHE    = 8'd40;

localparam integer CACHE_DEPTH = 512;

assign avs_waitrequest               = 1'b0;
assign activation_avm_byteenable     = 8'hff;
assign activation_avm_burstcount     = 5'd1;
assign parameter_avm_byteenable      = 8'hff;
assign parameter_avm_burstcount      = 5'd1;
assign output_avm_byteenable         = 8'hff;
assign output_avm_burstcount         = 5'd1;

reg [31:0] slot0 [0:15];
reg [31:0] slot1 [0:15];

reg         pending0;
reg         pending1;
reg         done0;
reg         done1;
reg         active_slot;
reg         round_robin;
reg         busy;
reg         irq_enable;
reg         error_flag;
reg [31:0]  last_error;
reg [31:0]  last_cycles;
reg [31:0]  active_cycles;
reg [31:0]  completed_sequence0;
reg [31:0]  completed_sequence1;
reg [31:0]  completed_jobs;
reg [7:0]   state;

reg [31:0] input_base;
reg [31:0] output_base;
reg [31:0] weight_base;
reg [31:0] bias_base;
reg [31:0] quant_base;
reg [9:0]  input_width;
reg [9:0]  input_height;
reg [9:0]  input_blocks;
reg [9:0]  output_width;
reg [9:0]  output_height;
reg [9:0]  output_blocks;
reg [2:0]  operation;
reg [3:0]  kernel_size;
reg [3:0]  stride;
reg [3:0]  padding;
reg [1:0]  activation_mode;
reg [31:0] sequence_id;

reg [9:0] output_block;
reg [9:0] output_x;
reg [9:0] output_y;
reg [3:0] kernel_x;
reg [3:0] kernel_y;
reg [9:0] input_block;
reg [9:0] global_x;
reg [9:0] global_y;
reg [9:0] cache_count;
reg [13:0] cache_count_candidate;
reg [9:0] cache_index;
reg [2:0] cache_lane;
reg [2:0] metadata_index;
reg [2:0] requant_lane;

reg signed [12:0] sample_x_stage;
reg signed [12:0] sample_y_stage;
reg        [19:0] activation_pixel_index;
reg        [29:0] activation_vector_index;
reg        [19:0] output_pixel_index;
reg        [29:0] output_vector_index;

reg [31:0] activation_address_reg;
reg [31:0] parameter_address_reg;
reg [31:0] output_address_reg;
reg [31:0] bias_address_cursor;
reg [31:0] quant_address_cursor;
reg [31:0] weight_address_cursor;

reg signed [39:0] accumulator [0:7];
reg signed [31:0] bias_value [0:7];
reg signed [31:0] quant_multiplier [0:7];
reg        [7:0] quant_shift [0:7];
reg signed [7:0] quant_zero [0:7];
reg signed [7:0] quant_min [0:7];
reg signed [7:0] quant_max [0:7];
reg signed [7:0] pool_maximum [0:7];

reg signed [71:0] requant_product;
reg        [71:0] requant_magnitude;
reg        [71:0] requant_rounded;
reg        [71:0] requant_shifted_magnitude;
reg signed [71:0] requant_shifted;
reg signed [71:0] requant_translated;
reg               requant_negative;
reg        [7:0]  requant_right_shift;
reg signed [7:0]  requant_zero_point;
reg signed [7:0]  requant_clamp_minimum;
reg signed [7:0]  requant_clamp_maximum;

reg [63:0] activation_vector;
reg [63:0] output_vector;
reg [63:0] weight_vector0;
reg [63:0] weight_vector1;
reg [63:0] weight_vector2;
reg [63:0] weight_vector3;
reg [63:0] weight_vector4;
reg [63:0] weight_vector5;
reg [63:0] weight_vector6;
reg [63:0] weight_vector7;

wire [8:0]  weight_cache_address;
wire        weight_cache_write_cycle;
wire [7:0]  weight_cache_write_enable;
wire [63:0] weight_cache_read0;
wire [63:0] weight_cache_read1;
wire [63:0] weight_cache_read2;
wire [63:0] weight_cache_read3;
wire [63:0] weight_cache_read4;
wire [63:0] weight_cache_read5;
wire [63:0] weight_cache_read6;
wire [63:0] weight_cache_read7;

wire signed [18:0] dot0;
wire signed [18:0] dot1;
wire signed [18:0] dot2;
wire signed [18:0] dot3;
wire signed [18:0] dot4;
wire signed [18:0] dot5;
wire signed [18:0] dot6;
wire signed [18:0] dot7;

cnn_dot8 dot_lane0(.activation(activation_vector), .weight(weight_vector0), .sum(dot0));
cnn_dot8 dot_lane1(.activation(activation_vector), .weight(weight_vector1), .sum(dot1));
cnn_dot8 dot_lane2(.activation(activation_vector), .weight(weight_vector2), .sum(dot2));
cnn_dot8 dot_lane3(.activation(activation_vector), .weight(weight_vector3), .sum(dot3));
cnn_dot8 dot_lane4(.activation(activation_vector), .weight(weight_vector4), .sum(dot4));
cnn_dot8 dot_lane5(.activation(activation_vector), .weight(weight_vector5), .sum(dot5));
cnn_dot8 dot_lane6(.activation(activation_vector), .weight(weight_vector6), .sum(dot6));
cnn_dot8 dot_lane7(.activation(activation_vector), .weight(weight_vector7), .sum(dot7));

assign irq = irq_enable && (done0 || done1 || error_flag);

integer calc_cache_index;
wire sample_in_bounds;

assign sample_in_bounds =
    (sample_x_stage >= 0) &&
    (sample_y_stage >= 0) &&
    (sample_x_stage < $signed({3'b000, input_width})) &&
    (sample_y_stage < $signed({3'b000, input_height}));

assign weight_cache_address = cache_index[8:0];
assign weight_cache_write_cycle = (state == S_WEIGHT_WAIT) &&
                                  parameter_avm_readdatavalid;
assign weight_cache_write_enable[0] = weight_cache_write_cycle &&
    (operation == OP_DEPTHWISE || cache_lane == 3'd0);
assign weight_cache_write_enable[1] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd1;
assign weight_cache_write_enable[2] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd2;
assign weight_cache_write_enable[3] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd3;
assign weight_cache_write_enable[4] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd4;
assign weight_cache_write_enable[5] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd5;
assign weight_cache_write_enable[6] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd6;
assign weight_cache_write_enable[7] = weight_cache_write_cycle &&
    operation == OP_CONV && cache_lane == 3'd7;

cnn_weight_cache cache0(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[0]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read0));
cnn_weight_cache cache1(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[1]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read1));
cnn_weight_cache cache2(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[2]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read2));
cnn_weight_cache cache3(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[3]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read3));
cnn_weight_cache cache4(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[4]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read4));
cnn_weight_cache cache5(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[5]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read5));
cnn_weight_cache cache6(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[6]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read6));
cnn_weight_cache cache7(
    .clk(clk), .address(weight_cache_address),
    .write_enable(weight_cache_write_enable[7]),
    .write_data(parameter_avm_readdata), .read_data(weight_cache_read7));

always @* begin
    if (operation == OP_CONV) begin
        calc_cache_index = (((kernel_y * kernel_size) + kernel_x) *
                            input_blocks) + input_block;
    end else begin
        calc_cache_index = (kernel_y * kernel_size) + kernel_x;
    end
end

always @* begin
    avs_readdata = 32'd0;
    case (avs_address)
        8'h00: avs_readdata = CORE_ID;
        8'h01: avs_readdata = CORE_VERSION;
        8'h02: avs_readdata = {29'd0, error_flag, irq_enable, 1'b0};
        8'h03: avs_readdata = {16'd0, state, irq, error_flag, done1, done0,
                              pending1, pending0, active_slot, busy};
        8'h04: avs_readdata = 32'd0;
        8'h05: avs_readdata = {29'd0, error_flag, done1, done0};
        8'h06: avs_readdata = last_cycles;
        8'h07: avs_readdata = last_error;
        8'h08: avs_readdata = completed_sequence0;
        8'h09: avs_readdata = completed_sequence1;
        8'h0a: avs_readdata = completed_jobs;
        default: begin
            if (avs_address >= 8'h10 && avs_address <= 8'h1f)
                avs_readdata = slot0[avs_address - 8'h10];
            else if (avs_address >= 8'h20 && avs_address <= 8'h2f)
                avs_readdata = slot1[avs_address - 8'h20];
        end
    endcase
end

always @* begin
    activation_avm_address = activation_address_reg;
    activation_avm_read = (state == S_ACT_REQ) ||
                          (state == S_GLOBAL_ACT_REQ);

    parameter_avm_address = parameter_address_reg;
    parameter_avm_read = (state == S_BIAS_REQ) ||
                         (state == S_QUANT_REQ) ||
                         (state == S_WEIGHT_REQ);

    output_avm_address = output_address_reg;
    output_avm_write = (state == S_OUTPUT_REQ);
    output_avm_writedata = output_vector;
end

integer index;
always @(posedge clk) begin
    if (reset) begin
        pending0 <= 1'b0;
        pending1 <= 1'b0;
        done0 <= 1'b0;
        done1 <= 1'b0;
        active_slot <= 1'b0;
        round_robin <= 1'b0;
        busy <= 1'b0;
        irq_enable <= 1'b0;
        error_flag <= 1'b0;
        last_error <= 32'd0;
        last_cycles <= 32'd0;
        active_cycles <= 32'd0;
        completed_sequence0 <= 32'd0;
        completed_sequence1 <= 32'd0;
        completed_jobs <= 32'd0;
        sample_x_stage <= 13'sd0;
        sample_y_stage <= 13'sd0;
        activation_pixel_index <= 20'd0;
        activation_vector_index <= 30'd0;
        output_pixel_index <= 20'd0;
        output_vector_index <= 30'd0;
        activation_address_reg <= 32'd0;
        parameter_address_reg <= 32'd0;
        output_address_reg <= 32'd0;
        bias_address_cursor <= 32'd0;
        quant_address_cursor <= 32'd0;
        weight_address_cursor <= 32'd0;
        cache_count_candidate <= 14'd0;
        requant_product <= 72'sd0;
        requant_magnitude <= 72'd0;
        requant_rounded <= 72'd0;
        requant_shifted_magnitude <= 72'd0;
        requant_shifted <= 72'sd0;
        requant_translated <= 72'sd0;
        requant_negative <= 1'b0;
        requant_right_shift <= 8'd0;
        requant_zero_point <= 8'sd0;
        requant_clamp_minimum <= 8'sh80;
        requant_clamp_maximum <= 8'sd127;
        state <= S_IDLE;
        for (index = 0; index < 16; index = index + 1) begin
            slot0[index] <= 32'd0;
            slot1[index] <= 32'd0;
        end
        for (index = 0; index < 8; index = index + 1) begin
            accumulator[index] <= 40'sd0;
            bias_value[index] <= 32'sd0;
            quant_multiplier[index] <= 32'sd0;
            quant_shift[index] <= 8'd0;
            quant_zero[index] <= 8'sd0;
            quant_min[index] <= 8'sh80;
            quant_max[index] <= 8'sd127;
            pool_maximum[index] <= 8'sh80;
        end
    end else if (avs_write && avs_address == 8'h02 && avs_writedata[0]) begin
        pending0 <= 1'b0;
        pending1 <= 1'b0;
        done0 <= 1'b0;
        done1 <= 1'b0;
        active_slot <= 1'b0;
        round_robin <= 1'b0;
        busy <= 1'b0;
        error_flag <= 1'b0;
        last_error <= 32'd0;
        active_cycles <= 32'd0;
        irq_enable <= avs_writedata[1];
        state <= S_IDLE;
    end else begin
        if (busy)
            active_cycles <= active_cycles + 1'b1;

        if (avs_write) begin
            if (avs_address == 8'h02) begin
                irq_enable <= avs_writedata[1];
                if (avs_writedata[2]) begin
                    error_flag <= 1'b0;
                    last_error <= 32'd0;
                end
            end else if (avs_address == 8'h04) begin
                if (avs_writedata[0]) begin
                    if (!pending0 && !(busy && active_slot == 1'b0))
                        pending0 <= 1'b1;
                    else begin
                        error_flag <= 1'b1;
                        last_error <= 32'h0000_0100;
                    end
                end
                if (avs_writedata[1]) begin
                    if (!pending1 && !(busy && active_slot == 1'b1))
                        pending1 <= 1'b1;
                    else begin
                        error_flag <= 1'b1;
                        last_error <= 32'h0000_0101;
                    end
                end
                if (avs_writedata[16])
                    done0 <= 1'b0;
                if (avs_writedata[17])
                    done1 <= 1'b0;
            end else if (avs_address == 8'h05) begin
                if (avs_writedata[0])
                    done0 <= 1'b0;
                if (avs_writedata[1])
                    done1 <= 1'b0;
                if (avs_writedata[2])
                    error_flag <= 1'b0;
            end else if (avs_address >= 8'h10 && avs_address <= 8'h1f) begin
                if (!pending0 && !(busy && active_slot == 1'b0))
                    slot0[avs_address - 8'h10] <= avs_writedata;
            end else if (avs_address >= 8'h20 && avs_address <= 8'h2f) begin
                if (!pending1 && !(busy && active_slot == 1'b1))
                    slot1[avs_address - 8'h20] <= avs_writedata;
            end
        end

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if ((round_robin == 1'b0 && pending0) ||
                    (round_robin == 1'b1 && !pending1 && pending0)) begin
                    active_slot <= 1'b0;
                    pending0 <= 1'b0;
                    done0 <= 1'b0;
                    busy <= 1'b1;
                    active_cycles <= 32'd0;
                    state <= S_LATCH_DESC;
                end else if (pending1) begin
                    active_slot <= 1'b1;
                    pending1 <= 1'b0;
                    done1 <= 1'b0;
                    busy <= 1'b1;
                    active_cycles <= 32'd0;
                    state <= S_LATCH_DESC;
                end
            end

            S_LATCH_DESC: begin
                if (active_slot == 1'b0) begin
                    input_base <= slot0[0];
                    output_base <= slot0[1];
                    weight_base <= slot0[2];
                    bias_base <= slot0[3];
                    quant_base <= slot0[4];
                    input_width <= slot0[5][9:0];
                    input_height <= slot0[5][19:10];
                    input_blocks <= slot0[5][29:20];
                    output_width <= slot0[6][9:0];
                    output_height <= slot0[6][19:10];
                    output_blocks <= slot0[6][29:20];
                    operation <= slot0[7][2:0];
                    kernel_size <= slot0[7][7:4];
                    stride <= slot0[7][11:8];
                    padding <= slot0[7][15:12];
                    activation_mode <= slot0[7][17:16];
                    sequence_id <= slot0[9];
                end else begin
                    input_base <= slot1[0];
                    output_base <= slot1[1];
                    weight_base <= slot1[2];
                    bias_base <= slot1[3];
                    quant_base <= slot1[4];
                    input_width <= slot1[5][9:0];
                    input_height <= slot1[5][19:10];
                    input_blocks <= slot1[5][29:20];
                    output_width <= slot1[6][9:0];
                    output_height <= slot1[6][19:10];
                    output_blocks <= slot1[6][29:20];
                    operation <= slot1[7][2:0];
                    kernel_size <= slot1[7][7:4];
                    stride <= slot1[7][11:8];
                    padding <= slot1[7][15:12];
                    activation_mode <= slot1[7][17:16];
                    sequence_id <= slot1[9];
                end
                state <= S_VALIDATE;
            end

            S_VALIDATE: begin
                if (input_width == 0 || input_height == 0 ||
                    input_blocks == 0 || output_width == 0 ||
                    output_height == 0 || output_blocks == 0) begin
                    last_error <= 32'h0000_0200;
                    state <= S_JOB_ERROR;
                end else if (operation > OP_GLOBAL_AVG) begin
                    last_error <= 32'h0000_0201;
                    state <= S_JOB_ERROR;
                end else if ((operation == OP_CONV ||
                              operation == OP_DEPTHWISE ||
                              operation == OP_MAXPOOL) &&
                             !(kernel_size == 1 || kernel_size == 2 ||
                               kernel_size == 3)) begin
                    last_error <= 32'h0000_0202;
                    state <= S_JOB_ERROR;
                end else if (stride == 0 || stride > 2) begin
                    last_error <= 32'h0000_0203;
                    state <= S_JOB_ERROR;
                end else if (input_base[2:0] != 0 || output_base[2:0] != 0 ||
                             weight_base[2:0] != 0 || bias_base[2:0] != 0 ||
                             quant_base[2:0] != 0) begin
                    last_error <= 32'h0000_0204;
                    state <= S_JOB_ERROR;
                end else if ((operation == OP_DEPTHWISE ||
                              operation == OP_MAXPOOL ||
                              operation == OP_GLOBAL_AVG) &&
                             input_blocks != output_blocks) begin
                    last_error <= 32'h0000_0205;
                    state <= S_JOB_ERROR;
                end else begin
                    if (operation == OP_CONV)
                        cache_count_candidate <=
                            kernel_size * kernel_size * input_blocks;
                    else
                        cache_count_candidate <= kernel_size * kernel_size;
                    state <= S_VALIDATE_CACHE;
                end
            end

            S_VALIDATE_CACHE: begin
                if ((operation == OP_CONV || operation == OP_DEPTHWISE) &&
                    cache_count_candidate > CACHE_DEPTH) begin
                    last_error <= 32'h0000_0206;
                    state <= S_JOB_ERROR;
                end else begin
                    output_block <= 10'd0;
                    output_x <= 10'd0;
                    output_y <= 10'd0;
                    metadata_index <= 3'd0;
                    bias_address_cursor <= bias_base;
                    quant_address_cursor <= quant_base;
                    weight_address_cursor <= weight_base;
                    parameter_address_reg <= bias_base;
                    cache_count <= cache_count_candidate[9:0];

                    if (operation == OP_MAXPOOL)
                        state <= S_INIT_PIXEL;
                    else
                        state <= S_BIAS_REQ;
                end
            end

            S_BIAS_REQ: begin
                if (!parameter_avm_waitrequest)
                    state <= S_BIAS_WAIT;
            end

            S_BIAS_WAIT: begin
                if (parameter_avm_readdatavalid) begin
                    bias_address_cursor <= bias_address_cursor + 32'd8;
                    case (metadata_index)
                        3'd0: begin
                            bias_value[0] <= parameter_avm_readdata[31:0];
                            bias_value[1] <= parameter_avm_readdata[63:32];
                        end
                        3'd1: begin
                            bias_value[2] <= parameter_avm_readdata[31:0];
                            bias_value[3] <= parameter_avm_readdata[63:32];
                        end
                        3'd2: begin
                            bias_value[4] <= parameter_avm_readdata[31:0];
                            bias_value[5] <= parameter_avm_readdata[63:32];
                        end
                        default: begin
                            bias_value[6] <= parameter_avm_readdata[31:0];
                            bias_value[7] <= parameter_avm_readdata[63:32];
                        end
                    endcase
                    if (metadata_index == 3'd3) begin
                        metadata_index <= 3'd0;
                        parameter_address_reg <= quant_address_cursor;
                        state <= S_QUANT_REQ;
                    end else begin
                        metadata_index <= metadata_index + 1'b1;
                        parameter_address_reg <= bias_address_cursor + 32'd8;
                        state <= S_BIAS_REQ;
                    end
                end
            end

            S_QUANT_REQ: begin
                if (!parameter_avm_waitrequest)
                    state <= S_QUANT_WAIT;
            end

            S_QUANT_WAIT: begin
                if (parameter_avm_readdatavalid) begin
                    quant_address_cursor <= quant_address_cursor + 32'd8;
                    quant_multiplier[metadata_index] <=
                        parameter_avm_readdata[31:0];
                    quant_shift[metadata_index] <= parameter_avm_readdata[39:32];
                    quant_zero[metadata_index] <= parameter_avm_readdata[47:40];
                    quant_min[metadata_index] <= parameter_avm_readdata[55:48];
                    quant_max[metadata_index] <= parameter_avm_readdata[63:56];
                    if (metadata_index == 3'd7) begin
                        metadata_index <= 3'd0;
                        cache_index <= 10'd0;
                        cache_lane <= 3'd0;
                        parameter_address_reg <= weight_address_cursor;
                        if (operation == OP_GLOBAL_AVG)
                            state <= S_INIT_PIXEL;
                        else
                            state <= S_WEIGHT_REQ;
                    end else begin
                        metadata_index <= metadata_index + 1'b1;
                        parameter_address_reg <= quant_address_cursor + 32'd8;
                        state <= S_QUANT_REQ;
                    end
                end
            end

            S_WEIGHT_REQ: begin
                if (!parameter_avm_waitrequest)
                    state <= S_WEIGHT_WAIT;
            end

            S_WEIGHT_WAIT: begin
                if (parameter_avm_readdatavalid) begin
                    weight_address_cursor <= weight_address_cursor + 32'd8;
                    parameter_address_reg <= weight_address_cursor + 32'd8;
                    if (operation == OP_DEPTHWISE) begin
                        if (cache_index + 1'b1 >= cache_count) begin
                            cache_index <= 10'd0;
                            state <= S_INIT_PIXEL;
                        end else begin
                            cache_index <= cache_index + 1'b1;
                            state <= S_WEIGHT_REQ;
                        end
                    end else begin
                        if (cache_lane == 3'd7) begin
                            cache_lane <= 3'd0;
                            if (cache_index + 1'b1 >= cache_count) begin
                                cache_index <= 10'd0;
                                state <= S_INIT_PIXEL;
                            end else begin
                                cache_index <= cache_index + 1'b1;
                                state <= S_WEIGHT_REQ;
                            end
                        end else begin
                            cache_lane <= cache_lane + 1'b1;
                            state <= S_WEIGHT_REQ;
                        end
                    end
                end
            end

            S_INIT_PIXEL: begin
                kernel_x <= 4'd0;
                kernel_y <= 4'd0;
                input_block <= 10'd0;
                global_x <= 10'd0;
                global_y <= 10'd0;
                requant_lane <= 3'd0;
                output_vector <= 64'd0;
                for (index = 0; index < 8; index = index + 1) begin
                    accumulator[index] <= bias_value[index];
                    pool_maximum[index] <= 8'sh80;
                end
                output_pixel_index <=
                    (output_y * output_width) + output_x;
                state <= S_OUTPUT_INDEX;
            end

            S_OUTPUT_INDEX: begin
                output_vector_index <=
                    (output_pixel_index * output_blocks) + output_block;
                state <= S_OUTPUT_ADDRESS;
            end

            S_OUTPUT_ADDRESS: begin
                output_address_reg <= output_base +
                    ({2'b00, output_vector_index} << 3);
                if (operation == OP_GLOBAL_AVG)
                    state <= S_GLOBAL_PREP;
                else
                    state <= S_SAMPLE_PREP;
            end

            S_SAMPLE_PREP: begin
                cache_index <= calc_cache_index[9:0];
                if (stride == 4'd2) begin
                    sample_x_stage <= $signed({2'b00, output_x, 1'b0}) +
                                      $signed({9'd0, kernel_x}) -
                                      $signed({9'd0, padding});
                    sample_y_stage <= $signed({2'b00, output_y, 1'b0}) +
                                      $signed({9'd0, kernel_y}) -
                                      $signed({9'd0, padding});
                end else begin
                    sample_x_stage <= $signed({3'b000, output_x}) +
                                      $signed({9'd0, kernel_x}) -
                                      $signed({9'd0, padding});
                    sample_y_stage <= $signed({3'b000, output_y}) +
                                      $signed({9'd0, kernel_y}) -
                                      $signed({9'd0, padding});
                end
                state <= S_CACHE_ADDR;
            end

            S_CACHE_ADDR: begin
                state <= S_CACHE_WAIT;
            end

            S_CACHE_WAIT: begin
                weight_vector0 <= weight_cache_read0;
                weight_vector1 <= weight_cache_read1;
                weight_vector2 <= weight_cache_read2;
                weight_vector3 <= weight_cache_read3;
                weight_vector4 <= weight_cache_read4;
                weight_vector5 <= weight_cache_read5;
                weight_vector6 <= weight_cache_read6;
                weight_vector7 <= weight_cache_read7;
                if (sample_in_bounds) begin
                    state <= S_ACT_PIXEL;
                end else begin
                    activation_vector <= 64'd0;
                    state <= S_MAC;
                end
            end

            S_ACT_PIXEL: begin
                activation_pixel_index <=
                    (sample_y_stage[9:0] * input_width) +
                    sample_x_stage[9:0];
                state <= S_ACT_VECTOR;
            end

            S_ACT_VECTOR: begin
                if (operation == OP_DEPTHWISE || operation == OP_MAXPOOL)
                    activation_vector_index <=
                        (activation_pixel_index * input_blocks) + output_block;
                else
                    activation_vector_index <=
                        (activation_pixel_index * input_blocks) + input_block;
                state <= S_ACT_ADDRESS;
            end

            S_ACT_ADDRESS: begin
                activation_address_reg <= input_base +
                    ({2'b00, activation_vector_index} << 3);
                state <= S_ACT_REQ;
            end

            S_ACT_REQ: begin
                if (!activation_avm_waitrequest)
                    state <= S_ACT_WAIT;
            end

            S_ACT_WAIT: begin
                if (activation_avm_readdatavalid) begin
                    activation_vector <= activation_avm_readdata;
                    state <= S_MAC;
                end
            end

            S_MAC: begin
                if (operation == OP_CONV) begin
                    accumulator[0] <= accumulator[0] + dot0;
                    accumulator[1] <= accumulator[1] + dot1;
                    accumulator[2] <= accumulator[2] + dot2;
                    accumulator[3] <= accumulator[3] + dot3;
                    accumulator[4] <= accumulator[4] + dot4;
                    accumulator[5] <= accumulator[5] + dot5;
                    accumulator[6] <= accumulator[6] + dot6;
                    accumulator[7] <= accumulator[7] + dot7;
                end else if (operation == OP_DEPTHWISE) begin
                    accumulator[0] <= accumulator[0] +
                        $signed(activation_vector[7:0]) * $signed(weight_vector0[7:0]);
                    accumulator[1] <= accumulator[1] +
                        $signed(activation_vector[15:8]) * $signed(weight_vector0[15:8]);
                    accumulator[2] <= accumulator[2] +
                        $signed(activation_vector[23:16]) * $signed(weight_vector0[23:16]);
                    accumulator[3] <= accumulator[3] +
                        $signed(activation_vector[31:24]) * $signed(weight_vector0[31:24]);
                    accumulator[4] <= accumulator[4] +
                        $signed(activation_vector[39:32]) * $signed(weight_vector0[39:32]);
                    accumulator[5] <= accumulator[5] +
                        $signed(activation_vector[47:40]) * $signed(weight_vector0[47:40]);
                    accumulator[6] <= accumulator[6] +
                        $signed(activation_vector[55:48]) * $signed(weight_vector0[55:48]);
                    accumulator[7] <= accumulator[7] +
                        $signed(activation_vector[63:56]) * $signed(weight_vector0[63:56]);
                end else begin
                    if ($signed(activation_vector[7:0]) > pool_maximum[0])
                        pool_maximum[0] <= activation_vector[7:0];
                    if ($signed(activation_vector[15:8]) > pool_maximum[1])
                        pool_maximum[1] <= activation_vector[15:8];
                    if ($signed(activation_vector[23:16]) > pool_maximum[2])
                        pool_maximum[2] <= activation_vector[23:16];
                    if ($signed(activation_vector[31:24]) > pool_maximum[3])
                        pool_maximum[3] <= activation_vector[31:24];
                    if ($signed(activation_vector[39:32]) > pool_maximum[4])
                        pool_maximum[4] <= activation_vector[39:32];
                    if ($signed(activation_vector[47:40]) > pool_maximum[5])
                        pool_maximum[5] <= activation_vector[47:40];
                    if ($signed(activation_vector[55:48]) > pool_maximum[6])
                        pool_maximum[6] <= activation_vector[55:48];
                    if ($signed(activation_vector[63:56]) > pool_maximum[7])
                        pool_maximum[7] <= activation_vector[63:56];
                end

                if (operation == OP_CONV && input_block + 1'b1 < input_blocks) begin
                    input_block <= input_block + 1'b1;
                    state <= S_SAMPLE_PREP;
                end else begin
                    input_block <= 10'd0;
                    if (kernel_x + 1'b1 < kernel_size) begin
                        kernel_x <= kernel_x + 1'b1;
                        state <= S_SAMPLE_PREP;
                    end else begin
                        kernel_x <= 4'd0;
                        if (kernel_y + 1'b1 < kernel_size) begin
                            kernel_y <= kernel_y + 1'b1;
                            state <= S_SAMPLE_PREP;
                        end else begin
                            kernel_y <= 4'd0;
                            requant_lane <= 3'd0;
                            if (operation == OP_MAXPOOL)
                                state <= S_POOL_PACK;
                            else
                                state <= S_REQUANT;
                        end
                    end
                end
            end

            S_GLOBAL_PREP: begin
                state <= S_GLOBAL_PIXEL;
            end

            S_GLOBAL_PIXEL: begin
                activation_pixel_index <=
                    (global_y * input_width) + global_x;
                state <= S_GLOBAL_VECTOR;
            end

            S_GLOBAL_VECTOR: begin
                activation_vector_index <=
                    (activation_pixel_index * input_blocks) + output_block;
                state <= S_GLOBAL_ADDRESS;
            end

            S_GLOBAL_ADDRESS: begin
                activation_address_reg <= input_base +
                    ({2'b00, activation_vector_index} << 3);
                state <= S_GLOBAL_ACT_REQ;
            end

            S_GLOBAL_ACT_REQ: begin
                if (!activation_avm_waitrequest)
                    state <= S_GLOBAL_ACT_WAIT;
            end

            S_GLOBAL_ACT_WAIT: begin
                if (activation_avm_readdatavalid) begin
                    activation_vector <= activation_avm_readdata;
                    state <= S_GLOBAL_MAC;
                end
            end

            S_GLOBAL_MAC: begin
                accumulator[0] <= accumulator[0] + $signed(activation_vector[7:0]);
                accumulator[1] <= accumulator[1] + $signed(activation_vector[15:8]);
                accumulator[2] <= accumulator[2] + $signed(activation_vector[23:16]);
                accumulator[3] <= accumulator[3] + $signed(activation_vector[31:24]);
                accumulator[4] <= accumulator[4] + $signed(activation_vector[39:32]);
                accumulator[5] <= accumulator[5] + $signed(activation_vector[47:40]);
                accumulator[6] <= accumulator[6] + $signed(activation_vector[55:48]);
                accumulator[7] <= accumulator[7] + $signed(activation_vector[63:56]);
                if (global_x + 1'b1 < input_width) begin
                    global_x <= global_x + 1'b1;
                    state <= S_GLOBAL_PREP;
                end else begin
                    global_x <= 10'd0;
                    if (global_y + 1'b1 < input_height) begin
                        global_y <= global_y + 1'b1;
                        state <= S_GLOBAL_PREP;
                    end else begin
                        global_y <= 10'd0;
                        requant_lane <= 3'd0;
                        state <= S_REQUANT;
                    end
                end
            end

            S_REQUANT: begin
                requant_product <= accumulator[requant_lane] *
                                   quant_multiplier[requant_lane];
                requant_right_shift <= quant_shift[requant_lane];
                requant_zero_point <= quant_zero[requant_lane];
                requant_clamp_minimum <= quant_min[requant_lane];
                requant_clamp_maximum <= quant_max[requant_lane];
                state <= S_RQ_MAGNITUDE;
            end

            S_RQ_MAGNITUDE: begin
                requant_negative <= requant_product < 0;
                if (requant_product < 0)
                    requant_magnitude <= -requant_product;
                else
                    requant_magnitude <= requant_product;
                state <= S_RQ_ROUND;
            end

            S_RQ_ROUND: begin
                if (requant_right_shift == 0)
                    requant_rounded <= requant_magnitude;
                else if (requant_right_shift >= 72)
                    requant_rounded <= 72'd0;
                else
                    requant_rounded <= requant_magnitude +
                        (72'd1 << (requant_right_shift - 1'b1));
                state <= S_RQ_SHIFT;
            end

            S_RQ_SHIFT: begin
                if (requant_right_shift == 0)
                    requant_shifted_magnitude <= requant_rounded;
                else if (requant_right_shift >= 72)
                    requant_shifted_magnitude <= 72'd0;
                else
                    requant_shifted_magnitude <=
                        requant_rounded >> requant_right_shift;
                state <= S_RQ_SIGN;
            end

            S_RQ_SIGN: begin
                if (requant_negative)
                    requant_shifted <= -$signed(requant_shifted_magnitude);
                else
                    requant_shifted <= $signed(requant_shifted_magnitude);
                state <= S_RQ_TRANSLATE;
            end

            S_RQ_TRANSLATE: begin
                requant_translated <= requant_shifted +
                    $signed({{64{requant_zero_point[7]}},
                             requant_zero_point});
                state <= S_RQ_CLAMP;
            end

            S_RQ_CLAMP: begin
                if (requant_translated <
                    $signed({{64{requant_clamp_minimum[7]}},
                             requant_clamp_minimum}))
                    output_vector[requant_lane * 8 +: 8] <=
                        requant_clamp_minimum;
                else if (requant_translated >
                    $signed({{64{requant_clamp_maximum[7]}},
                             requant_clamp_maximum}))
                    output_vector[requant_lane * 8 +: 8] <=
                        requant_clamp_maximum;
                else
                    output_vector[requant_lane * 8 +: 8] <=
                        requant_translated[7:0];
                if (requant_lane == 3'd7) begin
                    requant_lane <= 3'd0;
                    state <= S_OUTPUT_REQ;
                end else begin
                    requant_lane <= requant_lane + 1'b1;
                    state <= S_REQUANT;
                end
            end

            S_POOL_PACK: begin
                output_vector[7:0] <= pool_maximum[0];
                output_vector[15:8] <= pool_maximum[1];
                output_vector[23:16] <= pool_maximum[2];
                output_vector[31:24] <= pool_maximum[3];
                output_vector[39:32] <= pool_maximum[4];
                output_vector[47:40] <= pool_maximum[5];
                output_vector[55:48] <= pool_maximum[6];
                output_vector[63:56] <= pool_maximum[7];
                state <= S_OUTPUT_REQ;
            end

            S_OUTPUT_REQ: begin
                if (!output_avm_waitrequest) begin
                    if (operation == OP_GLOBAL_AVG) begin
                        state <= S_FINISH_BLOCK;
                    end else if (output_x + 1'b1 < output_width) begin
                        output_x <= output_x + 1'b1;
                        state <= S_INIT_PIXEL;
                    end else begin
                        output_x <= 10'd0;
                        if (output_y + 1'b1 < output_height) begin
                            output_y <= output_y + 1'b1;
                            state <= S_INIT_PIXEL;
                        end else begin
                            output_y <= 10'd0;
                            state <= S_FINISH_BLOCK;
                        end
                    end
                end
            end

            S_FINISH_BLOCK: begin
                if (output_block + 1'b1 < output_blocks) begin
                    output_block <= output_block + 1'b1;
                    metadata_index <= 3'd0;
                    cache_index <= 10'd0;
                    cache_lane <= 3'd0;
                    output_x <= 10'd0;
                    output_y <= 10'd0;
                    parameter_address_reg <= bias_address_cursor;
                    if (operation == OP_MAXPOOL)
                        state <= S_INIT_PIXEL;
                    else
                        state <= S_BIAS_REQ;
                end else begin
                    state <= S_JOB_DONE;
                end
            end

            S_JOB_DONE: begin
                busy <= 1'b0;
                last_cycles <= active_cycles;
                completed_jobs <= completed_jobs + 1'b1;
                round_robin <= ~active_slot;
                if (active_slot == 1'b0) begin
                    done0 <= 1'b1;
                    completed_sequence0 <= sequence_id;
                end else begin
                    done1 <= 1'b1;
                    completed_sequence1 <= sequence_id;
                end
                state <= S_IDLE;
            end

            S_JOB_ERROR: begin
                busy <= 1'b0;
                error_flag <= 1'b1;
                last_cycles <= active_cycles;
                round_robin <= ~active_slot;
                if (active_slot == 1'b0) begin
                    done0 <= 1'b1;
                    completed_sequence0 <= sequence_id;
                end else begin
                    done1 <= 1'b1;
                    completed_sequence1 <= sequence_id;
                end
                state <= S_IDLE;
            end

            default: begin
                last_error <= 32'h0000_02ff;
                state <= S_JOB_ERROR;
            end
        endcase
    end
end

endmodule
