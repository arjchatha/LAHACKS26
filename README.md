# Face Recognition Starter for ZETIC Melange

This repo now contains a Python helper that downloads a pretrained ONNX-based
face recognition package, runs it locally, and points you at the ONNX file you
can upload to ZETIC Melange.

## What this does

- Downloads an InsightFace model pack into the repo.
- Runs face detection plus face embedding extraction locally on CPU.
- Lets you build a face database from `input_images/<person_name>/...`.
- Lets you match a new image against the enrolled database.
- Lets you run live webcam recognition with green known-face boxes and red unknown-face boxes.

## Important Melange note

ZETIC Melange itself runs models through the Android or iOS SDK after you upload
an ONNX or `.pt2` model to the Melange dashboard. This Python file is the local
prep and validation layer. It helps you get a facial recognition model running
and identify the ONNX asset to upload.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

## Usage

Prepare the model package:

```bash
.venv/bin/python face_recognition_melange.py prepare
```

The default model size is `medium`, which maps to `buffalo_s`.
You can choose the size directly:

```bash
.venv/bin/python face_recognition_melange.py prepare --model-size small
```

The size mapping is:

```text
small  -> buffalo_sc
medium -> buffalo_s
large  -> buffalo_l
```

You can still choose the pack explicitly if you want:

```bash
.venv/bin/python face_recognition_melange.py prepare --model-pack buffalo_s
```

Enroll a person:

```bash
.venv/bin/python face_recognition_melange.py enroll alice /path/to/alice.jpg
```

Build the full database from person folders:

```bash
.venv/bin/python face_recognition_melange.py build-db --image-root input_images
```

Match a new image against the local database:

```bash
.venv/bin/python face_recognition_melange.py match /path/to/query.jpg
```

Directly compare two images:

```bash
.venv/bin/python face_recognition_melange.py compare /path/to/a.jpg /path/to/b.jpg
```

Capture input images from your webcam:

```bash
.venv/bin/python capture_face_inputs.py --person alice --prefix sample --count 3
```

This saves images like:

```text
input_images/alice/sample_01.jpg
input_images/alice/sample_02.jpg
```

Run live webcam recognition:

```bash
.venv/bin/python live_face_recognition.py --db face_db.json
```

## Model source

The script downloads official InsightFace release packages such as
`buffalo_s.zip`, `buffalo_l.zip`, or `buffalo_sc.zip` from the
`deepinsight/insightface` GitHub release URL.

## Licensing

InsightFace's repository notes that its pretrained face recognition models may
have separate licensing constraints. Check the current InsightFace license terms
before using the pretrained model in production or commercial settings.
