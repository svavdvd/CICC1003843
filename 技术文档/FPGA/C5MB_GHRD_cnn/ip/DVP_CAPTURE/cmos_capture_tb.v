module cmos_capture_tb;

	//range : 8, 16, 32, 64, 128, 256, 512, 1024 
	parameter DATAWIDTH = 32;
	//range: 1, 2, 4, 8, 16, 32, 64, 128
	parameter BYTEENABLEWIDTH = 2;
	parameter ADDRESSWIDTH = 32;
	//FIFO depth of the internal buffer
	//range: 4 ,8, 16, 62, 64, 128,256,512
	parameter FIFODEPTH = 256;
	parameter FIFODEPTH_LOG2 = 8;
	parameter FIFOUSEMEMORY = 1;		// 1 to use on chip memory, 0 to use logical elements
	parameter BURST_CAPABLE = 1;							// 1 to enable burst, 0 to disable it
	parameter MAXBURSTCOUNT = 8;
	parameter BURSTCOUNTWIDTH = 4;


	reg				clk_cmos;
	
	reg				clk;
	reg				reset;
	
// mm slave
	reg						as_chipselect;
	reg						as_read;
	reg						as_write;
	wire  [31:0]			as_readdata;
	reg	[31:0]			as_writedata;
	reg	[2:0]				as_address;
	
	wire	[DATAWIDTH - 1 : 0]			am_writedata;
	wire	[ADDRESSWIDTH - 1 : 0]		am_address;
	wire	[BURSTCOUNTWIDTH - 1 : 0]	am_burstcount;
	
// mm master
	wire					am_write;
//	wire	[15:0]		am_writedata;
//	wire	[31:0]	am_address;
//	wire  [3:0]am_burstcount;
	reg						am_waitrequest;
	
//CMOS Sensor Interface
	reg				cmos_pclk;			
	wire			cmos_xclk;			
	wire				cmos_vsync;			
	wire				cmos_href;		
	reg		[7:0]	cmos_din;			
	wire			cmos_rst_n;			
	wire			cmos_pwdn; 
	
	cmos_capture
	#(
		.DATAWIDTH(DATAWIDTH),
		.BYTEENABLEWIDTH(BYTEENABLEWIDTH),
		.ADDRESSWIDTH (ADDRESSWIDTH),
		.FIFODEPTH(FIFODEPTH),
		.FIFODEPTH_LOG2(FIFODEPTH_LOG2),	
		.FIFOUSEMEMORY(FIFOUSEMEMORY),		
		.BURST_CAPABLE(BURST_CAPABLE),
		.MAXBURSTCOUNT(MAXBURSTCOUNT),
		.BURSTCOUNTWIDTH(BURSTCOUNTWIDTH)
	)
	cmos_capture(
		.clk_cmos(clk_cmos),
		.clk(clk),
		.reset_i(reset),
		.as_chipselect(as_chipselect),
		.as_read(as_read),
		.as_write(as_write),
		.as_readdata(as_readdata),
		.as_writedata(as_writedata),
		.as_address(as_address),
		.am_write(am_write),
		.am_writedata(am_writedata),
		.am_address(am_address),
		.am_burstcount(am_burstcount),
		.am_waitrequest(am_waitrequest),
		.cmos_pclk(cmos_pclk),
		.cmos_xclk(cmos_xclk),
		.cmos_vsync(cmos_vsync),
		.cmos_href(cmos_href),
		.cmos_din(cmos_din),
		.cmos_rst_n(cmos_rst_n),
		.cmos_pwdn(cmos_pwdn)
	);

	initial clk_cmos = 1;
	always #20 clk_cmos = ~clk_cmos;

	initial cmos_pclk = 1;
	always #20 cmos_pclk = ~cmos_pclk;
	
	initial clk_cmos = 1;
	always #20 clk_cmos = ~clk_cmos;

	initial clk = 1;
	always #5 clk = ~clk;
	
	
	reg en_rd;
	reg [2:0]status_reg;
	initial begin
		reset = 1;
		en_rd = 0;
		#201;
		reset = 0;
		#200;
		as_write_data(1,1140);	//写入长度，65536字节
		as_write_data(2,0);	//写入基地址：0
		#300000;
		as_write_data(0,16'h0001);	//使能捕获
		en_rd = 0;
		while(!en_rd)begin
			as_read_data(3,status_reg);
			en_rd = status_reg[0];
		end
		#30;
//		as_write_data(3,0);	//清除状态寄存器
		#300000;
		$stop;
	end
	
	initial am_waitrequest = 0;
	
	task as_write_data;
		input [2:0]address;
		input [31:0]data;
		begin
			as_chipselect = 0;
			as_write = 0;
			#10;
			as_address = address;
			as_writedata = data;
			as_chipselect = 1;
			as_write = 1;
			#10;
			as_chipselect = 0;
			as_write = 0;
			#10;
		end
	endtask
	
	task as_read_data;
		input [2:0]address;
		output [31:0]data;
		begin
			as_chipselect = 0;
			as_read = 0;
			#10;
			as_address = address;
			as_chipselect = 1;
			as_read = 1;
			#10;
			data = as_readdata;
			as_chipselect = 0;
			as_read = 0;
			#10;
		end
	endtask
	
	
	reg [5:0]hcount;
	reg [4:0]vcount;
	
	
	always@(posedge cmos_pclk or posedge reset)
	if(reset)
		hcount <= 0;
	else
		hcount <= hcount + 1'b1;
	
	always@(posedge cmos_pclk or posedge reset)
	if(reset)
		vcount <= 0;
	else if(&hcount)
		vcount <= vcount + 1'b1;
	else
		vcount <= vcount;
		
	assign cmos_vsync = (vcount < 3);
	
	assign cmos_href = (vcount > 10) && (vcount < 30) && (hcount <60);
		
	always@(posedge cmos_pclk or posedge reset)
	if(reset)
		cmos_din <= 8'd0;
	else if(cmos_href)
		cmos_din <= cmos_din + 1'b1;
	else
		cmos_din <= 8'd0;

endmodule
