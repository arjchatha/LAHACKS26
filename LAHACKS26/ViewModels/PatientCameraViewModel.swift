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
        static let minimumRecognitionInterval: TimeInterval = 0.85
        static let recognitionHistoryLimit = 2
        static let stableMatchThreshold = 1
        static let recognitionIdentityResetDistance: CGFloat = 0.18
        static let unmatchedRecognitionsBeforeClearing = 2
        static let minimumEmbeddingCaptureInterval: TimeInterval = 0.35
        static let requiredLiveFaceSamples = 20
        static let enrollmentTimeout: TimeInterval = 90
        static let enrollmentNoFaceFrameLimit = 8
    }

    private struct FaceRecognitionState {
        var boundingBox: CGRect?
        var lastRecognitionDate = Date.distantPast
        var recognitionHistory: [String?] = []
        var stableFaceProfileId: String?
        var latestBestCandidate: FaceRecognitionMatch?
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
    @Published private(set) var cameraMessage: String?
    @Published private(set) var liveStatusText = "Starting live feed"
    @Published private(set) var activeEnrollmentName: String?
    @Published private(set) var activeEnrollmentProgress = 0
    @Published private(set) var activeEnrollmentTarget = Constants.requiredLiveFaceSamples

    let cameraManager = CameraManager()

    private let faceDetectionService = AppleVisionFaceDetectionService()
    private let memoryBridge: MemoryBridge
    private var isProcessingFrame = false
    private var lastFrameProcessDate = Date.distantPast
    private var faceMissStreak = 0
    private var smoothedBoundingBox: CGRect?
    private var recognitionState = FaceRecognitionState()
    private var enrollmentSession: LiveEnrollmentSession?
    private var enrollmentNoFaceStreak = 0
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestDetection: FaceDetectionResult?
    private var heardSpeechText = ""

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
        liveStatusText = "Requesting camera access"
        await faceDetectionService.prepare()
        await cameraManager.requestPermissionAndStart()

        switch cameraManager.state {
        case .ready:
            cameraMessage = nil
            liveStatusText = "Waiting for a face"
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
        cancelEnrollmentSession(message: nil)
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
        guard let result = results.first(where: \.hasFace) else {
            recordEnrollmentNoFaceFrame()
            clearDetectionAfterMisses()
            return
        }

        faceMissStreak = 0
        enrollmentNoFaceStreak = 0
        latestPixelBuffer = pixelBuffer

        let recognizedFaceProfileId = enrollmentSession == nil
            ? recognizedFaceProfileId(for: result, pixelBuffer: pixelBuffer)
            : nil
        let smoothedResult = FaceDetectionResult.detected(
            confidence: result.confidence,
            boundingBox: smoothedRect(toward: result.boundingBox),
            sourceImageSize: result.sourceImageSize,
            faceProfileId: recognizedFaceProfileId
        )
        latestDetection = smoothedResult

        withAnimation(.smooth(duration: 0.16)) {
            detectionResult = smoothedResult
        }

        captureEnrollmentEmbeddingIfNeeded(detection: smoothedResult, pixelBuffer: pixelBuffer)
    }

    private func recognizedFaceProfileId(for result: FaceDetectionResult, pixelBuffer: CVPixelBuffer) -> String? {
        var state = recognitionState(for: result)
        let now = Date()

        guard now.timeIntervalSince(state.lastRecognitionDate) >= Constants.minimumRecognitionInterval else {
            recognitionState = state
            return state.stableFaceProfileId
        }

        state.lastRecognitionDate = now
        let decision = memoryBridge.faceRecognitionDecision(for: result, in: pixelBuffer)
        state.latestBestCandidate = decision?.bestCandidate
        updateRecognitionState(&state, with: decision?.acceptedMatch?.faceProfileId)

        if state.recognitionHistory.count > Constants.recognitionHistoryLimit {
            state.recognitionHistory.removeFirst(state.recognitionHistory.count - Constants.recognitionHistoryLimit)
        }

        state.stableFaceProfileId = stableMatch(from: state.recognitionHistory)
        recognitionState = state
        return state.stableFaceProfileId
    }

    func handleTranscriptUpdate(_ transcript: String) {
        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        heardSpeechText = cleanedTranscript

        guard detectionResult.hasFace else { return }

        if let name = introducedName(in: cleanedTranscript) {
            if enrollmentSession?.name.localizedCaseInsensitiveCompare(name) != .orderedSame {
                enrollmentSession = LiveEnrollmentSession(name: name, transcript: cleanedTranscript)
                enrollmentNoFaceStreak = 0
                activeEnrollmentName = name
                activeEnrollmentProgress = 0
                recognitionState.stableFaceProfileId = nil
                recognitionState.recognitionHistory = []
                liveStatusText = "Learning \(name) 0/\(Constants.requiredLiveFaceSamples)"
            } else {
                enrollmentSession?.transcript = cleanedTranscript
            }

            if let latestDetection, let latestPixelBuffer {
                captureEnrollmentEmbeddingIfNeeded(detection: latestDetection, pixelBuffer: latestPixelBuffer)
            }
            return
        }

        if var session = enrollmentSession {
            session.transcript = cleanedTranscript
            enrollmentSession = session
            return
        }

        if let faceProfileId = detectionResult.faceProfileId, !cleanedTranscript.isEmpty {
            memoryBridge.appendTranscript(cleanedTranscript, to: faceProfileId)
        }
    }

    private func captureEnrollmentEmbeddingIfNeeded(detection: FaceDetectionResult, pixelBuffer: CVPixelBuffer) {
        guard var session = enrollmentSession else { return }

        let now = Date()
        if now.timeIntervalSince(session.startedAt) > Constants.enrollmentTimeout {
            cancelEnrollmentSession(message: "Stopped learning \(session.name): timed out.")
            return
        }

        guard now.timeIntervalSince(session.lastEmbeddingDate) >= Constants.minimumEmbeddingCaptureInterval else {
            return
        }

        guard let embedding = memoryBridge.faceEmbedding(for: detection, in: pixelBuffer) else {
            liveStatusText = "Learning \(session.name): waiting for a usable face"
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
            enrollmentNoFaceStreak = 0
            activeEnrollmentName = nil
            activeEnrollmentProgress = 0
            recognitionState.stableFaceProfileId = profile.faceProfileId
            recognitionState.recognitionHistory = [profile.faceProfileId]

            if detectionResult.hasFace {
                let updatedResult = FaceDetectionResult.detected(
                    id: detectionResult.id,
                    confidence: detectionResult.confidence,
                    boundingBox: detectionResult.boundingBox,
                    sourceImageSize: detectionResult.sourceImageSize,
                    faceProfileId: profile.faceProfileId
                )
                latestDetection = updatedResult
                detectionResult = updatedResult
            }

            liveStatusText = "Saved \(profile.name)"
        } catch {
            liveStatusText = "Could not save \(session.name): \(error.localizedDescription)"
        }
    }

    private func recordEnrollmentNoFaceFrame() {
        guard let session = enrollmentSession else {
            enrollmentNoFaceStreak = 0
            return
        }

        enrollmentNoFaceStreak += 1
        guard enrollmentNoFaceStreak >= Constants.enrollmentNoFaceFrameLimit else { return }

        cancelEnrollmentSession(message: "Stopped learning \(session.name): no face was visible.")
    }

    private func cancelEnrollmentSession(message: String?) {
        enrollmentSession = nil
        enrollmentNoFaceStreak = 0
        activeEnrollmentName = nil
        activeEnrollmentProgress = 0

        if let message {
            liveStatusText = message
        }
    }

    private func clearDetectionAfterMisses() {
        faceMissStreak += 1

        if detectionResult.hasFace {
            guard faceMissStreak >= Constants.emptyDetectionTolerance else { return }
        } else {
            guard faceMissStreak >= 2 else { return }
        }

        smoothedBoundingBox = nil
        recognitionState = FaceRecognitionState()
        latestPixelBuffer = nil
        latestDetection = nil

        withAnimation(.easeOut(duration: 0.2)) {
            detectionResult = .none
        }

        if enrollmentSession == nil {
            liveStatusText = "Waiting for a face"
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

    private func recognitionState(for detection: FaceDetectionResult) -> FaceRecognitionState {
        var state = recognitionState

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
            "going", "fine", "happy", "calling", "looking", "not", "recording"
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
