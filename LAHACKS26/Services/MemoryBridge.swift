//
//  MemoryBridge.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import Foundation

enum DemoPersonStatus: String, Equatable {
    case draft
    case approved
    case rejected

    var displayName: String {
        rawValue.capitalized
    }
}

enum DemoRecognitionStatus: String, Equatable {
    case unverified
    case approvedForRecognition
}

struct DemoPersonMemory: Identifiable, Equatable {
    let id: String
    var name: String
    var relationship: String
    var helpfulContext: String
    var patientPrompt: String
    var transcriptEvidence: [String]
    var faceProfileId: String?
    var faceCaptureConfidence: Double?
    var caregiverApproved: Bool
    var recognitionStatus: DemoRecognitionStatus
    var status: DemoPersonStatus
    var needsCaregiverReview: Bool
    var createdAt: Date
    var updatedAt: Date
    var approvedAt: Date?
    var rejectedAt: Date?
    var reviewedBy: String?

    var transcript: String {
        transcriptEvidence.joined(separator: "\n\n")
    }
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

struct PersonProfileDisplay: Equatable {
    let personId: String
    let faceProfileId: String
    let name: String
    let relationship: String
    let memoryCue: String
    let detailLines: [String]
}

enum PersonProfileDisplayResult: Equatable {
    case known(PersonProfileDisplay)
    case unknown(String)

    var title: String {
        switch self {
        case .known:
            "Remembered"
        case .unknown:
            "Face detected"
        }
    }

    var description: String {
        switch self {
        case let .known(profile):
            profile.memoryCue
        case let .unknown(message):
            message
        }
    }

    var detailLines: [String] {
        switch self {
        case let .known(profile):
            profile.detailLines
        case .unknown:
            []
        }
    }
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
    func rejectPersonEnrollment(personId: String, caregiverName: String)
    func allPeople() -> [DemoPersonMemory]
    func recentInteractions() -> [InteractionMemory]
    func pendingDraftPeople() -> [DemoPersonMemory]
    func approvedPeople() -> [DemoPersonMemory]
    func searchPeople(query: String) -> [DemoPersonMemory]
    func wikiPage(for personId: String) -> String?
    func memoryWikiMarkdown() -> String
}

@MainActor
final class MockMemoryBridge: ObservableObject, MemoryBridge {
    private enum DemoPerson {
        static let cautiousUnknownResponse = "Unknown face"
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
        let relationship = clean(extractedRelationship, fallback: "Unknown")
        let helpfulContext = clean(extractedHelpfulContext, fallback: "Not captured yet")
        let prompt = patientPrompt(
            name: name,
            relationship: relationship,
            helpfulContext: helpfulContext
        )
        let evidenceEntries = transcriptEvidenceEntries(from: transcript)
        let now = Date()

        if let index = people.firstIndex(where: { $0.id == personId }) {
            people[index].name = name
            people[index].relationship = relationship
            people[index].helpfulContext = helpfulContext
            people[index].patientPrompt = prompt
            for evidenceEntry in evidenceEntries {
                appendTranscriptEvidence(evidenceEntry, to: index)
            }
            people[index].faceProfileId = faceProfileId
            people[index].faceCaptureConfidence = confidence
            people[index].updatedAt = now

            if people[index].status != .approved {
                people[index].caregiverApproved = false
                people[index].recognitionStatus = .unverified
                people[index].status = .draft
                people[index].needsCaregiverReview = true
                people[index].approvedAt = nil
                people[index].rejectedAt = nil
                people[index].reviewedBy = nil
            }

            return people[index]
        }

        let draft = DemoPersonMemory(
            id: personId,
            name: name,
            relationship: relationship,
            helpfulContext: helpfulContext,
            patientPrompt: prompt,
            transcriptEvidence: evidenceEntries,
            faceProfileId: faceProfileId,
            faceCaptureConfidence: confidence,
            caregiverApproved: false,
            recognitionStatus: .unverified,
            status: .draft,
            needsCaregiverReview: true,
            createdAt: now,
            updatedAt: now,
            approvedAt: nil,
            rejectedAt: nil,
            reviewedBy: nil
        )

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
        guard let person = approvedPerson(for: faceProfileId) else {
            return DemoPerson.cautiousUnknownResponse
        }

        if let recentInteraction = interactions.first(where: { $0.faceProfileId == faceProfileId }) {
            return "\(person.patientPrompt) Last time, \(recentInteraction.summary.lowercasedFirstLetter())"
        }

        return person.patientPrompt
    }

    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult {
        guard let person = approvedPerson(for: faceProfileId) else {
            return .unknown(DemoPerson.cautiousUnknownResponse)
        }

        let recentInteraction = interactions.first { $0.faceProfileId == faceProfileId }
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
        let now = Date()
        people[index].caregiverApproved = true
        people[index].recognitionStatus = .approvedForRecognition
        people[index].status = .approved
        people[index].needsCaregiverReview = false
        people[index].updatedAt = now
        people[index].approvedAt = now
        people[index].rejectedAt = nil
        people[index].reviewedBy = caregiverName
        people[index].patientPrompt = patientPrompt(for: people[index])
    }

    func rejectPersonEnrollment(personId: String, caregiverName: String) {
        guard let index = people.firstIndex(where: { $0.id == personId }) else { return }
        let now = Date()
        people[index].caregiverApproved = false
        people[index].recognitionStatus = .unverified
        people[index].status = .rejected
        people[index].needsCaregiverReview = false
        people[index].updatedAt = now
        people[index].approvedAt = nil
        people[index].rejectedAt = now
        people[index].reviewedBy = caregiverName
    }

    func allPeople() -> [DemoPersonMemory] {
        people.sorted { $0.updatedAt > $1.updatedAt }
    }

    func recentInteractions() -> [InteractionMemory] {
        interactions.sorted { $0.createdAt > $1.createdAt }
    }

    func pendingDraftPeople() -> [DemoPersonMemory] {
        people.filter { $0.status == .draft || $0.needsCaregiverReview }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func approvedPeople() -> [DemoPersonMemory] {
        people.filter {
            $0.status == .approved &&
                $0.caregiverApproved &&
                $0.recognitionStatus == .approvedForRecognition
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func searchPeople(query: String) -> [DemoPersonMemory] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return people.sorted { $0.updatedAt > $1.updatedAt }
        }

        return people
            .filter { person in
                [
                    person.name,
                    person.relationship,
                    person.helpfulContext,
                    person.patientPrompt
                ].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) } ||
                    person.transcriptEvidence.contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func wikiPage(for personId: String) -> String? {
        guard let person = people.first(where: { $0.id == personId }) else { return nil }
        return markdownPage(for: person)
    }

    func memoryWikiMarkdown() -> String {
        guard !people.isEmpty || !interactions.isEmpty else {
            return "# MindAnchor Memory Wiki\n\nNo memories yet."
        }

        let personPages = people
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(markdownPage(for:))
        let interactionPages = interactions.map(markdownPage(for:))
        return (personPages + interactionPages).joined(separator: "\n\n---\n\n")
    }

    private func approvedPerson(for faceProfileId: String) -> DemoPersonMemory? {
        people.first {
            $0.faceProfileId == faceProfileId &&
                $0.caregiverApproved &&
                $0.recognitionStatus == .approvedForRecognition &&
                $0.status == .approved
        }
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

    private func transcriptEvidenceEntries(from transcript: String) -> [String] {
        let entries = transcript
            .components(separatedBy: .newlines)
            .map(Self.cleanEvidenceQuote(_:))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }

        let uniqueEntries = entries.reduce(into: [String]()) { result, entry in
            guard !result.contains(entry) else { return }
            result.append(entry)
        }

        return uniqueEntries.isEmpty ? ["No transcript evidence captured."] : uniqueEntries
    }

    private func cleanOptional(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private func appendTranscriptEvidence(_ transcript: String, to index: Int) {
        guard !people[index].transcriptEvidence.contains(transcript) else { return }
        people[index].transcriptEvidence.append(transcript)
    }

    private func patientPrompt(for person: DemoPersonMemory) -> String {
        patientPrompt(
            name: person.name,
            relationship: person.relationship,
            helpfulContext: person.helpfulContext
        )
    }

    private func patientPrompt(name: String, relationship: String, helpfulContext: String) -> String {
        let context = helpfulContext == "No helpful context captured yet." || helpfulContext == "Not captured yet"
            ? ""
            : " \(helpfulContext.asPatientPromptSentenceWithPronoun)"

        if relationship == "person I met" || relationship == "possible acquaintance" || relationship == "Unknown" {
            return "This is \(name).\(context)"
        }

        return "This is \(name), your \(relationship).\(context)"
    }

    private func patientPrompt(for interaction: InteractionMemory) -> String {
        if let followUpContext = interaction.followUpContext, !followUpContext.isEmpty {
            return "\(interaction.summary) \(followUpContext)"
        }

        return interaction.summary
    }

    private func profileDetailLines(for person: DemoPersonMemory, recentInteraction: InteractionMemory?) -> [String] {
        var lines: [String] = []

        if person.relationship != "person I met", person.relationship != "possible acquaintance", person.relationship != "Unknown" {
            lines.append(person.relationship)
        }

        if person.helpfulContext != "No helpful context captured yet.",
           person.helpfulContext != "Not captured yet",
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

        Status: \(person.status.displayName)
        Caregiver Approved: \(person.caregiverApproved)
        Recognition Status: \(person.recognitionStatus.rawValue)
        Trust Level: \(person.caregiverApproved ? "caregiverApproved" : "aiObserved")
        Needs Caregiver Review: \(person.needsCaregiverReview)
        Created: \(Self.localDateTime.string(from: person.createdAt))
        Updated: \(Self.localDateTime.string(from: person.updatedAt))
        Reviewed By: \(person.reviewedBy ?? "Not reviewed")
        Approved At: \(person.approvedAt.map(Self.localDateTime.string(from:)) ?? "Not approved")
        Rejected At: \(person.rejectedAt.map(Self.localDateTime.string(from:)) ?? "Not rejected")

        ## Extracted Information

        Name: \(person.name)
        Relationship: \(person.relationship)
        Helpful Context: \(person.helpfulContext)
        Retention Hint: \(person.needsCaregiverReview ? "Incomplete identity. Caregiver should add relationship/context." : "Reviewed")

        ## Evidence

        \(transcriptEvidenceMarkdown(for: person))

        Safety note:
        Do not identify this person until caregiver approval.

        Face profile ID:
        \(person.faceProfileId ?? "None")

        Face capture confidence:
        \(person.faceCaptureConfidence.map { String(format: "%.2f", $0) } ?? "None")

        ## Patient Prompt

        \(person.caregiverApproved ? person.patientPrompt : "Do not identify this person to the patient until caregiver approval.")
        """
    }

    private func markdownPage(for interaction: InteractionMemory) -> String {
        """
        # Recent Interaction

        Type: \(interaction.memoryType)
        Retention: \(interaction.retentionHint ?? "recent")
        Created: \(Self.localDateTime.string(from: interaction.createdAt))
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

    private func transcriptEvidenceMarkdown(for person: DemoPersonMemory) -> String {
        person.transcriptEvidence
            .enumerated()
            .map { index, transcript in
                "Evidence Quote \(index + 1):\n\"\(Self.cleanEvidenceQuote(transcript))\""
            }
            .joined(separator: "\n\n")
    }

    private static func cleanEvidenceQuote(_ transcript: String) -> String {
        transcript.replacingOccurrences(
            of: #"^\[\d{2}:\d{2}\]\s*(?:Speaker\s+[A-Z]|Conversation):\s*"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let localDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension String {
    var asPatientPromptSentenceWithPronoun: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lowercased = trimmed.lowercased()
        let sentence = lowercased.hasPrefix("she ") || lowercased.hasPrefix("he ") || lowercased.hasPrefix("they ")
            ? trimmed
            : "She \(trimmed)"

        let terminalPunctuation = CharacterSet(charactersIn: ".!?")
        if sentence.rangeOfCharacter(from: terminalPunctuation, options: .backwards)?.upperBound == sentence.endIndex {
            return sentence
        }

        return "\(sentence)."
    }

    func lowercasedFirstLetter() -> String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}
