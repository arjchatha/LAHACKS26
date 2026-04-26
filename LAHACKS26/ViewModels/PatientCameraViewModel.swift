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
        static let minimumRecognitionInterval: TimeInterval = 0.4
        static let recognitionHistoryLimit = 4
        static let stableMatchThreshold = 2
        static let recognitionIdentityResetDistance: CGFloat = 0.18
        static let unmatchedRecognitionsBeforeClearing = 2
    }

    private struct FaceRecognitionState {
        var boundingBox: CGRect?
        var lastRecognitionDate = Date.distantPast
        var recognitionHistory: [String?] = []
        var stableFaceProfileId: String?
        var manualFaceProfileId: String?
        var isForcedUnknown = false
        var unmatchedRecognitionStreak = 0
    }

    @Published private(set) var detectionResult: FaceDetectionResult = .none
    @Published private(set) var detectedPersonDescription: String?
    @Published private(set) var detectedPersonDetailLines: [String] = []
    @Published private(set) var focusedPersonTitle: String?
    @Published private(set) var cameraMessage: String?
    @Published private(set) var visiblePersonCount = 0
    @Published private(set) var focusedPersonDisplayIndex = 0
    @Published private(set) var identityChoices: [PersonProfileDisplay] = []

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
    private var recognitionStatesBySlot: [Int: FaceRecognitionState] = [:]
    private let unknownPersonDescription = "Unknown person. Tap here to switch focus."

    convenience init() {
        self.init(memoryBridge: MockMemoryBridge())
    }

    init(memoryBridge: MemoryBridge) {
        self.memoryBridge = memoryBridge
        identityChoices = memoryBridge.approvedProfileDisplays()
        cameraManager.onFrame = { [weak self] pixelBuffer, isUsingFrontCamera in
            self?.processFrame(pixelBuffer, isUsingFrontCamera: isUsingFrontCamera)
        }
    }

    func start() async {
        identityChoices = memoryBridge.approvedProfileDisplays()
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
        focusCurrentStablePerson()
    }

    func focusPreviousPerson() {
        guard stableDetections.count > 1 else { return }

        focusedFaceIndex = (focusedFaceIndex - 1 + stableDetections.count) % stableDetections.count
        focusCurrentStablePerson()
    }

    func assignFocusedPerson(to faceProfileId: String) {
        guard detectionResult.hasFace else { return }

        var state = recognitionState(forSlot: focusedFaceIndex, detection: detectionResult)
        state.manualFaceProfileId = faceProfileId
        state.isForcedUnknown = false
        state.stableFaceProfileId = faceProfileId
        state.recognitionHistory = [faceProfileId]
        recognitionStatesBySlot[focusedFaceIndex] = state
        applyDetection(detectionResult, personIndex: focusedFaceIndex, totalPeople: visiblePersonCount)
    }

    func markFocusedPersonUnknown() {
        guard detectionResult.hasFace else { return }

        var state = recognitionState(forSlot: focusedFaceIndex, detection: detectionResult)
        state.manualFaceProfileId = nil
        state.isForcedUnknown = true
        state.stableFaceProfileId = nil
        state.recognitionHistory = []
        recognitionStatesBySlot[focusedFaceIndex] = state
        applyDetection(detectionResult, personIndex: focusedFaceIndex, totalPeople: visiblePersonCount)
    }

    func clearFocusedPersonIdentityOverride() {
        guard detectionResult.hasFace else { return }

        var state = recognitionState(forSlot: focusedFaceIndex, detection: detectionResult)
        state.manualFaceProfileId = nil
        state.isForcedUnknown = false
        state.stableFaceProfileId = nil
        state.recognitionHistory = []
        recognitionStatesBySlot[focusedFaceIndex] = state
        applyDetection(detectionResult, personIndex: focusedFaceIndex, totalPeople: visiblePersonCount)
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
            updateVisiblePersonPosition(totalPeople: activeDetections.count)

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
        recognitionStatesBySlot = [:]
        updateVisiblePersonPosition(totalPeople: 0)

        withAnimation(.easeOut(duration: 0.2)) {
            applyDetection(.none, personIndex: 0, totalPeople: 0)
        }
    }

    private func focusCurrentStablePerson() {
        let focusedFace = stableDetections[focusedFaceIndex]
        focusedBoundingBox = focusedFace.boundingBox
        smoothedBoundingBox = focusedFace.boundingBox
        updateVisiblePersonPosition(totalPeople: stableDetections.count)

        let smoothedResult = FaceDetectionResult.detected(
            confidence: focusedFace.confidence,
            boundingBox: focusedFace.boundingBox,
            sourceImageSize: focusedFace.sourceImageSize,
            faceProfileId: focusedFace.faceProfileId
        )

        withAnimation(.smooth(duration: 0.18)) {
            applyDetection(
                smoothedResult,
                personIndex: focusedFaceIndex,
                totalPeople: stableDetections.count
            )
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
            : "Unknown person"

        guard let faceProfileId = recognizedFaceProfileIdIfNeeded(for: result, pixelBuffer: pixelBuffer, slot: personIndex) else {
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

    private func recognizedFaceProfileIdIfNeeded(
        for result: FaceDetectionResult,
        pixelBuffer: CVPixelBuffer?,
        slot: Int
    ) -> String? {
        var state = recognitionState(forSlot: slot, detection: result)

        if state.isForcedUnknown {
            recognitionStatesBySlot[slot] = state
            return nil
        }

        if let manualFaceProfileId = state.manualFaceProfileId {
            state.stableFaceProfileId = manualFaceProfileId
            recognitionStatesBySlot[slot] = state
            return manualFaceProfileId
        }

        guard let pixelBuffer else {
            recognitionStatesBySlot[slot] = state
            return state.stableFaceProfileId
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastRecognitionDate) >= Constants.minimumRecognitionInterval else {
            recognitionStatesBySlot[slot] = state
            return state.stableFaceProfileId
        }

        state.lastRecognitionDate = now
        let match = memoryBridge.recognizedFaceProfileId(for: result, in: pixelBuffer)
        updateRecognitionState(&state, with: match)

        if state.recognitionHistory.count > Constants.recognitionHistoryLimit {
            state.recognitionHistory.removeFirst(state.recognitionHistory.count - Constants.recognitionHistoryLimit)
        }

        state.stableFaceProfileId = stableMatch(from: state.recognitionHistory)
        recognitionStatesBySlot[slot] = state
        return state.stableFaceProfileId
    }

    private func updateRecognitionState(_ state: inout FaceRecognitionState, with match: String?) {
        if let stableFaceProfileId = state.stableFaceProfileId {
            if match == stableFaceProfileId {
                state.unmatchedRecognitionStreak = 0
                state.recognitionHistory.append(match)
                return
            }

            if match == nil {
                state.unmatchedRecognitionStreak += 1
                if state.unmatchedRecognitionStreak >= Constants.unmatchedRecognitionsBeforeClearing {
                    state.stableFaceProfileId = nil
                    state.recognitionHistory = []
                } else {
                    state.recognitionHistory.append(match)
                }
                return
            }

            state.unmatchedRecognitionStreak = 0
            state.stableFaceProfileId = nil
            state.recognitionHistory = [match]
            return
        }

        state.unmatchedRecognitionStreak = match == nil ? state.unmatchedRecognitionStreak + 1 : 0
        state.recognitionHistory.append(match)
    }

    private func stableMatch(from history: [String?]) -> String? {
        let counts = history.compactMap(\.self).reduce(into: [String: Int]()) { result, faceProfileId in
            result[faceProfileId, default: 0] += 1
        }

        return counts.first { _, count in
            count >= Constants.stableMatchThreshold
        }?.key
    }

    private func recognitionState(forSlot slot: Int, detection: FaceDetectionResult) -> FaceRecognitionState {
        var state = recognitionStatesBySlot[slot] ?? FaceRecognitionState()

        if let previousBox = state.boundingBox {
            let centerDistance = previousBox.center.distance(to: detection.boundingBox.center)
            let sizeDelta = abs(previousBox.width - detection.boundingBox.width)
                + abs(previousBox.height - detection.boundingBox.height)

            if centerDistance > Constants.recognitionIdentityResetDistance || sizeDelta > 0.32 {
                state = FaceRecognitionState()
            }
        }

        state.boundingBox = detection.boundingBox
        return state
    }

    private func updateVisiblePersonPosition(totalPeople: Int) {
        visiblePersonCount = totalPeople
        focusedPersonDisplayIndex = totalPeople > 0 ? min(focusedFaceIndex + 1, totalPeople) : 0
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
        pruneRecognitionStates(maxSlotCount: stableDetections.count)
        return stableDetections
    }

    private func pruneRecognitionStates(maxSlotCount: Int) {
        recognitionStatesBySlot = recognitionStatesBySlot.filter { slot, _ in
            slot >= 0 && slot < maxSlotCount
        }
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
