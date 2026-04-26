#!/usr/bin/env python3
"""
Local face recognition helper for preparing a Melange-friendly ONNX model.

This script uses an InsightFace model pack, which contains ONNX models
for face detection and face embedding extraction. The embedding ONNX file can be
uploaded to ZETIC Melange, while this CLI lets you validate the model locally.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import requests


REPO_ROOT = Path(__file__).resolve().parent
INSIGHTFACE_ROOT = REPO_ROOT / ".insightface"
MPLCONFIGDIR = REPO_ROOT / ".mplconfig"
DEFAULT_MODEL_PACK = "buffalo_s"
MODEL_PACK_URLS = {
    "buffalo_l": "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip",
    "buffalo_s": "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_s.zip",
    "buffalo_sc": "https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_sc.zip",
}
MODEL_SIZE_TO_PACK = {
    "small": "buffalo_sc",
    "medium": "buffalo_s",
    "large": "buffalo_l",
}
DEFAULT_MODEL_SIZE = "medium"
DEFAULT_DB_PATH = REPO_ROOT / "face_db.json"
DEFAULT_THRESHOLD = 0.45
DEFAULT_IMAGE_ROOT = REPO_ROOT / "input_images"
DEFAULT_EXPORT_DIR = REPO_ROOT / "melange_export"
DEFAULT_DETECTION_SIZE = 640


@dataclass
class FaceEmbedding:
    embedding: "np.ndarray"
    bbox: list[float]
    det_score: float


def ensure_native_architecture() -> None:
    if platform.system() != "Darwin":
        return
    if platform.machine() != "x86_64":
        return
    if os.environ.get("FACE_RECOGNITION_REEXEC") == "1":
        return

    probe = subprocess.run(
        ["arch", "-arm64", sys.executable, "-c", "import platform; print(platform.machine())"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if probe.returncode != 0 or probe.stdout.strip() != "arm64":
        return

    env = os.environ.copy()
    env["FACE_RECOGNITION_REEXEC"] = "1"
    os.execvpe("arch", ["arch", "-arm64", sys.executable, *sys.argv], env)


def np_module():
    import numpy as np

    return np


def configure_environment() -> None:
    INSIGHTFACE_ROOT.mkdir(parents=True, exist_ok=True)
    MPLCONFIGDIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("INSIGHTFACE_HOME", str(INSIGHTFACE_ROOT))
    os.environ.setdefault("MPLCONFIGDIR", str(MPLCONFIGDIR))
    os.environ.setdefault("NO_ALBUMENTATIONS_UPDATE", "1")


def resolve_model_pack(model_pack: str) -> tuple[str, Path]:
    if model_pack not in MODEL_PACK_URLS:
        supported = ", ".join(sorted(MODEL_PACK_URLS))
        raise ValueError(f"Unsupported model pack `{model_pack}`. Choose one of: {supported}")
    return MODEL_PACK_URLS[model_pack], INSIGHTFACE_ROOT / "models" / model_pack


def selected_model_pack(args: argparse.Namespace) -> str:
    if getattr(args, "model_pack", ""):
        return args.model_pack
    model_size = getattr(args, "model_size", DEFAULT_MODEL_SIZE)
    if model_size not in MODEL_SIZE_TO_PACK:
        supported = ", ".join(sorted(MODEL_SIZE_TO_PACK))
        raise ValueError(f"Unsupported model size `{model_size}`. Choose one of: {supported}")
    return MODEL_SIZE_TO_PACK[model_size]


def add_model_selection_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--model-size",
        default=DEFAULT_MODEL_SIZE,
        choices=sorted(MODEL_SIZE_TO_PACK),
        help=(
            "Model size preset to use: small=buffalo_sc, medium=buffalo_s, "
            f"large=buffalo_l. Default: {DEFAULT_MODEL_SIZE}"
        ),
    )
    parser.add_argument(
        "--model-pack",
        default="",
        choices=["", *sorted(MODEL_PACK_URLS)],
        help="Optional explicit InsightFace model pack override.",
    )


def download_file(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True, timeout=60) as response:
        response.raise_for_status()
        with dest.open("wb") as fh:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    fh.write(chunk)


def ensure_model_downloaded(model_pack: str) -> Path:
    model_url, model_dir = resolve_model_pack(model_pack)
    model_probe = list(model_dir.glob("*.onnx"))
    if model_probe:
        return model_dir

    flat_model_probe = list((INSIGHTFACE_ROOT / "models").glob("*.onnx"))
    if flat_model_probe:
        model_dir.mkdir(parents=True, exist_ok=True)
        for onnx_path in flat_model_probe:
            shutil.move(str(onnx_path), model_dir / onnx_path.name)
        return model_dir

    archive_path = INSIGHTFACE_ROOT / "models" / f"{model_pack}.zip"
    print(f"Downloading {model_pack} from {model_url}", file=sys.stderr)
    download_file(model_url, archive_path)

    print(f"Extracting to {archive_path.parent}", file=sys.stderr)
    with zipfile.ZipFile(archive_path) as archive:
        archive.extractall(archive_path.parent)

    flat_model_probe = list((INSIGHTFACE_ROOT / "models").glob("*.onnx"))
    if flat_model_probe:
        model_dir.mkdir(parents=True, exist_ok=True)
        for onnx_path in flat_model_probe:
            shutil.move(str(onnx_path), model_dir / onnx_path.name)

    model_probe = list(model_dir.glob("*.onnx"))
    if not model_probe:
        raise RuntimeError(
            f"Model extraction completed, but no ONNX files were found in {model_dir}."
        )
    return model_dir


def load_face_analysis(model_pack: str = DEFAULT_MODEL_PACK):
    configure_environment()
    ensure_model_downloaded(model_pack)

    from insightface.app import FaceAnalysis

    app = FaceAnalysis(
        name=model_pack,
        root=str(INSIGHTFACE_ROOT),
        providers=["CPUExecutionProvider"],
    )
    app.prepare(ctx_id=0, det_size=(640, 640))
    return app


def rewrite_onnx_input_shape(
    source_model: Path,
    output_model: Path,
    fixed_input_shape: list[int],
) -> Path:
    import onnx

    model = onnx.load(str(source_model))
    tensor_type = model.graph.input[0].type.tensor_type
    dims = tensor_type.shape.dim
    if len(dims) != len(fixed_input_shape):
        raise ValueError(
            f"Expected {len(fixed_input_shape)} input dims in {source_model}, found {len(dims)}."
        )

    for dim, target in zip(dims, fixed_input_shape):
        dim.ClearField("dim_param")
        dim.dim_value = int(target)

    onnx.checker.check_model(model)
    onnx.save(model, str(output_model))
    return output_model


def select_embedding_model_path(model_dir: Path) -> Path:
    import onnxruntime as ort

    candidates = []
    for model_path in sorted(model_dir.glob("*.onnx")):
        try:
            session = ort.InferenceSession(
                str(model_path),
                providers=["CPUExecutionProvider"],
            )
        except Exception:
            continue

        inputs = session.get_inputs()
        outputs = session.get_outputs()
        if len(inputs) != 1 or not outputs:
            continue

        shape = list(inputs[0].shape)
        if len(shape) != 4:
            continue

        dims = [dim if isinstance(dim, int) else None for dim in shape]
        if dims[1] == 3 and dims[2] in {112, 128} and dims[3] in {112, 128}:
            candidates.append(model_path)
            continue
        if dims[3] == 3 and dims[1] in {112, 128} and dims[2] in {112, 128}:
            candidates.append(model_path)

    if not candidates:
        raise RuntimeError(
            f"Could not identify a face embedding ONNX file in {model_dir}. "
            "Expected a model with a single 4D image input such as 1x3x112x112."
        )

    preferred = sorted(
        candidates,
        key=lambda path: (
            0 if "w600k" in path.name.lower() else 1,
            0 if "mbf" in path.name.lower() or "r50" in path.name.lower() else 1,
            path.name,
        ),
    )
    return preferred[0]


def select_detection_model_path(model_dir: Path) -> Path:
    import onnxruntime as ort

    candidates = []
    for model_path in sorted(model_dir.glob("*.onnx")):
        try:
            session = ort.InferenceSession(
                str(model_path),
                providers=["CPUExecutionProvider"],
            )
        except Exception:
            continue

        inputs = session.get_inputs()
        outputs = session.get_outputs()
        if len(inputs) != 1 or len(outputs) < 3:
            continue

        shape = list(inputs[0].shape)
        if len(shape) != 4:
            continue

        dims = [dim if isinstance(dim, int) else None for dim in shape]
        if dims[0] == 1 and dims[1] == 3:
            candidates.append(model_path)

    if not candidates:
        raise RuntimeError(f"Could not identify a face detection ONNX file in {model_dir}.")

    preferred = sorted(
        candidates,
        key=lambda path: (
            0 if "det" in path.name.lower() else 1,
            0 if "500m" in path.name.lower() else 1,
            path.name,
        ),
    )
    return preferred[0]


def inspect_onnx_model(model_path: Path) -> dict[str, object]:
    import onnxruntime as ort

    session = ort.InferenceSession(
        str(model_path),
        providers=["CPUExecutionProvider"],
    )
    inputs = session.get_inputs()
    outputs = session.get_outputs()
    if len(inputs) != 1:
        raise RuntimeError(
            f"Expected exactly one model input in {model_path}, found {len(inputs)}."
        )

    return {
        "input_name": inputs[0].name,
        "input_shape": list(inputs[0].shape),
        "output_names": [output.name for output in outputs],
        "output_shapes": [list(output.shape) for output in outputs],
    }


def load_image(image_path: Path) -> np.ndarray:
    np = np_module()
    import cv2

    raw = np.fromfile(str(image_path), dtype=np.uint8)
    image = cv2.imdecode(raw, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not decode image: {image_path}")
    return image


def detect_best_face(app, image_path: Path) -> tuple[np.ndarray, object]:
    image = load_image(image_path)
    faces = app.get(image)
    if not faces:
        raise ValueError(f"No face detected in {image_path}")

    best_face = max(
        faces,
        key=lambda face: float(face.det_score) * bbox_area(face.bbox),
    )
    return image, best_face


def extract_face_embedding(app, image_path: Path) -> FaceEmbedding:
    np = np_module()
    _, best_face = detect_best_face(app, image_path)
    embedding = np.asarray(best_face.embedding, dtype=np.float32)
    embedding /= np.linalg.norm(embedding)
    bbox = [float(v) for v in best_face.bbox.tolist()]
    return FaceEmbedding(
        embedding=embedding,
        bbox=bbox,
        det_score=float(best_face.det_score),
    )


def bbox_area(bbox: Iterable[float]) -> float:
    x1, y1, x2, y2 = bbox
    return max(0.0, float(x2) - float(x1)) * max(0.0, float(y2) - float(y1))


def clamp_bbox(bbox: Iterable[float], width: int, height: int) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = bbox
    return (
        max(0, min(int(round(float(x1))), width - 1)),
        max(0, min(int(round(float(y1))), height - 1)),
        max(1, min(int(round(float(x2))), width)),
        max(1, min(int(round(float(y2))), height)),
    )


def extract_face_crop(app, image_path: Path, image_size: int) -> np.ndarray:
    import cv2

    image, best_face = detect_best_face(app, image_path)
    kps = getattr(best_face, "kps", None)
    if kps is not None:
        from insightface.utils import face_align

        return face_align.norm_crop(image, landmark=kps, image_size=image_size)

    height, width = image.shape[:2]
    x1, y1, x2, y2 = clamp_bbox(best_face.bbox, width, height)
    cropped = image[y1:y2, x1:x2]
    if cropped.size == 0:
        raise ValueError(f"Detected face crop was empty for {image_path}")
    return cv2.resize(cropped, (image_size, image_size), interpolation=cv2.INTER_AREA)


def resolve_input_hw(input_shape: list[object]) -> tuple[int, int, bool]:
    if len(input_shape) != 4:
        raise ValueError(f"Unsupported input shape: {input_shape}")

    dims = [dim if isinstance(dim, int) else None for dim in input_shape]
    if dims[1] == 3 and dims[2] and dims[3]:
        return int(dims[2]), int(dims[3]), True
    if dims[3] == 3 and dims[1] and dims[2]:
        return int(dims[1]), int(dims[2]), False
    raise ValueError(f"Unsupported image input layout: {input_shape}")


def preprocess_face_for_embedding(face_bgr: np.ndarray, input_shape: list[object]) -> np.ndarray:
    np = np_module()
    import cv2

    height, width, channels_first = resolve_input_hw(input_shape)
    resized = cv2.resize(face_bgr, (width, height), interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    normalized = (rgb.astype(np.float32) - 127.5) / 127.5
    if channels_first:
        normalized = np.transpose(normalized, (2, 0, 1))
    return np.expand_dims(normalized, axis=0)


def preprocess_image_for_detection(image_bgr: np.ndarray, image_size: int) -> np.ndarray:
    np = np_module()
    import cv2

    resized = cv2.resize(image_bgr, (image_size, image_size), interpolation=cv2.INTER_LINEAR)
    normalized = (resized.astype(np.float32) - 127.5) / 128.0
    normalized = np.transpose(normalized, (2, 0, 1))
    return np.expand_dims(normalized, axis=0)


def find_default_sample_image(image_root: Path) -> Path:
    candidates = sorted(
        path
        for path in image_root.rglob("*")
        if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}
    )
    if not candidates:
        raise ValueError(
            f"No sample images found under {image_root}. "
            "Pass --image explicitly or add files under input_images/<person>/."
        )
    return candidates[0]


def write_image(image_path: Path, image: np.ndarray) -> None:
    import cv2

    suffix = image_path.suffix.lower() or ".png"
    extension = ".jpg" if suffix in {".jpg", ".jpeg"} else ".png"
    ok, encoded = cv2.imencode(extension, image)
    if not ok:
        raise ValueError(f"Could not encode image for {image_path}")
    image_path.write_bytes(encoded.tobytes())


def cosine_similarity(lhs: np.ndarray, rhs: np.ndarray) -> float:
    np = np_module()
    lhs = lhs / np.linalg.norm(lhs)
    rhs = rhs / np.linalg.norm(rhs)
    return float(np.dot(lhs, rhs))


def normalize_embedding(vector) -> np.ndarray:
    np = np_module()
    embedding = np.asarray(vector, dtype=np.float32)
    norm = np.linalg.norm(embedding)
    if norm == 0:
        raise ValueError("Encountered a zero-length embedding.")
    return embedding / norm


def match_embedding(
    probe_embedding,
    database: dict[str, list[float]],
    threshold: float,
) -> tuple[str, float, str]:
    np = np_module()
    if not database:
        raise ValueError("No enrolled faces found in the database.")

    probe = normalize_embedding(probe_embedding)
    scores = []
    for name, vector in database.items():
        score = cosine_similarity(
            probe,
            np.asarray(vector, dtype=np.float32),
        )
        scores.append((name, score))

    scores.sort(key=lambda item: item[1], reverse=True)
    winner, winner_score = scores[0]
    verdict = winner if winner_score >= threshold else "unknown"
    return winner, winner_score, verdict


def read_database(db_path: Path) -> dict[str, list[float]]:
    if not db_path.exists():
        return {}
    return json.loads(db_path.read_text())


def write_database(db_path: Path, data: dict[str, list[float]]) -> None:
    db_path.write_text(json.dumps(data, indent=2, sort_keys=True))


def command_prepare(args: argparse.Namespace) -> int:
    model_pack = selected_model_pack(args)
    model_dir = ensure_model_downloaded(model_pack)
    app = load_face_analysis(model_pack)
    onnx_files = sorted(model_dir.glob("*.onnx"))
    embedding_model = select_embedding_model_path(model_dir)
    print("Model is ready.")
    print(f"Model size: {args.model_size}")
    print(f"Model pack: {model_pack}")
    print(f"Using InsightFace root: {INSIGHTFACE_ROOT}")
    print(f"Prepared providers: {app.models.keys()}")
    print("ONNX files:")
    for path in onnx_files:
        print(f"  {path}")
    print(f"Selected embedding model for Melange: {embedding_model}")
    print("Run `export-melange` to generate the ONNX copy, sample input, and metadata bundle.")
    return 0


def command_export_melange(args: argparse.Namespace) -> int:
    np = np_module()

    model_pack = selected_model_pack(args)
    app = load_face_analysis(model_pack)
    model_dir = ensure_model_downloaded(model_pack)
    embedding_model = select_embedding_model_path(model_dir)
    model_info = inspect_onnx_model(embedding_model)

    image_root = args.image_root.resolve()
    sample_image = args.image.resolve() if args.image else find_default_sample_image(image_root)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    input_shape = model_info["input_shape"]
    height, width, _ = resolve_input_hw(input_shape)
    if height != width:
        raise ValueError(
            f"Expected square input for the embedding model, found {input_shape}."
        )

    face_crop = extract_face_crop(app, sample_image, image_size=height)
    input_tensor = preprocess_face_for_embedding(face_crop, input_shape)

    exported_model = output_dir / embedding_model.name
    exported_input = output_dir / "face_embedding_input.npy"
    exported_crop = output_dir / "sample_face_crop.png"
    exported_metadata = output_dir / "melange_metadata.json"
    exported_db = output_dir / "face_db.json"

    shutil.copy2(embedding_model, exported_model)
    np.save(exported_input, input_tensor)
    write_image(exported_crop, face_crop)

    if args.db.resolve().exists():
        shutil.copy2(args.db.resolve(), exported_db)

    metadata = {
        "model_pack": model_pack,
        "embedding_model": str(exported_model),
        "sample_input": str(exported_input),
        "sample_image": str(sample_image),
        "sample_face_crop": str(exported_crop),
        "input_name": model_info["input_name"],
        "input_shape": input_shape,
        "output_names": model_info["output_names"],
        "output_shapes": model_info["output_shapes"],
        "threshold": args.threshold,
        "database_path": str(exported_db) if exported_db.exists() else None,
        "zetic_cli_example": (
            f"zetic gen -p YOUR_PROJECT_NAME -i {exported_input.name} {exported_model.name}"
        ),
    }
    exported_metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True))

    print("Melange export bundle is ready.")
    print(f"Model: {exported_model}")
    print(f"Sample input (.npy): {exported_input}")
    print(f"Sample face crop: {exported_crop}")
    print(f"Metadata: {exported_metadata}")
    if exported_db.exists():
        print(f"Database copy: {exported_db}")
    print("Next step:")
    print(f"  cd {output_dir}")
    print(f"  {metadata['zetic_cli_example']}")
    return 0


def command_export_detector_melange(args: argparse.Namespace) -> int:
    np = np_module()

    model_pack = selected_model_pack(args)
    model_dir = ensure_model_downloaded(model_pack)
    detection_model = select_detection_model_path(model_dir)
    image_root = args.image_root.resolve()
    sample_image = args.image.resolve() if args.image else find_default_sample_image(image_root)
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    exported_model = output_dir / detection_model.name.replace(".onnx", "_fixed.onnx")
    rewrite_onnx_input_shape(
        detection_model,
        exported_model,
        [1, 3, args.image_size, args.image_size],
    )

    input_tensor = preprocess_image_for_detection(load_image(sample_image), args.image_size)
    exported_input = output_dir / "face_detection_input.npy"
    np.save(exported_input, input_tensor)

    model_info = inspect_onnx_model(exported_model)
    exported_metadata = output_dir / "melange_detector_metadata.json"
    metadata = {
        "model_pack": model_pack,
        "detection_model": str(exported_model),
        "sample_input": str(exported_input),
        "sample_image": str(sample_image),
        "input_name": model_info["input_name"],
        "input_shape": model_info["input_shape"],
        "output_names": model_info["output_names"],
        "output_shapes": model_info["output_shapes"],
        "zetic_cli_example": (
            f"zetic gen -p YOUR_PROJECT_NAME -i {exported_input.name} {exported_model.name}"
        ),
    }
    exported_metadata.write_text(json.dumps(metadata, indent=2, sort_keys=True))

    print("Melange detector export bundle is ready.")
    print(f"Model: {exported_model}")
    print(f"Sample input (.npy): {exported_input}")
    print(f"Metadata: {exported_metadata}")
    print("Next step:")
    print(f"  cd {output_dir}")
    print(f"  {metadata['zetic_cli_example']}")
    return 0


def command_enroll(args: argparse.Namespace) -> int:
    app = load_face_analysis(selected_model_pack(args))
    db_path = args.db.resolve()
    face = extract_face_embedding(app, args.image.resolve())
    db = read_database(db_path)
    db[args.name] = face.embedding.tolist()
    write_database(db_path, db)
    print(f"Enrolled `{args.name}` into {db_path}")
    print(f"Detection score: {face.det_score:.4f}")
    print(f"Bounding box: {face.bbox}")
    return 0


def command_match(args: argparse.Namespace) -> int:
    app = load_face_analysis(selected_model_pack(args))
    db_path = args.db.resolve()
    db = read_database(db_path)
    if not db:
        raise ValueError(f"No enrolled faces found in {db_path}")

    probe = extract_face_embedding(app, args.image.resolve())
    winner, winner_score, verdict = match_embedding(
        probe.embedding,
        db,
        args.threshold,
    )

    print(f"Best match: {winner}")
    print(f"Cosine similarity: {winner_score:.4f}")
    print(f"Threshold: {args.threshold:.4f}")
    print(f"Verdict: {verdict}")
    return 0


def command_build_db(args: argparse.Namespace) -> int:
    np = np_module()
    app = load_face_analysis(selected_model_pack(args))
    image_root = args.image_root.resolve()
    db_path = args.db.resolve()
    if not image_root.exists():
        raise ValueError(f"Image root does not exist: {image_root}")

    db: dict[str, list[float]] = {}
    enrolled_people = 0

    for person_dir in sorted(path for path in image_root.iterdir() if path.is_dir()):
        embeddings = []
        image_paths = sorted(
            path
            for path in person_dir.iterdir()
            if path.is_file() and path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp"}
        )
        if not image_paths:
            continue

        for image_path in image_paths:
            try:
                face = extract_face_embedding(app, image_path)
            except Exception as exc:
                print(f"Skipping {image_path}: {exc}", file=sys.stderr)
                continue
            embeddings.append(face.embedding)

        if not embeddings:
            print(f"Skipping `{person_dir.name}`: no usable face images found.", file=sys.stderr)
            continue

        mean_embedding = normalize_embedding(np.mean(np.stack(embeddings), axis=0))
        db[person_dir.name] = mean_embedding.tolist()
        enrolled_people += 1
        print(f"Enrolled `{person_dir.name}` from {len(embeddings)} image(s).")

    if not db:
        raise ValueError(
            f"No people were enrolled from {image_root}. "
            "Add images under subfolders like input_images/alice/photo1.jpg."
        )

    write_database(db_path, db)
    print(f"Wrote {enrolled_people} identity embedding(s) to {db_path}")
    return 0


def command_compare(args: argparse.Namespace) -> int:
    app = load_face_analysis(selected_model_pack(args))
    first = extract_face_embedding(app, args.first.resolve())
    second = extract_face_embedding(app, args.second.resolve())
    similarity = cosine_similarity(first.embedding, second.embedding)
    same_person = similarity >= args.threshold
    print(f"Cosine similarity: {similarity:.4f}")
    print(f"Threshold: {args.threshold:.4f}")
    print(f"Same person: {'yes' if same_person else 'no'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Prepare and run a local face recognition pipeline backed by "
            "InsightFace ONNX models."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser(
        "prepare",
        help="Download the pretrained ONNX model package and initialize it.",
    )
    add_model_selection_arguments(prepare)
    prepare.set_defaults(func=command_prepare)

    enroll = subparsers.add_parser(
        "enroll",
        help="Store a normalized face embedding in a local JSON database.",
    )
    enroll.add_argument("name", help="Label to store in the database.")
    enroll.add_argument("image", type=Path, help="Image path for the enrolled face.")
    add_model_selection_arguments(enroll)
    enroll.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Embedding database path. Default: {DEFAULT_DB_PATH}",
    )
    enroll.set_defaults(func=command_enroll)

    match_cmd = subparsers.add_parser(
        "match",
        help="Compare an image against the local embedding database.",
    )
    match_cmd.add_argument("image", type=Path, help="Image path to recognize.")
    add_model_selection_arguments(match_cmd)
    match_cmd.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Embedding database path. Default: {DEFAULT_DB_PATH}",
    )
    match_cmd.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help=f"Cosine similarity threshold. Default: {DEFAULT_THRESHOLD}",
    )
    match_cmd.set_defaults(func=command_match)

    build_db = subparsers.add_parser(
        "build-db",
        help="Build a face database from subfolders like input_images/alice/*.jpg.",
    )
    add_model_selection_arguments(build_db)
    build_db.add_argument(
        "--image-root",
        type=Path,
        default=DEFAULT_IMAGE_ROOT,
        help=f"Root folder containing person subfolders. Default: {DEFAULT_IMAGE_ROOT}",
    )
    build_db.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Embedding database path. Default: {DEFAULT_DB_PATH}",
    )
    build_db.set_defaults(func=command_build_db)

    export_melange = subparsers.add_parser(
        "export-melange",
        help="Export the embedding ONNX model, sample input .npy, and metadata for Melange.",
    )
    add_model_selection_arguments(export_melange)
    export_melange.add_argument(
        "--image",
        type=Path,
        help="Optional sample image for the exported Melange input.",
    )
    export_melange.add_argument(
        "--image-root",
        type=Path,
        default=DEFAULT_IMAGE_ROOT,
        help=f"Image root to search when --image is not set. Default: {DEFAULT_IMAGE_ROOT}",
    )
    export_melange.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_EXPORT_DIR,
        help=f"Directory for Melange-ready export artifacts. Default: {DEFAULT_EXPORT_DIR}",
    )
    export_melange.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Embedding database path to copy into the export bundle. Default: {DEFAULT_DB_PATH}",
    )
    export_melange.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help=f"Cosine similarity threshold to store in metadata. Default: {DEFAULT_THRESHOLD}",
    )
    export_melange.set_defaults(func=command_export_melange)

    export_detector = subparsers.add_parser(
        "export-detector-melange",
        help="Export a fixed-shape face detector ONNX model and sample input for Melange.",
    )
    add_model_selection_arguments(export_detector)
    export_detector.add_argument(
        "--image",
        type=Path,
        help="Optional sample image for the exported Melange detector input.",
    )
    export_detector.add_argument(
        "--image-root",
        type=Path,
        default=DEFAULT_IMAGE_ROOT,
        help=f"Image root to search when --image is not set. Default: {DEFAULT_IMAGE_ROOT}",
    )
    export_detector.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_EXPORT_DIR,
        help=f"Directory for Melange-ready export artifacts. Default: {DEFAULT_EXPORT_DIR}",
    )
    export_detector.add_argument(
        "--image-size",
        type=int,
        default=DEFAULT_DETECTION_SIZE,
        help=f"Fixed detector input size. Default: {DEFAULT_DETECTION_SIZE}",
    )
    export_detector.set_defaults(func=command_export_detector_melange)

    compare_cmd = subparsers.add_parser(
        "compare",
        help="Compare two images directly without using a database.",
    )
    compare_cmd.add_argument("first", type=Path, help="First image path.")
    compare_cmd.add_argument("second", type=Path, help="Second image path.")
    add_model_selection_arguments(compare_cmd)
    compare_cmd.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help=f"Cosine similarity threshold. Default: {DEFAULT_THRESHOLD}",
    )
    compare_cmd.set_defaults(func=command_compare)

    return parser


def main() -> int:
    ensure_native_architecture()
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
