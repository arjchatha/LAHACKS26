//
//  MemoryBridge.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import CoreVideo
import Foundation

protocol MemoryBridge: AnyObject {
    func startPersonEnrollmentSession() -> String
    func attachEnrollmentFaceProfile(sessionId: String, faceProfileId: String, confidence: Double)
    func recognizeApprovedPerson(faceProfileId: String) -> String
    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult
    func recognizedFaceProfileId(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> String?
    func approvePersonEnrollment(personId: String, caregiverName: String)
}

enum ProfileVideoStorageError: LocalizedError {
    case cannotFindDocumentsDirectory
    case cannotEncodeProfileIndex

    var errorDescription: String? {
        switch self {
        case .cannotFindDocumentsDirectory:
            "The app could not open local profile video storage."
        case .cannotEncodeProfileIndex:
            "The app could not save the local profile index."
        }
    }
}

final class MockMemoryBridge: ObservableObject, MemoryBridge {
    private enum DemoPerson {
        static let anitaPersonId = "person-anita"
        static let anitaFaceProfileId = "face-anita-001"
        static let rahulPersonId = "person-rahul"
        static let rahulFaceProfileId = "face-rahul-001"
        static let mayaPersonId = "person-maya"
        static let mayaFaceProfileId = "face-maya-001"
        static let cautiousUnknownResponse = "Unknown person. I do not have a caregiver-approved identity for them yet."
        static let approvedMayaResponse = "This is Maya, your neighbor from next door."
    }

    private var approvedFaceProfileIds: Set<String> = [
        DemoPerson.anitaFaceProfileId,
        DemoPerson.rahulFaceProfileId
    ]
    private var enrollmentFaceProfilesBySessionId: [String: String] = [:]
    @Published private(set) var enrolledVideoProfiles: [StoredPersonVideoProfile] = []

    private let faceRecognitionService = try? FaceRecognitionService()
    private var embeddingsByFaceProfileId: [String: [Float]] = [:]
    private var approvedProfilesByFaceProfileId: [String: PersonProfileDisplay] = [
        DemoPerson.anitaFaceProfileId: PersonProfileDisplay(
            personId: DemoPerson.anitaPersonId,
            faceProfileId: DemoPerson.anitaFaceProfileId,
            name: "Anita",
            relationship: "daughter and caregiver",
            memoryCue: "Anita is your daughter. She helps with appointments and medicine.",
            detailLines: [
                "Trusted caregiver",
                "She picks you up for appointments"
            ],
            caregiverApproved: true
        ),
        DemoPerson.rahulFaceProfileId: PersonProfileDisplay(
            personId: DemoPerson.rahulPersonId,
            faceProfileId: DemoPerson.rahulFaceProfileId,
            name: "Rahul",
            relationship: "grandson",
            memoryCue: "Rahul is your grandson. He likes visiting after school.",
            detailLines: [
                "Family",
                "Anita's son"
            ],
            caregiverApproved: true
        ),
        DemoPerson.mayaFaceProfileId: PersonProfileDisplay(
            personId: DemoPerson.mayaPersonId,
            faceProfileId: DemoPerson.mayaFaceProfileId,
            name: "Maya",
            relationship: "neighbor",
            memoryCue: "Maya is your neighbor from next door.",
            detailLines: [
                "Caregiver approved after enrollment",
                "Often says hello outside"
            ],
            caregiverApproved: true
        )
    ]

    init() {
        loadStoredVideoProfiles()
    }

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

    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult {
        guard
            approvedFaceProfileIds.contains(faceProfileId),
            let profile = approvedProfilesByFaceProfileId[faceProfileId],
            profile.caregiverApproved
        else {
            return .unknown(DemoPerson.cautiousUnknownResponse)
        }

        return .approved(profile)
    }

    func recognizedFaceProfileId(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> String? {
        guard detection.hasFace, detection.confidence >= 0.28 else { return nil }

        if let faceProfileId = detection.faceProfileId, approvedFaceProfileIds.contains(faceProfileId) {
            return faceProfileId
        }

        guard
            let faceRecognitionService,
            !embeddingsByFaceProfileId.isEmpty,
            let embedding = try? faceRecognitionService.liveEmbedding(from: pixelBuffer, detection: detection)
        else {
            return nil
        }

        let candidates = embeddingsByFaceProfileId.map { faceProfileId, embedding in
            FaceEmbeddingCandidate(faceProfileId: faceProfileId, embedding: embedding)
        }

        return faceRecognitionService.bestMatch(for: embedding, candidates: candidates)?.faceProfileId
    }

    @discardableResult
    func enrollPersonFromVideo(
        name: String,
        relationship: String,
        memoryCue: String,
        detailLines: [String],
        sourceVideoURL: URL
    ) throws -> PersonProfileDisplay {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanRelationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredMemoryCue = memoryCue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMemoryCue = enteredMemoryCue.isEmpty ? "This is \(cleanName)." : enteredMemoryCue
        let cleanDetailLines = detailLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let personId = "person-video-\(UUID().uuidString.prefix(8))"
        let faceProfileId = "face-video-\(UUID().uuidString.prefix(8))"
        let storedVideoURL = try storeProfileVideo(sourceURL: sourceVideoURL, personId: personId)
        guard let faceRecognitionService else {
            throw FaceRecognitionError.embeddingModelUnavailable("The face embedding model is not available.")
        }
        let embedding = try faceRecognitionService.enrollmentEmbedding(fromVideoAt: storedVideoURL)
        let profile = PersonProfileDisplay(
            personId: personId,
            faceProfileId: faceProfileId,
            name: cleanName,
            relationship: cleanRelationship,
            memoryCue: cleanMemoryCue,
            detailLines: cleanDetailLines.isEmpty ? ["Video profile", "Caregiver approved"] : cleanDetailLines,
            caregiverApproved: true
        )

        approvedFaceProfileIds.insert(faceProfileId)
        approvedProfilesByFaceProfileId[faceProfileId] = profile
        embeddingsByFaceProfileId[faceProfileId] = embedding
        enrolledVideoProfiles.append(
            StoredPersonVideoProfile(
                profile: profile,
                videoURL: storedVideoURL,
                embedding: embedding,
                createdAt: Date()
            )
        )
        try saveStoredVideoProfiles()

        return profile
    }

    func deleteVideoProfile(personId: String) {
        guard let index = enrolledVideoProfiles.firstIndex(where: { $0.profile.personId == personId }) else {
            return
        }

        let storedProfile = enrolledVideoProfiles.remove(at: index)
        approvedFaceProfileIds.remove(storedProfile.profile.faceProfileId)
        approvedProfilesByFaceProfileId.removeValue(forKey: storedProfile.profile.faceProfileId)
        embeddingsByFaceProfileId.removeValue(forKey: storedProfile.profile.faceProfileId)

        if FileManager.default.fileExists(atPath: storedProfile.videoURL.path) {
            try? FileManager.default.removeItem(at: storedProfile.videoURL)
        }
        try? saveStoredVideoProfiles()
    }

    func approvePersonEnrollment(personId: String, caregiverName: String) {
        guard personId == DemoPerson.mayaPersonId else { return }
        approvedFaceProfileIds.insert(DemoPerson.mayaFaceProfileId)
    }

    private func storeProfileVideo(sourceURL: URL, personId: String) throws -> URL {
        let directoryURL = try profileVideoDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let destinationURL = directoryURL.appendingPathComponent("\(personId).mov")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        return destinationURL
    }

    private func loadStoredVideoProfiles() {
        guard
            let indexURL = try? profileIndexURL(),
            let data = try? Data(contentsOf: indexURL),
            let storedProfiles = try? JSONDecoder().decode([StoredPersonVideoProfile].self, from: data)
        else {
            return
        }

        enrolledVideoProfiles = storedProfiles.filter { storedProfile in
            FileManager.default.fileExists(atPath: storedProfile.videoURL.path)
        }

        for storedProfile in enrolledVideoProfiles {
            let faceProfileId = storedProfile.profile.faceProfileId
            approvedFaceProfileIds.insert(faceProfileId)
            approvedProfilesByFaceProfileId[faceProfileId] = storedProfile.profile
            embeddingsByFaceProfileId[faceProfileId] = storedProfile.embedding
        }
    }

    private func saveStoredVideoProfiles() throws {
        let indexURL = try profileIndexURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(enrolledVideoProfiles)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            throw ProfileVideoStorageError.cannotEncodeProfileIndex
        }
    }

    private func profileIndexURL() throws -> URL {
        try profileVideoDirectoryURL().appendingPathComponent("profiles.json")
    }

    private func profileVideoDirectoryURL() throws -> URL {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ProfileVideoStorageError.cannotFindDocumentsDirectory
        }

        let directoryURL = documentsDirectory.appendingPathComponent("ProfileVideos", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
