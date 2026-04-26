//
//  LAHACKS26Tests.swift
//  LAHACKS26Tests
//
//  Created by Rikhil Rao on 4/24/26.
//

import Testing
@testable import LAHACKS26

struct LAHACKS26Tests {

    @Test func faceEmbeddingDistanceSeparatesDifferentVectors() async throws {
        let firstPerson = FaceEmbedding(values: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let samePerson = FaceEmbedding(values: [0.98, 0.02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let differentPerson = FaceEmbedding(values: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

        #expect(firstPerson.cosineDistance(to: samePerson) < 0.01)
        #expect(firstPerson.cosineDistance(to: differentPerson) > 0.9)
    }

    @Test func faceIdentityClearsOldProfileBeforeSwitching() async throws {
        var stabilizer = FaceIdentityStabilizer(requiredConsecutiveFrames: 2)

        #expect(stabilizer.resolvedProfileId(for: "face-local-001") == nil)
        #expect(stabilizer.resolvedProfileId(for: "face-local-001") == "face-local-001")

        #expect(stabilizer.resolvedProfileId(for: "face-local-002") == nil)
        #expect(stabilizer.stableProfileId == nil)
        #expect(stabilizer.resolvedProfileId(for: "face-local-002") == "face-local-002")
    }

    @Test func faceIdentityImmediatelyKeepsPreviouslyStableProfile() async throws {
        var stabilizer = FaceIdentityStabilizer(requiredConsecutiveFrames: 2)

        #expect(stabilizer.resolvedProfileId(for: "face-local-001") == nil)
        #expect(stabilizer.resolvedProfileId(for: "face-local-001") == "face-local-001")
        stabilizer.reset()
        #expect(stabilizer.resolvedProfileId(for: "face-local-001") == nil)
    }

    @MainActor
    @Test func memoryDisplayIsScopedToFaceProfile() async throws {
        let memoryBridge = MockMemoryBridge()

        _ = memoryBridge.storePersonDraft(
            transcript: "This is Akshay. He knows how to sing.",
            extractedName: "Akshay",
            extractedRelationship: "friend",
            extractedHelpfulContext: "knows how to sing",
            faceProfileId: "face-local-001",
            confidence: 0.88,
            needsCaregiverReview: false
        )
        _ = memoryBridge.storePersonDraft(
            transcript: "This is Arjun. He cannot sing.",
            extractedName: "Arjun",
            extractedRelationship: "person I met",
            extractedHelpfulContext: "cannot sing",
            faceProfileId: "face-local-002",
            confidence: 0.88,
            needsCaregiverReview: false
        )

        #expect(memoryBridge.profileDisplay(for: "face-local-001").title.contains("Akshay"))
        #expect(memoryBridge.profileDisplay(for: "face-local-002").title.contains("Arjun"))
        #expect(!memoryBridge.profileDisplay(for: "face-local-002").description.contains("Akshay"))
    }

}
