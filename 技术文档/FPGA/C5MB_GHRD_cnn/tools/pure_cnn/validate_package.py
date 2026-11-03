#!/usr/bin/env python3
"""Validate a c5mb-pure-cnn-v1 model package before deployment."""

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def tensor_bytes(width, height, blocks):
    return int(width) * int(height) * int(blocks) * 8


def check_range(offset, size, total, name, alignment=8):
    if offset < 0 or size < 0 or offset + size > total:
        raise ValueError(f"{name} range [{offset}, {offset + size}) exceeds {total}")
    if offset % alignment:
        raise ValueError(f"{name} offset {offset} is not {alignment}-byte aligned")


def validate(package):
    manifest_path = package / "model.json"
    parameter_path = package / "parameters.bin"
    prior_path = package / "priors.bin"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    if manifest.get("format") != "c5mb-pure-cnn-v1":
        raise ValueError("unsupported model package format")
    memory = manifest["memory"]
    parameter_bytes = parameter_path.stat().st_size
    prior_bytes = prior_path.stat().st_size
    if parameter_bytes != memory["parameter_bytes"]:
        raise ValueError("parameters.bin size does not match manifest")
    if prior_bytes != memory["prior_bytes"]:
        raise ValueError("priors.bin size does not match manifest")
    if memory["activation_banks"] != 2:
        raise ValueError("activation_banks must be two")

    checksums = manifest["checksums"]
    if sha256(parameter_path) != checksums["parameters_sha256"]:
        raise ValueError("parameters.bin SHA-256 mismatch")
    if sha256(prior_path) != checksums["priors_sha256"]:
        raise ValueError("priors.bin SHA-256 mismatch")

    arena_bytes = memory["activation_arena_bytes"]
    model_input = manifest["input"]
    if model_input["layout"] != "NHWC8":
        raise ValueError("input layout must be NHWC8")
    if model_input["channel_order"] not in {"BGR", "RGB"}:
        raise ValueError("channel_order must be BGR or RGB")
    check_range(
        model_input["offset"],
        tensor_bytes(model_input["width"], model_input["height"], 1),
        arena_bytes,
        "input tensor",
        64,
    )

    layers = manifest["layers"]
    if not layers:
        raise ValueError("model has no layers")
    for index, layer in enumerate(layers):
        if layer["index"] != index:
            raise ValueError(f"layer {index} index is not sequential")
        if layer["op"] not in {"conv", "depthwise"}:
            raise ValueError(f"layer {index} has unsupported op {layer['op']}")
        for key in (
            "input_width",
            "input_height",
            "input_blocks",
            "output_width",
            "output_height",
            "output_blocks",
        ):
            if not 1 <= layer[key] <= 1023:
                raise ValueError(f"layer {index} {key} does not fit descriptor")
        if layer["kernel"] not in {1, 3} or layer["stride"] not in {1, 2}:
            raise ValueError(f"layer {index} kernel/stride is unsupported")

        check_range(
            layer["input_offset"],
            tensor_bytes(
                layer["input_width"],
                layer["input_height"],
                layer["input_blocks"],
            ),
            arena_bytes,
            f"layer {index} input",
            64,
        )
        check_range(
            layer["output_offset"],
            tensor_bytes(
                layer["output_width"],
                layer["output_height"],
                layer["output_blocks"],
            ),
            arena_bytes,
            f"layer {index} output",
            64,
        )
        for prefix in ("weight", "bias", "quant"):
            check_range(
                layer[f"{prefix}_offset"],
                layer[f"{prefix}_bytes"],
                parameter_bytes,
                f"layer {index} {prefix}",
                8,
            )

        if layer["op"] == "conv":
            expected_weights = (
                layer["output_blocks"]
                * layer["kernel"]
                * layer["kernel"]
                * layer["input_blocks"]
                * 64
            )
        else:
            expected_weights = (
                layer["output_blocks"] * layer["kernel"] * layer["kernel"] * 8
            )
        if layer["weight_bytes"] != expected_weights:
            raise ValueError(f"layer {index} packed weight length mismatch")
        if layer["bias_bytes"] != layer["output_blocks"] * 32:
            raise ValueError(f"layer {index} packed bias length mismatch")
        if layer["quant_bytes"] != layer["output_blocks"] * 64:
            raise ValueError(f"layer {index} quant record length mismatch")

    labels = manifest["labels"]
    heads = manifest["heads"]
    expected_prior_end = 0
    for head_index, head in enumerate(heads):
        if head["index"] != head_index:
            raise ValueError("SSD head indexes are not sequential")
        if head["box_layer"] >= len(layers) or head["score_layer"] >= len(layers):
            raise ValueError(f"head {head_index} references an invalid layer")
        if head["classes_with_background"] != len(labels) + 1:
            raise ValueError(f"head {head_index} class count mismatch")
        expected = head["width"] * head["height"] * head["anchors"]
        if head["prior_start"] != expected_prior_end or head["prior_count"] != expected:
            raise ValueError(f"head {head_index} prior range mismatch")
        expected_prior_end += expected
    if expected_prior_end * 16 != prior_bytes:
        raise ValueError("prior file length does not match SSD heads")
    background = manifest["nms"]["background_label"]
    if not 0 <= background < len(labels) + 1:
        raise ValueError("background_label is outside score channels")

    return {
        "layers": len(layers),
        "heads": len(heads),
        "priors": expected_prior_end,
        "parameter_bytes": parameter_bytes,
        "arena_bytes_per_bank": arena_bytes,
        "activation_banks": memory["activation_banks"],
        "background_label": background,
        "labels": labels,
        "channel_order": model_input["channel_order"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    args = parser.parse_args()
    summary = validate(args.package)
    print(json.dumps(summary, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
