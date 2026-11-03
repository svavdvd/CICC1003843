module C5MB_net_top (
    input              FPGA_CLK1_50,

    output   [14:0]    HPS_DDR3_ADDR,
    output   [2:0]     HPS_DDR3_BA,
    output             HPS_DDR3_CAS_n,
    output   [0:0]     HPS_DDR3_CKE,
    output             HPS_DDR3_CK_n,
    output             HPS_DDR3_CK_p,
    output   [0:0]     HPS_DDR3_CS_n,
    output   [3:0]     HPS_DDR3_DM,
    inout    [31:0]    HPS_DDR3_DQ,
    inout    [3:0]     HPS_DDR3_DQS_n,
    inout    [3:0]     HPS_DDR3_DQS_p,
    output   [0:0]     HPS_DDR3_ODT,
    output             HPS_DDR3_RAS_n,
    output             HPS_DDR3_RESET_n,
    input              HPS_DDR3_RZQ,
    output             HPS_DDR3_WE_n,

    output             HPS_ENET_GTX_CLK,
    inout              HPS_ENET_INT_n,
    output             HPS_ENET_MDC,
    inout              HPS_ENET_MDIO,
    input              HPS_ENET_RX_CLK,
    input    [3:0]     HPS_ENET_RX_DATA,
    input              HPS_ENET_RX_DV,
    output   [3:0]     HPS_ENET_TX_DATA,
    output             HPS_ENET_TX_EN,

    inout              HPS_EMMC_SEL,
    output             HPS_SDMMC_CLK,
    inout              HPS_SDMMC_CMD,
    inout    [7:0]     HPS_SDMMC_DATA,
    output             HPS_EMMC_RST_n


);

wire hps_fpga_reset_n;

soc_system u0 (
    .clk_clk                                                    (FPGA_CLK1_50),
    .reset_reset_n                                              (hps_fpga_reset_n),
    .memory_mem_a                                               (HPS_DDR3_ADDR),
    .memory_mem_ba                                              (HPS_DDR3_BA),
    .memory_mem_ck                                              (HPS_DDR3_CK_p),
    .memory_mem_ck_n                                            (HPS_DDR3_CK_n),
    .memory_mem_cke                                             (HPS_DDR3_CKE),
    .memory_mem_cs_n                                            (HPS_DDR3_CS_n),
    .memory_mem_ras_n                                           (HPS_DDR3_RAS_n),
    .memory_mem_cas_n                                           (HPS_DDR3_CAS_n),
    .memory_mem_we_n                                            (HPS_DDR3_WE_n),
    .memory_mem_reset_n                                         (HPS_DDR3_RESET_n),
    .memory_mem_dq                                              (HPS_DDR3_DQ),
    .memory_mem_dqs                                             (HPS_DDR3_DQS_p),
    .memory_mem_dqs_n                                           (HPS_DDR3_DQS_n),
    .memory_mem_odt                                             (HPS_DDR3_ODT),
    .memory_mem_dm                                              (HPS_DDR3_DM),
    .memory_oct_rzqin                                           (HPS_DDR3_RZQ),

    .hps_0_hps_io_hps_io_emac1_inst_TX_CLK                      (HPS_ENET_GTX_CLK),
    .hps_0_hps_io_hps_io_emac1_inst_TXD0                        (HPS_ENET_TX_DATA[0]),
    .hps_0_hps_io_hps_io_emac1_inst_TXD1                        (HPS_ENET_TX_DATA[1]),
    .hps_0_hps_io_hps_io_emac1_inst_TXD2                        (HPS_ENET_TX_DATA[2]),
    .hps_0_hps_io_hps_io_emac1_inst_TXD3                        (HPS_ENET_TX_DATA[3]),
    .hps_0_hps_io_hps_io_emac1_inst_RXD0                        (HPS_ENET_RX_DATA[0]),
    .hps_0_hps_io_hps_io_emac1_inst_RXD1                        (HPS_ENET_RX_DATA[1]),
    .hps_0_hps_io_hps_io_emac1_inst_RXD2                        (HPS_ENET_RX_DATA[2]),
    .hps_0_hps_io_hps_io_emac1_inst_RXD3                        (HPS_ENET_RX_DATA[3]),
    .hps_0_hps_io_hps_io_emac1_inst_MDIO                        (HPS_ENET_MDIO),
    .hps_0_hps_io_hps_io_emac1_inst_MDC                         (HPS_ENET_MDC),
    .hps_0_hps_io_hps_io_emac1_inst_RX_CTL                      (HPS_ENET_RX_DV),
    .hps_0_hps_io_hps_io_emac1_inst_TX_CTL                      (HPS_ENET_TX_EN),
    .hps_0_hps_io_hps_io_emac1_inst_RX_CLK                      (HPS_ENET_RX_CLK),

    .hps_0_hps_io_hps_io_sdio_inst_CMD                          (HPS_SDMMC_CMD),
    .hps_0_hps_io_hps_io_sdio_inst_D0                           (HPS_SDMMC_DATA[0]),
    .hps_0_hps_io_hps_io_sdio_inst_D1                           (HPS_SDMMC_DATA[1]),
    .hps_0_hps_io_hps_io_sdio_inst_D2                           (HPS_SDMMC_DATA[2]),
    .hps_0_hps_io_hps_io_sdio_inst_D3                           (HPS_SDMMC_DATA[3]),
    .hps_0_hps_io_hps_io_sdio_inst_D4                           (HPS_SDMMC_DATA[4]),
    .hps_0_hps_io_hps_io_sdio_inst_D5                           (HPS_SDMMC_DATA[5]),
    .hps_0_hps_io_hps_io_sdio_inst_D6                           (HPS_SDMMC_DATA[6]),
    .hps_0_hps_io_hps_io_sdio_inst_D7                           (HPS_SDMMC_DATA[7]),
    .hps_0_hps_io_hps_io_sdio_inst_CLK                          (HPS_SDMMC_CLK),
    .hps_0_hps_io_hps_io_sdio_inst_PWREN                        (HPS_EMMC_RST_n),


    .hps_0_hps_io_hps_io_gpio_inst_GPIO35                       (HPS_ENET_INT_n),
    .hps_0_hps_io_hps_io_gpio_inst_GPIO44                       (HPS_EMMC_SEL),
    .hps_0_h2f_reset_reset_n                                    (hps_fpga_reset_n),
    .hps_0_f2h_cold_reset_req_reset_n                           (1'b1),
    .hps_0_f2h_debug_reset_req_reset_n                          (1'b1),
    .hps_0_f2h_warm_reset_req_reset_n                           (1'b1)
);

endmodule
