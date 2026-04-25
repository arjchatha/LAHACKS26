import { seedData } from "./seedData.js";
import { exportMarkdownWiki as renderMarkdownWiki } from "./markdownExport.js";
import type {
  DailySummary,
  EventMemory,
  EventType,
  MemorySeedData,
  MemorySource,
  MemorySnapshot,
  ObjectCorrectionFields,
  ObjectMemory,
  PersonMemory,
  PlaceMemory,
  RoutineMemory,
  TrustLevel,
} from "./types.js";

type EventDraft = {
  eventType: EventType;
  title: string;
  details: string;
  trustLevel: TrustLevel;
  source: MemorySource;
  needsCaregiverReview?: boolean;
  relatedMemoryIds?: string[];
  notes?: string[];
  confidence?: number;
};

export class MemoryStore {
  private readonly people = new Map<string, PersonMemory>();
  private readonly objects = new Map<string, ObjectMemory>();
  private readonly routines = new Map<string, RoutineMemory>();
  private readonly places = new Map<string, PlaceMemory>();
  private readonly events: EventMemory[] = [];

  public constructor(data: MemorySeedData = seedData) {
    data.people.forEach((person) => this.people.set(this.key(person.name), this.clone(person)));
    data.objects.forEach((object) => this.objects.set(this.key(object.name), this.clone(object)));
    data.routines.forEach((routine) => this.routines.set(this.key(routine.name), this.clone(routine)));
    data.places.forEach((place) => this.places.set(this.key(place.name), this.clone(place)));
    data.events.forEach((event) => this.events.push(this.clone(event)));
  }

  public updateObjectLastSeen(
    objectName: string,
    location: string,
    confidence: number,
    source: MemorySource,
  ): ObjectMemory {
    const now = this.now();
    const objectKey = this.key(objectName);
    const existing = this.objects.get(objectKey);
    const object: ObjectMemory =
      existing ??
      {
        id: this.idFromName("object", objectName),
        type: "object",
        name: this.toTitleCase(objectName),
        createdAt: now,
        updatedAt: now,
        trustLevel: source === "caregiver" ? "caregiverApproved" : "aiObserved",
        source,
        notes: ["Created from a last-seen observation."],
        importance: "medium",
      };

    const updated: ObjectMemory = {
      ...object,
      updatedAt: now,
      trustLevel: source === "caregiver" ? "caregiverApproved" : "aiObserved",
      source,
      confidence,
      lastSeenLocation: location,
      lastSeenAt: now,
    };

    this.objects.set(objectKey, updated);
    this.logEvent({
      eventType: "objectDetected",
      title: `${updated.name} detected`,
      details: `${updated.name} were detected near ${location}.`,
      trustLevel: "aiObserved",
      source,
      confidence,
      relatedMemoryIds: [updated.id],
      notes: [`Detection confidence: ${Math.round(confidence * 100)}%.`],
    });

    return this.clone(updated);
  }

  public answerWhereIsObject(objectName: string): string {
    const object = this.findObject(objectName);
    const displayName = object?.name.toLowerCase() ?? objectName.toLowerCase();
    const answer = object?.lastSeenLocation
      ? `Your ${displayName} were last seen near the ${object.lastSeenLocation}.`
      : object?.usualLocation
        ? `Your ${displayName} are usually ${object.usualLocation}.`
        : `I do not know where your ${displayName} are yet. I will ask Anita to help.`;

    this.logEvent({
      eventType: "objectAsked",
      title: `Asked where ${object?.name ?? this.toTitleCase(objectName)} are`,
      details: answer,
      trustLevel: "patientReported",
      source: "speech",
      relatedMemoryIds: object ? [object.id] : [],
    });

    return answer;
  }

  public answerConfusionPhrase(transcript: string): string {
    const routine = this.findMostRelevantRoutine(transcript);
    const helper = routine?.helperPersonId ? this.findPersonById(routine.helperPersonId) : undefined;
    const place = routine?.placeId ? this.findPlaceById(routine.placeId) : undefined;

    const answer = routine
      ? [
          `You have a ${routine.name.toLowerCase()} at ${routine.scheduledTime}.`,
          helper && routine.pickupTime
            ? `${helper.name} is picking you up at ${routine.pickupTime}.`
            : undefined,
          place ? `You are going to the ${place.name.toLowerCase()}.` : undefined,
          "You are safe.",
        ]
          .filter((part): part is string => part !== undefined)
          .join(" ")
      : "You are safe. I will ask Anita to help with where you are going.";

    this.logEvent({
      eventType: "confusion",
      title: "Patient confusion phrase",
      details: `Transcript: "${transcript}". Answer: ${answer}`,
      trustLevel: "patientReported",
      source: "speech",
      needsCaregiverReview: true,
      relatedMemoryIds: routine ? [routine.id] : [],
      notes: ["Review confusion context and confirm upcoming plans."],
    });

    return answer;
  }

  public answerWhoIsPerson(personName: string): string {
    const person = this.findPerson(personName);
    const answer =
      person && person.caregiverApproved && person.trustedSupport
        ? `This is ${person.name}, your ${person.relationship}. ${person.calmingDescription}`
        : `I cannot confirm who ${personName} is. Please check with Anita before trusting them.`;

    this.logEvent({
      eventType: "personAsked",
      title: `Asked who ${person?.name ?? this.toTitleCase(personName)} is`,
      details: answer,
      trustLevel: "patientReported",
      source: "speech",
      needsCaregiverReview: !person?.caregiverApproved,
      relatedMemoryIds: person ? [person.id] : [],
    });

    return answer;
  }

  public logRoutineCompleted(routineName: string): RoutineMemory | undefined {
    const routine = this.findRoutine(routineName);
    if (!routine) {
      this.logEvent({
        eventType: "routineCompleted",
        title: `Unknown routine marked complete: ${routineName}`,
        details: `A completion was reported for "${routineName}", but no matching routine exists.`,
        trustLevel: "patientReported",
        source: "patient",
        needsCaregiverReview: true,
      });
      return undefined;
    }

    const now = this.now();
    const updated: RoutineMemory = {
      ...routine,
      updatedAt: now,
      completedAt: now,
    };
    this.routines.set(this.key(routine.name), updated);

    this.logEvent({
      eventType: "routineCompleted",
      title: `${routine.name} completed`,
      details: `${routine.name} was marked complete.`,
      trustLevel: "aiObserved",
      source: "patient",
      relatedMemoryIds: [routine.id],
      needsCaregiverReview: Boolean(routine.safetyCritical),
      notes: routine.safetyCritical ? ["Safety-critical routine completion should be reviewable."] : [],
    });

    return this.clone(updated);
  }

  public addPatientReportedMemory(text: string): EventMemory {
    const safetyCritical = this.isSafetyCritical(text);
    return this.logEvent({
      eventType: "patientReported",
      title: "Patient-reported memory",
      details: text,
      trustLevel: "patientReported",
      source: "patient",
      needsCaregiverReview: safetyCritical,
      notes: safetyCritical
        ? ["Possible medication, appointment, leaving-home, or safety claim. Caregiver should review."]
        : ["Patient-reported clue logged without overwriting caregiver-approved memory."],
    });
  }

  public correctObjectMemory(
    objectName: string,
    fields: ObjectCorrectionFields,
    caregiverName: string,
  ): ObjectMemory {
    const now = this.now();
    const objectKey = this.key(objectName);
    const existing = this.objects.get(objectKey);
    const base: ObjectMemory =
      existing ??
      {
        id: this.idFromName("object", objectName),
        type: "object",
        name: this.toTitleCase(objectName),
        createdAt: now,
        updatedAt: now,
        trustLevel: "caregiverApproved",
        source: "caregiver",
        notes: [],
        importance: "medium",
      };

    const corrected: ObjectMemory = {
      ...base,
      ...fields,
      updatedAt: now,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      caregiverApproved: true,
      notes: [
        ...(fields.notes ?? base.notes),
        `Corrected by ${caregiverName} at ${this.formatTimeForHumans(now)}.`,
      ],
    };

    this.objects.set(objectKey, corrected);
    this.logEvent({
      eventType: "caregiverCorrection",
      title: `${corrected.name} memory corrected`,
      details: `${caregiverName} corrected ${corrected.name}.`,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      relatedMemoryIds: [corrected.id],
      notes: [`Updated fields: ${Object.keys(fields).join(", ") || "none"}.`],
    });

    return this.clone(corrected);
  }

  public generateDailySummary(): DailySummary {
    const today = this.localDate(this.now());
    const displayDate = this.formatDateForHumans(this.now());
    const todaysEvents = this.events.filter((event) => this.localDate(event.occurredAt) === today);
    const completedRoutines = this.routinesList()
      .filter((routine) => routine.completedAt && this.localDate(routine.completedAt) === today)
      .map((routine) => `${routine.name} completed at ${this.formatTimeForHumans(routine.completedAt)}`);
    const recentObjectSightings = todaysEvents
      .filter((event) => event.eventType === "objectDetected")
      .map((event) => `${event.details} (${this.formatTimeForHumans(event.occurredAt)})`);
    const patientReports = todaysEvents
      .filter((event) => event.eventType === "patientReported" || event.eventType === "confusion")
      .map((event) => `${event.details} (${this.formatTimeForHumans(event.occurredAt)})`);
    const caregiverCorrections = todaysEvents
      .filter((event) => event.eventType === "caregiverCorrection")
      .map((event) => `${event.details} (${this.formatTimeForHumans(event.occurredAt)})`);
    const reviewNeededCount = todaysEvents.filter((event) => event.needsCaregiverReview).length;
    const reviewEvents = todaysEvents.filter((event) => event.needsCaregiverReview);
    const bullets = [
      `${todaysEvents.length} event(s) logged for ${displayDate}.`,
      reviewNeededCount > 0
        ? `${reviewNeededCount} item(s) need caregiver review: ${reviewEvents
            .map((event) => `${event.title} at ${this.formatTimeForHumans(event.occurredAt)}`)
            .join("; ")}.`
        : "No caregiver review items are pending today.",
      recentObjectSightings.length > 0
        ? `Object sightings: ${recentObjectSightings.join("; ")}.`
        : "No object sightings logged today.",
      completedRoutines.length > 0
        ? `Completed routines: ${completedRoutines.join("; ")}.`
        : "No routines have been marked complete today.",
      caregiverCorrections.length > 0
        ? `Caregiver corrections: ${caregiverCorrections.join("; ")}.`
        : "No caregiver corrections logged today.",
    ];

    return {
      date: today,
      displayDate,
      totalEvents: todaysEvents.length,
      reviewNeededCount,
      completedRoutines,
      recentObjectSightings,
      patientReports,
      caregiverCorrections,
      bullets,
      narrative: bullets.map((bullet) => `- ${bullet}`).join("\n"),
    };
  }

  public getSnapshot(): MemorySnapshot {
    return {
      people: this.peopleList(),
      objects: this.objectsList(),
      routines: this.routinesList(),
      places: this.placesList(),
      events: this.eventsList(),
    };
  }

  public exportMarkdownWiki(): string {
    return renderMarkdownWiki(this.getSnapshot());
  }

  private logEvent(draft: EventDraft): EventMemory {
    const now = this.now();
    const event: EventMemory = {
      id: `event-${String(this.events.length + 1).padStart(4, "0")}`,
      type: "event",
      eventType: draft.eventType,
      title: draft.title,
      createdAt: now,
      updatedAt: now,
      occurredAt: now,
      details: draft.details,
      trustLevel: draft.trustLevel,
      source: draft.source,
      needsCaregiverReview: draft.needsCaregiverReview ?? false,
      relatedMemoryIds: draft.relatedMemoryIds ?? [],
      notes: draft.notes ?? [],
      ...(draft.confidence === undefined ? {} : { confidence: draft.confidence }),
    };
    this.events.push(event);
    return this.clone(event);
  }

  private findMostRelevantRoutine(transcript: string): RoutineMemory | undefined {
    const normalized = this.key(transcript);
    const appointment = this.findRoutine("Doctor Appointment");
    if (
      appointment &&
      (normalized.includes("going") ||
        normalized.includes("lost") ||
        normalized.includes("where") ||
        normalized.includes("appointment"))
    ) {
      return appointment;
    }

    return this.routinesList().find((routine) => !routine.completedAt) ?? appointment;
  }

  private isSafetyCritical(text: string): boolean {
    const normalized = this.key(text);
    const criticalWords = [
      "medicine",
      "medication",
      "pill",
      "doctor",
      "appointment",
      "lost",
      "leave",
      "leaving",
      "outside",
      "fall",
      "hurt",
      "pain",
    ];
    return criticalWords.some((word) => normalized.includes(word));
  }

  private findPerson(name: string): PersonMemory | undefined {
    return this.people.get(this.key(name));
  }

  private findPersonById(id: string): PersonMemory | undefined {
    return this.peopleList().find((person) => person.id === id);
  }

  private findObject(name: string): ObjectMemory | undefined {
    return this.objects.get(this.key(name));
  }

  private findRoutine(name: string): RoutineMemory | undefined {
    return this.routines.get(this.key(name));
  }

  private findPlaceById(id: string): PlaceMemory | undefined {
    return this.placesList().find((place) => place.id === id);
  }

  private peopleList(): PersonMemory[] {
    return [...this.people.values()].map((person) => this.clone(person));
  }

  private objectsList(): ObjectMemory[] {
    return [...this.objects.values()].map((object) => this.clone(object));
  }

  private routinesList(): RoutineMemory[] {
    return [...this.routines.values()].map((routine) => this.clone(routine));
  }

  private placesList(): PlaceMemory[] {
    return [...this.places.values()].map((place) => this.clone(place));
  }

  private eventsList(): EventMemory[] {
    return this.events.map((event) => this.clone(event));
  }

  private key(value: string): string {
    return value.trim().toLowerCase().replace(/\s+/g, " ");
  }

  private idFromName(prefix: string, name: string): string {
    return `${prefix}-${this.key(name).replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "")}`;
  }

  private toTitleCase(value: string): string {
    return this.key(value)
      .split(" ")
      .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
      .join(" ");
  }

  private now(): string {
    return new Date().toISOString();
  }

  private localDate(value: string): string {
    return new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Los_Angeles",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(new Date(value));
  }

  private formatDateForHumans(value: string): string {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return "unknown date";
    }

    return new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Los_Angeles",
      month: "long",
      day: "numeric",
      year: "numeric",
    }).format(date);
  }

  private formatTimeForHumans(value: string | undefined): string {
    if (!value) {
      return "unknown time";
    }

    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      return value;
    }

    return new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Los_Angeles",
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    }).format(new Date(value));
  }

  private clone<T>(value: T): T {
    return structuredClone(value);
  }
}
