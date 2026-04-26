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

struct InteractionMemory: Identifiable, Equatable {
    let id: String
    var memoryType: String
    var summary: String
    var evidenceQuote: String
    var emotionalContext: String?
    var followUpContext: String?
    var retentionHint: String?
    var transcript: String
    var faceProfileId: String?
    var createdAt: Date
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
    func storeInteractionMemory(
        memoryType: String,
        summary: String,
        evidenceQuote: String,
        emotionalContext: String?,
        followUpContext: String?,
        retentionHint: String?,
        transcript: String,
        faceProfileId: String
    ) -> InteractionMemory?
    func recognizeApprovedPerson(faceProfileId: String) -> String
    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult
    func approvePersonEnrollment(personId: String, caregiverName: String)
    func pendingDraftPeople() -> [DemoPersonMemory]
    func memoryWikiMarkdown() -> String
}

@MainActor
final class MockMemoryBridge: ObservableObject, MemoryBridge {
    private enum DemoPerson {
        static let unknownResponse = "I see someone nearby, but I do not know who they are yet."
    }

    @Published private(set) var people: [DemoPersonMemory] = []
    @Published private(set) var interactions: [InteractionMemory] = []

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
            caregiverApproved: true,
            recognitionStatus: "availableForRecall",
            status: "saved",
            needsCaregiverReview: false
        )

        people.removeAll { $0.id == draft.id }
        people.append(draft)
        return draft
    }

    func storeInteractionMemory(
        memoryType: String,
        summary: String,
        evidenceQuote: String,
        emotionalContext: String?,
        followUpContext: String?,
        retentionHint: String?,
        transcript: String,
        faceProfileId: String
    ) -> InteractionMemory? {
        let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedEvidence = evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty, !cleanedEvidence.isEmpty else { return nil }

        let interaction = InteractionMemory(
            id: stableInteractionId(summary: cleanedSummary, faceProfileId: faceProfileId),
            memoryType: memoryType,
            summary: cleanedSummary,
            evidenceQuote: cleanedEvidence,
            emotionalContext: cleanOptional(emotionalContext),
            followUpContext: cleanOptional(followUpContext),
            retentionHint: cleanOptional(retentionHint),
            transcript: transcript,
            faceProfileId: faceProfileId,
            createdAt: Date()
        )

        interactions.removeAll { $0.id == interaction.id }
        interactions.append(interaction)
        interactions.sort { $0.createdAt > $1.createdAt }
        return interaction
    }

    func recognizeApprovedPerson(faceProfileId: String) -> String {
        let recentInteraction = interactions.first { $0.faceProfileId == faceProfileId }

        guard let person = people.first(where: {
            $0.faceProfileId == faceProfileId &&
                $0.recognitionStatus == "availableForRecall" &&
                $0.status == "saved"
        }) else {
            if let recentInteraction {
                return patientPrompt(for: recentInteraction)
            }

            return DemoPerson.unknownResponse
        }

        if let recentInteraction {
            return "\(patientPrompt(for: person)) Last time, \(recentInteraction.summary.lowercasedFirstLetter())"
        }

        return patientPrompt(for: person)
    }

    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult {
        let recentInteraction = interactions.first { $0.faceProfileId == faceProfileId }

        guard let person = people.first(where: {
            $0.faceProfileId == faceProfileId &&
                $0.recognitionStatus == "availableForRecall" &&
                $0.status == "saved"
        }) else {
            if let recentInteraction {
                return .unknown(patientPrompt(for: recentInteraction))
            }

            return .unknown(DemoPerson.unknownResponse)
        }

        let detailLines = profileDetailLines(for: person, recentInteraction: recentInteraction)
        return .known(
            PersonProfileDisplay(
                personId: person.id,
                faceProfileId: faceProfileId,
                name: person.name,
                relationship: person.relationship == "person I met" ? "" : person.relationship,
                memoryCue: recognizeApprovedPerson(faceProfileId: faceProfileId),
                detailLines: detailLines
            )
        )
    }

    func approvePersonEnrollment(personId: String, caregiverName: String) {
        guard let index = people.firstIndex(where: { $0.id == personId }) else { return }
        people[index].caregiverApproved = true
        people[index].recognitionStatus = "availableForRecall"
        people[index].status = "saved"
        people[index].needsCaregiverReview = false
    }

    func pendingDraftPeople() -> [DemoPersonMemory] {
        people.filter { $0.status == "draft" || $0.needsCaregiverReview }
    }

    func memoryWikiMarkdown() -> String {
        guard !people.isEmpty || !interactions.isEmpty else {
            return "# MindAnchor Memory Wiki\n\nNo person memories yet."
        }

        let personPages = people.map(markdownPage(for:))
        let interactionPages = interactions.map(markdownPage(for:))
        return (personPages + interactionPages).joined(separator: "\n\n---\n\n")
    }

    private func stablePersonId(for name: String, faceProfileId: String) -> String {
        let normalizedName = name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }

        if !normalizedName.isEmpty {
            return "person-\(faceProfileId)-\(normalizedName)"
        }

        return "person-\(faceProfileId)"
    }

    private func stableInteractionId(summary: String, faceProfileId: String) -> String {
        let normalizedSummary = summary
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
            .prefix(40)

        if !normalizedSummary.isEmpty {
            return "interaction-\(faceProfileId)-\(normalizedSummary)"
        }

        return "interaction-\(faceProfileId)"
    }

    private func clean(_ value: String?, fallback: String) -> String {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return fallback
        }

        return cleaned
    }

    private func cleanOptional(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private func patientPrompt(for person: DemoPersonMemory) -> String {
        let context = person.helpfulContext == "No helpful context captured yet."
            ? ""
            : " \(person.name) \(person.helpfulContext)."

        if person.relationship == "person I met" || person.relationship == "possible acquaintance" {
            return "This is \(person.name).\(context)"
        }

        return "This is \(person.name), your \(person.relationship).\(context)"
    }

    private func patientPrompt(for interaction: InteractionMemory) -> String {
        if let followUpContext = interaction.followUpContext, !followUpContext.isEmpty {
            return "\(interaction.summary) \(followUpContext)"
        }

        return interaction.summary
    }

    private func profileDetailLines(for person: DemoPersonMemory, recentInteraction: InteractionMemory?) -> [String] {
        var lines: [String] = []

        if person.relationship != "person I met", person.relationship != "possible acquaintance" {
            lines.append(person.relationship)
        }

        if person.helpfulContext != "No helpful context captured yet.",
           !person.helpfulContext.lowercased().contains("introduced during the conversation") {
            lines.append(person.helpfulContext)
        }

        if let recentInteraction {
            lines.append("Last: \(recentInteraction.summary)")
        }

        return lines
    }

    private func markdownPage(for person: DemoPersonMemory) -> String {
        """
        # \(person.name)

        Status: \(person.status.capitalized)
        Patient Facing: true
        Recognition Status: \(person.recognitionStatus)
        Trust Level: patientObserved
        Ready for Recall: true

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

        \(patientPrompt(for: person))
        """
    }

    private func markdownPage(for interaction: InteractionMemory) -> String {
        """
        # Recent Interaction

        Type: \(interaction.memoryType)
        Retention: \(interaction.retentionHint ?? "recent")
        Face profile ID: \(interaction.faceProfileId ?? "None")

        ## Summary

        \(interaction.summary)

        ## Emotional Context

        \(interaction.emotionalContext ?? "None")

        ## Follow Up

        \(interaction.followUpContext ?? "None")

        ## Evidence

        "\(interaction.evidenceQuote)"
        """
    }
}

private extension String {
    func lowercasedFirstLetter() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
