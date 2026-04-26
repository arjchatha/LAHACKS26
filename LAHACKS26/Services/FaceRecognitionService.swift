//
//  FaceRecognitionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct FaceEmbeddingCandidate {
    let faceProfileId: String
    let embedding: [Float]
}

struct FaceRecognitionMatch {
    let faceProfileId: String
    let similarity: Float
}

enum FaceRecognitionError: LocalizedError {
    case noUsableFacesInVideo
    case embeddingModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noUsableFacesInVideo:
            "The video did not contain a clear face. Try recording again with one face centered in good light."
        case .embeddingModelUnavailable(let message):
            message
        }
    }
}

final class FaceRecognitionService {
    private enum Constants {
        static let maximumEnrollmentFrames = 10
        static let enrollmentFrameStrideSeconds = 0.35
        static let minimumFaceArea: CGFloat = 0.012
        static let minimumSimilarity: Float = 0.6
    }

    private let cropper = FaceCropper()
    private let embeddingService: CoreMLFaceEmbeddingService

    init() throws {
        do {
            embeddingService = try CoreMLFaceEmbeddingService()
        } catch {
            throw FaceRecognitionError.embeddingModelUnavailable(error.localizedDescription)
        }
    }

    func enrollmentEmbedding(fromVideoAt videoURL: URL) throws -> [Float] {
        let frameImages = try sampledImages(from: videoURL)
        var embeddings: [[Float]] = []

        for image in frameImages {
            guard let faceRect = bestFaceRect(in: image) else { continue }

            do {
                let tensor = try cropper.preprocessedTensor(
                    from: image,
                    topLeftNormalizedFaceRect: faceRect
                )
                let embedding = try embeddingService.embedding(forPreprocessedFaceTensor: tensor)
                embeddings.append(FaceEmbeddingMath.l2Normalized(embedding))
            } catch {
                continue
            }

            if embeddings.count >= Constants.maximumEnrollmentFrames {
                break
            }
        }

        guard !embeddings.isEmpty else {
            throw FaceRecognitionError.noUsableFacesInVideo
        }

        return FaceEmbeddingMath.l2Normalized(average(embeddings))
    }

    func liveEmbedding(from pixelBuffer: CVPixelBuffer, detection: FaceDetectionResult) throws -> [Float] {
        let tensor = try cropper.preprocessedTensor(
            from: pixelBuffer,
            faceRect: detection.boundingBox
        )
        let embedding = try embeddingService.embedding(forPreprocessedFaceTensor: tensor)
        return FaceEmbeddingMath.l2Normalized(embedding)
    }

    func bestMatch(for embedding: [Float], candidates: [FaceEmbeddingCandidate]) -> FaceRecognitionMatch? {
        let matches = candidates.compactMap { candidate -> FaceRecognitionMatch? in
            guard let similarity = FaceEmbeddingMath.cosineSimilarity(embedding, candidate.embedding) else {
                return nil
            }

            return FaceRecognitionMatch(
                faceProfileId: candidate.faceProfileId,
                similarity: similarity
            )
        }

        guard
            let bestMatch = matches.max(by: { $0.similarity < $1.similarity }),
            bestMatch.similarity >= Constants.minimumSimilarity
        else {
            return nil
        }

        return bestMatch
    }

    private func sampledImages(from videoURL: URL) throws -> [CGImage] {
        let asset = AVAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let durationSeconds = max(0, CMTimeGetSeconds(asset.duration))
        let sampleCount = max(
            1,
            min(
                Constants.maximumEnrollmentFrames * 2,
                Int(durationSeconds / Constants.enrollmentFrameStrideSeconds)
            )
        )
        let times = (0..<sampleCount).map { index in
            CMTime(
                seconds: min(durationSeconds, Double(index) * Constants.enrollmentFrameStrideSeconds),
                preferredTimescale: 600
            )
        }

        return times.compactMap { time in
            try? generator.copyCGImage(at: time, actualTime: nil)
        }
    }

    private func bestFaceRect(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return request.results?
            .filter { observation in
                let area = observation.boundingBox.width * observation.boundingBox.height
                return area >= Constants.minimumFaceArea
            }
            .max(by: { lhs, rhs in
                (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
            })
            .map { normalizedTopLeftRect(from: $0.boundingBox) }
    }

    private func normalizedTopLeftRect(from visionRect: CGRect) -> CGRect {
        CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        ).clampedToUnitRect()
    }

    private func average(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var result = [Float](repeating: 0, count: first.count)

        for embedding in embeddings where embedding.count == result.count {
            for index in result.indices {
                result[index] += embedding[index]
            }
        }

        let scale = Float(embeddings.count)
        guard scale > 0 else { return result }
        return result.map { $0 / scale }
    }
}

private extension CGRect {
    func clampedToUnitRect() -> CGRect {
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
}
