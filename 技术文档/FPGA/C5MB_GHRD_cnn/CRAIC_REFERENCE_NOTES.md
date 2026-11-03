# CRAIC 旧赛题参考结论

参考目录：

`C:\Users\Administrator\Desktop\fpga\CRAIC-master\CRAIC\厂商资料\defect-detection-master`

## 已采用

1. **Paddle SSD 三输入协议**

   输入为 `im_shape`、`image`、`scale_factor`。图像张量是
   `1x3x300x300 NCHW`，归一化参数为 `127.5/127.502231`。

2. **HPS `/predict` 接口协议**

   CRAIC 的 C++ 程序使用 `cpp-httplib` 接收 multipart 字段
   `image_file`，路径是 `POST /predict`，端口是 `8080`。返回格式为：

   ```json
   {"len":1,"result":[{"class_name":"zhen_kong","score":0.82,"loc":[1,2,3,4],"prediction_time":35.2}]}
   ```

   该格式与已分析的官方树莓派镜像调用完全一致，因此
   `app/ai_inference/predict_server.cpp` 沿用该协议并补充了上传大小、空文件、
   解码失败、类别越界和输出张量检查。

3. **工件门控思路**

   DVP 直接模式保留空场背景校准、灰度背景差分、进入/离开双阈值和连续帧消抖，
   避免把空输送带误判为合格品。

4. **OpenCV 3.4.10 ARM 运行库**

   `/predict` 源码使用 CRAIC 中与官方旧 C5MB 镜像一致的 OpenCV 3.4.10
   头文件和三个最小共享库。许可证保存在
   `app/ai_inference/vendor/opencv_c5mb/licenses`。

## 数据集解决的问题

`isdd-dataset-voc.zip` 已给出原始 `label_list.txt`，类别编号不再需要猜测：

| ID | 类别 | 分拣 |
| --- | --- | --- |
| 0 | `ca_shang` | NG / 左 |
| 1 | `zang_wu` | NG / 左 |
| 2 | `zhe_zhou` | NG / 左 |
| 3 | `zhen_kong` | NG / 左 |
| 4 | `zheng_chang` | OK / 右 |

直接 DVP 模式采用缺陷优先，阈值为 0/1/2/4 类 `0.70`、3 类 `0.20`。

## 未采用

- 不复制 CRAIC 的机械臂姿态常量；安装位置不同，必须实板标定。
- 不混用 `nnadrv.ko + libifcnna.so` 与当前
  `cnn_top.qxp + libvnna.so + cmadrv.ko`。
- 不把 CRAIC 的 BGR/RGB 行为当作已验证结论；官方 MVS 上传的是灰度 JPEG，
  DVP 彩色链路仍需上板检查。
- 不生成或部署树莓派程序。旧镜像代码仅用于确认协议，等实板到手再处理。

## 尚未完成

`/predict` 源码可以用 Vitis GCC 9 编译，但该产物超过旧镜像的 C++ 运行库版本；
Intel SoC EDS GCC 4.8 又不能链接 Paddle 的 `std::__cxx11` ABI。按当前决定，
运行库适配留到实际 C5MB 镜像到手后继续，详见
`app/ai_inference/HPS_BUILD_STATUS.md`。
