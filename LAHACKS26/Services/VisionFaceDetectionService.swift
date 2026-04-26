//
//  VisionFaceDetectionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import CoreGraphics
import CoreVideo
import ImageIO
import Vision

actor AppleVisionFaceDetectionService {
    private enum Constants {
        static let minimumConfidence: VNConfidence = 0.28
        static let minimumFaceArea: CGFloat = 0.0011
        static let maximumFaceArea: CGFloat = 0.85
        static let minimumAspectRatio: CGFloat = 0.35
        static let maximumAspectRatio: CGFloat = 2.6
        static let maximumTrackedFaces = 6
    }

    private let sequenceHandler = VNSequenceRequestHandler()
    private let detectionRequest: VNDetectFaceRectanglesRequest

    init() {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequest.supportedRevisions.max() ?? VNDetectFaceRectanglesRequest.defaultRevision
        request.preferBackgroundProcessing = false
        self.detectionRequest = request
    }

    func prepare() async {
        // Apple Vision ships with iOS, so there is no model download for the live detector.
    }

    func detectFaces(in pixelBuffer: CVPixelBuffer, isUsingFrontCamera _: Bool) async -> [FaceDetectionResult] {
        do {
            try sequenceHandler.perform([detectionRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return []
        }

        guard let observations = detectionRequest.results else {
            return []
        }

        let imageSize = sourceSize(from: pixelBuffer)
        return observations
            .filter(isPlausibleFace(_:))
            .sorted { lhs, rhs in
                let lhsCenterX = lhs.boundingBox.midX
                let rhsCenterX = rhs.boundingBox.midX

                if abs(lhsCenterX - rhsCenterX) > 0.06 {
                    return lhsCenterX < rhsCenterX
                }

                return score(lhs) > score(rhs)
            }
            .prefix(Constants.maximumTrackedFaces)
            .map { observation in
                FaceDetectionResult.detected(
                    confidence: Double(observation.confidence),
                    boundingBox: normalizedTopLeftRect(from: observation.boundingBox),
                    sourceImageSize: imageSize
                )
            }
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
}
