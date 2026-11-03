module cmos_capture
#(
	//range : 8, 16, 32, 64, 128, 256, 512, 1024 
	parameter DATAWIDTH = 16,
	//range: 1, 2, 4, 8, 16, 32, 64, 128
	parameter BYTEENABLEWIDTH = 2,
	parameter ADDRESSWIDTH = 32,
	//FIFO depth of the internal buffer
	//range: 4 ,8, 16, 62, 64, 128,256,512
	parameter FIFODEPTH = 512,
	parameter FIFODEPTH_LOG2 = 9,	
	parameter FIFOUSEMEMORY = 1,		// 1 to use on chip memory, 0 to use logical elements
	parameter BURST_CAPABLE = 1,							// 1 to enable burst, 0 to disable it
	parameter MAXBURSTCOUNT = 2,
	parameter BURSTCOUNTWIDTH = 2
)
(
	//global clock
	input				clk_cmos,
	
	input				clk,
	input				reset_i,
	
// mm slave
	input						as_chipselect,
	input						as_read,
	input						as_write,
	output reg	[31:0]	as_readdata,
	input	[31:0]			as_writedata,
	input	[2:0]				as_address,
	
// mm master
	output										am_write,
	output	[DATAWIDTH - 1 : 0]			am_writedata,
	output	[ADDRESSWIDTH - 1 : 0]		am_address,
	output	[BURSTCOUNTWIDTH - 1 : 0]	am_burstcount,	
	input											am_waitrequest,
	
//CMOS Sensor Interface
	input				cmos_pclk,			//24MHz CMOS Pixel clock input
	output			cmos_xclk,			//24MHz drive clock
	input				cmos_vsync,			//H : Data Valid; L : Frame Sync(Set it by register)
	input				cmos_href,			//H : Data vaild, L : Line Sync
	input		[7:0]	cmos_din,			//8 bits cmos data input
	output			cmos_rst_n,			//24MHz drive clock
	output			cmos_pwdn 			//24MHz drive clock
);

	//Avalon registers
	reg [31:0] control_register;    // Address 0
	reg [31:0] length_register;      // Address 1: 
	reg [31:0] base_register;           // Address 2:
	reg [1:0] status_register;         // Address 3: 
	
	wire control_fixed_location;
	wire reset;
	wire [15:0]cmos_frame_data;
	wire cmos_frame_clken;
	wire cmos_vsync_begin;
	wire cmos_vsync_end;
	reg control_go;
	wire control_done;
	
	wire strobe = as_chipselect & as_write;
	
	assign cmos_rst_n = ~reset;
	assign cmos_pwdn = 1'b0;
	
	
	assign reset = reset_i | control_register[1];    //merge software reset and hardware reset in the same signal
	assign control_fixed_location = control_register[2];              //1 if data will be written to the same address
	
	reg start_cap;
	reg en_cap;
	
	reg [7:0]frame_count;
		
	//状态寄存器bit0，帧结束标志信号		
	always @(posedge clk or posedge reset)
	if (reset)
		start_cap  <= 1'd0;
	else if(control_register[0] | frame_count)
		start_cap <= 1'd1;
	else if(en_cap && cmos_vsync_begin)
		start_cap  <= 1'd0;
	else
		start_cap  <= start_cap;

	always @(posedge cmos_pclk or posedge reset)
	if (reset)
		en_cap  <= 1'd0;
	else if (start_cap)begin
		if(cmos_vsync_end)
			en_cap  <= 1'd1;
		else if(cmos_vsync_begin)
			en_cap  <= 1'd0;
	end
	else
		en_cap  <= 1'd0;

	always @(posedge cmos_pclk or posedge reset)
	if (reset)
		control_go  <= 1'd0;
	else if (start_cap)begin
		if(cmos_vsync_end)
			control_go  <= 1'd1;
		else
			control_go  <= 1'd0;
	end
	else
		control_go  <= 1'd0;
		
	reg [1:0]control_go_r;
	always @(posedge clk)
		control_go_r <= {control_go_r[0],control_go};
	
	always @(posedge clk)
	if(control_register[0])
		frame_count <= control_register[15:8];
	else if(frame_count == 0)
		frame_count <= 0;
	else if(control_go_r == 2'b01)
		frame_count <= frame_count - 1'b1;

//状态寄存器bit0，帧结束标志信号		
	always @(posedge clk or posedge reset)
	if (reset)
		status_register[0]  <= 1'd0;
	else if(cmos_vsync_begin && en_cap && !frame_count)
		status_register[0]  <= 1'b1;	//使能采样了，则产生状态信号，未使能采样，则不产生
	else if((as_address == 3'b011) && strobe)	//CPU可主动清零该状态信号。
		status_register[0]  <= as_writedata[0];
	else
		status_register[0]  <= status_register[0];
		
//状态寄存器bit0，帧结束标志信号		
	always @(posedge clk or posedge reset)
	if (reset)
		status_register[1]  <= 1'd0;
	else if(control_go)
		status_register[1]  <= 1'd0;
	else if(control_done)
		status_register[1]  <= 1'd1;

	//读取寄存器
	always @(posedge clk or posedge reset)
	if (reset)
		as_readdata  <= 32'd0;
	else if (as_read == 1'b1) begin
			case (as_address)
				3'b000: as_readdata   <= control_register;
				3'b001: as_readdata   <= length_register;
				3'b010: as_readdata   <= base_register;
				3'b011: as_readdata   <= status_register;
			default: as_readdata  <= status_register;
		endcase
	end

	//写寄存器
	always @(posedge clk or posedge reset)
    if (reset) begin
        control_register    <= 32'b0;
        length_register  <= 32'b0;
        base_register       <= 32'b0;
		end
    else if (strobe) begin
        case (as_address)
            3'b000: control_register    <= as_writedata;
            3'b001: length_register  	 <= as_writedata;
            3'b010: base_register       <= as_writedata;
            default:;
        endcase
    end
	 else begin
		control_register[0] <= 1'b0;
	 end

	CMOS_Capture_RGB565	u_CMOS_Capture_RGB565
	(
		//global clock
		.clk_cmos				(clk_cmos),			//24MHz CMOS Driver clock input
		.rst_n					(!reset),	//global reset

		//CMOS Sensor Interface
		.cmos_pclk				(cmos_pclk),  		//24MHz CMOS Pixel clock input
		.cmos_xclk				(cmos_xclk),		//24MHz drive clock
		.cmos_din				(cmos_din),		//8 bits cmos data input
		.cmos_vsync				(cmos_vsync),		//L: vaild, H: invalid
		.cmos_href				(cmos_href),		//H: vaild, L: invalid
		
		//CMOS SYNC Data output
		.cmos_frame_vsync		(),	//cmos frame data vsync valid signal
		.cmos_frame_href		(),	//cmos frame data href vaild  signal
		.cmos_frame_data		(cmos_frame_data),	//cmos frame RGB output: {{R[4:0],G[5:3]}, {G2:0}, B[4:0]}	
		.cmos_frame_clken		(cmos_frame_clken),	//cmos frame data output/capture enable clock
		
		//user interface
		.cmos_fps_rate			(),		//cmos image output rate
		.cmos_vsync_begin		(cmos_vsync_begin),		//cmos image output rate
		.cmos_vsync_end		(cmos_vsync_end)		//cmos image output rate
	);
	
	generate
		if(BURST_CAPABLE == 1) begin
			burst_write_master burst_write_master
			(
				 .clk(clk),
				 .reset (reset),
				 
				 .control_fixed_location(control_fixed_location),
				 .control_write_base(base_register),
				 .control_write_length (length_register),
				 .control_go(control_go),
				 .control_done(control_done),
				 
				 .user_write_clk(cmos_pclk),
				 .user_write_buffer(cmos_frame_clken & en_cap),
				 .user_buffer_data(cmos_frame_data),
				 .user_buffer_full(),
				 
				 .master_address(am_address),
				 .master_write(am_write),
				 .master_byteenable(),
				 .master_writedata(am_writedata),
				 .master_burstcount(am_burstcount),
				 .master_waitrequest(am_waitrequest)
			);
			defparam burst_write_master.DATAWIDTH = DATAWIDTH;
			defparam burst_write_master.MAXBURSTCOUNT = MAXBURSTCOUNT;
			defparam burst_write_master.BURSTCOUNTWIDTH = BURSTCOUNTWIDTH;
			defparam burst_write_master.BYTEENABLEWIDTH = DATAWIDTH/8;
			defparam burst_write_master.ADDRESSWIDTH = ADDRESSWIDTH;
			defparam burst_write_master.FIFODEPTH = FIFODEPTH;
			defparam burst_write_master.FIFODEPTH_LOG2 = FIFODEPTH_LOG2;
			defparam burst_write_master.FIFOUSEMEMORY = FIFOUSEMEMORY;
		end
		else begin
			write_master write_master
			(
				 .clk(clk),
				 .reset (reset),
				 
				 .control_fixed_location(control_fixed_location),
				 .control_write_base(base_register),
				 .control_write_length (length_register),
				 .control_go(control_go),
				 .control_done(control_done),
				 
				 .user_write_clk(cmos_pclk),
				 .user_write_buffer(cmos_frame_clken & en_cap),
				 .user_buffer_data(cmos_frame_data),
				 .user_buffer_full(),
				 
				 .master_address(am_address),
				 .master_write(am_write),
				 .master_byteenable(),
				 .master_writedata(am_writedata),
				 .master_waitrequest(am_waitrequest)
			);
			defparam write_master.DATAWIDTH = DATAWIDTH;
			defparam write_master.BYTEENABLEWIDTH = DATAWIDTH/8;
			defparam write_master.ADDRESSWIDTH = ADDRESSWIDTH;
			defparam write_master.FIFODEPTH = FIFODEPTH;
			defparam write_master.FIFODEPTH_LOG2 = FIFODEPTH_LOG2;
			defparam write_master.FIFOUSEMEMORY = FIFOUSEMEMORY;
		end
	endgenerate
	
endmodule

