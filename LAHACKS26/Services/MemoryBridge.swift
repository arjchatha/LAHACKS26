//
//  MemoryBridge.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import Foundation

struct DemoPersonMemory: Identifiable, Equatable {
    let id: String
    var name: String
    var relationship: String
    var helpfulContext: String
    var transcript: String
    var faceProfileId: String?
    var faceCaptureConfidence: Double?
    var caregiverApproved: Bool
    var recognitionStatus: String
    var status: String
    var needsCaregiverReview: Bool
}

@MainActor
protocol MemoryBridge: AnyObject {
    func storePersonDraft(
        transcript: String,
        extractedName: String?,
        extractedRelationship: String?,
        extractedHelpfulContext: String?,
        faceProfileId: String,
        confidence: Double,
        needsCaregiverReview: Bool
    ) -> DemoPersonMemory?
    func recognizeApprovedPerson(faceProfileId: String) -> String
    func approvePersonEnrollment(personId: String, caregiverName: String)
    func pendingDraftPeople() -> [DemoPersonMemory]
    func memoryWikiMarkdown() -> String
}

@MainActor
final class MockMemoryBridge: ObservableObject, MemoryBridge {
    private enum DemoPerson {
        static let cautiousUnknownResponse = "I see someone nearby, but I do not have a caregiver-approved identity for them yet."
    }

    @Published private(set) var people: [DemoPersonMemory] = []

    func storePersonDraft(
        transcript: String,
        extractedName: String?,
        extractedRelationship: String?,
        extractedHelpfulContext: String?,
        faceProfileId: String,
        confidence: Double,
        needsCaregiverReview: Bool
    ) -> DemoPersonMemory? {
        guard let name = extractedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }

        let personId = stablePersonId(for: name, faceProfileId: faceProfileId)
        let draft = DemoPersonMemory(
            id: personId,
            name: name,
            relationship: clean(extractedRelationship, fallback: "possible acquaintance"),
            helpfulContext: clean(extractedHelpfulContext, fallback: "No helpful context captured yet."),
            transcript: transcript,
            faceProfileId: faceProfileId,
            faceCaptureConfidence: confidence,
            caregiverApproved: false,
            recognitionStatus: "unverified",
            status: "draft",
            needsCaregiverReview: needsCaregiverReview
        )

        people.removeAll { $0.id == draft.id }
        people.append(draft)
        return draft
    }

    func recognizeApprovedPerson(faceProfileId: String) -> String {
        guard let person = people.first(where: {
            $0.faceProfileId == faceProfileId &&
                $0.caregiverApproved &&
                $0.recognitionStatus == "approvedForRecognition" &&
                $0.status == "approved"
        }) else {
            return DemoPerson.cautiousUnknownResponse
        }

        return patientPrompt(for: person)
    }

    func approvePersonEnrollment(personId: String, caregiverName: String) {
        guard let index = people.firstIndex(where: { $0.id == personId }) else { return }
        people[index].caregiverApproved = true
        people[index].recognitionStatus = "approvedForRecognition"
        people[index].status = "approved"
        people[index].needsCaregiverReview = false
    }

    func pendingDraftPeople() -> [DemoPersonMemory] {
        people.filter { !$0.caregiverApproved || $0.status == "draft" || $0.needsCaregiverReview }
    }

    func memoryWikiMarkdown() -> String {
        guard !people.isEmpty else {
            return "# MindAnchor Memory Wiki\n\nNo person memories yet."
        }

        return people.map(markdownPage(for:)).joined(separator: "\n\n---\n\n")
    }

    private func stablePersonId(for name: String, faceProfileId: String) -> String {
        let normalizedName = name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        if !normalizedName.isEmpty {
            return "person-\(normalizedName)"
        }

        return "person-\(faceProfileId)"
    }

    private func clean(_ value: String?, fallback: String) -> String {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return fallback
        }

        return cleaned
    }

    private func patientPrompt(for person: DemoPersonMemory) -> String {
        let context = person.helpfulContext == "No helpful context captured yet."
            ? ""
            : " She \(person.helpfulContext)."

        return "This is \(person.name), your \(person.relationship).\(context)"
    }

    private func markdownPage(for person: DemoPersonMemory) -> String {
        """
        # \(person.name)

        Status: \(person.status.capitalized)
        Caregiver Approved: \(person.caregiverApproved)
        Recognition Status: \(person.recognitionStatus)
        Trust Level: \(person.caregiverApproved ? "caregiverApproved" : "aiObserved")
        Needs Caregiver Review: \(person.needsCaregiverReview)

        ## Extracted Information

        Name: \(person.name)
        Relationship: \(person.relationship)
        Helpful context: \(person.helpfulContext)

        ## Evidence

        Transcript:
        "\(person.transcript)"

        Face profile ID:
        \(person.faceProfileId ?? "None")

        ## Patient Prompt

        \(person.caregiverApproved ? patientPrompt(for: person) : "Do not identify this person to the patient until caregiver approval.")
        """
    }
}
