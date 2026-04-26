//
//  FaceRecognitionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import CoreGraphics
import CoreVideo
import Foundation
import UIKit
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
    case noUsableFacesInPhotos
    case faceDetectedButEmbeddingFailed(detectedFaceCount: Int, totalPhotoCount: Int)
    case embeddingModelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noUsableFacesInPhotos:
            "The photos did not contain a clear face. Try again with one face centered in good light."
        case .faceDetectedButEmbeddingFailed(let detectedFaceCount, let totalPhotoCount):
            "A face was detected in \(detectedFaceCount) of \(totalPhotoCount) photos, but the embedding model could not use those face crops. Try again with the face larger in frame and steadier lighting."
        case .embeddingModelUnavailable(let message):
            message
        }
    }
}

final class FaceRecognitionService {
    private enum Constants {
        static let maximumEnrollmentPhotos = 20
        static let minimumFaceArea: CGFloat = 0.006
        static let minimumSimilarity: Float = 0.65
        static let minimumMatchMargin: Float = 0.08
    }

    private let cropper = FaceCropper()
    private let embeddingService: ZeticFaceEmbeddingService

    init() throws {
        do {
            embeddingService = try ZeticFaceEmbeddingService()
        } catch {
            throw FaceRecognitionError.embeddingModelUnavailable(error.localizedDescription)
        }
    }

    func enrollmentEmbedding(fromImages images: [UIImage]) throws -> [Float] {
        let cgImages = images.compactMap(\.normalizedCGImage)
        return try enrollmentEmbedding(fromCGImages: cgImages)
    }

    func enrollmentEmbedding(fromCGImages images: [CGImage]) throws -> [Float] {
        var embeddings: [[Float]] = []
        var detectedFaceCount = 0

        for image in images {
            guard let faceRect = bestFaceRect(in: image) else { continue }
            detectedFaceCount += 1

            do {
                let candidateImages = try cropper.croppedFaceImages(
                    from: image,
                    topLeftNormalizedFaceRect: faceRect
                )
                let embedding = try firstEmbedding(from: candidateImages)
                embeddings.append(FaceEmbeddingMath.l2Normalized(embedding))
            } catch {
                continue
            }

            if embeddings.count >= Constants.maximumEnrollmentPhotos {
                break
            }
        }

        guard !embeddings.isEmpty else {
            if detectedFaceCount > 0 {
                throw FaceRecognitionError.faceDetectedButEmbeddingFailed(
                    detectedFaceCount: detectedFaceCount,
                    totalPhotoCount: images.count
                )
            }
            throw FaceRecognitionError.noUsableFacesInPhotos
        }

        return FaceEmbeddingMath.l2Normalized(average(embeddings))
    }

    func liveEmbedding(from pixelBuffer: CVPixelBuffer, detection: FaceDetectionResult) throws -> [Float] {
        let candidateImages = try cropper.croppedFaceImages(
            from: pixelBuffer,
            faceRect: detection.boundingBox
        )
        let embedding = try firstEmbedding(from: candidateImages)
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
        .sorted { $0.similarity > $1.similarity }

        guard let bestMatch = matches.first, bestMatch.similarity >= Constants.minimumSimilarity else {
            return nil
        }

        if let runnerUp = matches.dropFirst().first,
           bestMatch.similarity - runnerUp.similarity < Constants.minimumMatchMargin {
            return nil
        }

        return bestMatch
    }

    private func firstEmbedding(from candidateImages: [CGImage]) throws -> [Float] {
        for image in candidateImages {
            if let embedding = try? embeddingService.embedding(for: image) {
                return embedding
            }
        }

        throw ZeticFaceEmbeddingError.noEmbeddingOutput
    }

    private func bestFaceRect(in image: CGImage) -> CGRect? {
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .left, .down]

        let bestObservation = orientations.compactMap { orientation -> (CGImagePropertyOrientation, VNFaceObservation)? in
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])

            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            guard let observation = request.results?
                .filter({ candidate in
                    let area = candidate.boundingBox.width * candidate.boundingBox.height
                    return area >= Constants.minimumFaceArea
                })
                .max(by: { lhs, rhs in
                    (lhs.boundingBox.width * lhs.boundingBox.height) < (rhs.boundingBox.width * rhs.boundingBox.height)
                })
            else {
                return nil
            }

            return (orientation, observation)
        }
        .max(by: { lhs, rhs in
            let lhsArea = lhs.1.boundingBox.width * lhs.1.boundingBox.height
            let rhsArea = rhs.1.boundingBox.width * rhs.1.boundingBox.height
            return lhsArea < rhsArea
        })

        guard let (orientation, observation) = bestObservation else {
            return nil
        }

        return normalizedTopLeftRect(from: observation.boundingBox, orientation: orientation)
    }

    private func normalizedTopLeftRect(
        from visionRect: CGRect,
        orientation: CGImagePropertyOrientation = .up
    ) -> CGRect {
        let normalizedBottomLeftRect = visionRect.clampedToUnitRect()
        let orientedBottomLeftRect: CGRect

        switch orientation {
        case .up:
            orientedBottomLeftRect = normalizedBottomLeftRect
        case .right:
            orientedBottomLeftRect = CGRect(
                x: normalizedBottomLeftRect.minY,
                y: 1 - normalizedBottomLeftRect.maxX,
                width: normalizedBottomLeftRect.height,
                height: normalizedBottomLeftRect.width
            )
        case .left:
            orientedBottomLeftRect = CGRect(
                x: 1 - normalizedBottomLeftRect.maxY,
                y: normalizedBottomLeftRect.minX,
                width: normalizedBottomLeftRect.height,
                height: normalizedBottomLeftRect.width
            )
        case .down:
            orientedBottomLeftRect = CGRect(
                x: 1 - normalizedBottomLeftRect.maxX,
                y: 1 - normalizedBottomLeftRect.maxY,
                width: normalizedBottomLeftRect.width,
                height: normalizedBottomLeftRect.height
            )
        default:
            orientedBottomLeftRect = normalizedBottomLeftRect
        }

        return CGRect(
            x: orientedBottomLeftRect.minX,
            y: 1 - orientedBottomLeftRect.maxY,
            width: orientedBottomLeftRect.width,
            height: orientedBottomLeftRect.height
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

private extension UIImage {
    var normalizedCGImage: CGImage? {
        if let cgImage {
            return cgImage
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let renderedImage = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return renderedImage.cgImage
    }
}
