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
  PersonEnrollmentSession,
  PersonMemory,
  PatientSpeechIntent,
  PatientSpeechResult,
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
  private readonly enrollmentSessions = new Map<string, PersonEnrollmentSession>();

  public constructor(data: MemorySeedData = seedData) {
    data.people.forEach((person) => this.people.set(this.key(person.name), this.clone(person)));
    data.objects.forEach((object) => this.objects.set(this.key(object.name), this.clone(object)));
    data.routines.forEach((routine) => this.routines.set(this.key(routine.name), this.clone(routine)));
    data.places.forEach((place) => this.places.set(this.key(place.name), this.clone(place)));
    data.events.forEach((event) => this.events.push(this.clone(event)));
    data.enrollmentSessions.forEach((session) =>
      this.enrollmentSessions.set(session.id, this.clone(session)),
    );
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

  public startPersonEnrollmentSession(): PersonEnrollmentSession {
    const now = this.now();
    const session: PersonEnrollmentSession = {
      id: `enrollment-${String(this.enrollmentSessions.size + 1).padStart(4, "0")}`,
      status: "collectingEvidence",
      startedAt: now,
      updatedAt: now,
      transcriptSnippets: [],
      needsCaregiverReview: false,
      evidenceNotes: ["Enrollment started from an on-device conversation flow."],
    };

    this.enrollmentSessions.set(session.id, session);
    this.logEvent({
      eventType: "personEnrollmentStarted",
      title: "Person enrollment started",
      details: `Started person enrollment session ${session.id}.`,
      trustLevel: "aiObserved",
      source: "demo",
      relatedMemoryIds: [session.id],
    });

    return this.clone(session);
  }

  public addEnrollmentTranscript(
    sessionId: string,
    transcript: string,
  ): PersonEnrollmentSession | undefined {
    const session = this.enrollmentSessions.get(sessionId);
    if (!session) {
      return undefined;
    }

    const now = this.now();
    const extracted = this.extractIdentity(transcript);
    const updated: PersonEnrollmentSession = {
      ...session,
      updatedAt: now,
      transcriptSnippets: [...session.transcriptSnippets, transcript],
      evidenceNotes: [
        ...session.evidenceNotes,
        `Transcript evidence: "${transcript}"`,
        ...(extracted.name ? [`Extracted possible name: ${extracted.name}.`] : []),
        ...(extracted.relationship
          ? [`Extracted possible relationship: ${extracted.relationship}.`]
          : []),
      ],
      ...(extracted.name ? { extractedName: extracted.name } : {}),
      ...(extracted.relationship ? { extractedRelationship: extracted.relationship } : {}),
      ...(extracted.confidence === undefined
        ? {}
        : { extractionConfidence: extracted.confidence }),
    };

    this.enrollmentSessions.set(sessionId, updated);
    this.logEvent({
      eventType: "personEnrollmentTranscriptAdded",
      title: "Enrollment transcript added",
      details: `Added transcript to ${sessionId}.`,
      trustLevel: "aiObserved",
      source: "speech",
      ...(extracted.confidence === undefined ? {} : { confidence: extracted.confidence }),
      relatedMemoryIds: [sessionId],
      notes: [`Transcript: "${transcript}"`],
    });

    return this.clone(updated);
  }

  public attachEnrollmentFaceProfile(
    sessionId: string,
    faceProfileId: string,
    confidence: number,
  ): PersonEnrollmentSession | undefined {
    const session = this.enrollmentSessions.get(sessionId);
    if (!session) {
      return undefined;
    }

    const updated: PersonEnrollmentSession = {
      ...session,
      updatedAt: this.now(),
      faceProfileId,
      faceCaptureConfidence: confidence,
      evidenceNotes: [
        ...session.evidenceNotes,
        `Local face profile evidence: ${faceProfileId} (${Math.round(confidence * 100)}% confidence).`,
      ],
    };

    this.enrollmentSessions.set(sessionId, updated);
    this.logEvent({
      eventType: "personEnrollmentFaceAttached",
      title: "Enrollment face profile attached",
      details: `Attached local face profile ${faceProfileId} to ${sessionId}.`,
      trustLevel: "aiObserved",
      source: "demo",
      confidence,
      relatedMemoryIds: [sessionId],
    });

    return this.clone(updated);
  }

  public createDraftPersonFromEnrollment(sessionId: string): PersonMemory | undefined {
    const session = this.enrollmentSessions.get(sessionId);
    if (!session) {
      return undefined;
    }

    const now = this.now();
    const name = session.extractedName ?? "Unknown Person";
    const relationship = session.extractedRelationship ?? "unverified contact";
    const personId = this.uniquePersonId(name);
    const draft: PersonMemory = {
      id: personId,
      type: "person",
      name,
      relationship,
      calmingDescription: `${name} may be your ${relationship}. Anita needs to review this before MindAnchor identifies them.`,
      trustedSupport: false,
      createdAt: now,
      updatedAt: now,
      trustLevel: "aiObserved",
      source: "speech",
      caregiverApproved: false,
      notes: ["Draft person memory created from local enrollment evidence."],
      recognitionStatus: "unverified",
      needsCaregiverReview: true,
      evidenceNotes: [
        ...session.evidenceNotes,
        `Draft created from enrollment session ${session.id}.`,
      ],
      status: "draft",
      ...(session.extractionConfidence === undefined
        ? {}
        : { confidence: session.extractionConfidence }),
      ...(session.faceProfileId ? { faceProfileId: session.faceProfileId } : {}),
    };

    this.people.set(this.key(draft.name), draft);
    const updatedSession: PersonEnrollmentSession = {
      ...session,
      status: "caregiverReview",
      updatedAt: now,
      draftPersonId: draft.id,
      needsCaregiverReview: true,
      evidenceNotes: [
        ...session.evidenceNotes,
        `Draft person memory ${draft.id} created for caregiver review.`,
      ],
    };
    this.enrollmentSessions.set(session.id, updatedSession);

    this.logEvent({
      eventType: "personEnrollmentDraftCreated",
      title: `${draft.name} enrollment draft created`,
      details: `Created draft person memory for ${draft.name}. Caregiver approval is required before recognition.`,
      trustLevel: "aiObserved",
      source: "speech",
      ...(session.extractionConfidence === undefined
        ? {}
        : { confidence: session.extractionConfidence }),
      needsCaregiverReview: true,
      relatedMemoryIds: [draft.id, session.id],
      notes: draft.evidenceNotes ?? [],
    });

    return this.clone(draft);
  }

  public approvePersonEnrollment(
    personId: string,
    caregiverName: string,
  ): PersonMemory | undefined {
    const person = this.findPersonById(personId);
    if (!person) {
      return undefined;
    }

    const now = this.now();
    const approved: PersonMemory = {
      ...person,
      updatedAt: now,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      caregiverApproved: true,
      trustedSupport: true,
      recognitionStatus: "approvedForRecognition",
      needsCaregiverReview: false,
      status: "approved",
      calmingDescription: `This is ${person.name}, your ${person.relationship}.`,
      evidenceNotes: [
        ...(person.evidenceNotes ?? []),
        `Approved by ${caregiverName} at ${this.formatTimeForHumans(now)}.`,
      ],
      notes: [
        ...person.notes,
        `Enrollment approved by ${caregiverName} at ${this.formatTimeForHumans(now)}.`,
      ],
    };

    this.people.set(this.key(approved.name), approved);
    this.updateEnrollmentForDraft(personId, "approved", false, now);
    this.clearReviewEventsForMemory(personId, now);
    this.logEvent({
      eventType: "personEnrollmentApproved",
      title: `${approved.name} enrollment approved`,
      details: `${caregiverName} approved ${approved.name} for recognition.`,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      relatedMemoryIds: [approved.id],
    });

    return this.clone(approved);
  }

  public rejectPersonEnrollment(
    personId: string,
    caregiverName: string,
  ): PersonMemory | undefined {
    const person = this.findPersonById(personId);
    if (!person) {
      return undefined;
    }

    const now = this.now();
    const rejected: PersonMemory = {
      ...person,
      updatedAt: now,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      caregiverApproved: false,
      trustedSupport: false,
      recognitionStatus: "unverified",
      needsCaregiverReview: false,
      status: "rejected",
      evidenceNotes: [
        ...(person.evidenceNotes ?? []),
        `Rejected by ${caregiverName} at ${this.formatTimeForHumans(now)}.`,
      ],
      notes: [
        ...person.notes,
        `Enrollment rejected by ${caregiverName} at ${this.formatTimeForHumans(now)}.`,
      ],
    };

    this.people.set(this.key(rejected.name), rejected);
    this.updateEnrollmentForDraft(personId, "rejected", false, now);
    this.clearReviewEventsForMemory(personId, now);
    this.logEvent({
      eventType: "personEnrollmentRejected",
      title: `${rejected.name} enrollment rejected`,
      details: `${caregiverName} rejected ${rejected.name} for recognition.`,
      trustLevel: "caregiverApproved",
      source: "caregiver",
      relatedMemoryIds: [rejected.id],
    });

    return this.clone(rejected);
  }

  public recognizeApprovedPerson(faceProfileId: string): string {
    const person = this.peopleList().find(
      (candidate) =>
        candidate.faceProfileId === faceProfileId &&
        candidate.caregiverApproved &&
        candidate.recognitionStatus === "approvedForRecognition" &&
        candidate.status !== "rejected",
    );

    if (!person) {
      return "I do not recognize this person yet. Please check with Anita before trusting them.";
    }

    return `This is ${person.name}, your ${person.relationship}.`;
  }

  public processPatientSpeech(transcript: string): PatientSpeechResult {
    const normalized = this.key(transcript);
    let intent: PatientSpeechIntent = "unknown";
    let spokenResponse = "I am not sure yet. Please ask Anita to help.";
    let displayText = "Ask Anita for help.";
    let needsCaregiverReview = false;
    let relatedMemoryIds: string[] = [];

    if (this.isObjectLocationQuery(normalized)) {
      const objectName = this.extractObjectNameFromSpeech(transcript) ?? "object";
      const object = this.findObject(objectName);
      intent = "objectLocation";
      spokenResponse = this.answerWhereIsObject(objectName);
      displayText = object?.lastSeenLocation
        ? `${object.name}: ${object.lastSeenLocation}`
        : object?.usualLocation
          ? `${object.name}: usually ${object.usualLocation}`
          : spokenResponse;
      relatedMemoryIds = object ? [object.id] : [];
    } else if (this.isConfusionSpeech(normalized)) {
      const routine = this.findMostRelevantRoutine(transcript);
      intent = "confusion";
      spokenResponse = this.answerConfusionPhrase(transcript);
      displayText = routine
        ? `You are safe. ${routine.name} at ${routine.scheduledTime}.`
        : "You are safe. Anita can help.";
      needsCaregiverReview = true;
      relatedMemoryIds = routine ? [routine.id] : [];
    } else if (this.isRoutineStatusQuery(normalized)) {
      const routine = this.findRoutineForSpeech(transcript);
      intent = "routineStatus";
      spokenResponse = this.answerRoutineStatusForPatient(routine);
      displayText = routine
        ? `${routine.name}: ${routine.completedAt ? "completed" : "not marked complete"}`
        : "Routine status unknown.";
      relatedMemoryIds = routine ? [routine.id] : [];
    } else if (this.isPersonIdentityQuery(normalized)) {
      const personName = this.extractPersonNameFromSpeech(transcript);
      const person = personName ? this.findPerson(personName) : undefined;
      intent = "personIdentity";
      if (personName && person?.caregiverApproved && person.trustedSupport) {
        spokenResponse = this.answerWhoIsPerson(personName);
        displayText = `${person.name}: ${person.relationship}`;
        relatedMemoryIds = [person.id];
      } else {
        spokenResponse =
          "I cannot confirm who this person is yet. Please check with Anita before trusting them.";
        displayText = "Person not caregiver-approved yet.";
        needsCaregiverReview = true;
        relatedMemoryIds = person ? [person.id] : [];
      }
    } else {
      needsCaregiverReview = true;
    }

    const speechEventNeedsReview = intent === "confusion" ? false : needsCaregiverReview;

    this.logEvent({
      eventType: "patientSpeechProcessed",
      title: `Patient speech: ${intent}`,
      details: `Transcript: "${transcript}". Spoken response: ${spokenResponse}`,
      trustLevel: "patientReported",
      source: "speech",
      needsCaregiverReview: speechEventNeedsReview,
      relatedMemoryIds,
      notes: [`Display text: ${displayText}`],
    });

    return {
      transcript,
      intent,
      spokenResponse,
      displayText,
      needsCaregiverReview,
      relatedMemoryIds,
    };
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
      .filter(
        (event) =>
          event.eventType === "patientReported" ||
          event.eventType === "patientSpeechProcessed",
      )
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
      patientReports.length > 0
        ? `Patient speech interactions: ${patientReports.join("; ")}.`
        : "No patient speech interactions logged today.",
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
      enrollmentSessions: this.enrollmentSessionsList(),
    };
  }

  public exportMarkdownWiki(): string {
    return renderMarkdownWiki({
      ...this.getSnapshot(),
      dailySummary: this.generateDailySummary(),
    });
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

  private updateEnrollmentForDraft(
    draftPersonId: string,
    status: "approved" | "rejected",
    needsCaregiverReview: boolean,
    updatedAt: string,
  ): void {
    const session = this.enrollmentSessionsList().find(
      (candidate) => candidate.draftPersonId === draftPersonId,
    );
    if (!session) {
      return;
    }

    this.enrollmentSessions.set(session.id, {
      ...session,
      status,
      needsCaregiverReview,
      updatedAt,
      evidenceNotes: [
        ...session.evidenceNotes,
        `Enrollment session marked ${status} at ${this.formatTimeForHumans(updatedAt)}.`,
      ],
    });
  }

  private clearReviewEventsForMemory(memoryId: string, updatedAt: string): void {
    this.events.forEach((event) => {
      if (!event.needsCaregiverReview || !event.relatedMemoryIds.includes(memoryId)) {
        return;
      }

      event.needsCaregiverReview = false;
      event.updatedAt = updatedAt;
      event.notes = [
        ...event.notes,
        `Caregiver review resolved at ${this.formatTimeForHumans(updatedAt)}.`,
      ];
    });
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

  private enrollmentSessionsList(): PersonEnrollmentSession[] {
    return [...this.enrollmentSessions.values()].map((session) => this.clone(session));
  }

  private extractIdentity(transcript: string): {
    name?: string;
    relationship?: string;
    confidence?: number;
  } {
    const nameMatch = transcript.match(/\b(?:i'm|i am|my name is)\s+([A-Z][a-zA-Z'-]*)/i);
    const relationshipMatch = transcript.match(/\b(?:i'm|i am)\s+your\s+([^.!?]+)/i);
    const name = nameMatch?.[1] ? this.toTitleCase(nameMatch[1]) : undefined;
    const relationship = relationshipMatch?.[1]
      ? this.cleanRelationship(relationshipMatch[1])
      : undefined;

    return {
      ...(name ? { name } : {}),
      ...(relationship ? { relationship } : {}),
      ...(name || relationship
        ? { confidence: name && relationship ? 0.9 : 0.72 }
        : {}),
    };
  }

  private cleanRelationship(value: string): string {
    return this.key(value)
      .replace(/^(a|an|the)\s+/, "")
      .replace(/\s+$/, "");
  }

  private uniquePersonId(name: string): string {
    const baseId = this.idFromName("person", name);
    const existingIds = new Set(this.peopleList().map((person) => person.id));
    if (!existingIds.has(baseId)) {
      return baseId;
    }

    let suffix = 2;
    while (existingIds.has(`${baseId}-${suffix}`)) {
      suffix += 1;
    }
    return `${baseId}-${suffix}`;
  }

  private isObjectLocationQuery(normalizedTranscript: string): boolean {
    return (
      normalizedTranscript.startsWith("where are") ||
      normalizedTranscript.startsWith("where is") ||
      normalizedTranscript.includes("where did i put") ||
      normalizedTranscript.includes("where are my") ||
      normalizedTranscript.includes("where is my")
    );
  }

  private extractObjectNameFromSpeech(transcript: string): string | undefined {
    const match = transcript.match(
      /\bwhere\s+(?:are|is)\s+(?:my|the)?\s*([a-zA-Z][a-zA-Z\s'-]*?)[?.!]*$/i,
    );
    const fallback = transcript.match(
      /\bwhere\s+did\s+i\s+put\s+(?:my|the)?\s*([a-zA-Z][a-zA-Z\s'-]*?)[?.!]*$/i,
    );
    const raw = match?.[1] ?? fallback?.[1];
    if (!raw) {
      return undefined;
    }

    return raw.trim().replace(/[?.!]+$/, "");
  }

  private isConfusionSpeech(normalizedTranscript: string): boolean {
    return (
      normalizedTranscript.includes("forgot where i'm going") ||
      normalizedTranscript.includes("forgot where i am going") ||
      normalizedTranscript.includes("i feel lost") ||
      normalizedTranscript.includes("i am lost") ||
      normalizedTranscript.includes("i'm lost") ||
      normalizedTranscript.includes("where am i going")
    );
  }

  private isRoutineStatusQuery(normalizedTranscript: string): boolean {
    return (
      normalizedTranscript.includes("did i take") ||
      normalizedTranscript.includes("have i taken") ||
      normalizedTranscript.includes("did i do") ||
      normalizedTranscript.includes("is my medication done") ||
      normalizedTranscript.includes("medicine") ||
      normalizedTranscript.includes("medication")
    );
  }

  private findRoutineForSpeech(transcript: string): RoutineMemory | undefined {
    const normalized = this.key(transcript);
    if (
      normalized.includes("medicine") ||
      normalized.includes("medication") ||
      normalized.includes("pill")
    ) {
      return this.findRoutine("Morning Medication");
    }

    return this.routinesList().find((routine) =>
      normalized.includes(this.key(routine.name)),
    );
  }

  private answerRoutineStatusForPatient(routine: RoutineMemory | undefined): string {
    if (!routine) {
      return "I do not know that routine yet. Please check with Anita.";
    }

    const completedToday =
      routine.completedAt && this.localDate(routine.completedAt) === this.localDate(this.now());

    if (completedToday) {
      return `Yes. ${routine.name} is marked complete today.`;
    }

    if (routine.name === "Morning Medication") {
      return "I do not see your morning medication marked complete today. Please check with Anita before taking anything.";
    }

    return `I do not see ${routine.name.toLowerCase()} marked complete today. Please check with Anita if you are unsure.`;
  }

  private isPersonIdentityQuery(normalizedTranscript: string): boolean {
    return (
      normalizedTranscript === "who is this" ||
      normalizedTranscript === "who is this?" ||
      normalizedTranscript.startsWith("who is ") ||
      normalizedTranscript.startsWith("who's ") ||
      normalizedTranscript.includes("who am i talking to")
    );
  }

  private extractPersonNameFromSpeech(transcript: string): string | undefined {
    const match = transcript.match(/\bwho(?:\s+is|'s)\s+([A-Z][a-zA-Z'-]*)[?.!]*$/);
    const name = match?.[1];
    if (!name || this.key(name) === "this") {
      return undefined;
    }

    return this.toTitleCase(name);
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
