# Face Recognition Plan: VGG-Face + Core ML

This is the no-ZETIC path. It keeps the full face-recognition system local to iOS by converting the Oxford VGG-Face PyTorch model into a Core ML `.mlpackage`.

## Source Model

- Weights: https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.pth
- Model definition: https://www.robots.ox.ac.uk/~albanie/models/pytorch-mcn/vgg_face_dag.py

The model expects:

- Tensor input: `[1, 3, 224, 224]`
- Color order: RGB
- Mean subtraction per channel: `[129.186279296875, 104.76238250732422, 93.59396362304688]`
- Output after our wrapper: `embedding [1, 4096]`

The original model returns `fc8` class logits for 2,622 identities. For this app we replace `fc8` with `Identity` and use the `fc7` feature vector as the face embedding.

## Convert To Core ML

Install dependencies:

```bash
python3 -m pip install -r requirements.txt
```

Convert:

```bash
python3 scripts/export_vggface_embedding_for_coreml.py
```

Output:

```text
model_artifacts/vggface/VGGFaceEmbedding.mlpackage
```

Add `VGGFaceEmbedding.mlpackage` to the `LAHACKS26` Xcode target. Keep the generated file out of git unless the team intentionally wants to version a large model artifact.

## Enrollment Flow

When a caregiver records a profile video:

1. Sample video frames every `0.25-0.4s`.
2. Use Apple Vision to find face rectangles.
3. Keep frames with one clear, large face.
4. Crop with padding, square, resize to `224x224`.
5. Convert to `[1, 3, 224, 224]` RGB Float32.
6. Subtract VGG-Face channel means.
7. Run `VGGFaceEmbedding.mlpackage`.
8. L2-normalize each embedding.
9. Average the best embeddings.
10. L2-normalize the final average.
11. Store the final embedding with the profile.

## Live Recognition Flow

1. Apple Vision detects the live face box.
2. Crop and preprocess the face the same way as enrollment.
3. Run the Core ML model.
4. L2-normalize the embedding.
5. Compare against stored profile embeddings with cosine similarity.
6. Show the profile only after a stable match.

Suggested starting rule:

- `cosineSimilarity >= 0.78`
- same person wins `3` of the last `5` checks
- otherwise show "Person nearby"

Tune these numbers with real recorded profiles. For this product, false negatives are better than false names.

## Swift Services To Add

```text
Services/
  FaceCropper.swift
  CoreMLFaceEmbeddingService.swift
  FaceEmbeddingStore.swift
  FaceRecognitionService.swift
```

Responsibilities:

- `FaceCropper`: crop/resize/preprocess a Vision face box.
- `CoreMLFaceEmbeddingService`: load `VGGFaceEmbedding.mlpackage` and return `[Float]`.
- `FaceEmbeddingStore`: persist profile embeddings locally.
- `FaceRecognitionService`: compare embeddings and gate stable matches.

## Important Warning

The VGG-Face model is large. The converted model may be hundreds of MB, which is heavy for a hackathon iOS app and may be slow in Live mode. This direct Core ML path is simpler operationally than ZETIC, but a smaller mobile embedding model would be better before shipping.
