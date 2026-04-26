#!/usr/bin/env python3
"""Export Oxford VGG-Face as a Core ML embedding model.

The upstream VGG-Face model returns 2,622 classifier logits. For recognition we
replace fc8 with Identity so the exported Core ML model returns the 4,096-float
fc7 feature vector.
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import urllib.request

import coremltools as ct
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


def export(output_dir: pathlib.Path, quantize: bool) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    model_def_path = output_dir / "vgg_face_dag.py"
    weights_path = output_dir / "vgg_face_dag.pth"
    package_path = output_dir / "VGGFaceEmbedding.mlpackage"

    download(MODEL_DEF_URL, model_def_path)
    download(WEIGHTS_URL, weights_path)

    module = load_model_module(model_def_path)
    model = module.vgg_face_dag(weights_path=str(weights_path))
    model.fc8 = nn.Identity()
    model.eval()

    dummy_tensor = torch.zeros(INPUT_SHAPE, dtype=torch.float32)
    with torch.no_grad():
        output = model(dummy_tensor)

    if tuple(output.shape) != (1, 4096):
        raise RuntimeError(f"Expected embedding shape (1, 4096), got {tuple(output.shape)}")

    traced_model = torch.jit.trace(model, dummy_tensor)
    mlmodel = ct.convert(
        traced_model,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name="face_image",
                shape=INPUT_SHAPE,
                dtype=np.float32,
            )
        ],
        outputs=[
            ct.TensorType(name="embedding", dtype=np.float32)
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.ALL,
    )

    mlmodel.short_description = "Oxford VGG-Face fc7 embedding model for local face recognition."
    mlmodel.input_description["face_image"] = "Float32 NCHW tensor [1, 3, 224, 224], RGB, with VGG-Face channel means subtracted."
    mlmodel.output_description["embedding"] = "Float32 face embedding [1, 4096]. L2-normalize before comparing."

    if quantize:
        mlmodel = ct.optimize.coreml.linear_quantize_weights(
            mlmodel,
            config=ct.optimize.coreml.OpLinearQuantizerConfig(mode="linear_symmetric"),
        )

    if package_path.exists():
        import shutil
        shutil.rmtree(package_path)

    mlmodel.save(package_path)
    print(f"Wrote {package_path}")
    print("Add this .mlpackage to the LAHACKS26 Xcode target.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=pathlib.Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument(
        "--quantize",
        action="store_true",
        help="Try Core ML linear weight quantization after conversion.",
    )
    args = parser.parse_args()

    export(args.output_dir, args.quantize)


if __name__ == "__main__":
    main()
