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


def load_image(image_path: Path) -> np.ndarray:
    np = np_module()
    import cv2

    raw = np.fromfile(str(image_path), dtype=np.uint8)
    image = cv2.imdecode(raw, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not decode image: {image_path}")
    return image


def extract_face_embedding(app, image_path: Path) -> FaceEmbedding:
    np = np_module()
    image = load_image(image_path)
    faces = app.get(image)
    if not faces:
        raise ValueError(f"No face detected in {image_path}")

    best_face = max(
        faces,
        key=lambda face: float(face.det_score) * bbox_area(face.bbox),
    )
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
    print("Model is ready.")
    print(f"Model size: {args.model_size}")
    print(f"Model pack: {model_pack}")
    print(f"Using InsightFace root: {INSIGHTFACE_ROOT}")
    print(f"Prepared providers: {app.models.keys()}")
    print("ONNX files:")
    for path in onnx_files:
        print(f"  {path}")
    print(
        "For Melange, upload the face embedding ONNX from this package to the "
        "Melange dashboard. In the buffalo packs, that is typically the file "
        "containing `w600k` or `mbf` in its name."
    )
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
