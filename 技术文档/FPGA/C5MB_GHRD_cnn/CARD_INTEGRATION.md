# C5MB 与树莓派双 TF 卡集成

## 实际运行方式

- 树莓派 TF 卡运行 Debian 12，`eth0=172.16.68.111/24`。
- FPGA TF 卡运行 C5MB HPS Ubuntu，`eth0=172.16.68.110/24`。
- 两块实板只通过以太网连接；虚拟机不参与比赛运行。
- 相机、气泵、报警器接树莓派 USB；机械臂扩展板接树莓派 UART。

## FPGA TF 卡启动链

U-Boot 从 FAT 启动分区根目录加载 `soc_system.rbf`，随后执行
`bridge_enable_handoff` 并启动 Linux。`norm/`、`aocl/` 或其他名称的 RBF
不会被当前脚本自动加载。

官方 HPS 服务为：

```text
/etc/systemd/system/detect.service
/opt/ssd_detection_demo/run.sh
/opt/ssd_detection_demo/nnadrv.ko
/opt/ssd_detection_demo/ssd_detection
127.0.0.1:8080/predict
```

本工程新增 `pl-sort-gateway.service`，监听 `0.0.0.0:8082`。网关把 JPEG
转发到官方服务，随后把五类候选结果写入 PL `sort_control`，避免重编不兼容的
Paddle 运行库。

## 闭环协议

1. 树莓派 MVS 捕获铝片并向 `8082/predict` 上传 `image_file`。
2. 官方服务调用 CNN/NNA 完成 FPGA 加速推理。
3. HPS 网关写入候选类别和 Q0.16 置信度并提交 PL 事件。
4. PL 产生 `HOLD/SORT_LEFT/SORT_RIGHT` 及报警位。
5. 树莓派只执行 PL 动作，不重新按类别判断 OK/NG。
6. 机械臂归位且气泵释放后，树莓派向 HPS `/ack` 回传成功。
7. 串口、机械臂或气泵异常时回传失败；PL 锁存故障并保持。

PL 控制位 bit 3 为 `swap_sides`。默认缺陷左、正常右；设置后两者反向，报警
语义不变。

## 必需模型

安装脚本将文件部署为：

```text
/opt/ssd_detection_demo/ssd_mobilenet_v1/ssd_mobilenet_v1_opt.nb
/opt/ssd_detection_demo/labels/label_list
```

标签顺序必须为：`ca_shang,zang_wu,zhe_zhou,zhen_kong,zheng_chang`。

## 首次联调原则

先启用树莓派 `dry_run=true`，验证网络、推理、PL 决策和 ACK；再空载低速验证
左右轨迹；最后才连接吸盘并放置工件。完整步骤见各部署目录 README 和现场
检查清单。
