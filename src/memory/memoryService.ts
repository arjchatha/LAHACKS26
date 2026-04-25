import { MemoryStore } from "./MemoryStore.js";
import type {
  DailySummary,
  EventMemory,
  ObjectCorrectionFields,
  ObjectMemory,
  PatientSpeechResult,
  PersonEnrollmentSession,
  PersonMemory,
  RecognitionStatus,
  RoutineMemory,
  TrustLevel,
} from "./types.js";

export interface PatientHomeRoutine {
  id: string;
  name: string;
  scheduledTime: string;
  completed: boolean;
  helperName?: string;
  pickupTime?: string;
}

export interface PatientHomeObject {
  id: string;
  name: string;
  usualLocation?: string;
  lastSeenLocation?: string;
  lastSeenDisplay?: string;
}

export interface PatientHomeView {
  reassurance: string;
  primaryCaregiver?: {
    name: string;
    relationship: string;
  };
  trustedPeople: Array<{
    id: string;
    name: string;
    relationship: string;
  }>;
  routines: PatientHomeRoutine[];
  importantObjects: PatientHomeObject[];
}

export interface CaregiverDashboardEvent {
  id: string;
  title: string;
  eventType: string;
  occurredAt: string;
  needsCaregiverReview: boolean;
  details: string;
}

export interface CaregiverDashboardObject {
  id: string;
  name: string;
  usualLocation?: string;
  lastSeenLocation?: string;
  lastSeenAt?: string;
  trustLevel: TrustLevel;
  confidence?: number;
}

export interface CaregiverDashboardRoutine {
  id: string;
  name: string;
  scheduledTime: string;
  completedAt?: string;
  safetyCritical: boolean;
}

export interface CaregiverDashboardDraftPerson {
  id: string;
  name: string;
  relationship: string;
  status: "draft" | "approved" | "rejected";
  recognitionStatus: RecognitionStatus;
  faceProfileId?: string;
  needsCaregiverReview: boolean;
  evidenceNotes: string[];
  updatedAt: string;
}

export interface CaregiverDashboardEnrollmentSession {
  id: string;
  status: string;
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

export interface CaregiverNeedsReview {
  draftPeople: CaregiverDashboardDraftPerson[];
  enrollmentSessions: CaregiverDashboardEnrollmentSession[];
  events: CaregiverDashboardEvent[];
}

export interface CaregiverDashboard {
  summary: DailySummary;
  needsReview: CaregiverNeedsReview;
  reviewItems: CaregiverDashboardEvent[];
  recentEvents: CaregiverDashboardEvent[];
  objects: CaregiverDashboardObject[];
  routines: CaregiverDashboardRoutine[];
}

export interface PatientAnswer {
  answer: string;
}

export interface MutationResult<T> {
  ok: boolean;
  data?: T;
  message: string;
}

export class MemoryService {
  public constructor(private readonly store = new MemoryStore()) {}

  public getPatientHome(): PatientHomeView {
    const snapshot = this.store.getSnapshot();
    const primaryCaregiver = snapshot.people.find((person) =>
      person.relationship.toLowerCase().includes("caregiver"),
    );

    return {
      reassurance: "You are safe. Anita and your family can help.",
      ...(primaryCaregiver
        ? {
            primaryCaregiver: {
              name: primaryCaregiver.name,
              relationship: primaryCaregiver.relationship,
            },
          }
        : {}),
      trustedPeople: snapshot.people
        .filter((person) => person.caregiverApproved && person.trustedSupport)
        .map((person) => ({
          id: person.id,
          name: person.name,
          relationship: person.relationship,
        })),
      routines: snapshot.routines.map((routine) => this.toPatientRoutine(routine, snapshot.people)),
      importantObjects: snapshot.objects
        .filter((object) => object.importance === "high")
        .map((object) => this.toPatientObject(object)),
    };
  }

  public detectObject(
    objectName: string,
    location: string,
    confidence: number,
  ): MutationResult<CaregiverDashboardObject> {
    const object = this.store.updateObjectLastSeen(
      objectName,
      location,
      confidence,
      "objectDetection",
    );

    return {
      ok: true,
      data: this.toDashboardObject(object),
      message: `${object.name} detected near ${location}.`,
    };
  }

  public askWhereIsObject(objectName: string): PatientAnswer {
    return {
      answer: this.store.answerWhereIsObject(objectName),
    };
  }

  public reportConfusion(transcript: string): PatientAnswer {
    return {
      answer: this.store.answerConfusionPhrase(transcript),
    };
  }

  public completeRoutine(routineName: string): MutationResult<CaregiverDashboardRoutine> {
    const routine = this.store.logRoutineCompleted(routineName);
    return routine
      ? {
          ok: true,
          data: this.toDashboardRoutine(routine),
          message: `${routine.name} marked complete.`,
        }
      : {
          ok: false,
          message: `No routine named "${routineName}" was found.`,
        };
  }

  public correctObject(
    objectName: string,
    fields: ObjectCorrectionFields,
  ): MutationResult<CaregiverDashboardObject> {
    const object = this.store.correctObjectMemory(objectName, fields, "Anita");
    return {
      ok: true,
      data: this.toDashboardObject(object),
      message: `${object.name} memory updated by caregiver.`,
    };
  }

  public startPersonEnrollmentSession(): MutationResult<CaregiverDashboardEnrollmentSession> {
    const session = this.store.startPersonEnrollmentSession();
    return {
      ok: true,
      data: this.toDashboardEnrollmentSession(session),
      message: `Started enrollment session ${session.id}.`,
    };
  }

  public addEnrollmentTranscript(
    sessionId: string,
    transcript: string,
  ): MutationResult<CaregiverDashboardEnrollmentSession> {
    const session = this.store.addEnrollmentTranscript(sessionId, transcript);
    return session
      ? {
          ok: true,
          data: this.toDashboardEnrollmentSession(session),
          message: `Added transcript to ${session.id}.`,
        }
      : {
          ok: false,
          message: `No enrollment session named "${sessionId}" was found.`,
        };
  }

  public attachEnrollmentFaceProfile(
    sessionId: string,
    faceProfileId: string,
    confidence: number,
  ): MutationResult<CaregiverDashboardEnrollmentSession> {
    const session = this.store.attachEnrollmentFaceProfile(sessionId, faceProfileId, confidence);
    return session
      ? {
          ok: true,
          data: this.toDashboardEnrollmentSession(session),
          message: `Attached face profile ${faceProfileId} to ${session.id}.`,
        }
      : {
          ok: false,
          message: `No enrollment session named "${sessionId}" was found.`,
        };
  }

  public createDraftPersonFromEnrollment(
    sessionId: string,
  ): MutationResult<CaregiverDashboardDraftPerson> {
    const person = this.store.createDraftPersonFromEnrollment(sessionId);
    return person
      ? {
          ok: true,
          data: this.toDashboardDraftPerson(person),
          message: `Created draft person memory for ${person.name}.`,
        }
      : {
          ok: false,
          message: `No enrollment session named "${sessionId}" was found.`,
        };
  }

  public approvePersonEnrollment(
    personId: string,
    caregiverName: string,
  ): MutationResult<CaregiverDashboardDraftPerson> {
    const person = this.store.approvePersonEnrollment(personId, caregiverName);
    return person
      ? {
          ok: true,
          data: this.toDashboardDraftPerson(person),
          message: `${person.name} approved for recognition.`,
        }
      : {
          ok: false,
          message: `No person memory named "${personId}" was found.`,
        };
  }

  public rejectPersonEnrollment(
    personId: string,
    caregiverName: string,
  ): MutationResult<CaregiverDashboardDraftPerson> {
    const person = this.store.rejectPersonEnrollment(personId, caregiverName);
    return person
      ? {
          ok: true,
          data: this.toDashboardDraftPerson(person),
          message: `${person.name} rejected for recognition.`,
        }
      : {
          ok: false,
          message: `No person memory named "${personId}" was found.`,
        };
  }

  public recognizeApprovedPerson(faceProfileId: string): PatientAnswer {
    return {
      answer: this.store.recognizeApprovedPerson(faceProfileId),
    };
  }

  public processPatientSpeech(transcript: string): PatientSpeechResult {
    return this.store.processPatientSpeech(transcript);
  }

  public getCaregiverDashboard(): CaregiverDashboard {
    const snapshot = this.store.getSnapshot();
    const recentEvents = snapshot.events.slice(-10).reverse().map((event) => this.toDashboardEvent(event));
    const reviewEvents = snapshot.events
      .filter((event) => event.needsCaregiverReview)
      .reverse()
      .map((event) => this.toDashboardEvent(event));
    const draftPeople = snapshot.people
      .filter((person) => person.needsCaregiverReview || person.status === "draft")
      .map((person) => this.toDashboardDraftPerson(person));
    const enrollmentSessions = snapshot.enrollmentSessions
      .filter((session) => session.needsCaregiverReview || session.status === "caregiverReview")
      .map((session) => this.toDashboardEnrollmentSession(session));

    return {
      summary: this.store.generateDailySummary(),
      needsReview: {
        draftPeople,
        enrollmentSessions,
        events: reviewEvents,
      },
      reviewItems: reviewEvents,
      recentEvents,
      objects: snapshot.objects.map((object) => this.toDashboardObject(object)),
      routines: snapshot.routines.map((routine) => this.toDashboardRoutine(routine)),
    };
  }

  public getMarkdownWiki(): string {
    return this.store.exportMarkdownWiki();
  }

  private toPatientRoutine(
    routine: RoutineMemory,
    people: PersonMemory[],
  ): PatientHomeRoutine {
    const helper = routine.helperPersonId
      ? people.find((person) => person.id === routine.helperPersonId)
      : undefined;

    return {
      id: routine.id,
      name: routine.name,
      scheduledTime: routine.scheduledTime,
      completed: Boolean(routine.completedAt),
      ...(helper ? { helperName: helper.name } : {}),
      ...(routine.pickupTime ? { pickupTime: routine.pickupTime } : {}),
    };
  }

  private toPatientObject(object: ObjectMemory): PatientHomeObject {
    const lastSeenDisplay = this.formatTimestamp(object.lastSeenAt);
    return {
      id: object.id,
      name: object.name,
      ...(object.usualLocation ? { usualLocation: object.usualLocation } : {}),
      ...(object.lastSeenLocation ? { lastSeenLocation: object.lastSeenLocation } : {}),
      ...(lastSeenDisplay ? { lastSeenDisplay } : {}),
    };
  }

  private toDashboardEvent(event: EventMemory): CaregiverDashboardEvent {
    return {
      id: event.id,
      title: event.title,
      eventType: event.eventType,
      occurredAt: this.formatTimestamp(event.occurredAt) ?? "Unknown",
      needsCaregiverReview: event.needsCaregiverReview,
      details: event.details,
    };
  }

  private toDashboardObject(object: ObjectMemory): CaregiverDashboardObject {
    const lastSeenAt = this.formatTimestamp(object.lastSeenAt);
    return {
      id: object.id,
      name: object.name,
      ...(object.usualLocation ? { usualLocation: object.usualLocation } : {}),
      ...(object.lastSeenLocation ? { lastSeenLocation: object.lastSeenLocation } : {}),
      ...(lastSeenAt ? { lastSeenAt } : {}),
      trustLevel: object.trustLevel,
      ...(object.confidence === undefined ? {} : { confidence: object.confidence }),
    };
  }

  private toDashboardRoutine(routine: RoutineMemory): CaregiverDashboardRoutine {
    const completedAt = this.formatTimestamp(routine.completedAt);
    return {
      id: routine.id,
      name: routine.name,
      scheduledTime: routine.scheduledTime,
      ...(completedAt ? { completedAt } : {}),
      safetyCritical: Boolean(routine.safetyCritical),
    };
  }

  private toDashboardDraftPerson(person: PersonMemory): CaregiverDashboardDraftPerson {
    return {
      id: person.id,
      name: person.name,
      relationship: person.relationship,
      status: person.status ?? (person.caregiverApproved ? "approved" : "draft"),
      recognitionStatus: person.recognitionStatus ?? "unverified",
      ...(person.faceProfileId ? { faceProfileId: person.faceProfileId } : {}),
      needsCaregiverReview: Boolean(person.needsCaregiverReview),
      evidenceNotes: person.evidenceNotes ?? [],
      updatedAt: this.formatTimestamp(person.updatedAt) ?? "Unknown",
    };
  }

  private toDashboardEnrollmentSession(
    session: PersonEnrollmentSession,
  ): CaregiverDashboardEnrollmentSession {
    return {
      id: session.id,
      status: session.status,
      startedAt: this.formatTimestamp(session.startedAt) ?? "Unknown",
      updatedAt: this.formatTimestamp(session.updatedAt) ?? "Unknown",
      transcriptSnippets: session.transcriptSnippets,
      ...(session.extractedName ? { extractedName: session.extractedName } : {}),
      ...(session.extractedRelationship
        ? { extractedRelationship: session.extractedRelationship }
        : {}),
      ...(session.extractionConfidence === undefined
        ? {}
        : { extractionConfidence: session.extractionConfidence }),
      ...(session.faceProfileId ? { faceProfileId: session.faceProfileId } : {}),
      ...(session.faceCaptureConfidence === undefined
        ? {}
        : { faceCaptureConfidence: session.faceCaptureConfidence }),
      ...(session.draftPersonId ? { draftPersonId: session.draftPersonId } : {}),
      needsCaregiverReview: session.needsCaregiverReview,
      evidenceNotes: session.evidenceNotes,
    };
  }

  private formatTimestamp(value: string | undefined): string | undefined {
    if (!value) {
      return undefined;
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return value;
    }

    return new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Los_Angeles",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(date);
  }
}

export const memoryService = new MemoryService();

export const getPatientHome = (): PatientHomeView => memoryService.getPatientHome();

export const detectObject = (
  objectName: string,
  location: string,
  confidence: number,
): MutationResult<CaregiverDashboardObject> =>
  memoryService.detectObject(objectName, location, confidence);

export const askWhereIsObject = (objectName: string): PatientAnswer =>
  memoryService.askWhereIsObject(objectName);

export const reportConfusion = (transcript: string): PatientAnswer =>
  memoryService.reportConfusion(transcript);

export const processPatientSpeech = (transcript: string): PatientSpeechResult =>
  memoryService.processPatientSpeech(transcript);

export const completeRoutine = (routineName: string): MutationResult<CaregiverDashboardRoutine> =>
  memoryService.completeRoutine(routineName);

export const correctObject = (
  objectName: string,
  fields: ObjectCorrectionFields,
): MutationResult<CaregiverDashboardObject> => memoryService.correctObject(objectName, fields);

export const getCaregiverDashboard = (): CaregiverDashboard =>
  memoryService.getCaregiverDashboard();

export const getMarkdownWiki = (): string => memoryService.getMarkdownWiki();

export const startPersonEnrollmentSession =
  (): MutationResult<CaregiverDashboardEnrollmentSession> =>
    memoryService.startPersonEnrollmentSession();

export const addEnrollmentTranscript = (
  sessionId: string,
  transcript: string,
): MutationResult<CaregiverDashboardEnrollmentSession> =>
  memoryService.addEnrollmentTranscript(sessionId, transcript);

export const attachEnrollmentFaceProfile = (
  sessionId: string,
  faceProfileId: string,
  confidence: number,
): MutationResult<CaregiverDashboardEnrollmentSession> =>
  memoryService.attachEnrollmentFaceProfile(sessionId, faceProfileId, confidence);

export const createDraftPersonFromEnrollment = (
  sessionId: string,
): MutationResult<CaregiverDashboardDraftPerson> =>
  memoryService.createDraftPersonFromEnrollment(sessionId);

export const approvePersonEnrollment = (
  personId: string,
  caregiverName: string,
): MutationResult<CaregiverDashboardDraftPerson> =>
  memoryService.approvePersonEnrollment(personId, caregiverName);

export const rejectPersonEnrollment = (
  personId: string,
  caregiverName: string,
): MutationResult<CaregiverDashboardDraftPerson> =>
  memoryService.rejectPersonEnrollment(personId, caregiverName);

export const recognizeApprovedPerson = (faceProfileId: string): PatientAnswer =>
  memoryService.recognizeApprovedPerson(faceProfileId);
