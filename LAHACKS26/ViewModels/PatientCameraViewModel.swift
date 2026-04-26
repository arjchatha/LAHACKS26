//
//  PatientCameraViewModel.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import AVFoundation
import Combine
import CoreVideo
import Foundation
import SwiftUI

@MainActor
final class PatientCameraViewModel: ObservableObject {
    private enum Constants {
        static let minimumFrameInterval: TimeInterval = 0.12
        static let emptyDetectionTolerance = 4
        static let expandDetectionsThreshold = 2
        static let shrinkDetectionsThreshold = 3
        static let detectionMatchDistance: CGFloat = 0.24
        static let minimumRecognitionInterval: TimeInterval = 0.85
        static let recognitionHistoryLimit = 2
        static let stableMatchThreshold = 1
        static let recognitionIdentityResetDistance: CGFloat = 0.18
        static let unmatchedRecognitionsBeforeClearing = 2
        static let minimumEmbeddingCaptureInterval: TimeInterval = 0.35
        static let requiredLiveFaceSamples = 20
        static let enrollmentTimeout: TimeInterval = 90
    }

    private struct FaceRecognitionState {
        var boundingBox: CGRect?
        var lastRecognitionDate = Date.distantPast
        var recognitionHistory: [String?] = []
        var stableFaceProfileId: String?
        var latestBestCandidate: FaceRecognitionMatch?
        var manualFaceProfileId: String?
        var isForcedUnknown = false
        var unmatchedRecognitionStreak = 0
    }

    private struct LiveEnrollmentSession {
        let name: String
        var transcript: String
        var embeddings: [[Float]] = []
        var lastEmbeddingDate = Date.distantPast
        var startedAt = Date()
    }

    @Published private(set) var detectionResult: FaceDetectionResult = .none
    @Published private(set) var detectedPersonDescription: String?
    @Published private(set) var detectedPersonDetailLines: [String] = []
    @Published private(set) var focusedPersonTitle: String?
    @Published private(set) var cameraMessage: String?
    @Published private(set) var visiblePersonCount = 0
    @Published private(set) var focusedPersonDisplayIndex = 0
    @Published private(set) var liveStatusText = "Starting live feed"
    @Published private(set) var heardSpeechText = ""
    @Published private(set) var isListeningForSpeech = false
    @Published private(set) var activeEnrollmentName: String?
    @Published private(set) var activeEnrollmentProgress = 0
    @Published private(set) var activeEnrollmentTarget = Constants.requiredLiveFaceSamples

    let cameraManager = CameraManager()

    private let faceDetectionService = AppleVisionFaceDetectionService()
    private let speechService = AppleSpeechTranscriptionService()
    private let summaryService = IntroductionSummaryService()
    private let memoryBridge: MemoryBridge
    private var speechCancellable: AnyCancellable?
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
    private var enrollmentSession: LiveEnrollmentSession?
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestDetection: FaceDetectionResult?
    private let unknownPersonDescription = "Unknown"

    convenience init() {
        self.init(memoryBridge: MockMemoryBridge())
    }

    init(memoryBridge: MemoryBridge) {
        self.memoryBridge = memoryBridge
        cameraManager.onFrame = { [weak self] pixelBuffer, isUsingFrontCamera in
            self?.processFrame(pixelBuffer, isUsingFrontCamera: isUsingFrontCamera)
        }

        speechCancellable = speechService.$transcript
            .removeDuplicates()
            .sink { [weak self] transcript in
                self?.handleTranscriptUpdate(transcript)
            }
    }

    func start() async {
        liveStatusText = "Requesting camera and speech access"
        await speechService.requestPermissions()
        await faceDetectionService.prepare()
        await cameraManager.requestPermissionAndStart()

        switch cameraManager.state {
        case .ready:
            cameraMessage = nil
            liveStatusText = "Live feed ready"
        case .denied:
            cameraMessage = "Camera access is off. You can turn it on in Settings."
            liveStatusText = cameraMessage ?? liveStatusText
        case .unavailable(let message):
            cameraMessage = message
            liveStatusText = message
        case .idle, .requestingPermission:
            cameraMessage = "Camera is starting."
            liveStatusText = "Camera is starting"
        }
    }

    func stop() {
        stopSpeechRecording()
        cameraManager.stop()
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
            latestPixelBuffer = pixelBuffer
            startSpeechRecordingIfNeeded()

            let smoothedResult = FaceDetectionResult.detected(
                confidence: focus.detection.confidence,
                boundingBox: smoothedRect(toward: focus.detection.boundingBox),
                sourceImageSize: focus.detection.sourceImageSize,
                faceProfileId: focus.detection.faceProfileId
            )
            latestDetection = smoothedResult

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

    private func applyDetection(
        _ result: FaceDetectionResult,
        personIndex: Int,
        totalPeople: Int,
        pixelBuffer: CVPixelBuffer? = nil
    ) {
        detectionResult = result
        latestDetection = result.hasFace ? result : nil

        guard result.hasFace, totalPeople > 0 else {
            focusedPersonTitle = nil
            detectedPersonDescription = nil
            detectedPersonDetailLines = []
            return
        }

        let recognition = faceRecognitionIfNeeded(for: result, pixelBuffer: pixelBuffer, slot: personIndex)
        if let faceProfileId = recognition.acceptedFaceProfileId {
            showProfile(faceProfileId: faceProfileId)
            if !heardSpeechText.isEmpty {
                memoryBridge.appendTranscript(heardSpeechText, to: faceProfileId)
            }
            return
        }

        focusedPersonTitle = enrollmentSession.map { "Learning \($0.name)" } ?? fallbackTitle(personIndex: personIndex, totalPeople: totalPeople)
        detectedPersonDescription = enrollmentSession == nil
            ? unknownDescription(bestCandidate: recognition.bestCandidate)
            : "Listening for an introduction."
        detectedPersonDetailLines = enrollmentSession.map {
            ["Face samples \($0.embeddings.count)/\(Constants.requiredLiveFaceSamples)", "Listening"]
        } ?? []

        if let pixelBuffer {
            captureEnrollmentEmbeddingIfNeeded(detection: result, pixelBuffer: pixelBuffer)
        }
    }

    private func faceRecognitionIfNeeded(
        for result: FaceDetectionResult,
        pixelBuffer: CVPixelBuffer?,
        slot: Int
    ) -> (acceptedFaceProfileId: String?, bestCandidate: FaceRecognitionMatch?) {
        var state = recognitionState(forSlot: slot, detection: result)

        if state.isForcedUnknown {
            recognitionStatesBySlot[slot] = state
            return (nil, nil)
        }

        if let manualFaceProfileId = state.manualFaceProfileId {
            state.stableFaceProfileId = manualFaceProfileId
            recognitionStatesBySlot[slot] = state
            return (manualFaceProfileId, nil)
        }

        guard let pixelBuffer else {
            recognitionStatesBySlot[slot] = state
            return (state.stableFaceProfileId, state.latestBestCandidate)
        }

        let now = Date()
        guard now.timeIntervalSince(state.lastRecognitionDate) >= Constants.minimumRecognitionInterval else {
            recognitionStatesBySlot[slot] = state
            return (state.stableFaceProfileId, state.latestBestCandidate)
        }

        state.lastRecognitionDate = now
        let decision = memoryBridge.faceRecognitionDecision(for: result, in: pixelBuffer)
        state.latestBestCandidate = decision?.bestCandidate
        updateRecognitionState(&state, with: decision?.acceptedMatch?.faceProfileId)

        if state.recognitionHistory.count > Constants.recognitionHistoryLimit {
            state.recognitionHistory.removeFirst(state.recognitionHistory.count - Constants.recognitionHistoryLimit)
        }

        state.stableFaceProfileId = stableMatch(from: state.recognitionHistory)
        recognitionStatesBySlot[slot] = state
        return (state.stableFaceProfileId, state.latestBestCandidate)
    }

    private func fallbackTitle(personIndex: Int, totalPeople: Int) -> String {
        totalPeople > 1 ? "Person \(personIndex + 1)" : "Unknown"
    }

    private func unknownDescription(bestCandidate: FaceRecognitionMatch?) -> String {
        guard let bestCandidate else {
            return unknownPersonDescription
        }

        let displayResult = memoryBridge.profileDisplay(for: bestCandidate.faceProfileId)
        let percent = Int((bestCandidate.similarity.clamped(to: 0...1) * 100).rounded())
        return "Closest: \(displayResult.title) \(percent)%"
    }

    private func captureEnrollmentEmbeddingIfNeeded(detection: FaceDetectionResult, pixelBuffer: CVPixelBuffer) {
        guard var session = enrollmentSession else { return }

        let now = Date()
        if now.timeIntervalSince(session.startedAt) > Constants.enrollmentTimeout {
            enrollmentSession = nil
            activeEnrollmentName = nil
            activeEnrollmentProgress = 0
            liveStatusText = "Ready for a new introduction"
            return
        }

        guard now.timeIntervalSince(session.lastEmbeddingDate) >= Constants.minimumEmbeddingCaptureInterval else {
            return
        }

        guard let embedding = memoryBridge.faceEmbedding(for: detection, in: pixelBuffer) else {
            liveStatusText = "Face model is still warming up"
            return
        }

        session.embeddings.append(embedding)
        session.lastEmbeddingDate = now
        session.transcript = heardSpeechText
        enrollmentSession = session
        activeEnrollmentProgress = session.embeddings.count
        liveStatusText = "Learning \(session.name) \(session.embeddings.count)/\(Constants.requiredLiveFaceSamples)"

        if session.embeddings.count >= Constants.requiredLiveFaceSamples {
            saveEnrollment(session)
        }
    }

    private func saveEnrollment(_ session: LiveEnrollmentSession) {
        do {
            let profile = try memoryBridge.saveLiveProfile(
                name: session.name,
                transcript: session.transcript,
                embeddings: session.embeddings
            )
            enrollmentSession = nil
            activeEnrollmentName = nil
            activeEnrollmentProgress = 0
            var state = recognitionState(forSlot: focusedFaceIndex, detection: detectionResult)
            state.stableFaceProfileId = profile.faceProfileId
            state.recognitionHistory = [profile.faceProfileId]
            recognitionStatesBySlot[focusedFaceIndex] = state
            showProfile(faceProfileId: profile.faceProfileId)
            liveStatusText = "Saved \(profile.name)"
            generateAndStoreSummary(for: profile, transcript: session.transcript)
        } catch {
            liveStatusText = "Could not save \(session.name): \(error.localizedDescription)"
        }
    }

    private func generateAndStoreSummary(for profile: PersonProfileDisplay, transcript: String) {
        let evidence = transcript
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let summary = summaryService.summary(
            name: profile.name,
            transcriptEvidence: evidence.isEmpty ? [transcript] : evidence
        )
        memoryBridge.updateLiveProfileSummary(summary, for: profile.faceProfileId)
        if recognitionStatesBySlot[focusedFaceIndex]?.stableFaceProfileId == profile.faceProfileId {
            showProfile(faceProfileId: profile.faceProfileId)
        }
    }

    private func showProfile(faceProfileId: String) {
        let displayResult = memoryBridge.profileDisplay(for: faceProfileId)
        focusedPersonTitle = displayResult.title
        detectedPersonDescription = displayResult.description
        detectedPersonDetailLines = displayResult.detailLines
    }

    private func handleTranscriptUpdate(_ transcript: String) {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        heardSpeechText = cleanedTranscript
        isListeningForSpeech = speechService.isRecording

        guard detectionResult.hasFace else { return }

        if let name = introducedName(in: cleanedTranscript) {
            if enrollmentSession?.name.localizedCaseInsensitiveCompare(name) != .orderedSame {
                enrollmentSession = LiveEnrollmentSession(name: name, transcript: cleanedTranscript)
                activeEnrollmentName = name
                activeEnrollmentProgress = 0
                recognitionStatesBySlot[focusedFaceIndex]?.stableFaceProfileId = nil
                liveStatusText = "Started learning \(name)"
            } else {
                enrollmentSession?.transcript = cleanedTranscript
            }

            if let latestDetection, let latestPixelBuffer {
                captureEnrollmentEmbeddingIfNeeded(detection: latestDetection, pixelBuffer: latestPixelBuffer)
            }
        } else if var session = enrollmentSession {
            session.transcript = cleanedTranscript
            enrollmentSession = session
        } else if let stableFaceProfileId = recognitionStatesBySlot[focusedFaceIndex]?.stableFaceProfileId, !cleanedTranscript.isEmpty {
            memoryBridge.appendTranscript(cleanedTranscript, to: stableFaceProfileId)
        }
    }

    private func startSpeechRecordingIfNeeded() {
        guard !speechService.isRecording else {
            isListeningForSpeech = true
            return
        }

        speechService.resetTranscript()
        speechService.startRecording()
        isListeningForSpeech = speechService.isRecording
        liveStatusText = speechService.isRecording ? "Listening" : speechService.authorizationStatusDescription
    }

    private func stopSpeechRecording() {
        speechService.stopRecording()
        isListeningForSpeech = false
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
        latestPixelBuffer = nil
        latestDetection = nil
        updateVisiblePersonPosition(totalPeople: 0)
        stopSpeechRecording()

        withAnimation(.easeOut(duration: 0.2)) {
            applyDetection(.none, personIndex: 0, totalPeople: 0)
        }

        liveStatusText = enrollmentSession == nil ? "Waiting for a face" : "Waiting for \(enrollmentSession?.name ?? "person")"
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

    private func introducedName(in transcript: String) -> String? {
        let patterns = [
            "\\b(?:i am|i'm|im|my name is)\\s+([a-zA-Z][a-zA-Z'\\-]*(?:\\s+[a-zA-Z][a-zA-Z'\\-]*){0,2})",
            "\\bthis is\\s+([a-zA-Z][a-zA-Z'\\-]*(?:\\s+[a-zA-Z][a-zA-Z'\\-]*){0,2})"
        ]

        for pattern in patterns {
            guard
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                let match = regex.firstMatch(
                    in: transcript,
                    range: NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
                ),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: transcript)
            else {
                continue
            }

            if let name = normalizedIntroducedName(String(transcript[range])) {
                return name
            }
        }

        return nil
    }

    private func normalizedIntroducedName(_ rawName: String) -> String? {
        let stopWords: Set<String> = [
            "and", "but", "from", "with", "your", "the", "a", "an", "here",
            "going", "fine", "happy", "calling", "looking", "not"
        ]
        let words = rawName
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.letters.inverted) }
            .filter { !$0.isEmpty }

        var nameWords: [String] = []
        for word in words {
            let lowercased = word.lowercased()
            guard !stopWords.contains(lowercased) else { break }
            nameWords.append(word)
        }

        guard let firstWord = nameWords.first, firstWord.count >= 2 else { return nil }

        return nameWords
            .prefix(2)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
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

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
