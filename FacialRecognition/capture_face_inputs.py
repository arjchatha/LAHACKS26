#!/usr/bin/env python3
"""
Capture face input images from a webcam for the local face recognition workflow.
"""

from __future__ import annotations

import argparse
import os
import platform
import subprocess
import sys
import time
from pathlib import Path

DEFAULT_OUTPUT_DIR = Path("input_images")


def ensure_native_architecture() -> None:
    if platform.system() != "Darwin":
        return
    if platform.machine() != "x86_64":
        return
    if os.environ.get("FACE_INPUTS_REEXEC") == "1":
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
    env["FACE_INPUTS_REEXEC"] = "1"
    os.execvpe("arch", ["arch", "-arm64", sys.executable, *sys.argv], env)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Capture one or more face images from your webcam."
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory where captured images are stored. Default: {DEFAULT_OUTPUT_DIR}",
    )
    parser.add_argument(
        "--prefix",
        default="face",
        help="Filename prefix for saved images.",
    )
    parser.add_argument(
        "--person",
        default="",
        help="Optional person name; images will be saved under output-dir/person/",
    )
    parser.add_argument(
        "--count",
        type=int,
        default=1,
        help="How many images to capture. Default: 1",
    )
    parser.add_argument(
        "--camera-index",
        type=int,
        default=0,
        help="Webcam index to open. Default: 0",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=1.5,
        help="Delay in seconds between captures. Default: 1.5",
    )
    return parser


def save_frame(cv2_module, frame, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    ok = cv2_module.imwrite(str(output_path), frame)
    if not ok:
        raise RuntimeError(f"Failed to save image to {output_path}")


def main() -> int:
    ensure_native_architecture()
    import cv2

    args = build_parser().parse_args()

    destination_dir = args.output_dir / args.person if args.person else args.output_dir

    if args.count < 1:
        print("Error: --count must be at least 1", file=sys.stderr)
        return 1

    capture = cv2.VideoCapture(args.camera_index)
    if not capture.isOpened():
        print(
            f"Error: could not open webcam at index {args.camera_index}",
            file=sys.stderr,
        )
        return 1

    window_name = "Capture Face Inputs"
    print("Press SPACE to capture immediately, or ESC to quit.")
    print(
        f"Auto-capture is enabled: {args.count} image(s), {args.delay:.1f}s between shots."
    )

    saved_paths: list[Path] = []
    next_capture_time = time.monotonic() + max(args.delay, 0.0)

    try:
        while len(saved_paths) < args.count:
            ok, frame = capture.read()
            if not ok:
                print("Error: failed to read from webcam", file=sys.stderr)
                return 1

            remaining = args.count - len(saved_paths)
            preview = frame.copy()
            cv2.putText(
                preview,
                f"Remaining: {remaining}",
                (20, 40),
                cv2.FONT_HERSHEY_SIMPLEX,
                1.0,
                (0, 255, 0),
                2,
            )
            cv2.putText(
                preview,
                "SPACE: capture now  ESC: quit",
                (20, 80),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (0, 255, 0),
                2,
            )
            cv2.imshow(window_name, preview)

            key = cv2.waitKey(1) & 0xFF
            should_capture = False
            if key == 27:
                print("Capture cancelled.")
                return 130
            if key == 32:
                should_capture = True
            elif time.monotonic() >= next_capture_time:
                should_capture = True

            if not should_capture:
                continue

            output_path = (
                destination_dir
                / f"{args.prefix}_{len(saved_paths) + 1:02d}.jpg"
            ).resolve()
            save_frame(cv2, frame, output_path)
            saved_paths.append(output_path)
            next_capture_time = time.monotonic() + max(args.delay, 0.0)
            print(f"Saved {output_path}")

        print("Capture complete.")
        for path in saved_paths:
            print(path)
        return 0
    finally:
        capture.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    raise SystemExit(main())
