//
//  LAHACKS26Tests.swift
//  LAHACKS26Tests
//
//  Created by Rikhil Rao on 4/24/26.
//

import Testing
@testable import LAHACKS26

struct LAHACKS26Tests {

    @Test func approvedProfileDisplayReturnsMemoryCue() async throws {
        let bridge = MockMemoryBridge()

        let result = bridge.profileDisplay(for: "face-anita-001")

        guard case .approved(let profile) = result else {
            Issue.record("Expected Anita to be caregiver-approved for display")
            return
        }

        #expect(profile.name == "Anita")
        #expect(profile.relationship == "daughter and caregiver")
        #expect(profile.memoryCue.contains("daughter"))
        #expect(profile.detailLines.contains("Trusted caregiver"))
    }

    @Test func unapprovedProfileDisplayStaysUnknown() async throws {
        let bridge = MockMemoryBridge()

        let result = bridge.profileDisplay(for: "face-maya-001")

        guard case .unknown(let message) = result else {
            Issue.record("Expected Maya to remain hidden before caregiver approval")
            return
        }

        #expect(message.contains("caregiver-approved"))
    }

    @Test func caregiverApprovalEnablesProfileDisplay() async throws {
        let bridge = MockMemoryBridge()

        bridge.approvePersonEnrollment(personId: "person-maya", caregiverName: "Anita")
        let result = bridge.profileDisplay(for: "face-maya-001")

        guard case .approved(let profile) = result else {
            Issue.record("Expected caregiver approval to enable Maya's profile display")
            return
        }

        #expect(profile.name == "Maya")
        #expect(profile.memoryCue.contains("neighbor"))
    }

}
