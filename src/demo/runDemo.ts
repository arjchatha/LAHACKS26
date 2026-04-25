import { MemoryService } from "../memory/memoryService.js";

const memoryService = new MemoryService();

console.log("MindAnchor memory wiki demo");
console.log("============================");

console.log("\n1. Mock AI event: keys detected near kitchen counter");
memoryService.detectObject("Keys", "kitchen counter", 0.86);

console.log("\n2. Patient asks: Where are my keys?");
console.log(memoryService.askWhereIsObject("Keys").answer);

console.log('\n3. Patient says: "I forgot where I\'m going"');
console.log(memoryService.reportConfusion("I forgot where I'm going").answer);

console.log("\n4. Caregiver correction: usual key location updated");
memoryService.correctObject(
  "Keys",
  { usualLocation: "on the hook by the front door" },
);

console.log("\n5. Daily summary");
const dashboard = memoryService.getCaregiverDashboard();
console.log(dashboard.summary.narrative);
console.log(`Review needed: ${dashboard.summary.reviewNeededCount}`);

console.log("\n6. Markdown wiki export");
console.log(memoryService.getMarkdownWiki());
