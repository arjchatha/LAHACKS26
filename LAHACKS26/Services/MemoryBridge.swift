//
//  MemoryBridge.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Foundation

protocol MemoryBridge: AnyObject {
    func startPersonEnrollmentSession() -> String
    func attachEnrollmentFaceProfile(sessionId: String, faceProfileId: String, confidence: Double)
    func recognizeApprovedPerson(faceProfileId: String) -> String
    func approvePersonEnrollment(personId: String, caregiverName: String)
}

final class MockMemoryBridge: MemoryBridge {
    private enum DemoPerson {
        static let mayaPersonId = "person-maya"
        static let mayaFaceProfileId = "face-maya-001"
        static let cautiousUnknownResponse = "I see someone nearby, but I do not have a caregiver-approved identity for them yet."
        static let approvedMayaResponse = "This is Maya, your neighbor from next door."
    }

    private var approvedFaceProfileIds: Set<String> = []
    private var enrollmentFaceProfilesBySessionId: [String: String] = [:]

    func startPersonEnrollmentSession() -> String {
        "enrollment-\(UUID().uuidString.prefix(8))"
    }

    func attachEnrollmentFaceProfile(sessionId: String, faceProfileId: String, confidence: Double) {
        enrollmentFaceProfilesBySessionId[sessionId] = faceProfileId
    }

    func recognizeApprovedPerson(faceProfileId: String) -> String {
        guard approvedFaceProfileIds.contains(faceProfileId) else {
            return DemoPerson.cautiousUnknownResponse
        }

        if faceProfileId == DemoPerson.mayaFaceProfileId {
            return DemoPerson.approvedMayaResponse
        }

        return DemoPerson.cautiousUnknownResponse
    }

    func approvePersonEnrollment(personId: String, caregiverName: String) {
        guard personId == DemoPerson.mayaPersonId else { return }
        approvedFaceProfileIds.insert(DemoPerson.mayaFaceProfileId)
    }
}
