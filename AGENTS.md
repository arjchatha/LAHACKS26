# MindAnchor Agent Instructions

## Product Direction

MindAnchor is a privacy-first, local memory companion for people with early memory loss.

The current implementation is a TypeScript, in-memory backend for a local memory wiki. It supports voice-first Patient Mode, caregiver-reviewed memory editing, and a mocked local person enrollment pipeline.

Keep the product centered on this principle:

- Patient Mode is a calm voice assistant.
- Caregiver Mode is the trusted review and editing surface.
- The memory wiki is the private local source of truth.
- Future on-device models provide senses such as speech, object detection, and face recognition.

## Current Scope

This repo currently implements only the local backend layer.

Do not add unless explicitly requested:

- Frontend UI
- Database
- Express/API server
- Real ZETIC integration
- Real speech recognition
- Real face recognition
- Cloud sync
- Authentication
- Medical diagnosis or medical claims

Everything should remain local, mocked where needed, and runnable with:

```bash
npm run typecheck
npm run demo
```

## Project Structure

Core backend files:

- `src/memory/types.ts`
- `src/memory/seedData.ts`
- `src/memory/MemoryStore.ts`
- `src/memory/memoryService.ts`
- `src/memory/markdownExport.ts`
- `src/demo/runDemo.ts`

`MemoryStore` owns in-memory state and product logic.

`memoryService` is the frontend-friendly facade. Future UI work should import from this layer rather than reaching into store internals.

`markdownExport` is for caregiver/demo visibility only. Patients should not see raw wiki markdown.

## Trust Model

Use these trust levels:

- `caregiverApproved`: high trust. Use for people, medication routines, appointments, and safety-critical facts.
- `aiObserved`: medium trust. Use for object sightings, mocked model outputs, face profiles, and transcript extraction.
- `patientReported`: contextual trust. Useful as a clue, but it must not override safety-critical caregiver-approved facts.

Safety rules:

- Do not automatically accept patient-reported medication changes.
- Do not identify unapproved people as trusted.
- Do not expose detailed wiki pages in Patient Mode.
- Prefer short, calm, patient-safe responses.
- Caregiver-approved facts override AI-observed and patient-reported facts.

## Voice-First Patient Mode

Patient Mode is transcript-driven. The frontend should send local speech-to-text transcripts into:

```ts
processPatientSpeech(transcript: string)
```

The backend returns `PatientSpeechResult`:

- `transcript`
- `intent`
- `spokenResponse`
- `displayText`
- `needsCaregiverReview`
- `relatedMemoryIds`

Supported patient speech intents:

- `objectLocation`
- `confusion`
- `personIdentity`
- `routineStatus`
- `unknown`

Current routing expectations:

- "Where are my keys?" routes to object location memory.
- "Where are my glasses?" routes to object location memory.
- "I forgot where I'm going" routes to confusion support.
- "I feel lost" routes to confusion support.
- "Did I take my medicine?" routes to routine status.
- "Who is this?" returns a safe response unless an approved face/person context exists.

Responses should be suitable for text-to-speech. `displayText` should be short enough for a minimal overlay.

Speech interactions should be logged as events so caregivers can review what happened.

## Memory Models

The wiki stores:

- People
- Objects
- Routines
- Places
- Events
- Daily summaries
- Person enrollment sessions

Memory entries should include:

- `id`
- `type`
- `createdAt`
- `updatedAt`
- `trustLevel`
- `source`
- `notes`
- optional `caregiverApproved`
- optional `confidence`

People can also include:

- `recognitionStatus`
- `faceProfileId`
- `needsCaregiverReview`
- `evidenceNotes`
- `status`

## Seed Data

Keep demo seed data for:

- Anita: daughter and caregiver
- Rahul: grandson
- Keys: usually near the front door
- Glasses: usually on the bedroom nightstand
- Medicine Box: kitchen counter
- Morning Medication: 8:00 AM
- Doctor Appointment: 3:30 PM, Anita picks patient up at 3:15 PM
- Kitchen
- Bedroom
- Front door
- Doctor clinic

## MemoryStore Responsibilities

`MemoryStore` should continue to provide:

- `updateObjectLastSeen`
- `answerWhereIsObject`
- `answerConfusionPhrase`
- `answerWhoIsPerson`
- `logRoutineCompleted`
- `addPatientReportedMemory`
- `correctObjectMemory`
- `generateDailySummary`
- `exportMarkdownWiki`
- `getSnapshot`
- `processPatientSpeech`

Person enrollment methods:

- `startPersonEnrollmentSession`
- `addEnrollmentTranscript`
- `attachEnrollmentFaceProfile`
- `createDraftPersonFromEnrollment`
- `approvePersonEnrollment`
- `rejectPersonEnrollment`
- `recognizeApprovedPerson`

`generateDailySummary` should return caregiver-friendly bullet items, not a compressed stats sentence.

Timestamps shown in dashboard, markdown, and summaries should be readable local times, not raw ISO strings.

## Person Enrollment Pipeline

The current enrollment flow is local and mocked:

1. Patient talks to someone.
2. Local speech transcript is added to an enrollment session.
3. Simple extraction rules infer possible name and relationship.
4. A mocked local face profile id is attached.
5. A draft `PersonMemory` is created.
6. Caregiver reviews and approves or rejects.
7. Recognition only identifies the person after caregiver approval.

Draft person memory must use:

- `trustLevel: "aiObserved"`
- `caregiverApproved: false`
- `trustedSupport: false`
- `recognitionStatus: "unverified"`
- `needsCaregiverReview: true`
- `status: "draft"`
- evidence notes from transcript and face profile data

Approved person memory must use:

- `trustLevel: "caregiverApproved"`
- `caregiverApproved: true`
- `trustedSupport: true`
- `recognitionStatus: "approvedForRecognition"`
- `status: "approved"`

Rejected people must not be recognized as trusted.

`recognizeApprovedPerson(faceProfileId)` must only identify people who are caregiver-approved and approved for recognition. Otherwise it must return a safe unknown/unapproved response.

## memoryService Contract

Keep these stable frontend-facing functions:

- `getPatientHome`
- `detectObject`
- `askWhereIsObject`
- `reportConfusion`
- `completeRoutine`
- `correctObject`
- `getCaregiverDashboard`
- `getMarkdownWiki`
- `processPatientSpeech`

Enrollment-facing service functions:

- `startPersonEnrollmentSession`
- `addEnrollmentTranscript`
- `attachEnrollmentFaceProfile`
- `createDraftPersonFromEnrollment`
- `approvePersonEnrollment`
- `rejectPersonEnrollment`
- `recognizeApprovedPerson`

Return typed view models from `memoryService`, not raw internal state when a frontend-friendly shape is more appropriate.

`getCaregiverDashboard()` should include:

- daily summary
- review events
- recent events
- objects
- routines
- `needsReview.draftPeople`
- `needsReview.enrollmentSessions`
- `needsReview.events`

## Markdown Export

Markdown export is for caregiver/demo inspection.

It should include sections for:

- People
- Objects
- Routines
- Places
- Events
- Daily Summary

Draft or unapproved people must clearly show:

- Status
- Caregiver approved
- Recognition status
- Needs caregiver review
- Face profile id when present
- Evidence notes

## Demo Expectations

`src/demo/runDemo.ts` should exercise the main local flows:

- Object detection for keys near kitchen counter
- Voice-first patient speech:
  - "Where are my keys?"
  - "I forgot where I'm going"
  - "Did I take my medicine?"
  - "Who is this?"
- Caregiver object correction
- Person enrollment for Maya
- Recognition blocked before approval
- Anita approves Maya
- Recognition succeeds after approval
- Caregiver dashboard output
- Markdown wiki export

## Coding Style

- Keep code simple and readable.
- Prefer small files with clear responsibilities.
- Keep state local and in-memory unless explicitly asked otherwise.
- Use TypeScript types strictly.
- Add comments only where they clarify product logic or safety constraints.
- Avoid overengineering.
- Run `npm run typecheck` and `npm run demo` after backend changes.
