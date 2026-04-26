//
//  PatientCameraViewModel.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class PatientCameraViewModel: ObservableObject {
    private enum Constants {
        static let minimumFrameInterval: TimeInterval = 0.05
        static let emptyDetectionTolerance = 4
        static let expandDetectionsThreshold = 2
        static let shrinkDetectionsThreshold = 3
        static let detectionMatchDistance: CGFloat = 0.24
        static let minimumRecognitionInterval: TimeInterval = 0.65
        static let recognitionHistoryLimit = 5
        static let stableMatchThreshold = 3
    }

    @Published private(set) var detectionResult: FaceDetectionResult = .none
    @Published private(set) var detectedPersonDescription: String?
    @Published private(set) var detectedPersonDetailLines: [String] = []
    @Published private(set) var focusedPersonTitle: String?
    @Published private(set) var cameraMessage: String?

    let cameraManager = CameraManager()

    private let faceDetectionService = AppleVisionFaceDetectionService()
    private let memoryBridge: MemoryBridge
    private var isProcessingFrame = false
    private var lastFrameProcessDate = Date.distantPast
    private var faceMissStreak = 0
    private var focusedFaceIndex = 0
    private var stableDetections: [FaceDetectionResult] = []
    private var pendingDetections: [FaceDetectionResult] = []
    private var pendingDetectionsStreak = 0
    private var focusedBoundingBox: CGRect?
    private var smoothedBoundingBox: CGRect?
    private var lastRecognitionDate = Date.distantPast
    private var recognitionHistory: [String?] = []
    private var stableRecognizedFaceProfileId: String?
    private let unknownPersonDescription = "I see someone nearby. Tap here to switch focus."

    convenience init() {
        self.init(memoryBridge: MockMemoryBridge())
    }

    init(memoryBridge: MemoryBridge) {
        self.memoryBridge = memoryBridge
        cameraManager.onFrame = { [weak self] pixelBuffer, isUsingFrontCamera in
            self?.processFrame(pixelBuffer, isUsingFrontCamera: isUsingFrontCamera)
        }
    }

    func start() async {
        await faceDetectionService.prepare()
        await cameraManager.requestPermissionAndStart()

        switch cameraManager.state {
        case .ready:
            cameraMessage = nil
        case .denied:
            cameraMessage = "Camera access is off. You can turn it on in Settings."
        case .unavailable(let message):
            cameraMessage = message
        case .idle, .requestingPermission:
            cameraMessage = "Camera is starting."
        }
    }

    func stop() {
        cameraManager.stop()
    }

    func focusNextPerson() {
        guard stableDetections.count > 1 else { return }

        focusedFaceIndex = (focusedFaceIndex + 1) % stableDetections.count
        let focusedFace = stableDetections[focusedFaceIndex]
        focusedBoundingBox = focusedFace.boundingBox
        let smoothedResult = FaceDetectionResult.detected(
            confidence: focusedFace.confidence,
            boundingBox: smoothedRect(toward: focusedFace.boundingBox),
            sourceImageSize: focusedFace.sourceImageSize,
            faceProfileId: focusedFace.faceProfileId
        )

        withAnimation(.smooth(duration: 0.18)) {
            applyDetection(smoothedResult, personIndex: focusedFaceIndex, totalPeople: stableDetections.count)
        }
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer, isUsingFrontCamera: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameProcessDate) >= Constants.minimumFrameInterval else { return }
        guard !isProcessingFrame else { return }

        lastFrameProcessDate = now
        isProcessingFrame = true

        let sendablePixelBuffer = SendableFramePixelBuffer(value: pixelBuffer)
        Task { [weak self] in
            guard let self else { return }

            let results = await self.faceDetectionService.detectFaces(
                in: sendablePixelBuffer.value,
                isUsingFrontCamera: isUsingFrontCamera
            )

            await MainActor.run {
                self.handleDetectionResults(results, pixelBuffer: sendablePixelBuffer.value)
                self.isProcessingFrame = false
            }
        }
    }

    private func handleDetectionResults(_ results: [FaceDetectionResult], pixelBuffer: CVPixelBuffer) {
        let validResults = results.filter(\.hasFace)
        guard !validResults.isEmpty else {
            clearDetectionAfterMisses()
            return
        }

        let activeDetections = resolvedStableDetections(from: validResults)

        if !activeDetections.isEmpty, let focus = resolvedFocusedDetection(from: validResults) {
            faceMissStreak = 0
            focusedBoundingBox = focus.detection.boundingBox
            focusedFaceIndex = resolvedStableFocusIndex(for: focus.detection, within: activeDetections)

            let smoothedResult = FaceDetectionResult.detected(
                confidence: focus.detection.confidence,
                boundingBox: smoothedRect(toward: focus.detection.boundingBox),
                sourceImageSize: focus.detection.sourceImageSize,
                faceProfileId: focus.detection.faceProfileId
            )

            withAnimation(.smooth(duration: 0.16)) {
                applyDetection(
                    smoothedResult,
                    personIndex: focusedFaceIndex,
                    totalPeople: activeDetections.count,
                    pixelBuffer: pixelBuffer
                )
            }
            return
        }

        clearDetectionAfterMisses()
    }

    private func clearDetectionAfterMisses() {
        faceMissStreak += 1

        if detectionResult.hasFace {
            guard faceMissStreak >= Constants.emptyDetectionTolerance else { return }
        } else {
            guard faceMissStreak >= 2 else { return }
        }

        smoothedBoundingBox = nil
        focusedBoundingBox = nil
        stableDetections = []
        pendingDetections = []
        pendingDetectionsStreak = 0
        focusedFaceIndex = 0
        recognitionHistory = []
        stableRecognizedFaceProfileId = nil

        withAnimation(.easeOut(duration: 0.2)) {
            applyDetection(.none, personIndex: 0, totalPeople: 0)
        }
    }

    private func smoothedRect(toward nextRect: CGRect) -> CGRect {
        guard let currentRect = smoothedBoundingBox else {
            smoothedBoundingBox = nextRect
            return nextRect
        }

        let centerDistance = hypot(currentRect.midX - nextRect.midX, currentRect.midY - nextRect.midY)
        let sizeDelta = abs(currentRect.width - nextRect.width) + abs(currentRect.height - nextRect.height)

        if centerDistance < 0.006 && sizeDelta < 0.012 {
            return currentRect
        }

        let amount: CGFloat = centerDistance > 0.18 ? 0.58 : 0.2
        let smoothedRect = currentRect.interpolated(toward: nextRect, amount: amount)
        smoothedBoundingBox = smoothedRect
        return smoothedRect
    }

    private func applyDetection(
        _ result: FaceDetectionResult,
        personIndex: Int,
        totalPeople: Int,
        pixelBuffer: CVPixelBuffer? = nil
    ) {
        detectionResult = result
        guard result.hasFace, totalPeople > 0 else {
            focusedPersonTitle = nil
            detectedPersonDescription = nil
            detectedPersonDetailLines = []
            return
        }

        let fallbackTitle = totalPeople > 1
            ? "Person \(personIndex + 1) of \(totalPeople)"
            : "Person nearby"

        guard let faceProfileId = stableRecognizedFaceProfileId ?? recognizedFaceProfileIdIfNeeded(for: result, pixelBuffer: pixelBuffer) else {
            focusedPersonTitle = fallbackTitle
            detectedPersonDescription = unknownPersonDescription
            detectedPersonDetailLines = []
            return
        }

        let displayResult = memoryBridge.profileDisplay(for: faceProfileId)
        focusedPersonTitle = displayResult.title
        detectedPersonDescription = displayResult.description
        detectedPersonDetailLines = displayResult.detailLines
    }

    private func recognizedFaceProfileIdIfNeeded(for result: FaceDetectionResult, pixelBuffer: CVPixelBuffer?) -> String? {
        guard let pixelBuffer else { return nil }

        let now = Date()
        guard now.timeIntervalSince(lastRecognitionDate) >= Constants.minimumRecognitionInterval else {
            return stableRecognizedFaceProfileId
        }

        lastRecognitionDate = now
        let match = memoryBridge.recognizedFaceProfileId(for: result, in: pixelBuffer)
        recognitionHistory.append(match)

        if recognitionHistory.count > Constants.recognitionHistoryLimit {
            recognitionHistory.removeFirst(recognitionHistory.count - Constants.recognitionHistoryLimit)
        }

        stableRecognizedFaceProfileId = stableMatch(from: recognitionHistory)
        return stableRecognizedFaceProfileId
    }

    private func stableMatch(from history: [String?]) -> String? {
        let counts = history.compactMap(\.self).reduce(into: [String: Int]()) { result, faceProfileId in
            result[faceProfileId, default: 0] += 1
        }

        return counts.first { _, count in
            count >= Constants.stableMatchThreshold
        }?.key
    }

    private func resolvedStableDetections(from detections: [FaceDetectionResult]) -> [FaceDetectionResult] {
        guard !detections.isEmpty else {
            pendingDetections = []
            pendingDetectionsStreak = 0
            return stableDetections
        }

        if stableDetections.isEmpty {
            stableDetections = detections
            pendingDetections = []
            pendingDetectionsStreak = 0
            return stableDetections
        }

        if shouldKeepCurrentStableDetections(with: detections) {
            stableDetections = mergeStableDetections(current: stableDetections, incoming: detections)
            pendingDetections = []
            pendingDetectionsStreak = 0
            return stableDetections
        }

        if detectionsMatchPending(detections) {
            pendingDetectionsStreak += 1
        } else {
            pendingDetections = detections
            pendingDetectionsStreak = 1
        }

        let threshold = detections.count > stableDetections.count
            ? Constants.expandDetectionsThreshold
            : Constants.shrinkDetectionsThreshold

        guard pendingDetectionsStreak >= threshold else {
            stableDetections = mergeStableDetections(current: stableDetections, incoming: detections)
            return stableDetections
        }

        stableDetections = pendingDetections
        pendingDetections = []
        pendingDetectionsStreak = 0
        focusedFaceIndex = min(focusedFaceIndex, max(0, stableDetections.count - 1))
        return stableDetections
    }

    private func resolvedFocusedDetection(from detections: [FaceDetectionResult]) -> (index: Int, detection: FaceDetectionResult)? {
        guard !detections.isEmpty else { return nil }

        if let focusedBoundingBox,
           let bestIndex = detections.indices.min(by: { lhs, rhs in
               detections[lhs].boundingBox.center.distance(to: focusedBoundingBox.center)
                   < detections[rhs].boundingBox.center.distance(to: focusedBoundingBox.center)
           }),
           detections[bestIndex].boundingBox.center.distance(to: focusedBoundingBox.center) <= Constants.detectionMatchDistance {
            return (bestIndex, detections[bestIndex])
        }

        let safeIndex = min(focusedFaceIndex, detections.count - 1)
        return (safeIndex, detections[safeIndex])
    }

    private func resolvedStableFocusIndex(for detection: FaceDetectionResult, within detections: [FaceDetectionResult]) -> Int {
        guard !detections.isEmpty else { return 0 }

        return detections.indices.min(by: { lhs, rhs in
            detections[lhs].boundingBox.center.distance(to: detection.boundingBox.center)
                < detections[rhs].boundingBox.center.distance(to: detection.boundingBox.center)
        }) ?? 0
    }

    private func shouldKeepCurrentStableDetections(with detections: [FaceDetectionResult]) -> Bool {
        if detections.count == stableDetections.count {
            return true
        }

        let overlapCount = stableDetections.reduce(into: 0) { count, stable in
            let hasMatch = detections.contains { incoming in
                stable.boundingBox.center.distance(to: incoming.boundingBox.center) <= Constants.detectionMatchDistance
            }
            if hasMatch {
                count += 1
            }
        }

        return overlapCount == min(stableDetections.count, detections.count)
    }

    private func mergeStableDetections(current: [FaceDetectionResult], incoming: [FaceDetectionResult]) -> [FaceDetectionResult] {
        guard !incoming.isEmpty else { return current }

        var remainingIncoming = incoming
        var merged: [FaceDetectionResult] = []

        for stable in current {
            guard let bestMatchIndex = remainingIncoming.indices.min(by: { lhs, rhs in
                remainingIncoming[lhs].boundingBox.center.distance(to: stable.boundingBox.center)
                    < remainingIncoming[rhs].boundingBox.center.distance(to: stable.boundingBox.center)
            }) else {
                merged.append(stable)
                continue
            }

            let bestMatch = remainingIncoming[bestMatchIndex]
            let distance = bestMatch.boundingBox.center.distance(to: stable.boundingBox.center)

            if distance <= Constants.detectionMatchDistance {
                merged.append(bestMatch)
                remainingIncoming.remove(at: bestMatchIndex)
            } else if incoming.count >= current.count {
                merged.append(stable)
            }
        }

        merged.append(contentsOf: remainingIncoming)
        return merged
    }

    private func detectionsMatchPending(_ detections: [FaceDetectionResult]) -> Bool {
        guard detections.count == pendingDetections.count else { return false }

        return zip(detections, pendingDetections).allSatisfy { lhs, rhs in
            lhs.boundingBox.center.distance(to: rhs.boundingBox.center) <= Constants.detectionMatchDistance
        }
    }
}

private struct SendableFramePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

private extension CGRect {
    func interpolated(toward target: CGRect, amount: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + (target.origin.x - origin.x) * amount,
            y: origin.y + (target.origin.y - origin.y) * amount,
            width: size.width + (target.size.width - size.width) * amount,
            height: size.height + (target.size.height - size.height) * amount
        )
    }

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        hypot(x - point.x, y - point.y)
    }
}
