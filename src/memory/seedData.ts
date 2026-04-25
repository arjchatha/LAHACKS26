import type {
  MemorySeedData,
  ObjectMemory,
  PersonMemory,
  PlaceMemory,
  RoutineMemory,
} from "./types.js";

const seedTime = "2026-04-24T08:00:00.000-07:00";

const baseApproved = {
  createdAt: seedTime,
  updatedAt: seedTime,
  trustLevel: "caregiverApproved" as const,
  source: "caregiver" as const,
  caregiverApproved: true,
};

export const seedPeople: PersonMemory[] = [
  {
    ...baseApproved,
    id: "person-anita",
    type: "person",
    name: "Anita",
    relationship: "daughter and caregiver",
    calmingDescription: "Anita is your daughter and caregiver. She helps with appointments and medicine.",
    trustedSupport: true,
    notes: ["Primary caregiver contact."],
  },
  {
    ...baseApproved,
    id: "person-rahul",
    type: "person",
    name: "Rahul",
    relationship: "grandson",
    calmingDescription: "Rahul is your grandson. He visits often and is here to help.",
    trustedSupport: true,
    notes: ["Family member approved by Anita."],
  },
];

export const seedObjects: ObjectMemory[] = [
  {
    ...baseApproved,
    id: "object-keys",
    type: "object",
    name: "Keys",
    usualLocation: "near the front door",
    importance: "high",
    notes: ["Important object for leaving home."],
  },
  {
    ...baseApproved,
    id: "object-glasses",
    type: "object",
    name: "Glasses",
    usualLocation: "on the bedroom nightstand",
    importance: "high",
    notes: ["Needed for reading and moving around safely."],
  },
  {
    ...baseApproved,
    id: "object-medicine-box",
    type: "object",
    name: "Medicine Box",
    usualLocation: "on the kitchen counter",
    importance: "high",
    notes: ["Medication facts should remain caregiver-approved."],
  },
];

export const seedPlaces: PlaceMemory[] = [
  {
    ...baseApproved,
    id: "place-kitchen",
    type: "place",
    name: "Kitchen",
    description: "The kitchen area at home, including the counter where the medicine box is kept.",
    notes: ["Common place for morning routine items."],
  },
  {
    ...baseApproved,
    id: "place-bedroom",
    type: "place",
    name: "Bedroom",
    description: "The bedroom, including the nightstand where glasses are usually placed.",
    notes: ["Quiet place to look for personal items."],
  },
  {
    ...baseApproved,
    id: "place-front-door",
    type: "place",
    name: "Front door",
    description: "The front door area where keys are usually kept.",
    notes: ["Check here before leaving home."],
  },
  {
    ...baseApproved,
    id: "place-doctor-clinic",
    type: "place",
    name: "Doctor clinic",
    description: "The clinic for today's doctor appointment.",
    notes: ["Anita will help with transportation."],
  },
];

export const seedRoutines: RoutineMemory[] = [
  {
    ...baseApproved,
    id: "routine-morning-medication",
    type: "routine",
    name: "Morning Medication",
    scheduledTime: "8:00 AM",
    description: "Take the morning medicine from the medicine box on the kitchen counter.",
    placeId: "place-kitchen",
    safetyCritical: true,
    notes: ["Do not change medication details from patient reports alone."],
  },
  {
    ...baseApproved,
    id: "routine-doctor-appointment",
    type: "routine",
    name: "Doctor Appointment",
    scheduledTime: "3:30 PM",
    description: "Doctor appointment at the clinic.",
    placeId: "place-doctor-clinic",
    helperPersonId: "person-anita",
    pickupTime: "3:15 PM",
    safetyCritical: true,
    notes: ["Anita picks the patient up at 3:15 PM."],
  },
];

export const seedData: MemorySeedData = {
  people: seedPeople,
  objects: seedObjects,
  routines: seedRoutines,
  places: seedPlaces,
  events: [],
  enrollmentSessions: [],
};
