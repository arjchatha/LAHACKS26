import { MemoryStore } from "./MemoryStore.js";
import type {
  DailySummary,
  EventMemory,
  ObjectCorrectionFields,
  ObjectMemory,
  PersonMemory,
  RoutineMemory,
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

export interface CaregiverDashboard {
  summary: DailySummary;
  reviewItems: CaregiverDashboardEvent[];
  recentEvents: CaregiverDashboardEvent[];
  objects: Array<{
    id: string;
    name: string;
    usualLocation?: string;
    lastSeenLocation?: string;
    lastSeenDisplay?: string;
    trustLevel: string;
    confidence?: number;
  }>;
  routines: Array<{
    id: string;
    name: string;
    scheduledTime: string;
    completedAt?: string;
    completedDisplay?: string;
    safetyCritical: boolean;
  }>;
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
  ): MutationResult<ObjectMemory> {
    const object = this.store.updateObjectLastSeen(
      objectName,
      location,
      confidence,
      "objectDetection",
    );

    return {
      ok: true,
      data: object,
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

  public completeRoutine(routineName: string): MutationResult<RoutineMemory> {
    const routine = this.store.logRoutineCompleted(routineName);
    return routine
      ? {
          ok: true,
          data: routine,
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
  ): MutationResult<ObjectMemory> {
    const object = this.store.correctObjectMemory(objectName, fields, "Anita");
    return {
      ok: true,
      data: object,
      message: `${object.name} memory updated by caregiver.`,
    };
  }

  public getCaregiverDashboard(): CaregiverDashboard {
    const snapshot = this.store.getSnapshot();
    const recentEvents = snapshot.events.slice(-10).reverse().map((event) => this.toDashboardEvent(event));

    return {
      summary: this.store.generateDailySummary(),
      reviewItems: snapshot.events
        .filter((event) => event.needsCaregiverReview)
        .reverse()
        .map((event) => this.toDashboardEvent(event)),
      recentEvents,
      objects: snapshot.objects.map((object) => {
        const lastSeenDisplay = this.formatTimestamp(object.lastSeenAt);
        return {
          id: object.id,
          name: object.name,
          ...(object.usualLocation ? { usualLocation: object.usualLocation } : {}),
          ...(object.lastSeenLocation ? { lastSeenLocation: object.lastSeenLocation } : {}),
          ...(lastSeenDisplay ? { lastSeenDisplay } : {}),
          trustLevel: object.trustLevel,
          ...(object.confidence === undefined ? {} : { confidence: object.confidence }),
        };
      }),
      routines: snapshot.routines.map((routine) => {
        const completedDisplay = this.formatTimestamp(routine.completedAt);
        return {
          id: routine.id,
          name: routine.name,
          scheduledTime: routine.scheduledTime,
          ...(routine.completedAt ? { completedAt: routine.completedAt } : {}),
          ...(completedDisplay ? { completedDisplay } : {}),
          safetyCritical: Boolean(routine.safetyCritical),
        };
      }),
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
): MutationResult<ObjectMemory> => memoryService.detectObject(objectName, location, confidence);

export const askWhereIsObject = (objectName: string): PatientAnswer =>
  memoryService.askWhereIsObject(objectName);

export const reportConfusion = (transcript: string): PatientAnswer =>
  memoryService.reportConfusion(transcript);

export const completeRoutine = (routineName: string): MutationResult<RoutineMemory> =>
  memoryService.completeRoutine(routineName);

export const correctObject = (
  objectName: string,
  fields: ObjectCorrectionFields,
): MutationResult<ObjectMemory> => memoryService.correctObject(objectName, fields);

export const getCaregiverDashboard = (): CaregiverDashboard =>
  memoryService.getCaregiverDashboard();

export const getMarkdownWiki = (): string => memoryService.getMarkdownWiki();
