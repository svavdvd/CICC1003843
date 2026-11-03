# C5MB HPS 部署包

## 为什么使用网关

FPGA TF 卡中的官方 `ssd_detection` 已经能加载 `nnadrv.ko`、Paddle Lite 和
NNA/CNN IP。直接重编完整推理程序会遇到旧 Ubuntu 16.04 的 C++ ABI 冲突，
因此本包保留官方推理服务：

- `127.0.0.1:8080`：官方 `ssd_detection`，负责 JPEG 解码和 FPGA 加速推理。
- `0.0.0.0:8082`：`pl_sort_gateway`，负责转发图片、写 PL 分拣寄存器和 ACK。

网关是 ARMv7 hard-float ELF32，只依赖 glibc、libstdc++ 和 pthread；已使用
Quartus SoC EDS GCC 4.8 编译，最高要求 `GLIBC_2.4`、`GLIBCXX_3.4.19`。

## 安装

1. 将 `output_files/C5MB_top.rbf` 放到 FPGA TF 卡 FAT 启动分区根目录，并改名
   为 `soc_system.rbf`。先备份卡上的原文件。
2. 把本目录复制到 FPGA TF 卡 Linux 根文件系统的临时目录。
3. 在 C5MB HPS 上运行：

```sh
chmod +x install_hps.sh
sudo ./install_hps.sh
sudo reboot
```

安装脚本会把训练模型放到官方程序要求的路径：

```text
/opt/ssd_detection_demo/ssd_mobilenet_v1/ssd_mobilenet_v1_opt.nb
/opt/ssd_detection_demo/labels/label_list
```

## 检查

```sh
systemctl status detect.service --no-pager
systemctl status pl-sort-gateway.service --no-pager
curl http://127.0.0.1:8082/health
```

PL 地址必须为：CNN `0xFF200000`，分拣 IP `0xFF200800`，SYSID
`0xFF200C00`。`/health` 中 `pl_fault` 应为 0。

## 左右规则

`gateway.ini` 默认：

```ini
pl_swap_sides=false
```

即缺陷品向左、正常品向右。若现场规则确认相反，改为 `true` 后执行：

```sh
sudo systemctl restart pl-sort-gateway.service
```

不需要重新编译 Quartus。

默认 `pl_watchdog_ms=85000`，树莓派 `action_timeout_seconds=60`。PL 的 50 MHz、
32 位计数器上限约为 85.9 秒；若调整动作或 ACK 超时，必须保证 PL 看门狗大于
动作时间和 ACK 重试总时间。

若 `/ack` 失败，PL 会进入故障保持状态；排除机械臂
或串口问题后，可用 `POST /reset` 或重启网关清除。

`ssd_detection_pl.cc` 是完整重编官方推理服务的参考实现，不是本镜像的推荐
部署路径。
