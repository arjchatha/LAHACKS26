# Face Recognition Starter for ZETIC Melange

This repo contains a local face-recognition workflow plus a Melange export step.
It now does the handoff you actually need for ZETIC Melange:

- picks the correct face-embedding ONNX from the InsightFace pack
- generates a sample `.npy` input tensor for Melange upload
- exports metadata you can reuse during mobile integration
- keeps the local database and webcam tools for validation

## What this does

- Downloads an InsightFace model pack into the repo.
- Runs face detection plus face embedding extraction locally on CPU.
- Lets you build a face database from `FacialRecognition/input_images/<person_name>/...`.
- Lets you match a new image against the enrolled database.
- Lets you run live webcam recognition with green known-face boxes and red unknown-face boxes.

## Melange flow

ZETIC Melange runs the exported model through its Android or iOS SDK after you
upload the ONNX model and a representative sample input. The repo now produces
that upload bundle directly.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Usage

Prepare the model package:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py prepare
```

Export a Melange-ready bundle:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py export-melange
```

Export a fixed-shape face detector bundle too:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py export-detector-melange
```

That creates `FacialRecognition/melange_export/` with:

- the selected embedding ONNX model
- `face_embedding_input.npy` for Melange upload
- `sample_face_crop.png` so you can inspect the aligned crop
- `melange_metadata.json` with input shape, tensor names, threshold, and a CLI example
- `face_db.json` if you already built or enrolled a database
- `det_500m_fixed.onnx` and `face_detection_input.npy` if you export the detector bundle
- `melange_detector_metadata.json` for the detector upload path

The default model size is `medium`, which maps to `buffalo_s`.
You can choose the size directly:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py prepare --model-size small
```

The size mapping is:

```text
small  -> buffalo_sc
medium -> buffalo_s
large  -> buffalo_l
```

You can still choose the pack explicitly if you want:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py prepare --model-pack buffalo_s
```

Enroll a person:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py enroll alice /path/to/alice.jpg
```

Build the full database from person folders:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py build-db --image-root FacialRecognition/input_images
```

Match a new image against the local database:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py match /path/to/query.jpg
```

Directly compare two images:

```bash
.venv/bin/python FacialRecognition/face_recognition_melange.py compare /path/to/a.jpg /path/to/b.jpg
```

Capture input images from your webcam:

```bash
.venv/bin/python FacialRecognition/capture_face_inputs.py --person alice --prefix sample --count 3
```

This saves images like:

```text
FacialRecognition/input_images/alice/sample_01.jpg
FacialRecognition/input_images/alice/sample_02.jpg
```

Run live webcam recognition:

```bash
.venv/bin/python FacialRecognition/live_face_recognition.py --db FacialRecognition/face_db.json
```

## Upload to Melange

After `export-melange`, upload these files from `FacialRecognition/melange_export/`:

- the exported embedding `.onnx`
- `face_embedding_input.npy`

If you prefer the CLI, the script prints a ready-made command in this form:

```bash
zetic gen -p YOUR_PROJECT_NAME -i face_embedding_input.npy w600k_mbf.onnx
```

For the current Melange integration flow and SDK setup, see the official docs:

- [ZETIC Melange Quick Start](https://docs.zetic.ai/)
- [ZETIC Melange iOS Integration](https://docs.zetic.ai/app-implementation/ios)

Those docs currently describe initializing `ZeticMLangeModel` with your
`personalKey` and deployed model `name`, then calling `run(inputs:)` with the
same input shape you exported here.

## Model source

The script downloads official InsightFace release packages such as
`buffalo_s.zip`, `buffalo_l.zip`, or `buffalo_sc.zip` from the
`deepinsight/insightface` GitHub release URL.

## Licensing

InsightFace's repository notes that its pretrained face recognition models may
have separate licensing constraints. Check the current InsightFace license terms
before using the pretrained model in production or commercial settings.
