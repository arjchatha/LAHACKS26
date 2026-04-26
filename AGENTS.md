# MindAnchor Agent Instructions

## Product Direction

MindAnchor is a privacy-first, local memory companion for people with early memory loss.

The active prototype is a focused SwiftUI/Xcode demo:

- The patient camera screen is the main experience.
- Apple Vision detects whether a face is in frame.
- Speech transcription starts only while a face is bounded.
- Transcript snapshots are sent to a memory coordinator.
- An LLM decision engine decides whether the conversation contains important memory information.
- Important person memories are stored locally as draft memories.
- Patient Mode stays quiet: no tabs, no buttons, no raw transcript, no wiki popup.
- When a memory is being written, show only a small temporary green top-right chip such as `Saving` then `Saved`.

Core principle:

- Patient Mode is calm, voice-first, and camera-first.
- The memory wiki/storage layer is the private local source of truth.
- Face detection means only “a face is present,” not “this person is Maya.”
- Identity should never be presented as trusted without caregiver approval.

Keep the project simple, local, and demo-ready.

## Current App Structure

Important Swift files:

- `LAHACKS26/ContentView.swift`
- `LAHACKS26/Views/PatientCameraView.swift`
- `LAHACKS26/ViewModels/PatientCameraViewModel.swift`
- `LAHACKS26/Models/FaceDetectionResult.swift`
- `LAHACKS26/Services/CameraManager.swift`
- `LAHACKS26/Services/VisionFaceDetectionService.swift`
- `LAHACKS26/Services/AppleSpeechTranscriptionService.swift`
- `LAHACKS26/Services/SpeechTranscriptionService.swift`
- `LAHACKS26/Services/ZeticWhisperTranscriptionService.swift`
- `LAHACKS26/Services/LLMDecisionEngine.swift`
- `LAHACKS26/Services/MemoryCoordinator.swift`
- `LAHACKS26/Services/MemoryBridge.swift`
- `LAHACKS26/Services/TextToSpeechService.swift`

`ContentView` should keep showing `PatientCameraView` as the primary app surface.

`PatientCameraView` owns the quiet patient experience:

- rear camera preview
- single polished face bounding box
- face-gated speech transcription
- calls into `MemoryCoordinator`
- optional patient-safe text-to-speech response
- temporary top-right green save chip

`MemoryCoordinator` owns the memory-capture pipeline:

- starts and ends face-bound conversations
- accepts transcript updates
- debounces Apple Speech partial transcripts into stable snapshots
- prints transcript and LLM decisions to the console during testing
- runs live, reconciliation, and final LLM passes
- stores memory only when the decision engine says it is important enough
- publishes `MemoryCoordinatorEvent` for `Saving` and `Saved` UI chips

`MemoryBridge` owns local in-memory storage only.

`LLMDecisionEngine` owns transcript analysis. Do not move LLM-ish parsing back into `MockMemoryBridge`.

## Patient Camera Requirements

Patient Mode must remain minimal.

Allowed on the patient camera screen:

- rear camera feed
- face bounding box
- calm camera permission/fallback message
- small temporary top-right green chip when saving/noted

Not allowed on the patient camera screen unless explicitly requested:

- bottom tabs
- manual capture buttons
- raw transcript panels
- markdown/wiki popups
- debug JSON
- caregiver review controls
- long instructional text

Speech transcription should only run while a face is being bounded. Keep the gate tolerant enough that brief detection flicker does not constantly start and stop transcription.

## Face Pipeline

Current milestone is face detection only.

Use Apple Vision for detection:

- `VNDetectFaceRectanglesRequest`
- rear camera only
- preview uses aspect fill
- draw one polished bounding box for the best/current face

Important:

- Face detection is not face recognition.
- Do not claim identity from Vision face detection.
- The current `faceProfileId` is a mocked local placeholder for future enrollment/recognition.
- If rear camera is unavailable, show a calm fallback message.

## Speech Pipeline

Use Apple Speech framework for the working prototype:

- `SFSpeechRecognizer`
- `AVAudioEngine`
- `SFSpeechAudioBufferRecognitionRequest`
- live partial transcripts

Keep `ZeticWhisperTranscriptionService` as a compile-safe stub for the future ZETIC Melange Whisper path:

- Audio -> Whisper feature extractor -> encoder -> decoder -> transcript
- Keep the transcript interface swappable with Apple Speech.
- Do not add broken ZETIC imports if the SDK is unavailable.

## LLM-Coordinated Memory Capture

The correct architecture is:

```txt
Rear camera face detection
  -> face-gated Apple Speech transcription
  -> stable transcript snapshots
  -> MemoryCoordinator
  -> LLMDecisionEngine
  -> local MemoryBridge storage if important
  -> temporary Saved chip
```

Do not use simple pattern matching as the primary decision for whether to store memory. The LLM decision engine should decide whether a transcript is important.

The current decision model includes:

- `TranscriptAnalysisDecision`
- `MemoryType`
- `MemoryImportance`
- `ConversationState`
- `ConversationAnalysisResult`
- timestamped transcript segments

The coordinator should use a hybrid streaming plus consolidation flow:

- Fast live layer: update provisional conversation state every few seconds.
- Reconciliation layer: periodically revisit recent context.
- Final layer: run when the face-bound conversation ends.

Live LLM outputs are provisional. Final storage should happen from reconciliation or final decisions, not from every partial speech result.

For testing, console logging should include:

- transcript snapshots
- live/reconciliation/final decisions
- conversation state JSON
- memory saved messages

## Storage Rules

Store person memory only when the LLM decision is strong enough.

Expected important examples:

- `This is Akshay. He is my grandson.`
- `Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail.`
- `My name is Maya. I live next door.`

Expected unimportant examples:

- `Hey`
- `How are you?`
- `Nice weather today.`
- short small talk with no durable identity, relationship, routine, or object fact

Draft person memories should remain local/in-memory for now.

Draft identity memory should use safe defaults:

- caregiver approval required
- recognition unverified
- not trusted as a patient-facing identity yet

Unapproved recognition must return a safe response:

```txt
I see someone nearby, but I do not have a caregiver-approved identity for them yet.
```

Approved recognition can return a patient-safe identity prompt, for example:

```txt
This is Maya, your neighbor from next door. She helps bring in your mail.
```

## Save Chip Behavior

When the coordinator is actually saving a memory:

- publish a `MemoryCoordinatorEvent` with title `Saving`
- show the small green top-right chip
- after local storage succeeds, publish title `Saved`
- hide the chip after a short delay

Do not show a permanent “saved draft memory” widget. Do not show the wiki on top of the camera screen.

## Trust And Safety

Never identify a person as trusted before caregiver approval.

Do not say:

- `This is Maya.`
- `You can trust this person.`
- `This person is safe.`

unless the memory is caregiver-approved and approved for recognition.

Do not make medical claims.

Do not say:

- `You are having a dementia episode.`
- `This proves memory decline.`
- `This person is safe` before caregiver approval.

Patient-facing language should be:

- short
- calm
- spoken clearly
- non-clinical
- reassuring

## Scope Boundaries

Do not add unless explicitly requested:

- cloud sync
- authentication
- production database
- Express/API server
- full caregiver UI
- bottom-tab navigation
- object recall
- medication tracking
- emergency dispatch
- medical diagnosis claims
- production ZETIC integration if the SDK is not ready

Keep everything local/in-memory unless explicitly requested otherwise.

## UI Style

The app should feel native iOS, not like a debug screen.

Use:

- SwiftUI
- translucent materials where appropriate
- capsules
- SF Symbols
- soft shadows
- calm spacing
- simple typography

Avoid:

- crowded controls
- raw logs in Patient Mode
- raw JSON in Patient Mode
- long text in Patient Mode
- permanent overlays

## Build And Validation

After Swift changes, build with:

```bash
xcodebuild -project LAHACKS26.xcodeproj -scheme LAHACKS26 -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/LAHACKS26DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected manual test flow:

1. Launch the app on a device.
2. Point rear camera at a face.
3. Confirm a face bounding box appears.
4. Confirm transcription starts only while the face is bounded.
5. Say: `This is Akshay. He is my grandson.`
6. Watch console logs for transcript snapshots and LLM decisions.
7. Confirm a temporary green `Saving` / `Saved` chip appears only when memory is stored.
8. Confirm small talk like `How are you? Nice weather today.` does not store a memory.

The simulator may emit CoreSimulator service warnings in sandboxed CLI builds. The important line is:

```txt
** BUILD SUCCEEDED **
```

## Coding Style

- Keep the demo simple.
- Keep views separate from memory logic.
- Use protocols for services.
- Keep all state local/in-memory.
- Avoid overengineering.
- Keep patient-facing text short.
- Do not identify unapproved people.
- Do not add unrelated features.
- Use `apply_patch` for manual edits.
