//
//  VisionFaceDetectionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import CoreVideo
import ImageIO
import Foundation
import Vision

actor AppleVisionFaceDetectionService {
    private enum Constants {
        static let minimumConfidence: VNConfidence = 0.28
        static let minimumFaceArea: CGFloat = 0.0011
        static let maximumFaceArea: CGFloat = 0.85
        static let minimumAspectRatio: CGFloat = 0.35
        static let maximumAspectRatio: CGFloat = 2.6
        static let modelBackedFaceMatchDistance: Float = 0.34
        static let modelBackedProfileSampleDistance: Float = 0.18
        static let modelBackedPendingFaceDistance: Float = 0.42
        static let localFaceMatchDistance: Float = 0.16
        static let localProfileSampleDistance: Float = 0.08
        static let localPendingFaceDistance: Float = 0.24
        static let localRecentReturnDistance: Float = 0.36
        static let recentReturnWindow: TimeInterval = 18
        static let maximumSamplesPerProfile = 5
        static let maximumStoredProfiles = 12
    }

    private struct LocalFaceProfile {
        var id: String
        var embeddings: [FaceEmbedding]
        var sightings: Int
        var lastSeen: Date
    }

    private struct PendingFaceProfile {
        var id: String
        var embedding: FaceEmbedding
        var sightings: Int
        var lastSeen: Date
    }

    private let sequenceHandler = VNSequenceRequestHandler()
    private let detectionRequest: VNDetectFaceRectanglesRequest
    private let embeddingProvider = HybridFaceEmbeddingProvider()
    private var localFaceProfiles: [LocalFaceProfile] = []
    private var pendingFaceProfile: PendingFaceProfile?
    private var identityStabilizer = FaceIdentityStabilizer(requiredConsecutiveFrames: 2)
    private var nextFaceProfileIndex = 1
    private var didLogEmbeddingProvider = false
    private var lastResolvedProfileId: String?
    private var lastResolvedProfileDate = Date.distantPast

    init() {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequest.supportedRevisions.max() ?? VNDetectFaceRectanglesRequest.defaultRevision
        request.preferBackgroundProcessing = false
        self.detectionRequest = request
    }

    func prepare() async {
        logEmbeddingProviderIfNeeded()
    }

    func detectFace(in pixelBuffer: CVPixelBuffer, isUsingFrontCamera _: Bool) async -> FaceDetectionResult {
        if let detectedResult = detectNewFace(in: pixelBuffer) {
            return detectedResult
        }

        pendingFaceProfile = nil
        identityStabilizer.reset()
        return .none
    }

    private func detectNewFace(in pixelBuffer: CVPixelBuffer) -> FaceDetectionResult? {
        do {
            try sequenceHandler.perform([detectionRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return nil
        }

        guard
            let observations = detectionRequest.results,
            let bestFace = observations
                .filter(isPlausibleFace(_:))
                .max(by: { score($0) < score($1) })
        else {
            return nil
        }

        let candidateProfileId = candidateFaceProfileId(
            in: pixelBuffer,
            visionBoundingBox: bestFace.boundingBox
        )
        let stableProfileId = identityStabilizer.resolvedProfileId(for: candidateProfileId)
        let displayProfileId = stableProfileId ?? recoveringProfileId(for: candidateProfileId)

        if let displayProfileId {
            lastResolvedProfileId = displayProfileId
            lastResolvedProfileDate = Date()
        }

        return FaceDetectionResult.detected(
            confidence: Double(bestFace.confidence),
            boundingBox: normalizedTopLeftRect(from: bestFace.boundingBox),
            sourceImageSize: sourceSize(from: pixelBuffer),
            faceProfileId: displayProfileId
        )
    }

    private func isPlausibleFace(_ observation: VNFaceObservation) -> Bool {
        let box = observation.boundingBox
        let area = box.width * box.height

        guard observation.confidence >= Constants.minimumConfidence else { return false }
        guard area >= Constants.minimumFaceArea && area <= Constants.maximumFaceArea else { return false }
        guard box.height > 0 else { return false }

        let aspectRatio = box.width / box.height
        return aspectRatio >= Constants.minimumAspectRatio && aspectRatio <= Constants.maximumAspectRatio
    }

    private func score(_ observation: VNFaceObservation) -> CGFloat {
        let box = observation.boundingBox
        let area = box.width * box.height
        return CGFloat(observation.confidence) * pow(area, 0.18)
    }

    private func candidateFaceProfileId(in pixelBuffer: CVPixelBuffer, visionBoundingBox: CGRect) -> String? {
        logEmbeddingProviderIfNeeded()

        guard let embedding = embeddingProvider.embedding(in: pixelBuffer, visionBoundingBox: visionBoundingBox) else {
            return nil
        }

        let faceMatchDistance = embeddingProvider.isModelBacked ?
            Constants.modelBackedFaceMatchDistance :
            Constants.localFaceMatchDistance
        let profileSampleDistance = embeddingProvider.isModelBacked ?
            Constants.modelBackedProfileSampleDistance :
            Constants.localProfileSampleDistance
        let pendingFaceDistance = embeddingProvider.isModelBacked ?
            Constants.modelBackedPendingFaceDistance :
            Constants.localPendingFaceDistance

        if let match = closestProfile(to: embedding), match.distance <= faceMatchDistance {
            pendingFaceProfile = nil
            if match.distance <= profileSampleDistance {
                appendSample(embedding, toProfileAt: match.index)
            }
            localFaceProfiles[match.index].sightings += 1
            localFaceProfiles[match.index].lastSeen = Date()
            return localFaceProfiles[match.index].id
        }

        if
            !embeddingProvider.isModelBacked,
            let recentMatch = closestRecentProfile(to: embedding),
            recentMatch.distance <= Constants.localRecentReturnDistance
        {
            pendingFaceProfile = nil
            appendSample(embedding, toProfileAt: recentMatch.index)
            localFaceProfiles[recentMatch.index].sightings += 1
            localFaceProfiles[recentMatch.index].lastSeen = Date()
            return localFaceProfiles[recentMatch.index].id
        }

        if let pendingFaceProfile {
            let distance = embedding.cosineDistance(to: pendingFaceProfile.embedding)

            if distance <= pendingFaceDistance {
                var updatedPending = pendingFaceProfile
                updatedPending.embedding = embedding
                updatedPending.sightings += 1
                updatedPending.lastSeen = Date()
                self.pendingFaceProfile = updatedPending

                if updatedPending.sightings >= identityStabilizer.requiredConsecutiveFrames {
                    localFaceProfiles.append(
                        LocalFaceProfile(
                            id: updatedPending.id,
                            embeddings: [updatedPending.embedding, embedding],
                            sightings: updatedPending.sightings,
                            lastSeen: updatedPending.lastSeen
                        )
                    )
                    self.pendingFaceProfile = nil
                    trimStoredProfilesIfNeeded()
                }

                return updatedPending.id
            }
        }

        let profileId = String(format: "face-local-%03d", nextFaceProfileIndex)
        nextFaceProfileIndex += 1
        pendingFaceProfile = PendingFaceProfile(
            id: profileId,
            embedding: embedding,
            sightings: 1,
            lastSeen: Date()
        )
        return profileId
    }

    private func recoveringProfileId(for candidateProfileId: String?) -> String? {
        guard
            let candidateProfileId,
            let lastResolvedProfileId,
            candidateProfileId == lastResolvedProfileId,
            Date().timeIntervalSince(lastResolvedProfileDate) <= Constants.recentReturnWindow
        else {
            return nil
        }

        return lastResolvedProfileId
    }

    private func closestProfile(to embedding: FaceEmbedding) -> (index: Int, distance: Float)? {
        var bestMatch: (index: Int, distance: Float)?

        for index in localFaceProfiles.indices {
            for storedEmbedding in localFaceProfiles[index].embeddings {
                let distance = embedding.cosineDistance(to: storedEmbedding)

                if bestMatch == nil || distance < bestMatch!.distance {
                    bestMatch = (index, distance)
                }
            }
        }

        return bestMatch
    }

    private func closestRecentProfile(to embedding: FaceEmbedding) -> (index: Int, distance: Float)? {
        let now = Date()
        var bestMatch: (index: Int, distance: Float)?

        for index in localFaceProfiles.indices {
            guard now.timeIntervalSince(localFaceProfiles[index].lastSeen) <= Constants.recentReturnWindow else {
                continue
            }

            if let centroid = FaceEmbedding.mean(of: localFaceProfiles[index].embeddings) {
                let distance = embedding.cosineDistance(to: centroid)
                if bestMatch == nil || distance < bestMatch!.distance {
                    bestMatch = (index, distance)
                }
            }
        }

        return bestMatch
    }

    private func trimStoredProfilesIfNeeded() {
        guard localFaceProfiles.count > Constants.maximumStoredProfiles else { return }

        localFaceProfiles.sort {
            if $0.sightings == $1.sightings {
                return $0.lastSeen > $1.lastSeen
            }

            return $0.sightings > $1.sightings
        }
        localFaceProfiles = Array(localFaceProfiles.prefix(Constants.maximumStoredProfiles))
    }

    private func appendSample(_ embedding: FaceEmbedding, toProfileAt index: Int) {
        localFaceProfiles[index].embeddings.append(embedding)
        if localFaceProfiles[index].embeddings.count > Constants.maximumSamplesPerProfile {
            localFaceProfiles[index].embeddings.removeFirst(
                localFaceProfiles[index].embeddings.count - Constants.maximumSamplesPerProfile
            )
        }
    }

    private func logEmbeddingProviderIfNeeded() {
        guard !didLogEmbeddingProvider else { return }
        didLogEmbeddingProvider = true

        if embeddingProvider.isModelBacked {
            print("MindAnchor face identity: using bundled Core ML face embedding model")
        } else {
            print("MindAnchor face identity: FaceEmbedding.mlmodelc not bundled; using local face appearance embeddings")
        }
    }

    private func normalizedTopLeftRect(from visionRect: CGRect) -> CGRect {
        let rect = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )

        return rect.clampedToUnitRect()
    }

    private func sourceSize(from pixelBuffer: CVPixelBuffer) -> CGSize {
        CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }
}

private extension CGRect {
    nonisolated func clampedToUnitRect() -> CGRect {
        let minX = max(0, min(1, origin.x))
        let minY = max(0, min(1, origin.y))
        let maxX = max(0, min(1, origin.x + size.width))
        let maxY = max(0, min(1, origin.y + size.height))

        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    nonisolated func paddedBy(_ amount: CGFloat) -> CGRect {
        insetBy(dx: -width * amount, dy: -height * amount)
    }
}
