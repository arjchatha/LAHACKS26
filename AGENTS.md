
# MindAnchor Agent Instructions — Focused Person Memory Demo

## Product Summary

MindAnchor is a privacy-first memory companion for people with early memory loss.

This prototype is focused on one clear demo:

> The patient meets someone they do not remember. MindAnchor listens to the conversation, extracts who the person is, stores a draft memory page, asks the caregiver to approve it, and later recognizes the same person to remind the patient who they are.

Core principle:

- Patient Mode is calm and voice-first.
- Caregiver Mode is the trusted review and approval surface.
- The memory wiki is the private local source of truth.
- Face/speech model outputs are treated as local evidence.
- Identity is never shown as trusted until caregiver approval.

This is a quick hackathon prototype. Keep it simple, local, and demo-ready.

---

## Current Prototype Scope

The current demo should focus on:

1. Person learning from conversation
2. Draft person memory creation
3. Caregiver approval
4. Later recognition using a mocked local face profile ID
5. A readable memory wiki page for the learned person

Allowed:

- SwiftUI frontend
- Local Swift mock memory store / memory bridge
- Conversation transcript input or simulated speech transcript
- Mock face profile ID, such as `face-maya-001`
- Apple Vision face detection bounding boxes if already available
- ZETIC/Melange adapter stubs if useful
- Text-to-speech for patient-facing responses
- Caregiver approval UI
- Memory wiki demo view

Do not add unless explicitly requested:

- Cloud sync
- Authentication
- Production database
- Medical diagnosis claims
- Emergency dispatch
- Full dementia assessment
- Large unrelated features like object recall, medication tracking, or full daily planning
- Real biometric identity claims without caregiver approval

Everything should remain local/in-memory unless explicitly requested otherwise.

---

## Main Demo Flow

The demo should show this exact story:

### Scene 1: First Conversation

Patient is talking to a person they do not know.

Transcript:

```txt
Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail.
````

MindAnchor extracts:

* Name: Maya
* Relationship: neighbor from next door
* Helpful context: usually helps bring in your mail
* Face profile ID: `face-maya-001`

MindAnchor creates a draft person memory.

Patient-facing response before approval:

```txt
I learned a possible new person. A caregiver needs to approve this memory before I identify them for you.
```

---

### Scene 2: Caregiver Review

Caregiver sees a draft card:

```txt
Maya
Possible relationship: neighbor from next door
Helpful context: helps bring in your mail
Evidence: conversation transcript
Face profile: face-maya-001
Status: Needs approval
```

Caregiver taps:

```txt
Approve
```

The person becomes approved for recognition.

---

### Scene 3: Later Recognition

Patient meets the same person again.

The app receives or simulates:

```txt
faceProfileId = face-maya-001
```

If Maya is approved, the app speaks/displays:

```txt
This is Maya, your neighbor from next door. She helps bring in your mail.
```

If Maya is not approved yet, the app must say:

```txt
I see someone nearby, but I do not have a caregiver-approved identity for them yet.
```

---

## Product Safety Rules

Never identify a person as trusted before caregiver approval.

Do not say:

```txt
This is Maya.
```

unless:

* the person memory is approved
* caregiverApproved is true
* recognitionStatus is approvedForRecognition

Before approval, say:

```txt
I see someone nearby, but I do not have a caregiver-approved identity for them yet.
```

Do not make medical claims.

Do not say:

* “You are having a dementia episode.”
* “This proves memory decline.”
* “This person is safe” before caregiver approval.
* “You can trust this person” unless caregiver approved.

Patient-facing language should be:

* short
* calm
* spoken clearly
* non-clinical
* reassuring

---

## Memory Wiki Concept

The memory wiki is the local source of truth.

For this focused demo, the wiki only needs to store:

* People
* Conversation evidence
* Face profile IDs
* Approval state
* Recognition state

The patient should not see raw markdown.

The caregiver/demo view can show a readable “memory wiki” page.

Example draft page:

```md
# Maya

Status: Draft
Caregiver Approved: false
Recognition Status: unverified
Trust Level: aiObserved
Needs Caregiver Review: true

## Extracted Information

Name: Maya
Relationship: neighbor from next door
Helpful context: helps bring in your mail

## Evidence

Transcript:
“Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail.”

Face profile ID:
face-maya-001

## Safety

Do not identify this person to the patient until caregiver approval.
```

Example approved page:

```md
# Maya

Status: Approved
Caregiver Approved: true
Recognition Status: approvedForRecognition
Trust Level: caregiverApproved

## Relationship

Neighbor from next door.

## Helpful Context

Maya usually helps bring in the mail.

## Patient Prompt

This is Maya, your neighbor from next door. She helps bring in your mail.

## Evidence

Originally introduced in conversation.
Approved by caregiver.
Face profile ID: face-maya-001
```

---

## Data Model

Create or maintain a person memory model like:

```swift
struct PersonMemory: Identifiable {
    let id: String
    var name: String
    var relationship: String
    var helpfulContext: String
    var patientPrompt: String
    var transcriptEvidence: [String]
    var faceProfileId: String?
    var voiceProfileId: String?
    var status: PersonStatus
    var caregiverApproved: Bool
    var recognitionStatus: RecognitionStatus
    var trustLevel: TrustLevel
    var createdAt: Date
    var updatedAt: Date
}
```

Suggested enums:

```swift
enum PersonStatus {
    case draft
    case approved
    case rejected
}

enum RecognitionStatus {
    case unverified
    case approvedForRecognition
}

enum TrustLevel {
    case caregiverApproved
    case aiObserved
    case patientReported
}
```

Enrollment session model:

```swift
struct PersonEnrollmentSession: Identifiable {
    let id: String
    var transcript: String
    var extractedName: String?
    var extractedRelationship: String?
    var extractedHelpfulContext: String?
    var faceProfileId: String?
    var faceConfidence: Double?
    var draftPersonId: String?
    var status: EnrollmentStatus
    var createdAt: Date
    var updatedAt: Date
}
```

Suggested enum:

```swift
enum EnrollmentStatus {
    case collectingEvidence
    case draftCreated
    case caregiverReview
    case approved
    case rejected
}
```

---

## Required Memory Bridge

If this branch is SwiftUI-only, implement a local Swift memory bridge.

Use a protocol like:

```swift
protocol MemoryBridge {
    func startPersonEnrollmentSession() -> String

    func addConversationTranscript(
        sessionId: String,
        transcript: String
    )

    func attachFaceProfile(
        sessionId: String,
        faceProfileId: String,
        confidence: Double
    )

    func createDraftPersonMemory(
        sessionId: String
    ) -> String?

    func approvePerson(
        personId: String,
        caregiverName: String
    )

    func rejectPerson(
        personId: String,
        caregiverName: String
    )

    func recognizePersonByFaceProfile(
        faceProfileId: String
    ) -> PatientRecognitionResult

    func getCaregiverReviewQueue() -> [PersonMemory]

    func getPersonWikiPage(
        personId: String
    ) -> String
}
```

Result model:

```swift
struct PatientRecognitionResult {
    let spokenResponse: String
    let displayText: String
    let recognizedPersonId: String?
    let caregiverApproved: Bool
}
```

Implement `MockMemoryBridge` locally for the demo.

---

## Required Functions

The app should support these operations:

### 1. Start Enrollment

```swift
let sessionId = memoryBridge.startPersonEnrollmentSession()
```

Creates a new person enrollment session.

---

### 2. Add Conversation Transcript

```swift
memoryBridge.addConversationTranscript(
    sessionId: sessionId,
    transcript: "Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail."
)
```

For the MVP, extraction can be rule-based.

It should detect:

* `I'm Maya`
* `my name is Maya`
* `I'm your neighbor`
* `neighbor from next door`
* `help bring in your mail`

Expected extraction:

```txt
Name: Maya
Relationship: neighbor from next door
Helpful context: helps bring in your mail
```

No real LLM is required for this prototype, but the logic should be shaped so a future LLM extractor can replace the rules.

---

### 3. Attach Face Profile

```swift
memoryBridge.attachFaceProfile(
    sessionId: sessionId,
    faceProfileId: "face-maya-001",
    confidence: 0.88
)
```

For MVP, the face profile ID can be mocked.

If Apple Vision/ZETIC face detection exists, use it only to detect a face and trigger profile capture. Do not claim real biometric recognition unless implemented.

---

### 4. Create Draft Person

```swift
let personId = memoryBridge.createDraftPersonMemory(sessionId: sessionId)
```

Creates draft `PersonMemory`.

Draft person memory must use:

* `status: .draft`
* `trustLevel: .aiObserved`
* `caregiverApproved: false`
* `recognitionStatus: .unverified`

---

### 5. Approve Person

```swift
memoryBridge.approvePerson(
    personId: personId,
    caregiverName: "Anita"
)
```

Approved person memory must use:

* `status: .approved`
* `trustLevel: .caregiverApproved`
* `caregiverApproved: true`
* `recognitionStatus: .approvedForRecognition`

---

### 6. Recognize Later

```swift
let result = memoryBridge.recognizePersonByFaceProfile(
    faceProfileId: "face-maya-001"
)
```

If approved, return:

```txt
This is Maya, your neighbor from next door. She helps bring in your mail.
```

If not approved, return:

```txt
I see someone nearby, but I do not have a caregiver-approved identity for them yet.
```

---

## Frontend Screens

Build the frontend around three simple screens or sections.

### 1. Conversation Capture Screen

Purpose:

* Simulate or capture the first conversation.
* Extract person information.
* Create a draft memory.

Should include:

* camera preview or camera placeholder
* transcript input or demo transcript button
* extracted info preview
* button: “Create Draft Memory”
* status message: “Needs caregiver approval”

Demo transcript button should insert:

```txt
Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail.
```

---

### 2. Caregiver Review Screen

Purpose:

* Show draft person memories.
* Approve or reject them.

Should include:

* draft person card
* name
* relationship
* helpful context
* transcript evidence
* face profile ID
* approve button
* reject button

---

### 3. Later Recognition Screen

Purpose:

* Simulate the later conversation.
* Recognize the same local face profile.
* Retrieve the approved person memory.

Should include:

* camera preview or placeholder
* button: “Simulate Maya recognized”
* patient-facing response overlay
* text-to-speech response if available

Before approval, this screen should return the safe unapproved response.

After approval, it should return Maya’s approved prompt.

---

### 4. Memory Wiki View

Purpose:

* Show the generated person wiki page.
* Make the LLM wiki idea visible to judges.

Should show:

* draft wiki page before approval
* approved wiki page after approval
* transcript evidence
* face profile ID
* approval state
* recognition state

This view is caregiver/demo-facing only.

---

## Camera / Face Detection Direction

For the quick demo, face recognition can be mocked.

Minimum:

* Use a camera preview or placeholder.
* Use Apple Vision face detection if already available.
* Draw a polished face bounding box if a face is detected.
* Create a mocked face profile ID when the user taps a demo button.

Preferred first technical milestone:

```txt
Rear camera feed
→ Apple Vision face detection bounding box
→ mocked faceProfileId
→ enrollment session
→ caregiver approval
→ later recognition by same faceProfileId
```

Important:

* Face detection is not face recognition.
* Do not claim actual identity matching unless implemented.
* The mock `faceProfileId` is acceptable for hackathon demo if clearly framed as a local profile placeholder.

---

## UI Style

The app should feel native iOS, not like a debug screen.

Use:

* SwiftUI
* translucent materials
* rounded cards
* capsules
* SF Symbols
* soft shadows
* calm spacing
* simple typography

Avoid:

* harsh debug rectangles
* crowded buttons
* raw JSON
* raw logs
* long text in patient mode
* neon green debug boxes unless in debug mode

Patient-facing UI should be minimal.

Caregiver/demo UI can show more details.

---

## Text-to-Speech

If implemented, use `AVSpeechSynthesizer`.

Create a small service like:

```swift
final class TextToSpeechService {
    func speak(_ text: String) {
        // AVSpeechSynthesizer implementation
    }
}
```

Use it when recognition returns a patient-facing prompt.

Speech should be calm and not too fast.

---

## Demo Buttons

For reliability, include demo buttons.

Suggested buttons:

Conversation Capture:

* “Use Maya Transcript”
* “Attach Face Profile”
* “Create Draft Memory”

Caregiver Review:

* “Approve Maya”
* “Reject Maya”

Later Recognition:

* “Simulate Maya Recognized”
* “Ask Who Is This?”

Memory Wiki:

* “Show Draft Wiki”
* “Show Approved Wiki”

---

## Required Demo Script

The app should support this sequence:

1. Open Conversation Capture.
2. Tap “Use Maya Transcript.”
3. Tap “Attach Face Profile.”
4. Tap “Create Draft Memory.”
5. Show draft wiki page:

   * Maya
   * neighbor from next door
   * helps bring in mail
   * caregiver approved: false
6. Go to Later Recognition.
7. Tap “Simulate Maya Recognized” before approval.
8. App says:

   * “I see someone nearby, but I do not have a caregiver-approved identity for them yet.”
9. Go to Caregiver Review.
10. Tap “Approve Maya.”
11. Go back to Later Recognition.
12. Tap “Simulate Maya Recognized.”
13. App says:

* “This is Maya, your neighbor from next door. She helps bring in your mail.”

14. Show approved wiki page.

---

## ZETIC/Melange Direction

ZETIC/Melange is part of the final sponsor story, but this focused demo can mock model outputs if needed.

Use this explanation:

* Speech model transcribes the conversation on-device.
* Face detection/profile capture happens locally.
* Extracted identity information is stored in a local memory wiki.
* Caregiver approves the memory.
* Later recognition retrieves the approved memory.

If implementing stubs:

```swift
final class ZeticSpeechService {
    func transcribeDemoAudio() -> String {
        "Hi, I'm Maya. I'm your neighbor from next door. I usually help bring in your mail."
    }
}
```

```swift
final class ZeticFaceProfileService {
    func captureDemoFaceProfile() -> (faceProfileId: String, confidence: Double) {
        ("face-maya-001", 0.88)
    }
}
```

If real Melange is unavailable, keep the app compiling with mocks and TODOs.

---

## Coding Style

* Keep the demo simple.
* Prefer a working mock over a broken real integration.
* Keep views separate from memory logic.
* Use protocols for services.
* Keep all state local/in-memory.
* Avoid overengineering.
* Keep patient-facing text short.
* Make approval state obvious.
* Do not identify unapproved people.
* Do not add unrelated features.

---

## What Codex Should Do First

Before coding, Codex should inspect the repo and determine:

1. Whether an Xcode project exists.
2. Which SwiftUI views currently exist.
3. Whether there is already a camera manager.
4. Whether there is already a memory bridge.
5. Whether Apple Vision face detection is already partially implemented.
6. Whether demo controls already exist.

Then Codex should propose the smallest file changes to implement the focused person-memory demo.

If no Xcode project exists, create documentation/stubs only and do not attempt to create a broken Xcode project unless explicitly asked.

---

## Validation

After changes:

* Build the Xcode project if possible.
* Keep the demo flow working.
* Keep all memory local.
* Do not introduce medical claims.
* Do not identify anyone before approval.

```
```
