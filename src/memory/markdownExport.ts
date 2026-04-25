import type {
  EventMemory,
  ObjectMemory,
  PersonMemory,
  PlaceMemory,
  RoutineMemory,
} from "./types.js";

export interface MarkdownWikiInput {
  people: PersonMemory[];
  objects: ObjectMemory[];
  routines: RoutineMemory[];
  places: PlaceMemory[];
  events: EventMemory[];
}

const formatList = (items: string[]): string =>
  items.length > 0 ? items.map((item) => `  - ${item}`).join("\n") : "  - None";

const formatTimestamp = (value: string | undefined): string => {
  if (!value) {
    return "Unknown";
  }

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return value;
  }

  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Los_Angeles",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  }).format(date);
};

const formatField = (label: string, value: string | number | boolean | undefined): string =>
  `- ${label}: ${value === undefined || value === "" ? "Unknown" : String(value)}`;

const section = (title: string, body: string): string => `## ${title}\n\n${body}`;

const personPage = (person: PersonMemory): string =>
  [
    `### ${person.name}`,
    formatField("ID", person.id),
    formatField("Relationship", person.relationship),
    formatField("Trust", person.trustLevel),
    formatField("Caregiver approved", person.caregiverApproved),
    formatField("Trusted support", person.trustedSupport),
    formatField("Updated", formatTimestamp(person.updatedAt)),
    "",
    person.calmingDescription,
    "",
    "Notes:",
    formatList(person.notes),
  ].join("\n");

const objectPage = (object: ObjectMemory): string =>
  [
    `### ${object.name}`,
    formatField("ID", object.id),
    formatField("Usual location", object.usualLocation),
    formatField("Last seen", object.lastSeenLocation),
    formatField("Last seen at", formatTimestamp(object.lastSeenAt)),
    formatField("Importance", object.importance),
    formatField("Trust", object.trustLevel),
    formatField("Source", object.source),
    formatField("Confidence", object.confidence),
    formatField("Caregiver approved", object.caregiverApproved),
    "",
    "Notes:",
    formatList(object.notes),
  ].join("\n");

const routinePage = (routine: RoutineMemory): string =>
  [
    `### ${routine.name}`,
    formatField("ID", routine.id),
    formatField("Scheduled time", routine.scheduledTime),
    formatField("Pickup time", routine.pickupTime),
    formatField("Completed at", formatTimestamp(routine.completedAt)),
    formatField("Safety critical", routine.safetyCritical),
    formatField("Trust", routine.trustLevel),
    formatField("Caregiver approved", routine.caregiverApproved),
    "",
    routine.description,
    "",
    "Notes:",
    formatList(routine.notes),
  ].join("\n");

const placePage = (place: PlaceMemory): string =>
  [
    `### ${place.name}`,
    formatField("ID", place.id),
    formatField("Trust", place.trustLevel),
    formatField("Caregiver approved", place.caregiverApproved),
    "",
    place.description,
    "",
    "Notes:",
    formatList(place.notes),
  ].join("\n");

const eventPage = (event: EventMemory): string =>
  [
    `### ${event.title}`,
    formatField("ID", event.id),
    formatField("Event type", event.eventType),
    formatField("Occurred at", formatTimestamp(event.occurredAt)),
    formatField("Trust", event.trustLevel),
    formatField("Source", event.source),
    formatField("Confidence", event.confidence),
    formatField("Needs caregiver review", event.needsCaregiverReview),
    formatField("Related memories", event.relatedMemoryIds.join(", ")),
    "",
    event.details,
    "",
    "Notes:",
    formatList(event.notes),
  ].join("\n");

export const exportMarkdownWiki = (input: MarkdownWikiInput): string => {
  const people = input.people.map(personPage).join("\n\n");
  const objects = input.objects.map(objectPage).join("\n\n");
  const routines = input.routines.map(routinePage).join("\n\n");
  const places = input.places.map(placePage).join("\n\n");
  const events = input.events.map(eventPage).join("\n\n");

  return [
    "# MindAnchor Memory Wiki",
    "",
    section("People", people || "_No people memories._"),
    section("Objects", objects || "_No object memories._"),
    section("Routines", routines || "_No routine memories._"),
    section("Places", places || "_No place memories._"),
    section("Events", events || "_No events logged._"),
  ].join("\n\n");
};
