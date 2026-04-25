#!/usr/bin/env python3
"""
Run live webcam face recognition with colored boxes and labels.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from face_recognition_melange import (
    DEFAULT_DB_PATH,
    DEFAULT_THRESHOLD,
    ensure_native_architecture,
    load_face_analysis,
    add_model_selection_arguments,
    match_embedding,
    read_database,
    selected_model_pack,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Open the webcam, detect faces live, and draw green boxes for "
            "recognized faces or red boxes for unknown faces."
        )
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Embedding database path. Default: {DEFAULT_DB_PATH}",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        help=f"Recognition threshold. Default: {DEFAULT_THRESHOLD}",
    )
    add_model_selection_arguments(parser)
    parser.add_argument(
        "--camera-index",
        type=int,
        default=0,
        help="Webcam index to open. Default: 0",
    )
    parser.add_argument(
        "--min-score",
        type=float,
        default=0.50,
        help="Minimum face detection confidence to display. Default: 0.50",
    )
    return parser


def clamp_bbox(bbox, width: int, height: int) -> tuple[int, int, int, int]:
    x1, y1, x2, y2 = bbox
    return (
        max(0, min(width - 1, int(x1))),
        max(0, min(height - 1, int(y1))),
        max(0, min(width - 1, int(x2))),
        max(0, min(height - 1, int(y2))),
    )


def main() -> int:
    ensure_native_architecture()
    import cv2

    args = build_parser().parse_args()
    db = read_database(args.db.resolve())
    if not db:
        print(
            f"Error: no enrolled faces found in {args.db.resolve()}. "
            "Build the database first with `face_recognition_melange.py build-db`.",
            file=sys.stderr,
        )
        return 1

    app = load_face_analysis(selected_model_pack(args))
    capture = cv2.VideoCapture(args.camera_index)
    if not capture.isOpened():
        print(
            f"Error: could not open webcam at index {args.camera_index}",
            file=sys.stderr,
        )
        return 1

    print("Press Q or ESC to quit.")
    try:
        while True:
            ok, frame = capture.read()
            if not ok:
                print("Error: failed to read from webcam", file=sys.stderr)
                return 1

            faces = app.get(frame)
            height, width = frame.shape[:2]

            for face in faces:
                det_score = float(face.det_score)
                if det_score < args.min_score:
                    continue

                best_name, similarity, verdict = match_embedding(
                    face.embedding,
                    db,
                    args.threshold,
                )
                recognized = verdict != "unknown"
                label = verdict if recognized else "unknown"
                if recognized:
                    label = f"{label} {similarity:.2f}"
                else:
                    label = f"unknown {similarity:.2f}"

                color = (0, 200, 0) if recognized else (0, 0, 255)
                x1, y1, x2, y2 = clamp_bbox(face.bbox, width, height)
                cv2.rectangle(frame, (x1, y1), (x2, y2), color, 2)

                text_origin_y = y1 - 10 if y1 > 30 else y1 + 25
                cv2.putText(
                    frame,
                    label,
                    (x1, text_origin_y),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.7,
                    color,
                    2,
                    cv2.LINE_AA,
                )

            cv2.imshow("Live Face Recognition", frame)
            key = cv2.waitKey(1) & 0xFF
            if key in {27, ord("q"), ord("Q")}:
                break
    finally:
        capture.release()
        cv2.destroyAllWindows()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
