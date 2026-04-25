export type MemoryType = "person" | "object" | "routine" | "place" | "event";

export type TrustLevel = "caregiverApproved" | "aiObserved" | "patientReported";

export type MemorySource =
  | "caregiver"
  | "objectDetection"
  | "speech"
  | "patient"
  | "demo";

export type EventType =
  | "objectDetected"
  | "objectAsked"
  | "confusion"
  | "personAsked"
  | "routineCompleted"
  | "patientReported"
  | "caregiverCorrection"
  | "personEnrollmentStarted"
  | "personEnrollmentTranscriptAdded"
  | "personEnrollmentFaceAttached"
  | "personEnrollmentDraftCreated"
  | "personEnrollmentApproved"
  | "personEnrollmentRejected"
  | "patientSpeechProcessed";

export type PatientSpeechIntent =
  | "objectLocation"
  | "confusion"
  | "personIdentity"
  | "routineStatus"
  | "unknown";

export type EnrollmentStatus =
  | "collectingEvidence"
  | "draftCreated"
  | "caregiverReview"
  | "approved"
  | "rejected";

export type RecognitionStatus = "unverified" | "approvedForRecognition";

export interface MemoryBase {
  id: string;
  type: MemoryType;
  createdAt: string;
  updatedAt: string;
  trustLevel: TrustLevel;
  source: MemorySource;
  notes: string[];
  caregiverApproved?: boolean;
  confidence?: number;
}

export interface PersonMemory extends MemoryBase {
  type: "person";
  name: string;
  relationship: string;
  calmingDescription: string;
  trustedSupport: boolean;
  recognitionStatus?: RecognitionStatus;
  faceProfileId?: string;
  needsCaregiverReview?: boolean;
  evidenceNotes?: string[];
  status?: "draft" | "approved" | "rejected";
}

export interface ObjectMemory extends MemoryBase {
  type: "object";
  name: string;
  usualLocation?: string;
  lastSeenLocation?: string;
  lastSeenAt?: string;
  importance: "low" | "medium" | "high";
}

export interface RoutineMemory extends MemoryBase {
  type: "routine";
  name: string;
  scheduledTime: string;
  description: string;
  placeId?: string;
  helperPersonId?: string;
  pickupTime?: string;
  completedAt?: string;
  safetyCritical?: boolean;
}

export interface PlaceMemory extends MemoryBase {
  type: "place";
  name: string;
  description: string;
}

export interface EventMemory extends MemoryBase {
  type: "event";
  eventType: EventType;
  title: string;
  occurredAt: string;
  details: string;
  needsCaregiverReview: boolean;
  relatedMemoryIds: string[];
}

export interface DailySummary {
  date: string;
  displayDate: string;
  totalEvents: number;
  reviewNeededCount: number;
  completedRoutines: string[];
  recentObjectSightings: string[];
  patientReports: string[];
  caregiverCorrections: string[];
  bullets: string[];
  narrative: string;
}

export interface PatientSpeechResult {
  transcript: string;
  intent: PatientSpeechIntent;
  spokenResponse: string;
  displayText: string;
  needsCaregiverReview: boolean;
  relatedMemoryIds: string[];
}

export interface PersonEnrollmentSession {
  id: string;
  status: EnrollmentStatus;
  startedAt: string;
  updatedAt: string;
  transcriptSnippets: string[];
  extractedName?: string;
  extractedRelationship?: string;
  extractionConfidence?: number;
  faceProfileId?: string;
  faceCaptureConfidence?: number;
  draftPersonId?: string;
  needsCaregiverReview: boolean;
  evidenceNotes: string[];
}

export interface MemorySeedData {
  people: PersonMemory[];
  objects: ObjectMemory[];
  routines: RoutineMemory[];
  places: PlaceMemory[];
  events: EventMemory[];
  enrollmentSessions: PersonEnrollmentSession[];
}

export type MemorySnapshot = MemorySeedData;

export type ObjectCorrectionFields = Partial<
  Pick<ObjectMemory, "usualLocation" | "lastSeenLocation" | "importance" | "notes">
>;
