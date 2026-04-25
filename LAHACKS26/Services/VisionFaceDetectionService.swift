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
        static let faceProfileId = "face-local-001"
        static let detectionRefreshFrames = 4
        static let minimumTrackingConfidence: VNConfidence = 0.2
    }

    private let sequenceHandler = VNSequenceRequestHandler()
    private let detectionRequest: VNDetectFaceRectanglesRequest
    private var trackingRequest: VNTrackObjectRequest?
    private var framesSinceDetection = 0

    init() {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequest.supportedRevisions.max() ?? VNDetectFaceRectanglesRequest.defaultRevision
        request.preferBackgroundProcessing = false
        self.detectionRequest = request
    }

    func prepare() async {
        // Apple Vision ships with iOS, so there is no model download for the live detector.
    }

    func detectFace(in pixelBuffer: CVPixelBuffer, isUsingFrontCamera _: Bool) async -> FaceDetectionResult {
        framesSinceDetection += 1

        if framesSinceDetection < Constants.detectionRefreshFrames, let trackedResult = trackFace(in: pixelBuffer) {
            return trackedResult
        }

        if let detectedResult = detectNewFace(in: pixelBuffer) {
            framesSinceDetection = 0
            return detectedResult
        }

        if let trackedResult = trackFace(in: pixelBuffer) {
            return trackedResult
        }

        trackingRequest = nil
        framesSinceDetection = 0
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

        trackingRequest = makeTrackingRequest(for: bestFace.boundingBox)

        return FaceDetectionResult.detected(
            confidence: Double(bestFace.confidence),
            boundingBox: normalizedTopLeftRect(from: bestFace.boundingBox),
            faceProfileId: Constants.faceProfileId,
            sourceImageSize: sourceSize(from: pixelBuffer)
        )
    }

    private func trackFace(in pixelBuffer: CVPixelBuffer) -> FaceDetectionResult? {
        guard let trackingRequest else { return nil }

        do {
            try sequenceHandler.perform([trackingRequest], on: pixelBuffer, orientation: .up)
        } catch {
            return nil
        }

        guard
            let observation = trackingRequest.results?.first as? VNDetectedObjectObservation,
            observation.confidence >= Constants.minimumTrackingConfidence
        else {
            return nil
        }

        trackingRequest.inputObservation = observation

        return FaceDetectionResult.detected(
            confidence: Double(observation.confidence),
            boundingBox: normalizedTopLeftRect(from: observation.boundingBox),
            faceProfileId: Constants.faceProfileId,
            sourceImageSize: sourceSize(from: pixelBuffer)
        )
    }

    private func makeTrackingRequest(for boundingBox: CGRect) -> VNTrackObjectRequest {
        let observation = VNDetectedObjectObservation(boundingBox: boundingBox)
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = .accurate
        return request
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
