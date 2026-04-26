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

protocol MemoryBridge: AnyObject {
    func startPersonEnrollmentSession() -> String
    func attachEnrollmentFaceProfile(sessionId: String, faceProfileId: String, confidence: Double)
    func recognizeApprovedPerson(faceProfileId: String) -> String
    func profileDisplay(for faceProfileId: String) -> PersonProfileDisplayResult
    func approvedProfileDisplays() -> [PersonProfileDisplay]
    func recognizedFaceProfileId(for detection: FaceDetectionResult, in pixelBuffer: CVPixelBuffer) -> String?
    func approvePersonEnrollment(personId: String, caregiverName: String)
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
    @Published private(set) var enrolledPhotoProfiles: [StoredPersonPhotoProfile] = []

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
        loadStoredPhotoProfiles()
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

    func approvedProfileDisplays() -> [PersonProfileDisplay] {
        approvedFaceProfileIds
            .compactMap { approvedProfilesByFaceProfileId[$0] }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
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

        let personId = "person-photo-\(UUID().uuidString.prefix(8))"
        let faceProfileId = "face-photo-\(UUID().uuidString.prefix(8))"
        let storedPhotoURLs = try storeProfilePhotos(sourceImages: sourceImages, personId: personId)
        guard let faceRecognitionService else {
            throw FaceRecognitionError.embeddingModelUnavailable("The face embedding model is not available.")
        }

        let embedding = try faceRecognitionService.enrollmentEmbedding(fromImages: sourceImages)
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
            try? removeStoredProfilePhotos(at: storedPhotoURLs)
            throw ProfilePhotoStorageError.invalidEmbeddingData
        }
        let profile = PersonProfileDisplay(
            personId: personId,
            faceProfileId: faceProfileId,
            name: cleanName,
            relationship: cleanRelationship,
            memoryCue: cleanMemoryCue,
            detailLines: cleanDetailLines.isEmpty ? ["Photo profile", "Caregiver approved"] : cleanDetailLines,
            caregiverApproved: true
        )

        approvedFaceProfileIds.insert(faceProfileId)
        approvedProfilesByFaceProfileId[faceProfileId] = profile
        embeddingsByFaceProfileId[faceProfileId] = embedding
        enrolledPhotoProfiles.append(
            StoredPersonPhotoProfile(
                profile: profile,
                photoURLs: storedPhotoURLs,
                embedding: embedding,
                createdAt: Date()
            )
        )
        do {
            try saveStoredPhotoProfiles()
        } catch {
            approvedFaceProfileIds.remove(faceProfileId)
            approvedProfilesByFaceProfileId.removeValue(forKey: faceProfileId)
            embeddingsByFaceProfileId.removeValue(forKey: faceProfileId)
            enrolledPhotoProfiles.removeAll { $0.profile.faceProfileId == faceProfileId }
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
        approvedFaceProfileIds.remove(storedProfile.profile.faceProfileId)
        approvedProfilesByFaceProfileId.removeValue(forKey: storedProfile.profile.faceProfileId)
        embeddingsByFaceProfileId.removeValue(forKey: storedProfile.profile.faceProfileId)

        for photoURL in storedProfile.photoURLs where FileManager.default.fileExists(atPath: photoURL.path) {
            try? FileManager.default.removeItem(at: photoURL)
        }
        try? saveStoredPhotoProfiles()
    }

    func approvePersonEnrollment(personId: String, caregiverName: String) {
        guard personId == DemoPerson.mayaPersonId else { return }
        approvedFaceProfileIds.insert(DemoPerson.mayaFaceProfileId)
    }

    private func storeProfilePhotos(sourceImages: [UIImage], personId: String) throws -> [URL] {
        let directoryURL = try profilePhotoDirectoryURL()
        let profileDirectoryURL = directoryURL.appendingPathComponent(personId, isDirectory: true)
        try FileManager.default.createDirectory(at: profileDirectoryURL, withIntermediateDirectories: true)

        if let existingFiles = try? FileManager.default.contentsOfDirectory(
            at: profileDirectoryURL,
            includingPropertiesForKeys: nil
        ) {
            for fileURL in existingFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        var storedURLs: [URL] = []

        for (index, image) in sourceImages.enumerated() {
            guard let imageData = image.jpegData(compressionQuality: 0.92) else { continue }
            let destinationURL = profileDirectoryURL.appendingPathComponent("photo-\(index + 1).jpg")
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
            !storedProfile.photoURLs.isEmpty
                && storedProfile.photoURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }

        for storedProfile in enrolledPhotoProfiles {
            let faceProfileId = storedProfile.profile.faceProfileId
            approvedFaceProfileIds.insert(faceProfileId)
            approvedProfilesByFaceProfileId[faceProfileId] = storedProfile.profile
            embeddingsByFaceProfileId[faceProfileId] = storedProfile.embedding
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

    private func profileIndexURL() throws -> URL {
        try profilePhotoDirectoryURL().appendingPathComponent("profiles.json")
    }

    private func profilePhotoDirectoryURL() throws -> URL {
        guard let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw ProfilePhotoStorageError.cannotFindDocumentsDirectory
        }

        let directoryURL = documentsDirectory.appendingPathComponent("ProfilePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
