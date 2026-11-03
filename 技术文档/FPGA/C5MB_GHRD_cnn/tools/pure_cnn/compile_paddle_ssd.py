#!/usr/bin/env python3
"""Compile a Paddle QAT SSD-MobileNet model for pure_cnn_accel.v.

The generated package contains no executable code. It is consumed by the HPS
runtime, which allocates coherent CMA memory and supplies physical addresses to
the PL accelerator.
"""

import argparse
import collections
import hashlib
import json
import math
import re
import struct
from pathlib import Path

import numpy as np

import framework_pb2


ALIGNMENT = 64
QMIN = -127
QMAX = 127
PL_CACHE_DEPTH = 512


def align_up(value, alignment=ALIGNMENT):
    return (value + alignment - 1) // alignment * alignment


def product(values):
    result = 1
    for value in values:
        result *= int(value)
    return result


def first_port(op, name, required=True):
    for port in op.inputs:
        if port.parameter == name and port.arguments:
            return port.arguments[0]
    for port in op.outputs:
        if port.parameter == name and port.arguments:
            return port.arguments[0]
    if required:
        raise ValueError(f"operator {op.type} has no populated port {name}")
    return None


def all_inputs(op):
    result = []
    for port in op.inputs:
        result.extend(port.arguments)
    return result


def all_outputs(op):
    result = []
    for port in op.outputs:
        result.extend(port.arguments)
    return result


def get_attr(op, name, default=None):
    fields = {
        framework_pb2.INT: "i",
        framework_pb2.FLOAT: "f",
        framework_pb2.STRING: "s",
        framework_pb2.INTS: "ints",
        framework_pb2.FLOATS: "floats",
        framework_pb2.STRINGS: "strings",
        framework_pb2.BOOLEAN: "b",
        framework_pb2.BOOLEANS: "bools",
        framework_pb2.LONG: "l",
        framework_pb2.LONGS: "longs",
        framework_pb2.FLOAT64: "float64",
        framework_pb2.FLOAT64S: "float64s",
    }
    repeated = {
        framework_pb2.INTS,
        framework_pb2.FLOATS,
        framework_pb2.STRINGS,
        framework_pb2.BOOLEANS,
        framework_pb2.LONGS,
        framework_pb2.FLOAT64S,
    }
    for item in op.attrs:
        if item.name != name:
            continue
        field = fields.get(item.type)
        if field is None:
            return default
        value = getattr(item, field)
        if item.type in repeated:
            return list(value)
        if isinstance(value, bytes):
            return value.decode("utf-8")
        return value
    return default


def tensor_desc(var):
    if var.type.HasField("lod_tensor"):
        return var.type.lod_tensor.tensor
    if var.type.HasField("selected_rows"):
        return var.type.selected_rows
    return None


def load_program(path):
    program = framework_pb2.ProgramDesc()
    program.ParseFromString(Path(path).read_bytes())
    if len(program.blocks) != 1:
        raise ValueError("only single-block inference programs are supported")
    return program


def persistable_names(program):
    excluded = {
        framework_pb2.VarType.FEED_MINIBATCH,
        framework_pb2.VarType.FETCH_LIST,
        framework_pb2.VarType.RAW,
    }
    names = []
    for var in program.blocks[0].vars:
        if var.persistable and var.type.type not in excluded:
            names.append(var.name)
    return sorted(names)


DTYPES = {
    framework_pb2.VarType.BOOL: np.dtype("?"),
    framework_pb2.VarType.INT16: np.dtype("<i2"),
    framework_pb2.VarType.INT32: np.dtype("<i4"),
    framework_pb2.VarType.INT64: np.dtype("<i8"),
    framework_pb2.VarType.FP32: np.dtype("<f4"),
    framework_pb2.VarType.FP64: np.dtype("<f8"),
    framework_pb2.VarType.UINT8: np.dtype("u1"),
    framework_pb2.VarType.INT8: np.dtype("i1"),
}


def load_combined_parameters(path, program):
    raw = memoryview(Path(path).read_bytes())
    cursor = 0
    tensors = {}
    for name in persistable_names(program):
        if cursor + 20 > len(raw):
            raise ValueError(f"truncated pdiparams before {name}")
        version = struct.unpack_from("<I", raw, cursor)[0]
        cursor += 4
        if version != 0:
            raise ValueError(f"unsupported tensor version {version} for {name}")
        lod_level = struct.unpack_from("<Q", raw, cursor)[0]
        cursor += 8
        for _ in range(lod_level):
            lod_bytes = struct.unpack_from("<Q", raw, cursor)[0]
            cursor += 8 + lod_bytes
        inner_version = struct.unpack_from("<I", raw, cursor)[0]
        cursor += 4
        if inner_version != 0:
            raise ValueError(f"unsupported inner tensor version for {name}")
        desc_size = struct.unpack_from("<i", raw, cursor)[0]
        cursor += 4
        desc = framework_pb2.VarType.TensorDesc()
        desc.ParseFromString(bytes(raw[cursor : cursor + desc_size]))
        cursor += desc_size
        dtype = DTYPES.get(desc.data_type)
        if dtype is None:
            dtype_name = framework_pb2.VarType.Type.Name(desc.data_type)
            raise ValueError(f"unsupported dtype {dtype_name} for {name}")
        shape = tuple(int(value) for value in desc.dims)
        byte_count = product(shape) * dtype.itemsize
        if cursor + byte_count > len(raw):
            raise ValueError(f"truncated tensor payload for {name}")
        tensor = np.frombuffer(raw[cursor : cursor + byte_count], dtype=dtype)
        tensors[name] = tensor.reshape(shape).copy()
        cursor += byte_count
    if cursor != len(raw):
        raise ValueError(
            f"pdiparams has {len(raw) - cursor} trailing bytes after all variables"
        )
    return tensors


def scalar(tensors, name):
    value = tensors.get(name)
    if value is None or value.size != 1:
        raise ValueError(f"expected scalar parameter {name}")
    return float(value.reshape(-1)[0])


def producer_and_consumers(ops):
    producers = {}
    consumers = collections.defaultdict(list)
    for index, op in enumerate(ops):
        for name in all_outputs(op):
            producers[name] = index
        for name in all_inputs(op):
            consumers[name].append(index)
    return producers, consumers


def variable_shapes(program):
    result = {}
    for var in program.blocks[0].vars:
        desc = tensor_desc(var)
        if desc is not None:
            result[var.name] = [int(value) for value in desc.dims]
    return result


def resolve_quant_source(name, ops, producers, expected_type):
    index = producers.get(name)
    if index is None:
        return name
    op = ops[index]
    if op.type != expected_type:
        return name
    return first_port(op, "X")


def direct_consumer(name, ops, consumers, allowed):
    candidates = [index for index in consumers.get(name, []) if ops[index].type in allowed]
    if len(candidates) == 1:
        return ops[candidates[0]]
    return None


def detection_head_kind(name, ops, consumers):
    transpose = direct_consumer(name, ops, consumers, {"transpose2"})
    if transpose is None:
        return None
    transpose_output = first_port(transpose, "Out")
    reshape = direct_consumer(transpose_output, ops, consumers, {"reshape2"})
    if reshape is None:
        return None
    shape = [int(value) for value in get_attr(reshape, "shape", [])]
    if not shape:
        return None
    if shape[-1] == 4:
        return "box"
    if shape[-1] > 1:
        return "score"
    return None


def activation_absmax(ops, tensors):
    scales = collections.defaultdict(list)
    quant_type = "fake_quantize_dequantize_moving_average_abs_max"
    for op in ops:
        if op.type != quant_type:
            continue
        source = first_port(op, "X")
        scale_name = first_port(op, "InScale")
        value = abs(scalar(tensors, scale_name))
        if value > 0.0:
            scales[source].append(value)
    return {name: max(values) for name, values in scales.items()}


def valid_nchw(shape, name, input_width, input_height):
    if len(shape) != 4:
        raise ValueError(f"tensor {name} is not NCHW: {shape}")
    _, channels, height, width = shape
    if height <= 0:
        height = input_height
    if width <= 0:
        width = input_width
    if channels <= 0:
        raise ValueError(f"tensor {name} has invalid channel count {channels}")
    return int(channels), int(height), int(width)


def fixed_multiplier(real_multiplier):
    if not math.isfinite(real_multiplier) or real_multiplier < 0.0:
        raise ValueError(f"invalid requant multiplier {real_multiplier}")
    if real_multiplier == 0.0:
        return 0, 0
    maximum = (1 << 31) - 1
    if real_multiplier > maximum:
        raise ValueError(f"requant multiplier is too large: {real_multiplier}")
    shift = min(71, max(0, int(math.floor(math.log2(maximum / real_multiplier)))))
    multiplier = int(round(real_multiplier * (1 << shift)))
    while multiplier > maximum and shift > 0:
        shift -= 1
        multiplier = int(round(real_multiplier * (1 << shift)))
    if multiplier == 0:
        raise ValueError(f"requant multiplier underflow: {real_multiplier}")
    return multiplier, shift


def append_aligned(buffer, payload):
    offset = align_up(len(buffer))
    if offset > len(buffer):
        buffer.extend(b"\0" * (offset - len(buffer)))
    buffer.extend(payload)
    return offset, len(payload)


def pack_standard_weights(weights):
    output_channels, input_channels, kernel_h, kernel_w = weights.shape
    output_blocks = (output_channels + 7) // 8
    input_blocks = (input_channels + 7) // 8
    packed = bytearray()
    for output_block in range(output_blocks):
        for kernel_y in range(kernel_h):
            for kernel_x in range(kernel_w):
                for input_block in range(input_blocks):
                    for output_lane in range(8):
                        output_channel = output_block * 8 + output_lane
                        for input_lane in range(8):
                            input_channel = input_block * 8 + input_lane
                            value = 0
                            if output_channel < output_channels and input_channel < input_channels:
                                value = int(
                                    weights[
                                        output_channel,
                                        input_channel,
                                        kernel_y,
                                        kernel_x,
                                    ]
                                )
                            packed.extend(struct.pack("<b", value))
    return bytes(packed)


def pack_depthwise_weights(weights):
    channels, multiplier, kernel_h, kernel_w = weights.shape
    if multiplier != 1:
        raise ValueError("depthwise channel multiplier other than one is unsupported")
    blocks = (channels + 7) // 8
    packed = bytearray()
    for block in range(blocks):
        for kernel_y in range(kernel_h):
            for kernel_x in range(kernel_w):
                for lane in range(8):
                    channel = block * 8 + lane
                    value = 0 if channel >= channels else int(weights[channel, 0, kernel_y, kernel_x])
                    packed.extend(struct.pack("<b", value))
    return bytes(packed)


def quantize_layer(
    weights,
    bias,
    input_scale,
    output_scale,
    activation,
    depthwise,
):
    output_channels = weights.shape[0]
    flattened = weights.reshape(output_channels, -1)
    maxima = np.max(np.abs(flattened), axis=1)
    natural_scales = np.where(maxima > 0.0, maxima / QMAX, 0.0).astype(np.float64)

    # QAT models can contain pruned channels whose folded weights are around
    # 1e-15 while the folded BN bias is still non-zero. Scaling such channels
    # solely from their weight maximum would overflow the integer bias. A
    # 2^-20 output-scale floor keeps those channels numerically constant while
    # retaining substantially more precision than the final INT8 output.
    accumulator_floor = output_scale / float(1 << 20)
    bias_floor = np.abs(bias) / float((1 << 31) - 1)
    accumulator_floors = np.maximum(accumulator_floor, bias_floor)
    weight_floors = accumulator_floors / input_scale
    weight_scales = np.maximum(natural_scales, weight_floors)
    quantized = np.rint(weights / weight_scales.reshape((-1, 1, 1, 1)))
    quantized = np.clip(quantized, QMIN, QMAX).astype(np.int8)

    padded_channels = align_up(output_channels, 8)
    bias_values = np.zeros(padded_channels, dtype=np.int32)
    records = bytearray()
    for channel in range(padded_channels):
        if channel >= output_channels:
            records.extend(struct.pack("<iBbbb", 0, 0, 0, 0, 0))
            continue
        accumulator_scale = input_scale * float(weight_scales[channel])
        raw_bias = int(round(float(bias[channel]) / accumulator_scale))
        if raw_bias < -(1 << 31) or raw_bias > (1 << 31) - 1:
            raise ValueError(f"bias overflow on output channel {channel}: {raw_bias}")
        bias_values[channel] = raw_bias
        multiplier, shift = fixed_multiplier(accumulator_scale / output_scale)
        clamp_minimum = QMIN
        clamp_maximum = QMAX
        if activation in {"relu", "relu6"}:
            clamp_minimum = 0
        if activation == "relu6":
            clamp_maximum = min(QMAX, int(round(6.0 / output_scale)))
        records.extend(
            struct.pack(
                "<iBbbb",
                multiplier,
                shift,
                0,
                clamp_minimum,
                clamp_maximum,
            )
        )

    if depthwise:
        weight_payload = pack_depthwise_weights(quantized)
    else:
        weight_payload = pack_standard_weights(quantized)
    return weight_payload, bias_values.tobytes(order="C"), bytes(records), weight_scales


def parse_labels(path):
    if path is None:
        return []
    labels = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        value = line.strip()
        if value:
            labels.append(value)
    return labels


def compile_layers(program, tensors, args):
    block = program.blocks[0]
    ops = list(block.ops)
    shapes = variable_shapes(program)
    producers, consumers = producer_and_consumers(ops)
    absmax = activation_absmax(ops, tensors)
    parameters = bytearray()
    layers = []
    tensor_info = {}
    head_counts = collections.defaultdict(int)

    quant_activation = "fake_quantize_dequantize_moving_average_abs_max"
    quant_weight = "fake_channel_wise_quantize_dequantize_abs_max"

    for op_index, op in enumerate(ops):
        if op.type not in {"conv2d", "depthwise_conv2d"}:
            continue
        input_quant = first_port(op, "Input")
        weight_quant = first_port(op, "Filter")
        input_name = resolve_quant_source(
            input_quant, ops, producers, quant_activation
        )
        weight_name = resolve_quant_source(
            weight_quant, ops, producers, quant_weight
        )
        if weight_name not in tensors:
            raise ValueError(f"missing convolution weights {weight_name}")
        weights = tensors[weight_name].astype(np.float64)
        if weights.ndim != 4:
            raise ValueError(f"weights {weight_name} must be OIHW")

        conv_output = first_port(op, "Output")
        output_name = conv_output
        output_threshold = get_attr(op, "out_threshold", None)
        activation = "none"
        bias = np.zeros(weights.shape[0], dtype=np.float64)

        bias_name = first_port(op, "Bias", required=False)
        if bias_name:
            bias = tensors[bias_name].astype(np.float64).reshape(-1)

        batch_norm = direct_consumer(conv_output, ops, consumers, {"batch_norm"})
        if batch_norm is not None:
            gamma = tensors[first_port(batch_norm, "Scale")].astype(np.float64).reshape(-1)
            mean = tensors[first_port(batch_norm, "Mean")].astype(np.float64).reshape(-1)
            variance = tensors[first_port(batch_norm, "Variance")].astype(np.float64).reshape(-1)
            beta = tensors[first_port(batch_norm, "Bias")].astype(np.float64).reshape(-1)
            epsilon = float(get_attr(batch_norm, "epsilon", 1e-5))
            factor = gamma / np.sqrt(variance + epsilon)
            weights = weights * factor.reshape((-1, 1, 1, 1))
            bias = (bias - mean) * factor + beta
            output_name = first_port(batch_norm, "Y")
            activation_op = direct_consumer(
                output_name, ops, consumers, {"relu", "relu6"}
            )
            if activation_op is not None:
                activation = activation_op.type
                output_name = first_port(activation_op, "Out")
        else:
            add_op = direct_consumer(conv_output, ops, consumers, {"elementwise_add"})
            if add_op is not None:
                x_name = first_port(add_op, "X")
                y_name = first_port(add_op, "Y")
                if x_name != conv_output or y_name not in tensors:
                    raise ValueError("only persistable channel bias elementwise_add is supported")
                bias = bias + tensors[y_name].astype(np.float64).reshape(-1)
                output_name = first_port(add_op, "Out")
                output_threshold = get_attr(add_op, "out_threshold", output_threshold)

        input_shape = shapes.get(input_name, shapes.get(input_quant))
        output_shape = shapes.get(output_name, shapes.get(conv_output))
        if input_shape is None or output_shape is None:
            raise ValueError(f"missing shape for layer at op {op_index}")
        input_channels, input_height, input_width = valid_nchw(
            input_shape, input_name, args.input_width, args.input_height
        )
        output_channels, output_height, output_width = valid_nchw(
            output_shape, output_name, args.input_width, args.input_height
        )
        if weights.shape[0] != output_channels:
            raise ValueError(f"output channel mismatch for {weight_name}")
        if bias.size != output_channels:
            raise ValueError(f"bias channel mismatch for {weight_name}")

        kernel_h, kernel_w = int(weights.shape[2]), int(weights.shape[3])
        if kernel_h != kernel_w or kernel_h not in {1, 3}:
            raise ValueError(f"unsupported kernel {kernel_h}x{kernel_w} in {weight_name}")
        strides = [int(value) for value in get_attr(op, "strides", [1, 1])]
        paddings = [int(value) for value in get_attr(op, "paddings", [0, 0])]
        dilations = [int(value) for value in get_attr(op, "dilations", [1, 1])]
        if strides[0] != strides[1] or strides[0] not in {1, 2}:
            raise ValueError(f"unsupported stride in {weight_name}: {strides}")
        if len(paddings) == 4:
            if not (paddings[0] == paddings[1] == paddings[2] == paddings[3]):
                raise ValueError(f"asymmetric padding is unsupported: {paddings}")
            padding = paddings[0]
        else:
            if paddings[0] != paddings[1]:
                raise ValueError(f"asymmetric padding is unsupported: {paddings}")
            padding = paddings[0]
        if dilations != [1, 1]:
            raise ValueError(f"dilated convolution is unsupported: {dilations}")

        groups = int(get_attr(op, "groups", 1))
        depthwise = op.type == "depthwise_conv2d" or (
            groups == input_channels and output_channels == input_channels
        )
        if depthwise and weights.shape[1] != 1:
            raise ValueError(f"invalid depthwise weights {weights.shape}")
        if not depthwise and groups != 1:
            raise ValueError(f"grouped non-depthwise convolution is unsupported: {groups}")

        input_absmax = absmax.get(input_name)
        output_absmax = absmax.get(output_name)
        if input_absmax is None:
            raise ValueError(f"no QAT input scale found for tensor {input_name}")
        if output_absmax is None:
            threshold = output_threshold
            if threshold is None or float(threshold) <= 0.0:
                raise ValueError(f"no QAT output scale found for tensor {output_name}")
            output_absmax = float(threshold)
        input_scale = float(input_absmax) / QMAX
        output_scale = float(output_absmax) / QMAX

        weight_payload, bias_payload, quant_payload, weight_scales = quantize_layer(
            weights,
            bias,
            input_scale,
            output_scale,
            activation,
            depthwise,
        )
        weight_offset, weight_bytes = append_aligned(parameters, weight_payload)
        bias_offset, bias_bytes = append_aligned(parameters, bias_payload)
        quant_offset, quant_bytes = append_aligned(parameters, quant_payload)

        input_blocks = (input_channels + 7) // 8
        output_blocks = (output_channels + 7) // 8
        cache_words = kernel_h * kernel_w * (1 if depthwise else input_blocks)
        if cache_words > PL_CACHE_DEPTH:
            raise ValueError(
                f"layer {weight_name} needs {cache_words} cache rows, PL has {PL_CACHE_DEPTH}"
            )

        scale_consumers = []
        for consumer_index in consumers.get(output_name, []):
            consumer = ops[consumer_index]
            if consumer.type == quant_activation:
                scale_consumers.append(first_port(consumer, "InScale"))
        head_kind = None
        head_index = None
        for scale_name in scale_consumers:
            match = re.fullmatch(r"(box|score)_quantize(\d+)\.scale_0", scale_name)
            if match:
                head_kind = match.group(1)
                head_index = int(match.group(2))
        if head_kind is None:
            head_kind = detection_head_kind(output_name, ops, consumers)
        if head_kind is not None:
            if head_index is None:
                head_index = head_counts[head_kind]
            head_counts[head_kind] = max(head_counts[head_kind], head_index + 1)

        layer = {
            "index": len(layers),
            "name": weight_name.rsplit(".w_0", 1)[0],
            "op": "depthwise" if depthwise else "conv",
            "input_tensor": input_name,
            "output_tensor": output_name,
            "input_width": input_width,
            "input_height": input_height,
            "input_channels": input_channels,
            "input_blocks": input_blocks,
            "output_width": output_width,
            "output_height": output_height,
            "output_channels": output_channels,
            "output_blocks": output_blocks,
            "kernel": kernel_h,
            "stride": strides[0],
            "padding": padding,
            "activation": activation,
            "activation_code": {"none": 0, "relu": 1, "relu6": 2}[activation],
            "input_scale": input_scale,
            "output_scale": output_scale,
            "weight_offset": weight_offset,
            "weight_bytes": weight_bytes,
            "bias_offset": bias_offset,
            "bias_bytes": bias_bytes,
            "quant_offset": quant_offset,
            "quant_bytes": quant_bytes,
            "weight_scale_min": float(np.min(weight_scales)),
            "weight_scale_max": float(np.max(weight_scales)),
            "source_op_index": op_index,
        }
        if head_kind is not None:
            layer["head_kind"] = head_kind
            layer["head_index"] = head_index
        layers.append(layer)
        tensor_info[input_name] = {
            "width": input_width,
            "height": input_height,
            "channels": input_channels,
            "blocks": input_blocks,
            "scale": input_scale,
        }
        tensor_info[output_name] = {
            "width": output_width,
            "height": output_height,
            "channels": output_channels,
            "blocks": output_blocks,
            "scale": output_scale,
        }

    return layers, tensor_info, parameters, ops


def plan_activation_arena(layers, tensor_info):
    produced_at = {}
    last_use = {}
    for index, layer in enumerate(layers):
        output_name = layer["output_tensor"]
        produced_at[output_name] = index
        last_use.setdefault(output_name, index)
        input_name = layer["input_tensor"]
        produced_at.setdefault(input_name, -1)
        last_use[input_name] = max(last_use.get(input_name, -1), index)
    for layer in layers:
        if "head_kind" in layer:
            last_use[layer["output_tensor"]] = len(layers)

    tensors = sorted(produced_at, key=lambda name: (produced_at[name], name))
    active = []
    free_blocks = []
    offsets = {}
    arena_end = 0

    def coalesce(blocks):
        blocks = sorted(blocks)
        merged = []
        for offset, size in blocks:
            if merged and merged[-1][0] + merged[-1][1] == offset:
                merged[-1] = (merged[-1][0], merged[-1][1] + size)
            else:
                merged.append((offset, size))
        return merged

    for name in tensors:
        start = produced_at[name]
        still_active = []
        for end, offset, size in active:
            if end < start:
                free_blocks.append((offset, size))
            else:
                still_active.append((end, offset, size))
        active = still_active
        free_blocks = coalesce(free_blocks)
        info = tensor_info[name]
        size = align_up(info["width"] * info["height"] * info["blocks"] * 8)
        selected = None
        for block_index, (offset, block_size) in enumerate(free_blocks):
            if block_size >= size:
                selected = (block_index, offset, block_size)
                break
        if selected is None:
            offset = align_up(arena_end)
            arena_end = offset + size
        else:
            block_index, offset, block_size = selected
            del free_blocks[block_index]
            if block_size > size:
                free_blocks.append((offset + size, block_size - size))
        offsets[name] = offset
        active.append((last_use[name], offset, size))

    for layer in layers:
        layer["input_offset"] = offsets[layer["input_tensor"]]
        layer["output_offset"] = offsets[layer["output_tensor"]]
    return align_up(arena_end), offsets


def expanded_aspect_ratios(values, flip):
    result = [1.0]
    for value in values:
        value = float(value)
        if not any(abs(value - existing) < 1e-6 for existing in result):
            result.append(value)
            if flip:
                result.append(1.0 / value)
    return result


def generate_prior_boxes(op, feature_width, feature_height, image_width, image_height):
    min_sizes = [float(value) for value in get_attr(op, "min_sizes", [])]
    max_sizes = [float(value) for value in get_attr(op, "max_sizes", [])]
    aspect_ratios = expanded_aspect_ratios(
        get_attr(op, "aspect_ratios", []), bool(get_attr(op, "flip", True))
    )
    variances = [float(value) for value in get_attr(op, "variances", [0.1, 0.1, 0.2, 0.2])]
    steps = [float(value) for value in get_attr(op, "steps", [0.0, 0.0])]
    offset = float(get_attr(op, "offset", 0.5))
    clip = bool(get_attr(op, "clip", False))
    if not min_sizes:
        raise ValueError("prior_box has no min_sizes")
    step_w = steps[0] if len(steps) > 0 and steps[0] > 0.0 else image_width / feature_width
    step_h = steps[1] if len(steps) > 1 and steps[1] > 0.0 else image_height / feature_height
    boxes = []
    for y in range(feature_height):
        for x in range(feature_width):
            center_x = (x + offset) * step_w / image_width
            center_y = (y + offset) * step_h / image_height
            for size_index, min_size in enumerate(min_sizes):
                width = min_size / image_width
                height = min_size / image_height
                boxes.append(
                    [center_x - width / 2, center_y - height / 2,
                     center_x + width / 2, center_y + height / 2]
                )
                if size_index < len(max_sizes) and max_sizes[size_index] > 0.0:
                    size = math.sqrt(min_size * max_sizes[size_index])
                    width = size / image_width
                    height = size / image_height
                    boxes.append(
                        [center_x - width / 2, center_y - height / 2,
                         center_x + width / 2, center_y + height / 2]
                    )
                for ratio in aspect_ratios:
                    if abs(ratio - 1.0) < 1e-6:
                        continue
                    width = min_size * math.sqrt(ratio) / image_width
                    height = min_size / math.sqrt(ratio) / image_height
                    boxes.append(
                        [center_x - width / 2, center_y - height / 2,
                         center_x + width / 2, center_y + height / 2]
                    )
    output = np.asarray(boxes, dtype=np.float32)
    if clip:
        output = np.clip(output, 0.0, 1.0)
    return output, variances


def build_detection_metadata(ops, layers, tensor_info, labels, args):
    box_heads = {layer.get("head_index"): layer for layer in layers if layer.get("head_kind") == "box"}
    score_heads = {layer.get("head_index"): layer for layer in layers if layer.get("head_kind") == "score"}
    prior_ops = [op for op in ops if op.type == "prior_box"]
    if not box_heads and not score_heads:
        return [], b"", {}
    if set(box_heads) != set(score_heads):
        raise ValueError("box and score head indexes do not match")
    if len(prior_ops) != len(box_heads):
        raise ValueError(
            f"model has {len(box_heads)} head pairs but {len(prior_ops)} prior_box ops"
        )
    num_foreground = len(labels)
    priors = []
    heads = []
    prior_cursor = 0
    for head_index, prior_op in zip(sorted(box_heads), prior_ops):
        box = box_heads[head_index]
        score = score_heads[head_index]
        if box["input_tensor"] != score["input_tensor"]:
            raise ValueError(f"head {head_index} box/score feature mismatch")
        anchors = box["output_channels"] // 4
        if anchors * 4 != box["output_channels"]:
            raise ValueError(f"head {head_index} box channels are not divisible by four")
        classes_with_background = score["output_channels"] // anchors
        if classes_with_background * anchors != score["output_channels"]:
            raise ValueError(f"head {head_index} score channels do not match anchors")
        if num_foreground and classes_with_background != num_foreground + 1:
            raise ValueError(
                f"head {head_index} implies {classes_with_background - 1} labels, got {num_foreground}"
            )
        feature = tensor_info[box["input_tensor"]]
        generated, variances = generate_prior_boxes(
            prior_op,
            feature["width"],
            feature["height"],
            args.input_width,
            args.input_height,
        )
        expected = feature["width"] * feature["height"] * anchors
        if generated.shape[0] != expected:
            raise ValueError(
                f"head {head_index} expects {expected} priors, generated {generated.shape[0]}"
            )
        priors.append(generated)
        heads.append(
            {
                "index": head_index,
                "feature_tensor": box["input_tensor"],
                "width": feature["width"],
                "height": feature["height"],
                "anchors": anchors,
                "classes_with_background": classes_with_background,
                "box_layer": box["index"],
                "score_layer": score["index"],
                "prior_start": prior_cursor,
                "prior_count": expected,
                "variances": variances,
            }
        )
        prior_cursor += expected

    nms_op = next((op for op in ops if op.type in {"multiclass_nms", "multiclass_nms3"}), None)
    nms = {
        "background_label": 0,
        "score_threshold": 0.20,
        "nms_threshold": 0.45,
        "nms_top_k": 400,
        "keep_top_k": 100,
    }
    if nms_op is not None:
        for name in list(nms):
            nms[name] = get_attr(nms_op, name, nms[name])
    prior_payload = np.concatenate(priors, axis=0).astype("<f4").tobytes()
    return heads, prior_payload, nms


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--params", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--labels", type=Path)
    parser.add_argument("--input-width", type=int, default=300)
    parser.add_argument("--input-height", type=int, default=300)
    parser.add_argument("--mean", default="127.5,127.5,127.5")
    parser.add_argument("--std", default="127.502231,127.502231,127.502231")
    parser.add_argument("--channel-order", choices=("BGR", "RGB"), default="BGR")
    args = parser.parse_args()

    labels = parse_labels(args.labels)
    means = [float(value) for value in args.mean.split(",")]
    stds = [float(value) for value in args.std.split(",")]
    if len(means) != 3 or len(stds) != 3 or any(value == 0.0 for value in stds):
        raise ValueError("mean and std must each contain three non-zero values")
    if args.input_width <= 0 or args.input_height <= 0:
        raise ValueError("input dimensions must be positive")

    program = load_program(args.model)
    tensors = load_combined_parameters(args.params, program)
    layers, tensor_info, parameters, ops = compile_layers(program, tensors, args)
    if not layers:
        raise ValueError("no supported convolution layers found")
    arena_bytes, tensor_offsets = plan_activation_arena(layers, tensor_info)
    heads, prior_payload, nms = build_detection_metadata(
        ops, layers, tensor_info, labels, args
    )

    input_tensor = layers[0]["input_tensor"]
    manifest = {
        "format": "c5mb-pure-cnn-v1",
        "model_source": str(args.model),
        "input": {
            "tensor": input_tensor,
            "width": args.input_width,
            "height": args.input_height,
            "channels": 3,
            "layout": "NHWC8",
            "channel_order": args.channel_order,
            "mean": means,
            "std": stds,
            "scale": tensor_info[input_tensor]["scale"],
            "offset": tensor_offsets[input_tensor],
        },
        "labels": labels,
        "layers": layers,
        "heads": heads,
        "nms": nms,
        "memory": {
            "alignment": ALIGNMENT,
            "activation_arena_bytes": arena_bytes,
            "activation_banks": 2,
            "parameter_bytes": align_up(len(parameters)),
            "prior_bytes": len(prior_payload),
        },
    }

    if len(parameters) < manifest["memory"]["parameter_bytes"]:
        parameters.extend(b"\0" * (manifest["memory"]["parameter_bytes"] - len(parameters)))
    parameter_digest = hashlib.sha256(parameters).hexdigest()
    prior_digest = hashlib.sha256(prior_payload).hexdigest()
    manifest["checksums"] = {
        "parameters_sha256": parameter_digest,
        "priors_sha256": prior_digest,
    }

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "parameters.bin").write_bytes(parameters)
    (args.output / "priors.bin").write_bytes(prior_payload)
    (args.output / "model.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    if labels:
        (args.output / "labels.txt").write_text("\n".join(labels) + "\n", encoding="utf-8")

    print(f"compiled_layers={len(layers)}")
    print(f"detection_heads={len(heads)}")
    print(f"parameter_bytes={len(parameters)}")
    print(f"activation_arena_bytes={arena_bytes} x 2")
    print(f"prior_boxes={len(prior_payload) // 16}")
    print(f"output={args.output}")


if __name__ == "__main__":
    main()
