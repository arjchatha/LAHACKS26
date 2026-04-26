//
//  MemoryBridge.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import CoreVideo
import Foundation
import UIKit

enum DemoPersonStatus: String, Equatable {
    case saved
    case removed

    var displayName: String {
        switch self {
        case .saved:
            "Saved"
        case .removed:
            "Removed"
        }
    }
}

enum DemoRecognitionStatus: String, Equatable {
    case unverified
    case availableForRecognition
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
    var recognitionStatus: DemoRecognitionStatus
    var status: DemoPersonStatus
    var createdAt: Date
    var updatedAt: Date
    var lastEditedAt: Date?

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

struct PersonProfileDisplay: Codable, Equatable {
    let personId: String
    let faceProfileId: String
    let name: String
    let relationship: String
    let memoryCue: String
    let detailLines: [String]

    var title: String {
        relationship.isEmpty ? name : "\(name) • \(relationship)"
    }

    var spokenSafeSummary: String {
        memoryCue
    }
}

struct StoredPersonPhotoProfile: Codable, Identifiable, Equatable {
    let profile: PersonProfileDisplay
    let photoURLs: [URL]
    let embedding: [Float]
    let createdAt: Date

    var id: String {
        profile.personId
    }
}

struct StoredLivePersonProfile: Codable, Identifiable, Equatable {
    let profile: PersonProfileDisplay
    let embedding: [Float]
    let transcriptEvidence: [String]
    let faceSampleCount: Int
    let createdAt: Date
    let updatedAt: Date

    var id: String {
        profile.personId
    }
}

enum PersonProfileDisplayResult: Equatable {
    case known(PersonProfileDisplay)
    case unknown(String)

    var cameraLabelTitle: String {
        switch self {
        case let .known(profile):
            profile.name
        case .unknown:
            "Unknown"
        }
    }

    var cameraLabelDescription: String {
        switch self {
        case let .known(profile):
            profile.relationship
        case .unknown:
            ""
        }
    }

    var title: String {
        switch self {
        case let .known(profile):
            profile.title
        case .unknown:
            "Face detected"
        }
    }

    var description: String {
        switch self {
        case let .known(profile):
            profile.spokenSafeSummary
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

enum ProfilePhotoStorageError: LocalizedError {
    case cannotFindDocumentsDirectory
    case cannotEncodeProfileIndex
    case invalidEmbeddingData

    var errorDescription: String? {
        switch self {
        case .cannotFindDocumentsDirectory:
            "The app could not open local profile photo storage."
        case .cannotEncodeProfileIndex:
            "The app could not save the local profile index."
        case .invalidEmbeddingData:
            "The face embedding data was invalid. Try capturing the profile again in steady lighting."
        }
    }
}

@MainActor
protocol MemoryBridge: AnyObject {
    func storePersonMemory(
        transcript: String,
        extractedName: String?,
        extractedRelationship: String?,
        extractedHelpfulContext: String?,
        faceProfileId: String,
        confidence: Double
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
    func recognizeStoredPerson(faceProfileId: String) -> String
    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult
    func faceRecognitionDecision(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> FaceRecognitionDecision?
    func recognizedFaceProfileId(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> String?
    func faceEmbedding(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> [Float]?
    func saveLiveProfile(name: String, transcript: String, embeddings: [[Float]]) throws -> PersonProfileDisplay
    func appendTranscript(_ transcript: String, to faceProfileId: String)
    func enrollPersonFromPhotos(
        name: String,
        relationship: String,
        memoryCue: String,
        detailLines: [String],
        sourceImages: [UIImage]
    ) throws -> PersonProfileDisplay
    func deletePhotoProfile(personId: String)
    func clearMemory()
    func updatePersonMemory(
        personId: String,
        name: String,
        relationship: String,
        helpfulContext: String,
        patientPrompt: String
    ) -> DemoPersonMemory?
    func allPeople() -> [DemoPersonMemory]
    func recentInteractions() -> [InteractionMemory]
    func storedPeople() -> [DemoPersonMemory]
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
    @Published private(set) var enrolledPhotoProfiles: [StoredPersonPhotoProfile] = []
    @Published private(set) var enrolledLiveProfiles: [StoredLivePersonProfile] = []

    private var faceRecognitionService: FaceRecognitionService?
    private var didFailToLoadFaceRecognitionService = false
    private var embeddingsByFaceProfileId: [String: [Float]] = [:]

    init() {
        loadStoredPhotoProfiles()
        loadStoredLiveProfiles()
    }

    func storePersonMemory(
        transcript: String,
        extractedName: String?,
        extractedRelationship: String?,
        extractedHelpfulContext: String?,
        faceProfileId: String,
        confidence: Double
    ) -> DemoPersonMemory? {
        guard let name = extractedName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }

        let evidenceEntries = transcriptEvidenceEntries(from: transcript)
        let personId = stablePersonId(for: name, faceProfileId: faceProfileId)
        let relationship = clean(extractedRelationship, fallback: "Unknown")
        let helpfulContext = preferredHelpfulContext(
            current: extractedHelpfulContext,
            transcriptEvidence: evidenceEntries,
            name: name
        )
        let prompt = patientPrompt(
            name: name,
            relationship: relationship,
            helpfulContext: helpfulContext
        )
        let now = Date()

        if let index = people.firstIndex(where: {
            $0.id == personId ||
                $0.faceProfileId == faceProfileId ||
                ($0.name.caseInsensitiveCompare(name) == .orderedSame && ($0.faceProfileId == nil || $0.faceProfileId == faceProfileId))
        }) {
            let lockedName = lockedIdentityName(existing: people[index].name, incoming: name)
            let lockedRelationship = lockedRelationship(existing: people[index].relationship, incoming: relationship)
            let lockedHelpfulContext = preferredHelpfulContext(
                current: extractedHelpfulContext ?? people[index].helpfulContext,
                transcriptEvidence: evidenceEntries,
                name: lockedName
            )
            let lockedPrompt = patientPrompt(
                name: lockedName,
                relationship: lockedRelationship,
                helpfulContext: lockedHelpfulContext
            )

            people[index].name = lockedName
            people[index].relationship = lockedRelationship
            people[index].helpfulContext = lockedHelpfulContext
            people[index].patientPrompt = lockedPrompt
            for evidenceEntry in evidenceEntries {
                appendTranscriptEvidence(evidenceEntry, to: index)
            }
            people[index].faceProfileId = faceProfileId
            people[index].faceCaptureConfidence = confidence
            people[index].updatedAt = now

            people[index].recognitionStatus = .availableForRecognition
            people[index].status = .saved

            return people[index]
        }

        let memory = DemoPersonMemory(
            id: personId,
            name: name,
            relationship: relationship,
            helpfulContext: helpfulContext,
            patientPrompt: prompt,
            transcriptEvidence: evidenceEntries,
            faceProfileId: faceProfileId,
            faceCaptureConfidence: confidence,
            recognitionStatus: .availableForRecognition,
            status: .saved,
            createdAt: now,
            updatedAt: now,
            lastEditedAt: nil
        )

        people.append(memory)
        return memory
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

    func recognizeStoredPerson(faceProfileId: String) -> String {
        guard let person = storedPerson(for: faceProfileId) else {
            return DemoPerson.cautiousUnknownResponse
        }

        if let recentInteraction = interactions.first(where: { $0.faceProfileId == faceProfileId }) {
            return "\(person.patientPrompt) Last time, \(recentInteraction.summary.lowercasedFirstLetter())"
        }

        return person.patientPrompt
    }

    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult {
        guard let person = storedPerson(for: faceProfileId) else {
            return .unknown(DemoPerson.cautiousUnknownResponse)
        }

        let recentInteraction = interactions.first { $0.faceProfileId == faceProfileId }
        let detailLines = profileDetailLines(for: person, recentInteraction: recentInteraction)
        return .known(
            PersonProfileDisplay(
                personId: person.id,
                faceProfileId: faceProfileId,
                name: person.name,
                relationship: ["person I met", "possible acquaintance", "Unknown"].contains(person.relationship) ? "" : person.relationship,
                memoryCue: liveDisplaySummary(for: person, recentInteraction: recentInteraction),
                detailLines: detailLines
            )
        )
    }

    func faceRecognitionDecision(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> FaceRecognitionDecision? {
        guard detection.hasFace, detection.confidence >= 0.28 else { return nil }

        if let faceProfileId = detection.faceProfileId, embeddingsByFaceProfileId[faceProfileId] != nil {
            let match = FaceRecognitionMatch(faceProfileId: faceProfileId, similarity: Float(detection.confidence))
            return FaceRecognitionDecision(acceptedMatch: match, bestCandidate: match)
        }

        guard
            !embeddingsByFaceProfileId.isEmpty,
            let faceRecognitionService = faceRecognitionServiceInstance(),
            let embedding = try? faceRecognitionService.liveEmbedding(from: pixelBuffer, detection: detection)
        else {
            return nil
        }

        let candidates = embeddingsByFaceProfileId.map { faceProfileId, embedding in
            FaceEmbeddingCandidate(faceProfileId: faceProfileId, embedding: embedding)
        }

        return faceRecognitionService.recognitionDecision(for: embedding, candidates: candidates)
    }

    func recognizedFaceProfileId(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> String? {
        faceRecognitionDecision(for: detection, in: pixelBuffer)?.acceptedMatch?.faceProfileId
    }

    func faceEmbedding(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> [Float]? {
        guard detection.hasFace, let faceRecognitionService = faceRecognitionServiceInstance() else { return nil }
        return try? faceRecognitionService.liveEmbedding(from: pixelBuffer, detection: detection)
    }

    @discardableResult
    func saveLiveProfile(
        name: String,
        transcript: String,
        embeddings: [[Float]]
    ) throws -> PersonProfileDisplay {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !embeddings.isEmpty else {
            throw ProfilePhotoStorageError.invalidEmbeddingData
        }

        let embedding = FaceEmbeddingMath.l2Normalized(average(embeddings))
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
            throw ProfilePhotoStorageError.invalidEmbeddingData
        }

        let now = Date()
        let matchingLiveIndex = bestExistingLiveProfileIndex(for: embedding)
        let existingLiveIndex = enrolledLiveProfiles.firstIndex {
            $0.profile.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        } ?? matchingLiveIndex
        let existingLiveProfile = existingLiveIndex.map { enrolledLiveProfiles[$0] }
        let existingPerson = people.first {
            $0.status == .saved &&
                ($0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame ||
                    (existingLiveProfile?.profile.faceProfileId != nil && $0.faceProfileId == existingLiveProfile?.profile.faceProfileId))
        }
        let displayName = existingLiveProfile.map { preferredStoredName(existing: $0.profile.name, incoming: cleanName) } ?? cleanName
        let personId = existingLiveProfile?.profile.personId
            ?? existingPerson?.id
            ?? "person-live-\(UUID().uuidString.prefix(8))"
        let faceProfileId = existingLiveProfile?.profile.faceProfileId
            ?? existingPerson?.faceProfileId
            ?? "face-live-\(UUID().uuidString.prefix(8))"
        let relationship = preferredRelationship(
            liveProfile: existingLiveProfile?.profile,
            person: existingPerson
        )
        let previousEvidence = existingLiveProfile?.transcriptEvidence ?? existingPerson?.transcriptEvidence ?? []
        let mergedEvidence = uniqueTranscriptEvidence(previousEvidence + liveTranscriptEvidenceEntries(from: cleanTranscript))
        let mergedEmbedding = existingLiveProfile.map {
            FaceEmbeddingMath.l2Normalized(average([$0.embedding, embedding]))
        } ?? embedding
        let faceSampleCount = (existingLiveProfile?.faceSampleCount ?? 0) + embeddings.count
        let helpfulContext = preferredHelpfulContext(
            current: existingPerson?.helpfulContext,
            transcriptEvidence: mergedEvidence,
            name: displayName
        )
        let profile = PersonProfileDisplay(
            personId: personId,
            faceProfileId: faceProfileId,
            name: displayName,
            relationship: relationship,
            memoryCue: helpfulContext,
            detailLines: detailLines(faceSampleCount: faceSampleCount, transcriptEvidence: mergedEvidence)
        )
        let storedProfile = StoredLivePersonProfile(
            profile: profile,
            embedding: mergedEmbedding,
            transcriptEvidence: mergedEvidence,
            faceSampleCount: faceSampleCount,
            createdAt: existingLiveProfile?.createdAt ?? now,
            updatedAt: now
        )

        if let existingLiveIndex {
            enrolledLiveProfiles[existingLiveIndex] = storedProfile
        } else {
            enrolledLiveProfiles.append(storedProfile)
        }

        embeddingsByFaceProfileId[faceProfileId] = mergedEmbedding
        _ = storePersonMemory(
            transcript: mergedEvidence.joined(separator: "\n"),
            extractedName: displayName,
            extractedRelationship: relationship.isEmpty ? nil : relationship,
            extractedHelpfulContext: helpfulContext,
            faceProfileId: faceProfileId,
            confidence: 1.0
        )
        try saveStoredLiveProfiles()
        return profile
    }

    func appendTranscript(_ transcript: String, to faceProfileId: String) {
        let evidenceEntries = liveTranscriptEvidenceEntries(from: transcript)
        guard !evidenceEntries.isEmpty else { return }

        if let liveIndex = enrolledLiveProfiles.firstIndex(where: { $0.profile.faceProfileId == faceProfileId }) {
            let existing = enrolledLiveProfiles[liveIndex]
            let mergedEvidence = uniqueTranscriptEvidence(existing.transcriptEvidence + evidenceEntries)
            guard mergedEvidence != existing.transcriptEvidence else { return }

            let updatedProfile = PersonProfileDisplay(
                personId: existing.profile.personId,
                faceProfileId: existing.profile.faceProfileId,
                name: existing.profile.name,
                relationship: existing.profile.relationship,
                memoryCue: preferredHelpfulContext(
                    current: existing.profile.memoryCue,
                    transcriptEvidence: mergedEvidence,
                    name: existing.profile.name
                ),
                detailLines: detailLines(faceSampleCount: existing.faceSampleCount, transcriptEvidence: mergedEvidence)
            )

            enrolledLiveProfiles[liveIndex] = StoredLivePersonProfile(
                profile: updatedProfile,
                embedding: existing.embedding,
                transcriptEvidence: mergedEvidence,
                faceSampleCount: existing.faceSampleCount,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )
            try? saveStoredLiveProfiles()
        }

        guard let personIndex = people.firstIndex(where: { $0.faceProfileId == faceProfileId }) else { return }
        for evidenceEntry in evidenceEntries {
            appendTranscriptEvidence(evidenceEntry, to: personIndex)
        }
        let helpfulContext = preferredHelpfulContext(
            current: people[personIndex].helpfulContext,
            transcriptEvidence: people[personIndex].transcriptEvidence,
            name: people[personIndex].name
        )
        people[personIndex].helpfulContext = helpfulContext
        people[personIndex].patientPrompt = patientPrompt(
            name: people[personIndex].name,
            relationship: people[personIndex].relationship,
            helpfulContext: helpfulContext
        )
        people[personIndex].updatedAt = Date()
    }

    @discardableResult
    func enrollPersonFromPhotos(
        name: String,
        relationship: String,
        memoryCue: String,
        detailLines: [String],
        sourceImages: [UIImage]
    ) throws -> PersonProfileDisplay {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRelationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredMemoryCue = memoryCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMemoryCue = enteredMemoryCue.isEmpty ? "This is \(cleanName)." : enteredMemoryCue
        let cleanDetailLines = detailLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !cleanName.isEmpty, !sourceImages.isEmpty else {
            throw ProfilePhotoStorageError.invalidEmbeddingData
        }
        guard let faceRecognitionService = faceRecognitionServiceInstance() else {
            throw FaceRecognitionError.embeddingModelUnavailable("The face embedding model is not available.")
        }

        let embedding = try faceRecognitionService.enrollmentEmbedding(fromImages: sourceImages)
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
            throw ProfilePhotoStorageError.invalidEmbeddingData
        }

        let existingPhotoIndex = enrolledPhotoProfiles.firstIndex {
            $0.profile.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame
        }
        let existingPhotoProfile = existingPhotoIndex.map { enrolledPhotoProfiles[$0] }
        let existingPerson = people.first {
            $0.name.localizedCaseInsensitiveCompare(cleanName) == .orderedSame && $0.status == .saved
        }
        let personId = existingPhotoProfile?.profile.personId
            ?? existingPerson?.id
            ?? "person-photo-\(UUID().uuidString.prefix(8))"
        let faceProfileId = existingPhotoProfile?.profile.faceProfileId
            ?? existingPerson?.faceProfileId
            ?? "face-photo-\(UUID().uuidString.prefix(8))"

        let storedPhotoURLs = try storeProfilePhotos(
            sourceImages: sourceImages,
            personId: personId,
            startingIndex: existingPhotoProfile?.photoURLs.count ?? 0
        )
        let mergedEmbedding = existingPhotoProfile.map {
            FaceEmbeddingMath.l2Normalized(average([$0.embedding, embedding]))
        } ?? embedding
        let mergedPhotoURLs = (existingPhotoProfile?.photoURLs ?? []) + storedPhotoURLs
        let detail = cleanDetailLines.isEmpty
            ? ["Photo profile", "\(mergedPhotoURLs.count) photo(s)"]
            : cleanDetailLines
        let profile = PersonProfileDisplay(
            personId: personId,
            faceProfileId: faceProfileId,
            name: cleanName,
            relationship: cleanRelationship,
            memoryCue: cleanMemoryCue,
            detailLines: detail
        )
        let storedProfile = StoredPersonPhotoProfile(
            profile: profile,
            photoURLs: mergedPhotoURLs,
            embedding: mergedEmbedding,
            createdAt: existingPhotoProfile?.createdAt ?? Date()
        )

        if let existingPhotoIndex {
            enrolledPhotoProfiles[existingPhotoIndex] = storedProfile
        } else {
            enrolledPhotoProfiles.append(storedProfile)
        }

        embeddingsByFaceProfileId[faceProfileId] = mergedEmbedding
        _ = storePersonMemory(
            transcript: cleanMemoryCue,
            extractedName: cleanName,
            extractedRelationship: cleanRelationship.isEmpty ? nil : cleanRelationship,
            extractedHelpfulContext: enteredMemoryCue.isEmpty ? "Face profile ready for recognition." : enteredMemoryCue,
            faceProfileId: faceProfileId,
            confidence: 1.0
        )

        do {
            try saveStoredPhotoProfiles()
        } catch {
            if let existingPhotoIndex {
                enrolledPhotoProfiles[existingPhotoIndex] = existingPhotoProfile!
            } else {
                enrolledPhotoProfiles.removeAll { $0.profile.faceProfileId == faceProfileId }
            }
            embeddingsByFaceProfileId[faceProfileId] = existingPhotoProfile?.embedding
            try? removeStoredProfilePhotos(at: storedPhotoURLs)
            throw error
        }

        return profile
    }

    func deletePhotoProfile(personId: String) {
        guard let index = enrolledPhotoProfiles.firstIndex(where: { $0.profile.personId == personId }) else {
            return
        }

        let storedProfile = enrolledPhotoProfiles.remove(at: index)
        embeddingsByFaceProfileId.removeValue(forKey: storedProfile.profile.faceProfileId)

        for photoURL in storedProfile.photoURLs where FileManager.default.fileExists(atPath: photoURL.path) {
            try? FileManager.default.removeItem(at: photoURL)
        }

        for personIndex in people.indices where people[personIndex].faceProfileId == storedProfile.profile.faceProfileId {
            people[personIndex].status = .removed
            people[personIndex].updatedAt = Date()
        }

        try? saveStoredPhotoProfiles()
    }

    func clearMemory() {
        people.removeAll()
        interactions.removeAll()
        enrolledPhotoProfiles.removeAll()
        enrolledLiveProfiles.removeAll()
        embeddingsByFaceProfileId.removeAll()
        faceRecognitionService = nil
        didFailToLoadFaceRecognitionService = false

        let fileManager = FileManager.default
        if let profileDirectoryURL = try? profilePhotoDirectoryURL(),
           fileManager.fileExists(atPath: profileDirectoryURL.path) {
            try? fileManager.removeItem(at: profileDirectoryURL)
        }

        if let liveProfileDirectoryURL = try? liveProfileDirectoryURL(),
           fileManager.fileExists(atPath: liveProfileDirectoryURL.path) {
            try? fileManager.removeItem(at: liveProfileDirectoryURL)
        }
    }

    func updatePersonMemory(
        personId: String,
        name: String,
        relationship: String,
        helpfulContext: String,
        patientPrompt: String
    ) -> DemoPersonMemory? {
        guard let index = people.firstIndex(where: { $0.id == personId }) else { return nil }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return nil }

        let cleanedRelationship = clean(relationship, fallback: "Unknown")
        let cleanedHelpfulContext = clean(helpfulContext, fallback: "Not captured yet")
        let cleanedPrompt = patientPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()

        people[index].name = cleanedName
        people[index].relationship = cleanedRelationship
        people[index].helpfulContext = cleanedHelpfulContext
        people[index].patientPrompt = cleanedPrompt.isEmpty
            ? self.patientPrompt(name: cleanedName, relationship: cleanedRelationship, helpfulContext: cleanedHelpfulContext)
            : cleanedPrompt
        people[index].recognitionStatus = .availableForRecognition
        people[index].status = .saved
        people[index].updatedAt = now
        people[index].lastEditedAt = now

        return people[index]
    }

    func allPeople() -> [DemoPersonMemory] {
        people
            .filter { $0.status == .saved }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func recentInteractions() -> [InteractionMemory] {
        interactions.sorted { $0.createdAt > $1.createdAt }
    }

    func storedPeople() -> [DemoPersonMemory] {
        people.filter {
            $0.status == .saved &&
                $0.recognitionStatus == .availableForRecognition
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func searchPeople(query: String) -> [DemoPersonMemory] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return allPeople()
        }

        return people
            .filter { $0.status == .saved }
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

    private func storeProfilePhotos(
        sourceImages: [UIImage],
        personId: String,
        startingIndex: Int
    ) throws -> [URL] {
        let directoryURL = try profilePhotoDirectoryURL()
        let profileDirectoryURL = directoryURL.appendingPathComponent(personId, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)

        var storedURLs: [URL] = []

        for (offset, image) in sourceImages.enumerated() {
            guard let imageData = image.jpegData(compressionQuality: 0.92) else { continue }
            let destinationURL = profileDirectoryURL.appendingPathComponent("photo-\(startingIndex + offset + 1).jpg")
            try imageData.write(to: destinationURL, options: [.atomic])
            storedURLs.append(destinationURL)
        }

        return storedURLs
    }

    private func removeStoredProfilePhotos(at photoURLs: [URL]) throws {
        for photoURL in photoURLs where FileManager.default.fileExists(atPath: photoURL.path) {
            try FileManager.default.removeItem(at: photoURL)
        }
    }

    private func loadStoredPhotoProfiles() {
        guard
            let indexURL = try? profileIndexURL(),
            let data = try? Data(contentsOf: indexURL),
            let storedProfiles = try? JSONDecoder().decode([StoredPersonPhotoProfile].self, from: data)
        else {
            return
        }

        enrolledPhotoProfiles = storedProfiles.filter { storedProfile in
            !storedProfile.photoURLs.isEmpty &&
                storedProfile.photoURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } &&
                !storedProfile.embedding.isEmpty &&
                storedProfile.embedding.allSatisfy(\.isFinite)
        }

        for storedProfile in enrolledPhotoProfiles {
            let profile = storedProfile.profile
            embeddingsByFaceProfileId[profile.faceProfileId] = storedProfile.embedding
            _ = storePersonMemory(
                transcript: profile.memoryCue,
                extractedName: profile.name,
                extractedRelationship: profile.relationship.isEmpty ? nil : profile.relationship,
                extractedHelpfulContext: profile.memoryCue,
                faceProfileId: profile.faceProfileId,
                confidence: 1.0
            )
        }
    }

    private func loadStoredLiveProfiles() {
        guard
            let indexURL = try? liveProfileIndexURL(),
            let data = try? Data(contentsOf: indexURL),
            let storedProfiles = try? JSONDecoder().decode([StoredLivePersonProfile].self, from: data)
        else {
            return
        }

        enrolledLiveProfiles = storedProfiles.filter { storedProfile in
            !storedProfile.embedding.isEmpty && storedProfile.embedding.allSatisfy(\.isFinite)
        }

        for storedProfile in enrolledLiveProfiles {
            let profile = storedProfile.profile
            embeddingsByFaceProfileId[profile.faceProfileId] = storedProfile.embedding
            _ = storePersonMemory(
                transcript: storedProfile.transcriptEvidence.joined(separator: "\n"),
                extractedName: profile.name,
                extractedRelationship: profile.relationship.isEmpty ? nil : profile.relationship,
                extractedHelpfulContext: profile.memoryCue,
                faceProfileId: profile.faceProfileId,
                confidence: 1.0
            )
        }
    }

    private func saveStoredPhotoProfiles() throws {
        let indexURL = try profileIndexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(enrolledPhotoProfiles)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            throw ProfilePhotoStorageError.cannotEncodeProfileIndex
        }
    }

    private func saveStoredLiveProfiles() throws {
        let indexURL = try liveProfileIndexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(enrolledLiveProfiles)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            throw ProfilePhotoStorageError.cannotEncodeProfileIndex
        }
    }

    private func profileIndexURL() throws -> URL {
        try profilePhotoDirectoryURL().appendingPathComponent("profiles.json")
    }

    private func liveProfileIndexURL() throws -> URL {
        try liveProfileDirectoryURL().appendingPathComponent("profiles.json")
    }

    private func profilePhotoDirectoryURL() throws -> URL {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ProfilePhotoStorageError.cannotFindDocumentsDirectory
        }

        let directoryURL = documentsDirectory.appendingPathComponent("ProfilePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func liveProfileDirectoryURL() throws -> URL {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ProfilePhotoStorageError.cannotFindDocumentsDirectory
        }

        let directoryURL = documentsDirectory.appendingPathComponent("LiveProfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func average(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var result = [Float](repeating: 0, count: first.count)
        var count: Float = 0

        for embedding in embeddings where embedding.count == result.count {
            for index in result.indices {
                result[index] += embedding[index]
            }
            count += 1
        }

        guard count > 0 else { return [] }
        return result.map { $0 / count }
    }

    private func storedPerson(for faceProfileId: String) -> DemoPersonMemory? {
        people.first {
            $0.faceProfileId == faceProfileId &&
                $0.recognitionStatus == .availableForRecognition &&
                $0.status == .saved
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
            .compactMap(Self.normalizedEvidenceEntry(_:))

        let uniqueEntries = entries.reduce(into: [String]()) { result, entry in
            guard !result.contains(entry) else { return }
            result.append(entry)
        }

        return uniqueEntries.isEmpty ? ["No transcript evidence captured."] : uniqueEntries
    }

    private func liveTranscriptEvidenceEntries(from transcript: String) -> [String] {
        let entries = transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .compactMap(Self.normalizedEvidenceEntry(_:))

        let uniqueEntries = uniqueTranscriptEvidence(entries)
        if !uniqueEntries.isEmpty {
            return uniqueEntries
        }

        guard let fallback = Self.normalizedEvidenceEntry(transcript) else { return [] }
        return [fallback]
    }

    private func uniqueTranscriptEvidence(_ entries: [String]) -> [String] {
        var seen: Set<String> = []
        var uniqueEntries: [String] = []

        for entry in entries {
            guard let cleanEntry = Self.normalizedEvidenceEntry(entry) else { continue }
            let key = cleanEntry.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            uniqueEntries.append(cleanEntry)
        }

        return Array(uniqueEntries.suffix(8))
    }

    private func preferredRelationship(
        liveProfile: PersonProfileDisplay?,
        person: DemoPersonMemory?
    ) -> String {
        if let relationship = liveProfile?.relationship, !relationship.isEmpty {
            return relationship
        }

        guard let relationship = person?.relationship, !relationship.isEmpty else {
            return ""
        }

        return relationship == "Unknown" || relationship == "person I met" || relationship == "possible acquaintance"
            ? ""
            : relationship
    }

    private func bestExistingLiveProfileIndex(for embedding: [Float]) -> Int? {
        let scoredProfiles = enrolledLiveProfiles.indices.compactMap { index -> (index: Int, similarity: Float)? in
            guard let similarity = FaceEmbeddingMath.cosineSimilarity(embedding, enrolledLiveProfiles[index].embedding) else {
                return nil
            }

            return (index, similarity)
        }
        .sorted { $0.similarity > $1.similarity }

        guard let best = scoredProfiles.first, best.similarity >= 0.58 else {
            return nil
        }

        return best.index
    }

    private func preferredStoredName(existing: String, incoming: String) -> String {
        let cleanedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedExisting.isEmpty || cleanedExisting.localizedCaseInsensitiveContains("unknown") {
            return cleanedIncoming
        }

        return cleanedExisting
    }

    private func lockedIdentityName(existing: String, incoming: String) -> String {
        let cleanedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanedExisting.isEmpty, !cleanedExisting.localizedCaseInsensitiveContains("unknown") else {
            return cleanedIncoming
        }

        return cleanedExisting
    }

    private func lockedRelationship(existing: String, incoming: String) -> String {
        let cleanedExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isUnassignedRelationship(cleanedExisting) else {
            return cleanedExisting
        }

        return cleanedIncoming.isEmpty ? "Unknown" : cleanedIncoming
    }

    private func preferredHelpfulContext(
        current: String?,
        transcriptEvidence: [String],
        name: String
    ) -> String {
        if let inferredContext = importantContext(from: transcriptEvidence, name: name) {
            return inferredContext
        }

        let cleanedCurrent = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedCurrent,
           !cleanedCurrent.isEmpty,
           !Self.isLowValueHelpfulContext(cleanedCurrent, name: name) {
            return Self.punctuated(cleanedCurrent)
        }

        return "No key details yet."
    }

    private func faceRecognitionServiceInstance() -> FaceRecognitionService? {
        if let faceRecognitionService {
            return faceRecognitionService
        }

        guard !didFailToLoadFaceRecognitionService else {
            return nil
        }

        do {
            let service = try FaceRecognitionService()
            faceRecognitionService = service
            return service
        } catch {
            didFailToLoadFaceRecognitionService = true
            print("MindAnchor face recognition model unavailable:", error.localizedDescription)
            return nil
        }
    }

    private func memoryCue(for name: String, transcriptEvidence: [String]) -> String {
        preferredHelpfulContext(current: nil, transcriptEvidence: transcriptEvidence, name: name)
    }

    private func detailLines(faceSampleCount: Int, transcriptEvidence: [String]) -> [String] {
        var lines = [
            "Live speech profile",
            "\(faceSampleCount) face sample(s)"
        ]

        if let latestEvidence = transcriptEvidence.last {
            lines.append("\"\(latestEvidence)\"")
        }

        return lines
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
        let context = Self.isEmptyHelpfulContext(helpfulContext)
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

    private func liveDisplaySummary(for person: DemoPersonMemory, recentInteraction: InteractionMemory?) -> String {
        if !Self.isEmptyHelpfulContext(person.helpfulContext) {
            return Self.punctuated(person.helpfulContext)
        }

        if let recentInteraction {
            return Self.punctuated(recentInteraction.summary)
        }

        return "No key details yet."
    }

    private func profileDetailLines(for person: DemoPersonMemory, recentInteraction: InteractionMemory?) -> [String] {
        var lines: [String] = []

        if person.relationship != "person I met", person.relationship != "possible acquaintance", person.relationship != "Unknown" {
            lines.append(person.relationship)
        }

        if !Self.isEmptyHelpfulContext(person.helpfulContext),
           !person.helpfulContext.lowercased().contains("introduced during the conversation") {
            lines.append(person.helpfulContext)
        }

        if let recentInteraction {
            lines.append("Last: \(recentInteraction.summary)")
        }

        return lines
    }

    private func importantContext(from transcriptEvidence: [String], name: String) -> String? {
        for evidence in transcriptEvidence.reversed() {
            guard let cleanedEvidence = Self.normalizedEvidenceEntry(evidence) else { continue }

            if let context = Self.contextAfterIntroduction(in: cleanedEvidence, name: name) {
                return context
            }

            if let context = Self.contextFromStandaloneStatement(cleanedEvidence) {
                return context
            }
        }

        return nil
    }

    private func markdownPage(for person: DemoPersonMemory) -> String {
        """
        # \(person.name)

        Status: Saved
        Recognition: \(person.recognitionStatus == .availableForRecognition ? "Available" : "Unavailable")
        Created: \(Self.localDateTime.string(from: person.createdAt))
        Updated: \(Self.localDateTime.string(from: person.updatedAt))
        Last Edited At: \(person.lastEditedAt.map(Self.localDateTime.string(from:)) ?? "Not edited")

        ## Extracted Information

        Name: \(person.name)
        Relationship: \(person.relationship)
        Helpful Context: \(person.helpfulContext)

        ## Evidence

        \(transcriptEvidenceMarkdown(for: person))

        Face profile ID:
        \(person.faceProfileId ?? "None")

        Face capture confidence:
        \(person.faceCaptureConfidence.map { String(format: "%.2f", $0) } ?? "None")

        ## Patient Prompt

        \(person.patientPrompt)
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
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedEvidenceEntry(_ transcript: String) -> String? {
        let cleaned = cleanEvidenceQuote(transcript)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !cleaned.isEmpty, !isLowValueEvidence(cleaned) else { return nil }
        return cleaned
    }

    private static func isLowValueEvidence(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lowValueExact = [
            "yeah", "yes", "yep", "okay", "ok", "sure", "right", "she", "he", "they",
            "this", "that", "can you say", "say that", "repeat that", "what", "hello",
            "hi", "hey", "no transcript evidence captured"
        ]
        if lowValueExact.contains(normalized) {
            return true
        }

        return normalized.count < 3
    }

    private static func isEmptyHelpfulContext(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return [
            "",
            "not captured yet",
            "no key details yet",
            "no helpful context captured yet",
            "face profile ready for recognition"
        ].contains(normalized)
    }

    private static func isUnassignedRelationship(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return [
            "",
            "unknown",
            "person i met",
            "possible acquaintance"
        ].contains(normalized)
    }

    private static func isLowValueHelpfulContext(_ value: String, name: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !isEmptyHelpfulContext(value) else { return true }
        if normalized.contains("introduced themselves by saying") {
            return true
        }
        if normalized == "this is \(name.lowercased())" {
            return true
        }
        if normalized.hasPrefix("this is \(name.lowercased()). they introduced") {
            return true
        }
        return isLowValueEvidence(value)
    }

    private static func contextAfterIntroduction(in text: String, name: String) -> String? {
        let cleaned = strippedFillerPrefix(from: text)
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)\b(?:i\s+am|i'm|im|my\s+name\s+is|this\s+is)\s+\#(escapedName)\b(?:\s*(?:,|and|\.)\s*)?(.*)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: cleaned,
                range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: cleaned)
        else {
            return nil
        }

        let remainder = String(cleaned[range])
        return normalizedContext(from: remainder)
    }

    private static func contextFromStandaloneStatement(_ text: String) -> String? {
        normalizedContext(from: strippedFillerPrefix(from: text))
    }

    private static func normalizedContext(from rawText: String) -> String? {
        var text = strippedFillerPrefix(from: rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        text = text.replacingOccurrences(of: #"(?i)^(?:and|but|so)\s+"#, with: "", options: .regularExpression)
        guard !text.isEmpty, !isLowValueEvidence(text) else { return nil }

        let lowercased = text.lowercased()
        guard !lowercased.contains("introduced themselves by saying") else {
            return nil
        }

        if lowercased.hasPrefix("i'm ") || lowercased.hasPrefix("i am ") || lowercased.hasPrefix("im ") {
            let prefix = lowercased.hasPrefix("i am ") ? 5 : lowercased.hasPrefix("i'm ") ? 4 : 3
            let remainder = String(text.dropFirst(prefix))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !remainder.isEmpty else { return nil }
            if remainder.lowercased().split(separator: " ").first?.hasSuffix("ing") == true {
                return punctuated(remainder)
            }
            return punctuated("is \(remainder)")
        }

        let replacements: [(String, String)] = [
            ("i like to ", "likes to "),
            ("i love to ", "loves to "),
            ("i like ", "likes "),
            ("i love ", "loves "),
            ("i prefer ", "prefers "),
            ("i play ", "plays "),
            ("i watch ", "watches "),
            ("i go to ", "goes to "),
            ("i live ", "lives "),
            ("i work ", "works "),
            ("i study ", "studies "),
            ("we go to the same school", "goes to the same school"),
            ("we go to same school", "goes to the same school")
        ]

        for (prefix, replacement) in replacements where lowercased.hasPrefix(prefix) {
            let remainder = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return punctuated("\(replacement)\(remainder)")
        }

        return punctuated(text)
    }

    private static func strippedFillerPrefix(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)^\s*(?:oh|yeah|yes|yep|okay|ok|um|uh|like)\s*,?\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func punctuated(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return cleaned }

        if cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?"), options: .backwards)?.upperBound == cleaned.endIndex {
            return cleaned
        }

        return "\(cleaned)."
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
        let sentence: String
        if lowercased.hasPrefix("this is ") {
            sentence = trimmed
        } else if lowercased.hasPrefix("he ") ||
                    lowercased.hasPrefix("she ") ||
                    lowercased.hasPrefix("they ") ||
                    lowercased.hasPrefix("this person ") {
            sentence = trimmed
        } else if lowercased.hasPrefix("is ") ||
                    lowercased.hasPrefix("was ") ||
                    lowercased.hasPrefix("can ") ||
                    lowercased.hasPrefix("cannot ") ||
                    lowercased.hasPrefix("can't ") {
            sentence = "This person \(trimmed)"
        } else if lowercased.split(separator: " ").first?.hasSuffix("ing") == true {
            sentence = "This person is \(trimmed)"
        } else {
            sentence = "This person \(trimmed)"
        }

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
