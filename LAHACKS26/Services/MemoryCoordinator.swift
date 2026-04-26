//
//  MemoryCoordinator.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import Foundation

struct MemoryCoordinatorEvent: Identifiable, Equatable {
    enum Kind: Equatable {
        case saving
        case stored
        case noted
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String?
    let patientSafeResponse: String?
}

@MainActor
final class MemoryCoordinator: ObservableObject {
    @Published private(set) var latestEvent: MemoryCoordinatorEvent?

    private let memoryBridge: MemoryBridge
    private let decisionEngine: LLMDecisionEngine
    private let faceProfileId: String
    private let faceConfidence: Double
    private var isConversationActive = false
    private var conversationStartedAt: Date?
    private var transcriptSegments: [TimestampedTranscriptSegment] = []
    private var conversationState = ConversationState.empty
    private var currentTranscript = ""
    private var lastCommittedTranscript = ""
    private var lastStoredSignature = ""
    private var liveAnalysisTask: Task<Void, Never>?
    private var transcriptCommitTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var finalAnalysisTask: Task<Void, Never>?

    init(
        memoryBridge: MemoryBridge,
        decisionEngine: LLMDecisionEngine? = nil,
        faceProfileId: String = "face-maya-001",
        faceConfidence: Double = 0.88
    ) {
        self.memoryBridge = memoryBridge
        self.decisionEngine = decisionEngine ?? DefaultLLMDecisionEngineFactory.make()
        self.faceProfileId = faceProfileId
        self.faceConfidence = faceConfidence
    }

    func beginFaceBoundConversation() {
        guard !isConversationActive else { return }

        isConversationActive = true
        conversationStartedAt = Date()
        transcriptSegments = []
        conversationState = .empty
        currentTranscript = ""
        lastCommittedTranscript = ""
        liveAnalysisTask?.cancel()
        transcriptCommitTask?.cancel()
        finalAnalysisTask?.cancel()

        print("MindAnchor conversation: started face-bound transcription")
        startReconciliationLoop()
    }

    func endFaceBoundConversation() {
        guard isConversationActive else { return }

        isConversationActive = false
        transcriptCommitTask?.cancel()
        commitCurrentTranscriptSnapshot()
        liveAnalysisTask?.cancel()
        liveAnalysisTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil

        let fullTranscript = formattedTranscript()
        guard !fullTranscript.isEmpty else {
            print("MindAnchor conversation: ended with no transcript")
            return
        }

        print("MindAnchor conversation: ended, running final pass")
        finalAnalysisTask = Task { [weak self] in
            await self?.runFinalAnalysis(fullTranscript: fullTranscript)
        }
    }

    func submitTranscript(_ transcript: String) {
        guard isConversationActive else { return }

        let cleanedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty, cleanedTranscript != currentTranscript else { return }

        currentTranscript = cleanedTranscript
        scheduleTranscriptCommit()
    }

    func flushCurrentTranscript() {
        commitCurrentTranscriptSnapshot()
    }

    func clearLatestEvent() {
        latestEvent = nil
    }

    private func scheduleTranscriptCommit() {
        transcriptCommitTask?.cancel()
        transcriptCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }

            self?.commitCurrentTranscriptSnapshot()
        }
    }

    private func commitCurrentTranscriptSnapshot() {
        let cleanedTranscript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty, cleanedTranscript != lastCommittedTranscript else { return }

        let segment = TimestampedTranscriptSegment(
            elapsedTime: Date().timeIntervalSince(conversationStartedAt ?? Date()),
            speakerLabel: "Speaker A",
            text: cleanedTranscript
        )
        replaceLatestTranscriptSnapshot(with: segment)

        lastCommittedTranscript = cleanedTranscript
        print("MindAnchor transcript snapshot:", segment.formattedLine)
        scheduleLiveAnalysis()
    }

    private func scheduleLiveAnalysis() {
        guard liveAnalysisTask == nil else { return }

        liveAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            await self?.runLiveAnalysis()
        }
    }

    private func startReconciliationLoop() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled else { return }

                await self?.runReconciliationPass()
            }
        }
    }

    private func runLiveAnalysis() async {
        defer { liveAnalysisTask = nil }
        guard isConversationActive else { return }

        let transcriptWindow = formattedTranscript()
        guard !transcriptWindow.isEmpty else { return }

        let result = await decisionEngine.updateConversationState(
            previousState: conversationState,
            recentTranscript: transcriptWindow
        )
        conversationState = result.conversationState

        print("MindAnchor live decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
    }

    private func runReconciliationPass() async {
        guard isConversationActive else { return }

        let transcriptWindow = formattedTranscript()
        guard !transcriptWindow.isEmpty else { return }

        let result = await decisionEngine.reconcileConversationState(
            previousState: conversationState,
            transcriptWindow: transcriptWindow
        )
        conversationState = result.conversationState

        print("MindAnchor reconciliation decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
        if !storeIfNeeded(decision: result.decision, transcript: transcriptWindow) {
            let fallbackDecision = await decisionEngine.analyzeTranscript(transcriptWindow)
            print("MindAnchor reconciliation storage fallback decision:", fallbackDecision)
            _ = storeIfNeeded(decision: fallbackDecision, transcript: transcriptWindow)
        }
    }

    private func runFinalAnalysis(fullTranscript: String) async {
        let result = await decisionEngine.finalizeConversation(
            previousState: conversationState,
            fullTranscript: fullTranscript
        )
        conversationState = result.conversationState

        print("MindAnchor final decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
        if !storeIfNeeded(decision: result.decision, transcript: fullTranscript) {
            let fallbackDecision = await decisionEngine.analyzeTranscript(fullTranscript)
            print("MindAnchor final storage fallback decision:", fallbackDecision)
            _ = storeIfNeeded(decision: fallbackDecision, transcript: fullTranscript)
        }
    }

    private func storeIfNeeded(decision: TranscriptAnalysisDecision, transcript: String) -> Bool {
        guard decision.shouldStore, decision.memoryType == .person, decision.storageConfidence >= 0.75 else { return false }
        guard decision.extractedName != nil, decision.extractedRelationship != nil || decision.extractedHelpfulContext != nil else { return false }

        let signature = [
            decision.extractedName ?? "",
            decision.extractedRelationship ?? "",
            decision.extractedHelpfulContext ?? ""
        ].joined(separator: "|").lowercased()
        guard !signature.isEmpty, signature != lastStoredSignature else { return false }

        latestEvent = MemoryCoordinatorEvent(
            kind: .saving,
            title: "Saving",
            subtitle: nil,
            patientSafeResponse: nil
        )

        guard let memory = memoryBridge.storePersonDraft(
            transcript: transcript,
            extractedName: decision.extractedName,
            extractedRelationship: decision.extractedRelationship,
            extractedHelpfulContext: decision.extractedHelpfulContext,
            faceProfileId: faceProfileId,
            confidence: faceConfidence,
            needsCaregiverReview: decision.needsCaregiverReview
        ) else {
            latestEvent = nil
            return false
        }

        lastStoredSignature = signature
        print("MindAnchor memory saved:", memory.name)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            latestEvent = MemoryCoordinatorEvent(
                kind: .stored,
                title: "Saved",
                subtitle: nil,
                patientSafeResponse: decision.patientSafeResponse
            )
        }
        return true
    }

    private func formattedTranscript() -> String {
        transcriptSegments
            .last?
            .formattedLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }

    private func replaceLatestTranscriptSnapshot(with segment: TimestampedTranscriptSegment) {
        if transcriptSegments.isEmpty {
            transcriptSegments.append(segment)
        } else {
            transcriptSegments[transcriptSegments.count - 1] = segment
        }
    }
}
