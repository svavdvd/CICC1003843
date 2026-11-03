# C5MB PL 视觉推理与分拣工程

本目录是赛方 `C5MB_GHRD` 的独立工作副本，目标器件为
`5CSEBA6U23I7`。原工程未覆盖，比赛时使用两张独立 TF 卡；虚拟机只用于读取
和分析镜像。

`C5MB_top.qsf` 的器件与物理引脚只适用于赛方 C5MB，不适用于 DE10-Nano
或旧 C5TB；其他开发板必须建立独立顶层、QSF 和启动镜像。

## 系统边界

```text
工业相机 --USB--> 树莓派 MVS
树莓派 172.16.68.111 --以太网/JPEG--> C5MB HPS 172.16.68.110
C5MB HPS --Paddle/NNA--> PL CNN --候选框--> PL sort_control
PL action/alarm --以太网/JSON--> 树莓派
树莓派 --UART--> 机械臂，--USB串口--> 气泵和报警器
树莓派 --ACK--> HPS --> PL
```

FPGA 与树莓派之间只有以太网。工业相机、机械臂、气泵和报警器需要 Linux
设备驱动，不能只靠 Quartus 文件完成。

## 已实现

| 层 | 实现 |
| --- | --- |
| PL | 70 MHz `cnn_top.qxp`、128 位 F2SDRAM、Avalon 分拣状态机、阈值、看门狗、事件 ACK、左右互换 |
| HPS | 保留镜像官方 Paddle/NNA 推理服务，新增 ARM32 `pl_sort_gateway` |
| 树莓派 | 保留 MVS 动态铝片触发，新增 PL 动作执行、报警、气泵、机械臂事件状态和 ACK |
| 安全 | `HOLD` 不动作；执行失败进入 PL 故障保持；树莓派支持 `dry_run` |

## Qsys 地址

以下为轻量 HPS-to-FPGA 桥的物理地址：

| 模块 | 地址 | 范围 |
| --- | --- | --- |
| CNN/NNA | `0xFF200000` | `0x400` |
| PL 分拣控制 | `0xFF200800` | `0x100` |
| SYSID | `0xFF200C00` | `0x8` |

生成的 `hps_0.h` 使用相对 `0xFF200000` 的偏移 `0x000/0x800/0xC00`。
卡内官方 NNA SDK 固定访问 CNN `0xFF200000`，因此不能恢复旧地址
`0xFF200400`。

## 网络服务

- C5MB 官方推理：`127.0.0.1:8080/predict`。
- C5MB PL 网关：`172.16.68.110:8082/predict`、`/ack`、`/health`、`/reset`。
- 树莓派机械臂：`127.0.0.1:8899/grab`、`/events/<id>`、`/health`。

`/predict` 保留官方 `len/result`，并增加 `event_id`、`decision`、`action`、
`alarm`、`pl_status` 和 `pl_fault`。

## 左右规则

默认 `gateway.ini` 中 `pl_swap_sides=false`：缺陷左、正常右。若比赛规则确认
相反，改为 `true` 并重启 HPS 网关，不需要重新编译 Quartus。机械臂物理左右
轨迹在树莓派 `config.ini` 的 `arm_positions` 中现场校准。

## 构建结果

- Quartus 18.1 全编译：PASS，0 errors / 388 warnings；SOF、RBF 生成成功。
- ModelSim `sort_control_tb`：PASS，0 error / 0 warning。
- ARM32 HPS 网关：ELF32 ARM hard-float，最高 `GLIBC_2.4`、
  `GLIBCXX_3.4.19`。
- Python：语法检查通过，PL 调度 3 个单元测试通过。
- TimeQuest 复核：setup/hold fully constrained；四工况最差 setup `+0.991 ns`、
  hold `+0.069 ns`，未约束端口和路径均为 0。
- 资源：16,001 / 41,910 ALM（38%），1,255,308 / 5,662,720 RAM bit
  （22%），87 / 112 DSP（78%），26,830 registers。
- 仍保留 Quartus 18.1 生成的 HPS DDR/EMAC SDC 匹配与不确定度警告；
  DDR、TF 启动和网口必须在 C5MB 实板上验证。

最终文件：

```text
output_files/C5MB_top.sof  SHA256=7C1DEB8CAD2EDE60366B73CB81A7634F2DA003C02F936B986F439E1ED5295C88
output_files/C5MB_top.rbf  SHA256=05923578E0B73B349AD4C3448A3EEC1710C419D703662015AAEB4D171B153BB9
deploy/fpga_hps/pl_sort_gateway  SHA256=8290FE3AE2DAD96ABC9704FCA5BB9A58BB21F49A0721896C19974A0FF12471BC
app/ai_inference/model/ssd_mobilenet_v1_op.nb  SHA256=C3EA619EDD5E49C135BA187099F7A2E010F53231C269CB377FBAAC3F481BFA07
```

## 入口文件

- `C5MB_top.qpf`：Quartus 工程。
- `C5MB_net_top.v`：仅保留 HPS DDR、EMAC 和必要系统引脚的顶层。
- `soc_system.qsys`：HPS、CNN、DDR 桥和分拣 IP。
- `ip/sort_control/sort_control.v`：PL 决策与闭环状态机。
- `deploy/fpga_hps/README.md`：FPGA TF 卡部署。
- `deploy/raspberry_pi/README.md`：树莓派 TF 卡部署。
- `现场40分钟检查清单.md`：实板联调顺序。

软件和位流已完成离线编译验证，但工业相机曝光、运动触发阈值、吸取高度、
左右舵机角度以及真实串口设备必须在实物上校准，不能在虚拟机中宣称完成。
