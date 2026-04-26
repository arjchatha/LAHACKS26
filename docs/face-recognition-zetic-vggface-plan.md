# Face Recognition Plan: VGG-Face + ZETIC

This plan turns the Oxford VGG-Face PyTorch model into the local face-recognition engine for MindAnchor.

## Source Model

- Weights: https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.pth
- Model definition: https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.py

The model definition reports:

- Input shape: `224x224x3`
- Runtime tensor shape for PyTorch/ZETIC export: `[1, 3, 224, 224]`
- Per-channel mean: `[129.186279296875, 104.76238250732422, 93.59396362304688]`
- Per-channel std: `[1, 1, 1]`
- Default output: `2622` class logits from `fc8`

For face recognition, we should not use the `fc8` classifier output. We export an embedding model by replacing `fc8` with `Identity`, so the model returns the `relu7` / `fc7` feature vector. That embedding is `4096` floats.

## Export For ZETIC

Use the helper script:

```bash
python3 scripts/export_vggface_embedding_for_zetic.py
```

It creates ignored local files under:

```text
model_artifacts/vggface/
  vgg_face_dag.py
  vgg_face_dag.pth
  input.npy
  vgg_face_embedding.onnx
```

Upload `vgg_face_embedding.onnx` and `input.npy` to ZETIC Melange. ZETIC requires a fixed input order and fixed shape, so keep the sample input exactly `[1, 3, 224, 224]`.

The script exports ONNX opset 18 by default and embeds weights directly in `vgg_face_embedding.onnx`, avoiding a separate `.onnx.data` sidecar file.

## ZETIC Project Values Needed

After upload, the iOS app needs:

- `ZETIC_PERSONAL_KEY`
- `ZETIC_VGGFACE_MODEL_NAME`
- optional `ZETIC_VGGFACE_MODEL_VERSION`

These should live in local developer config or an ignored `.xcconfig`, not committed source.

## Enrollment Flow

When a caregiver records a profile video:

1. Sample frames from the video every `0.25-0.4s`.
2. Use Apple Vision to detect face rectangles.
3. Keep frames with exactly one clear, large face.
4. Crop face with padding, square it, resize to `224x224`.
5. Convert to RGB float tensor.
6. Subtract VGG-Face mean per channel.
7. Run ZETIC embedding inference.
8. L2-normalize every `4096`-float embedding.
9. Average the best embeddings.
10. L2-normalize the averaged embedding.
11. Store it with the profile.

## Live Recognition Flow

In Live mode:

1. Apple Vision keeps detecting/tracking face boxes.
2. Every few frames, crop and preprocess the focused face.
3. Run the same ZETIC embedding model.
4. L2-normalize the live embedding.
5. Compare to stored profile embeddings with cosine similarity.
6. Only display a name after a stable match.

Suggested first-pass thresholds:

- `cosineSimilarity >= 0.78`: candidate match
- same `personId` wins at least `3` of the last `5` checks
- otherwise show the existing safe unknown message

These numbers must be tuned with real videos from the actual app.

## Swift Services To Add

```text
Services/
  FaceCropper.swift
  ZeticFaceEmbeddingService.swift
  FaceEmbeddingStore.swift
  FaceRecognitionService.swift
```

Responsibilities:

- `FaceCropper`: Vision bounding box to padded `224x224` face image/tensor.
- `ZeticFaceEmbeddingService`: ZETIC model initialization and inference.
- `FaceEmbeddingStore`: local storage for profile embeddings.
- `FaceRecognitionService`: enrollment embedding extraction, live matching, stability gating.

## Safety Rules

- Never show a name from a single frame.
- Prefer "Person nearby" when confidence is ambiguous.
- Deleted profiles must remove stored video and stored embedding.
- Patient mode should not expose raw embeddings, raw model output, or detailed internal matching scores.
