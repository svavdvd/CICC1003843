# 集创赛 · 金属缺陷检测与自动分拣（CICC 1003843）

第十届集成电路创新创业大赛参赛工程：在铝片输送线上用工业相机拍照，由 FPGA（Intel Cyclone V SoC）
加速的 SSD 目标检测识别 5 类表面缺陷，再由 PL 逻辑做出分拣决策，树莓派驱动机械臂与气泵把工件分到左右两侧。

本仓库只收录**文档、源码与工程配置**；板卡镜像、模型权重、Quartus 构建产物等大文件未纳入版本管理，
原因与去向见文末「未纳入仓库的大文件」。

## 系统组成

```text
工业相机 --USB--> 树莓派 (MVS SDK, 172.16.68.111)
    --以太网/JPEG--> C5MB HPS (ARM Linux, 172.16.68.110)
    --Paddle Lite / NNA--> FPGA PL 中的 CNN 加速器
    --候选框--> PL sort_control 分拣状态机
    --JSON(action/alarm)--> 树莓派 --UART--> 机械臂，--USB串口--> 气泵/报警器
    --ACK--> HPS --> PL（闭环确认）
```

- **FPGA 板**：Intel Cyclone V SoC `5CSEBA6U23I7`，Quartus 18.1 / Platform Designer，Verilog 实现
  CNN 加速器、分拣状态机、DVP 相机采集与 OV5640 的 I2C 配置
- **算法**：PaddlePaddle 2.1.2 + PaddleDetection 2.2（SSD-MobileNet-V1），PaddleSlim 量化感知训练，
  导出为 Paddle Lite `intel_fpga,arm` 模型
- **树莓派**：相机采集、机械臂/气泵/报警器驱动

缺陷类别（顺序固定）：`ca_shang` 划痕、`zang_wu` 脏污、`zhe_zhou` 褶皱、`zhen_kong` 针孔 → 判 NG 分左；
`zheng_chang` 正常 → 判 OK 分右。

## 目录说明

| 路径 | 内容 |
| --- | --- |
| `第十届集创赛PPT.pptx` | 参赛答辩 PPT |
| `第十届集创赛技术文档.docx` | 技术文档（方案、实现、测试） |
| `项目新手学习笔记.md` | 零基础入门笔记，用类比讲清整个系统怎么串起来 |
| `技术文档/FPGA/C5MB_GHRD_cnn/` | Quartus 工程：`C5MB_top.qpf/qsf` 顶层、`src/` Verilog 源码、`ip/` CNN IP、`deploy/` HPS 与树莓派侧源码与构建脚本、`scripts/` 生成与配置脚本 |
| `技术文档/FPGA/output_files/` | 已排除（构建产物） |
| `技术文档/model/` | 训练说明与训练曲线；权重与数据集已排除 |

## 关键地址（HPS 侧访问 PL 寄存器）

| 模块 | 物理地址 | 范围 |
| --- | --- | --- |
| CNN / NNA | `0xFF200000` | `0x400` |
| PL 分拣控制 | `0xFF200800` | `0x100` |
| SYSID | `0xFF200C00` | `0x8` |

网络服务：官方推理 `127.0.0.1:8080/predict`；PL 网关 `172.16.68.110:8082/predict`、`/ack`、`/health`、`/reset`。

## 构建与运行

1. **FPGA**：Quartus 18.1 打开 `技术文档/FPGA/C5MB_GHRD_cnn/C5MB_top.qpf`，全编译生成 `.sof`；
   器件与引脚约束仅适用于赛方 C5MB 板，换板需重建顶层与 QSF。
2. **HPS 侧**：`deploy/fpga_hps/build.sh` 交叉编译 ARM32 网关闭环程序，部署到板卡后随镜像启动。
3. **树莓派**：`deploy/raspberry_pi/` 下的脚本负责相机触发与动作执行。

更多细节见 `技术文档/FPGA/C5MB_GHRD_cnn/README_AI.md` 与 `CARD_INTEGRATION.md`。

## 未纳入仓库的大文件

以下文件仍保留在原始工程目录 `G:\CICC1003843+皓耀` 与开发机上，不进 Git（单文件超 100 MB 会被 GitHub 拒收）：

| 内容 | 大小 | 原因 |
| --- | --- | --- |
| `技术文档/镜像文件/` | ≈3.7 GB | 板卡启动镜像的根文件系统，含 1.5 GB 与 1.1 GB 的 Paddle 静态库 |
| `技术文档/model/output/`、`isdd-dataset-voc/` | ≈230 MB | 训练权重与数据集，可由训练流程重新生成 |
| `技术文档/FPGA/C5MB_GHRD_cnn/db|incremental_db|output_files|simulation/` | ≈190 MB | Quartus 与 ModelSim 中间产物 |
| `deploy/fpga_hps/lib/*.so`、`model/parameters.bin` | ≈76 MB | OpenCV 动态库与模型参数，属运行时产物 |
