#!/usr/bin/env python3
"""Export Oxford VGG-Face as an ONNX embedding model for ZETIC.

The upstream VGG-Face model returns 2,622 classifier logits. For recognition we
replace fc8 with Identity so the exported model returns the 4,096-float fc7
feature vector.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import urllib.request

import numpy as np
import torch
from torch import nn


MODEL_DEF_URL = "https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.py"
WEIGHTS_URL = "https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.pth"
DEFAULT_OUTPUT_DIR = pathlib.Path("model_artifacts/vggface")
INPUT_SHAPE = (1, 3, 224, 224)


def download(url: str, destination: pathlib.Path) -> None:
    if destination.exists():
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {url}")
    urllib.request.urlretrieve(url, destination)


def load_model_module(model_def_path: pathlib.Path):
    spec = importlib.util.spec_from_file_location("vgg_face_dag", model_def_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not import {model_def_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def export(output_dir: pathlib.Path, opset: int) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    model_def_path = output_dir / "vgg_face_dag.py"
    weights_path = output_dir / "vgg_face_dag.pth"
    onnx_path = output_dir / "vgg_face_embedding.onnx"
    external_data_path = output_dir / "vgg_face_embedding.onnx.data"
    input_path = output_dir / "input.npy"

    download(MODEL_DEF_URL, model_def_path)
    download(WEIGHTS_URL, weights_path)

    module = load_model_module(model_def_path)
    model = module.vgg_face_dag(weights_path=str(weights_path))
    model.fc8 = nn.Identity()
    model.eval()

    sample_input = np.zeros(INPUT_SHAPE, dtype=np.float32)
    np.save(input_path, sample_input)
    dummy_tensor = torch.from_numpy(sample_input)

    with torch.no_grad():
        output = model(dummy_tensor)

    if tuple(output.shape) != (1, 4096):
        raise RuntimeError(f"Expected embedding shape (1, 4096), got {tuple(output.shape)}")

    for stale_path in [onnx_path, external_data_path]:
        if stale_path.exists():
            stale_path.unlink()

    torch.onnx.export(
        model,
        dummy_tensor,
        onnx_path,
        export_params=True,
        opset_version=opset,
        do_constant_folding=True,
        input_names=["face_image"],
        output_names=["embedding"],
        dynamic_axes=None,
        external_data=False,
    )

    print(f"Wrote {onnx_path}")
    print(f"Wrote {input_path}")
    print("Upload both files to ZETIC Melange with the input order preserved.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=pathlib.Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--opset", type=int, default=18)
    args = parser.parse_args()

    export(args.output_dir, args.opset)


if __name__ == "__main__":
    main()
