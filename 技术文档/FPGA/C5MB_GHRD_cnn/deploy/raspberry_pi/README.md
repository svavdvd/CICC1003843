# 树莓派部署包

树莓派只执行 Linux 能完成的工作：MVS 工业相机采集、USB 报警器、USB 气泵
串口和机械臂 UART。它不再根据类别自行决定左右，动作完全来自 C5MB PL 返回
的 `action`。

## 安装

```sh
chmod +x install_pi.sh
sudo ./install_pi.sh
```

脚本会先生成 `.before_pl` 备份，然后更新：

```text
/opt/MVS/Samples/aarch64/Python/GrabImage/api.py
/opt/MVS/Samples/aarch64/Python/GrabImage/pl_dispatch.py
/home/jetson/Desktop/api.py
```

## 无动作联调

首次上电先在两处 `config.ini` 设置：

```ini
[arm_hardware]
dry_run = true
```

然后检查：

```sh
curl http://127.0.0.1:8899/health
curl http://172.16.68.110:8082/health
```

此模式会走完图片上传、PL 决策、机械臂事件和 ACK，但不会驱动舵机或气泵。
确认网络链路后再改回 `false` 并重启 `pl-arm-control.service`。

## 实物校准

- `/dev/BAOJING`：报警器 USB 串口。
- `/dev/XIPAN`：气泵继电器 USB 串口。
- 机械臂通过树莓派 UART 扩展板，由 `Arm_Lib` 访问。
- `arm_positions` 中 `left_*` 与 `right_*` 是两组可现场修改的舵机角度。

先空载、低速分别验证左右轨迹，再安装吸盘并放置铝片。若只是正常/缺陷规则
反了，应修改 C5MB 的 `pl_swap_sides`；若机械臂物理方向与命名相反，应交换
树莓派 `left_*` 和 `right_*` 两组角度。

动作流程为：PL 决策 -> 报警（仅缺陷）-> 机械臂取料 -> 气泵吸取 -> 左/右
放料 -> 气泵释放 -> 树莓派 ACK。任何超时或串口异常都会发送失败 ACK，PL
保持并报警，不会擅自执行下一件。

## 当前动作耗时

默认 `time=4`、`speed=1300` 时，从 PL 返回识别结果开始计算：

| 阶段 | 约用时 |
| --- | ---: |
| 吸盘开启 | 7.0 秒 |
| 铝片抬起 | 8.4 秒 |
| 缺陷品左侧释放 | 11.4 秒 |
| 缺陷流程回原位 | 15.0 秒 |
| 正常流程回原位 | 16.4 秒 |

以上不含相机曝光、JPEG 上传和 FPGA 推理时间。`time=4` 是动态铝片从相机
检测位置运动到吸取位置的补偿量；现场应按输送速度和两点距离校准。
`GET /events/<event_id>` 返回 `started_at`、`finished_at`，两者相减可得到实板
整条机械臂轨迹的实际耗时。
