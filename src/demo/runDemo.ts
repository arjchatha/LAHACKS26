import { MemoryService } from "../memory/memoryService.js";
import type { MutationResult } from "../memory/memoryService.js";

const memoryService = new MemoryService();

const requireData = <T>(result: MutationResult<T>): T => {
  if (!result.ok || !result.data) {
    throw new Error(result.message);
  }

  return result.data;
};

console.log("MindAnchor memory wiki demo");
console.log("============================");

console.log("\n1. Mock AI event: keys detected near kitchen counter");
memoryService.detectObject("Keys", "kitchen counter", 0.86);

console.log('\n2. Voice-first patient speech: "Where are my keys?"');
console.log(memoryService.processPatientSpeech("Where are my keys?"));

console.log('\n3. Voice-first patient speech: "I forgot where I\'m going"');
console.log(memoryService.processPatientSpeech("I forgot where I'm going"));

console.log('\n4. Voice-first patient speech: "Did I take my medicine?"');
console.log(memoryService.processPatientSpeech("Did I take my medicine?"));

console.log('\n5. Voice-first patient speech: "Who is this?"');
console.log(memoryService.processPatientSpeech("Who is this?"));

console.log("\n6. Caregiver correction: usual key location updated");
memoryService.correctObject(
  "Keys",
  { usualLocation: "on the hook by the front door" },
);

console.log("\n7. Person enrollment: patient talks to Maya");
const enrollment = requireData(memoryService.startPersonEnrollmentSession());
memoryService.addEnrollmentTranscript(
  enrollment.id,
  "Hi, I'm Maya. I'm your neighbor from next door.",
);
memoryService.attachEnrollmentFaceProfile(enrollment.id, "face-maya-001", 0.88);
const draftMaya = requireData(memoryService.createDraftPersonFromEnrollment(enrollment.id));

console.log("\n8. Caregiver dashboard before approval");
console.log(JSON.stringify(memoryService.getCaregiverDashboard().needsReview, null, 2));

console.log("\n9. Recognition before caregiver approval");
console.log(memoryService.recognizeApprovedPerson("face-maya-001").answer);

console.log("\n10. Caregiver Anita approves Maya");
memoryService.approvePersonEnrollment(draftMaya.id, "Anita");

console.log("\n11. Recognition after caregiver approval");
console.log(memoryService.recognizeApprovedPerson("face-maya-001").answer);

console.log("\n12. Daily summary");
const dashboard = memoryService.getCaregiverDashboard();
console.log(dashboard.summary.narrative);
console.log(`Review needed: ${dashboard.summary.reviewNeededCount}`);

console.log("\n13. Caregiver dashboard after approval");
console.log(JSON.stringify(dashboard.needsReview, null, 2));

console.log("\n14. Markdown wiki export");
console.log(memoryService.getMarkdownWiki());
