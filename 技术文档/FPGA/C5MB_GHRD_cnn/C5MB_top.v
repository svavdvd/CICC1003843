module C5MB_top(
    input              FPGA_CLK1_50,

    output   [14: 0]   HPS_DDR3_ADDR,
    output   [ 2: 0]   HPS_DDR3_BA,
    output             HPS_DDR3_CAS_n,
    output   [ 0: 0]   HPS_DDR3_CKE,
    output             HPS_DDR3_CK_n,
    output             HPS_DDR3_CK_p,
    output   [ 0: 0]   HPS_DDR3_CS_n,
    output   [ 3: 0]   HPS_DDR3_DM,
    inout    [31: 0]   HPS_DDR3_DQ,
    inout    [ 3: 0]   HPS_DDR3_DQS_n,
    inout    [ 3: 0]   HPS_DDR3_DQS_p,
    output   [ 0: 0]   HPS_DDR3_ODT,
    output             HPS_DDR3_RAS_n,
    output             HPS_DDR3_RESET_n,
    input              HPS_DDR3_RZQ,
    output             HPS_DDR3_WE_n,
    output             HPS_ENET_GTX_CLK,
    inout              HPS_ENET_INT_n,
    output             HPS_ENET_MDC,
    inout              HPS_ENET_MDIO,
    input              HPS_ENET_RX_CLK,
    input    [ 3: 0]   HPS_ENET_RX_DATA,
    input              HPS_ENET_RX_DV,
    output   [ 3: 0]   HPS_ENET_TX_DATA,
    output             HPS_ENET_TX_EN,    

    inout              HPS_EMMC_SEL,
    output             HPS_SDMMC_CLK,
    inout              HPS_SDMMC_CMD,

    inout    [ 7: 0]   HPS_SDMMC_DATA,
    output             HPS_EMMC_RST_n,

    input              HPS_UART_RX,
    output             HPS_UART_TX,

    input              HPS_USB_CLKOUT,
    inout    [ 7: 0]   HPS_USB_DATA,
    input              HPS_USB_DIR,
    input              HPS_USB_NXT,
    output             HPS_USB_STP,
	 
	 //cmos
    inout              cmos_sclk,
    inout              cmos_sdat,
    input              cmos_vsync,
    input              cmos_href,
    input              cmos_pclk,
    output             cmos_xclk,
    input    [7:0]     cmos_data,
    output             cmos_rst_n,
    output             cmos_pwdn
);

wire hps_fpga_reset_n;

wire fpga_clk_24;
wire locked;
pll_tv pll_tv_inst (
    .refclk           (FPGA_CLK1_50),
    .rst              (~hps_fpga_reset_n),
    .outclk_0         (fpga_clk_24),
    .locked           (locked)
);

reg                    rst_i2c;
always@ (posedge FPGA_CLK1_50 or negedge cmos_rst_n)
begin	
    if (cmos_rst_n==1'b0)
        rst_i2c<=1'b1;
    else
        rst_i2c<=1'b0;
end

wire         [9:0]     lut_index;
wire         [31:0]    lut_data;
//configure look-up table
lut_ov5640_rgb565_1024_768 lut_ov5640_rgb565_1024_768_m0(
    .lut_index                  (lut_index                ),
    .lut_data                   (lut_data                 )
);

i2c_config i2c_config_0(
    .rst                        (rst_i2c                  ),
    .clk                        (FPGA_CLK1_50              ),
    .clk_div_cnt                (16'd500                  ),
    .i2c_addr_2byte             (1'b1                     ),
    .lut_index                  (lut_index                ),
    .lut_dev_addr               (lut_data[31:24]          ),
    .lut_reg_addr               (lut_data[23:8]           ),
    .lut_reg_data               (lut_data[7:0]            ),
    .error                      (                         ),
    .done                       (                         ),
    .i2c_scl                    (cmos_sclk                ),
    .i2c_sda                    (cmos_sdat                )
);

soc_system u0 (
    .clk_clk                                                    (FPGA_CLK1_50           ),
    .reset_reset_n                                              (hps_fpga_reset_n       ),
    .memory_mem_a                                               (HPS_DDR3_ADDR          ),
    .memory_mem_ba                                              (HPS_DDR3_BA            ),
    .memory_mem_ck                                              (HPS_DDR3_CK_p          ),
    .memory_mem_ck_n                                            (HPS_DDR3_CK_n          ),
    .memory_mem_cke                                             (HPS_DDR3_CKE           ),
    .memory_mem_cs_n                                            (HPS_DDR3_CS_n          ),
    .memory_mem_ras_n                                           (HPS_DDR3_RAS_n         ),
    .memory_mem_cas_n                                           (HPS_DDR3_CAS_n         ),
    .memory_mem_we_n                                            (HPS_DDR3_WE_n          ),
    .memory_mem_reset_n                                         (HPS_DDR3_RESET_n       ),
    .memory_mem_dq                                              (HPS_DDR3_DQ            ),
    .memory_mem_dqs                                             (HPS_DDR3_DQS_p         ),
    .memory_mem_dqs_n                                           (HPS_DDR3_DQS_n         ),
    .memory_mem_odt                                             (HPS_DDR3_ODT           ),
    .memory_mem_dm                                              (HPS_DDR3_DM            ),
    .memory_oct_rzqin                                           (HPS_DDR3_RZQ           ),
    .hps_0_hps_io_hps_io_emac1_inst_TX_CLK                      (HPS_ENET_GTX_CLK       ),
    .hps_0_hps_io_hps_io_emac1_inst_TXD0                        (HPS_ENET_TX_DATA[0]    ),
    .hps_0_hps_io_hps_io_emac1_inst_TXD1                        (HPS_ENET_TX_DATA[1]    ),
    .hps_0_hps_io_hps_io_emac1_inst_TXD2                        (HPS_ENET_TX_DATA[2]    ),
    .hps_0_hps_io_hps_io_emac1_inst_TXD3                        (HPS_ENET_TX_DATA[3]    ),
    .hps_0_hps_io_hps_io_emac1_inst_RXD0                        (HPS_ENET_RX_DATA[0]    ),
    .hps_0_hps_io_hps_io_emac1_inst_MDIO                        (HPS_ENET_MDIO          ),
    .hps_0_hps_io_hps_io_emac1_inst_MDC                         (HPS_ENET_MDC           ),
    .hps_0_hps_io_hps_io_emac1_inst_RX_CTL                      (HPS_ENET_RX_DV         ),
    .hps_0_hps_io_hps_io_emac1_inst_TX_CTL                      (HPS_ENET_TX_EN         ),
    .hps_0_hps_io_hps_io_emac1_inst_RX_CLK                      (HPS_ENET_RX_CLK        ),
    .hps_0_hps_io_hps_io_emac1_inst_RXD1                        (HPS_ENET_RX_DATA[1]    ),
    .hps_0_hps_io_hps_io_emac1_inst_RXD2                        (HPS_ENET_RX_DATA[2]    ),
    .hps_0_hps_io_hps_io_emac1_inst_RXD3                        (HPS_ENET_RX_DATA[3]    ),
    .hps_0_hps_io_hps_io_sdio_inst_CMD                          (HPS_SDMMC_CMD          ),
    .hps_0_hps_io_hps_io_sdio_inst_D0                           (HPS_SDMMC_DATA[0]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D1                           (HPS_SDMMC_DATA[1]      ),
    .hps_0_hps_io_hps_io_sdio_inst_CLK                          (HPS_SDMMC_CLK          ),
    .hps_0_hps_io_hps_io_sdio_inst_D2                           (HPS_SDMMC_DATA[2]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D3                           (HPS_SDMMC_DATA[3]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D4                           (HPS_SDMMC_DATA[4]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D5                           (HPS_SDMMC_DATA[5]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D6                           (HPS_SDMMC_DATA[6]      ),
    .hps_0_hps_io_hps_io_sdio_inst_D7                           (HPS_SDMMC_DATA[7]      ),
    .hps_0_hps_io_hps_io_sdio_inst_PWREN                        (HPS_EMMC_RST_n         ),
    .hps_0_hps_io_hps_io_usb1_inst_D0                           (HPS_USB_DATA[0]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D1                           (HPS_USB_DATA[1]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D2                           (HPS_USB_DATA[2]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D3                           (HPS_USB_DATA[3]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D4                           (HPS_USB_DATA[4]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D5                           (HPS_USB_DATA[5]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D6                           (HPS_USB_DATA[6]        ),
    .hps_0_hps_io_hps_io_usb1_inst_D7                           (HPS_USB_DATA[7]        ),
    .hps_0_hps_io_hps_io_usb1_inst_CLK                          (HPS_USB_CLKOUT         ),
    .hps_0_hps_io_hps_io_usb1_inst_STP                          (HPS_USB_STP            ),
    .hps_0_hps_io_hps_io_usb1_inst_DIR                          (HPS_USB_DIR            ),
    .hps_0_hps_io_hps_io_usb1_inst_NXT                          (HPS_USB_NXT            ),
    .hps_0_hps_io_hps_io_uart0_inst_RX                          (HPS_UART_RX            ),
    .hps_0_hps_io_hps_io_uart0_inst_TX                          (HPS_UART_TX            ),
    .hps_0_hps_io_hps_io_gpio_inst_GPIO35                       (HPS_ENET_INT_n         ),
    .hps_0_hps_io_hps_io_gpio_inst_GPIO44                       (HPS_EMMC_SEL           ),
    .hps_0_h2f_reset_reset_n                                    (hps_fpga_reset_n       ),
    .hps_0_f2h_cold_reset_req_reset_n                           (1'b1                   ),
    .hps_0_f2h_debug_reset_req_reset_n                          (1'b1                   ),
    .hps_0_f2h_warm_reset_req_reset_n                           (1'b1                   ),
	.clock_bridge_24_in_clk_clk            							 (fpga_clk_24				 ),
    .dvp_cap_0_wire_cmos_pclk              							 (cmos_pclk					 ),
    .dvp_cap_0_wire_cmos_xclk              							 (cmos_xclk					 ),
    .dvp_cap_0_wire_cmos_vsync             							 (~cmos_vsync				 ),
    .dvp_cap_0_wire_cmos_href              							 (cmos_href					 ),
    .dvp_cap_0_wire_cmos_din               							 (cmos_data					 ),
    .dvp_cap_0_wire_cmos_pwdn              							 (cmos_pwdn					 ),
    .dvp_cap_0_wire_cmos_rst_n             							 (cmos_rst_n				 )
);
endmodule


