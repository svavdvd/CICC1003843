# Pure CNN model compiler

This directory converts a Paddle QAT SSD-MobileNet inference export into the
binary layout consumed by `ip/pure_cnn_accel.v`.

Input files must be the inference export (`model.pdmodel` and
`model.pdiparams`), not a training checkpoint and not only a Paddle Lite `.nb`
file. Replacing a model does not normally require rebuilding the Quartus image.

```powershell
python compile_paddle_ssd.py `
  --model path\to\model.pdmodel `
  --params path\to\model.pdiparams `
  --labels path\to\labels.txt `
  --output path\to\pure_cnn_model
```

The compiler fuses convolution, batch normalization and ReLU/ReLU6, performs
per-output-channel INT8 quantization, packs weights as NHWC8 tiles, builds the
activation lifetime arena, and emits SSD prior-box metadata.

Generated files:

- `model.json`: layer descriptors, memory offsets, scales and post-processing.
- `parameters.bin`: packed weights, INT32 biases and fixed-point quantization.
- `priors.bin`: fixed SSD prior boxes for the configured input dimensions.
- `labels.txt`: copied class order when `--labels` is provided.
