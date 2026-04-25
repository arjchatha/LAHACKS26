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
  | "caregiverCorrection";

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

export interface MemorySeedData {
  people: PersonMemory[];
  objects: ObjectMemory[];
  routines: RoutineMemory[];
  places: PlaceMemory[];
  events: EventMemory[];
}

export type MemorySnapshot = MemorySeedData;

export type ObjectCorrectionFields = Partial<
  Pick<ObjectMemory, "usualLocation" | "lastSeenLocation" | "importance" | "notes">
>;
