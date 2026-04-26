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
    private let localExtractor = LocalEpisodicMemoryExtractor()
    private let shouldUseLLMRefinement = false
    private var faceProfileId: String
    private let faceConfidence: Double
    private var isConversationActive = false
    private var conversationStartedAt: Date?
    private var transcriptSegments: [TimestampedTranscriptSegment] = []
    private var conversationState = ConversationState.empty
    private var currentTranscript = ""
    private var lastCommittedTranscript = ""
    private var lastStoredSignature = ""
    private var lastSavedEvidenceQuote = ""
    private var lastLocalSaveDate = Date.distantPast
    private var needsLiveAnalysisRerun = false
    private var liveAnalysisTask: Task<Void, Never>?
    private var transcriptCommitTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var finalAnalysisTask: Task<Void, Never>?

    init(
        memoryBridge: MemoryBridge,
        decisionEngine: LLMDecisionEngine? = nil,
        faceProfileId: String = "face-unassigned",
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
        lastSavedEvidenceQuote = ""
        lastLocalSaveDate = .distantPast
        needsLiveAnalysisRerun = false
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
        needsLiveAnalysisRerun = false
        reconciliationTask?.cancel()
        reconciliationTask = nil

        let fullTranscript = formattedTranscript()
        guard !fullTranscript.isEmpty else {
            print("MindAnchor conversation: ended with no transcript")
            return
        }

        if shouldUseLLMRefinement, localExtractor.shouldSendToLLM(fullTranscript) {
            print("MindAnchor conversation: ended, running final pass")
            finalAnalysisTask = Task { [weak self] in
                await self?.runFinalAnalysis(fullTranscript: fullTranscript)
            }
        } else {
            print("MindAnchor conversation: ended")
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

    func updateActiveFaceProfileId(_ faceProfileId: String?) {
        guard
            let faceProfileId = faceProfileId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !faceProfileId.isEmpty,
            faceProfileId != self.faceProfileId
        else {
            return
        }

        if isConversationActive {
            commitCurrentTranscriptSnapshot()
            currentTranscript = ""
            lastCommittedTranscript = ""
        }

        self.faceProfileId = faceProfileId
        print("MindAnchor active face profile:", faceProfileId)
    }

    func clearLatestEvent() {
        latestEvent = nil
    }

    private func scheduleTranscriptCommit() {
        transcriptCommitTask?.cancel()
        transcriptCommitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            self?.commitCurrentTranscriptSnapshot()
        }
    }

    private func commitCurrentTranscriptSnapshot() {
        let cleanedTranscript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTranscript.isEmpty, cleanedTranscript != lastCommittedTranscript else { return }

        let segment = TimestampedTranscriptSegment(
            elapsedTime: Date().timeIntervalSince(conversationStartedAt ?? Date()),
            speakerLabel: "Conversation",
            text: cleanedTranscript
        )
        replaceLatestTranscriptSnapshot(with: segment)

        lastCommittedTranscript = cleanedTranscript
        print("MindAnchor transcript snapshot:", segment.formattedLine)
        if !storeLocalPersonIfNeeded(from: cleanedTranscript) {
            storeLocalInteractionIfNeeded(from: cleanedTranscript)
        }

        if shouldUseLLMRefinement, localExtractor.shouldSendToLLM(cleanedTranscript) {
            scheduleLiveAnalysis()
        }
    }

    private func scheduleLiveAnalysis() {
        guard liveAnalysisTask == nil else {
            needsLiveAnalysisRerun = true
            return
        }

        liveAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
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
                guard self?.shouldUseLLMRefinement == true else { continue }

                await self?.runReconciliationPass()
            }
        }
    }

    private func runLiveAnalysis() async {
        defer {
            liveAnalysisTask = nil
            if needsLiveAnalysisRerun, isConversationActive {
                needsLiveAnalysisRerun = false
                scheduleLiveAnalysis()
            }
        }
        guard isConversationActive else { return }

        let transcriptWindow = formattedTranscript()
        guard !transcriptWindow.isEmpty else { return }
        guard localExtractor.shouldSendToLLM(transcriptWindow) else { return }

        let result = await decisionEngine.updateConversationState(
            previousState: conversationState,
            recentTranscript: transcriptWindow
        )
        conversationState = result.conversationState

        print("MindAnchor live decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
        _ = storeIfNeeded(decision: result.decision, transcript: transcriptWindow)
    }

    private func runReconciliationPass() async {
        guard isConversationActive else { return }

        let transcriptWindow = formattedTranscript()
        guard !transcriptWindow.isEmpty else { return }
        guard localExtractor.shouldSendToLLM(transcriptWindow) else { return }

        let result = await decisionEngine.reconcileConversationState(
            previousState: conversationState,
            transcriptWindow: transcriptWindow
        )
        conversationState = result.conversationState

        print("MindAnchor reconciliation decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
        _ = storeIfNeeded(decision: result.decision, transcript: transcriptWindow)
    }

    private func runFinalAnalysis(fullTranscript: String) async {
        let result = await decisionEngine.finalizeConversation(
            previousState: conversationState,
            fullTranscript: fullTranscript
        )
        conversationState = result.conversationState

        print("MindAnchor final decision:", result.decision)
        print("MindAnchor conversation state:", conversationState.promptJSON)
        _ = storeIfNeeded(decision: result.decision, transcript: fullTranscript)
    }

    private func storeIfNeeded(decision: TranscriptAnalysisDecision, transcript: String) -> Bool {
        guard canStoreForActiveFace else { return false }
        guard decision.shouldStore, decision.memoryType != .none, decision.storageConfidence >= 0.8 else { return false }

        if decision.memoryType != .person {
            return storeInteractionIfNeeded(decision: decision, transcript: transcript)
        }

        guard isValidPersonDecision(decision, transcript: transcript) else {
            if storeInteractionIfNeeded(decision: decision, transcript: transcript) {
                return true
            }

            print("MindAnchor memory rejected: invalid person extraction:", decision)
            return false
        }

        let signature = [
            faceProfileId,
            decision.memoryType.rawValue,
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
            needsCaregiverReview: false
        ) else {
            latestEvent = nil
            return false
        }

        lastStoredSignature = signature
        print("MindAnchor memory saved:", memory.name)
        _ = storeInteractionIfNeeded(decision: decision, transcript: transcript, shouldShowEvent: false)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            latestEvent = MemoryCoordinatorEvent(
                kind: .stored,
                title: "Remembered",
                subtitle: memory.name,
                patientSafeResponse: decision.patientSafeResponse ?? memoryBridge.recognizeApprovedPerson(faceProfileId: faceProfileId)
            )
        }
        return true
    }

    private func storeLocalPersonIfNeeded(from transcript: String) -> Bool {
        guard canStoreForActiveFace else { return false }
        guard let candidate = localExtractor.extractPersonProfile(from: transcript) else { return false }

        let signature = [
            faceProfileId,
            "person",
            candidate.name,
            candidate.relationship,
            candidate.helpfulContext
        ].joined(separator: "|").lowercased()
        guard !signature.isEmpty, signature != lastStoredSignature else { return false }

        latestEvent = MemoryCoordinatorEvent(
            kind: .saving,
            title: "Saving",
            subtitle: candidate.name,
            patientSafeResponse: nil
        )

        guard let memory = memoryBridge.storePersonDraft(
            transcript: transcript,
            extractedName: candidate.name,
            extractedRelationship: candidate.relationship,
            extractedHelpfulContext: candidate.helpfulContext,
            faceProfileId: faceProfileId,
            confidence: faceConfidence,
            needsCaregiverReview: false
        ) else {
            latestEvent = nil
            return false
        }

        let interaction = memoryBridge.storeInteractionMemory(
            memoryType: "lastInteraction",
            summary: candidate.summary,
            evidenceQuote: candidate.evidenceQuote,
            emotionalContext: nil,
            followUpContext: nil,
            retentionHint: "recent",
            transcript: transcript,
            faceProfileId: faceProfileId
        )

        lastStoredSignature = signature
        lastSavedEvidenceQuote = candidate.evidenceQuote
        lastLocalSaveDate = Date()
        print("MindAnchor local person memory saved:", memory.name)
        if let interaction {
            print("MindAnchor local interaction memory saved:", interaction.summary)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            latestEvent = MemoryCoordinatorEvent(
                kind: .stored,
                title: "Remembered",
                subtitle: memory.name,
                patientSafeResponse: memoryBridge.recognizeApprovedPerson(faceProfileId: faceProfileId)
            )
        }
        return true
    }

    private func storeLocalInteractionIfNeeded(from transcript: String) {
        guard canStoreForActiveFace else { return }
        guard let candidate = localExtractor.extract(from: transcript) else { return }
        guard shouldPresentLocalSave(for: candidate) else { return }

        let signature = [
            faceProfileId,
            candidate.memoryType,
            candidate.summary,
            candidate.evidenceQuote,
            candidate.retentionHint ?? ""
        ].joined(separator: "|").lowercased()
        guard !signature.isEmpty, signature != lastStoredSignature else { return }

        latestEvent = MemoryCoordinatorEvent(
            kind: .saving,
            title: "Saving",
            subtitle: nil,
            patientSafeResponse: nil
        )

        guard let memory = memoryBridge.storeInteractionMemory(
            memoryType: candidate.memoryType,
            summary: candidate.summary,
            evidenceQuote: candidate.evidenceQuote,
            emotionalContext: candidate.emotionalContext,
            followUpContext: candidate.followUpContext,
            retentionHint: candidate.retentionHint,
            transcript: transcript,
            faceProfileId: faceProfileId
        ) else {
            latestEvent = nil
            return
        }

        lastStoredSignature = signature
        lastSavedEvidenceQuote = candidate.evidenceQuote
        lastLocalSaveDate = Date()
        print("MindAnchor local interaction memory saved:", memory.summary)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            latestEvent = MemoryCoordinatorEvent(
                kind: .stored,
                title: "Remembered",
                subtitle: nil,
                patientSafeResponse: memory.summary
            )
        }
    }

    private func shouldPresentLocalSave(for candidate: LocalEpisodicMemoryCandidate) -> Bool {
        let evidence = candidate.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !evidence.isEmpty else { return false }

        if evidence.hasPrefix(lastSavedEvidenceQuote), evidence != lastSavedEvidenceQuote {
            return Date().timeIntervalSince(lastLocalSaveDate) >= 4
        }

        if lastSavedEvidenceQuote.hasPrefix(evidence) {
            return false
        }

        return true
    }

    private func storeInteractionIfNeeded(
        decision: TranscriptAnalysisDecision,
        transcript: String,
        shouldShowEvent: Bool = true
    ) -> Bool {
        guard canStoreForActiveFace else { return false }
        guard isValidInteractionDecision(decision, transcript: transcript) else { return false }

        let signature = [
            faceProfileId,
            decision.memoryType.rawValue,
            decision.interactionSummary ?? "",
            decision.evidenceQuote ?? "",
            decision.retentionHint ?? ""
        ].joined(separator: "|").lowercased()
        guard !signature.isEmpty, signature != lastStoredSignature else { return false }

        if shouldShowEvent {
            latestEvent = MemoryCoordinatorEvent(
                kind: .saving,
                title: "Saving",
                subtitle: nil,
                patientSafeResponse: nil
            )
        }

        guard let memory = memoryBridge.storeInteractionMemory(
            memoryType: decision.memoryType.rawValue,
            summary: decision.interactionSummary ?? "",
            evidenceQuote: decision.evidenceQuote ?? "",
            emotionalContext: decision.emotionalContext,
            followUpContext: decision.followUpContext,
            retentionHint: decision.retentionHint,
            transcript: transcript,
            faceProfileId: faceProfileId
        ) else {
            if shouldShowEvent {
                latestEvent = nil
            }
            return false
        }

        lastStoredSignature = signature
        print("MindAnchor interaction memory saved:", memory.summary)

        guard shouldShowEvent else { return true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            latestEvent = MemoryCoordinatorEvent(
                kind: .stored,
                title: "Remembered",
                subtitle: nil,
                patientSafeResponse: decision.patientSafeResponse ?? memory.summary
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

    private var canStoreForActiveFace: Bool {
        !faceProfileId.isEmpty && faceProfileId != "face-unassigned"
    }

    private func isValidPersonDecision(_ decision: TranscriptAnalysisDecision, transcript: String) -> Bool {
        guard let name = cleanedDecisionField(decision.extractedName) else { return false }
        let relationship = cleanedDecisionField(decision.extractedRelationship)
        let helpfulContext = cleanedDecisionField(decision.extractedHelpfulContext)
        guard relationship != nil || helpfulContext != nil else { return false }

        let normalizedName = normalized(name)
        guard !isGenericNamePlaceholder(normalizedName) else { return false }
        guard transcript.localizedCaseInsensitiveContains(name) else { return false }

        if let relationship, isGenericFieldPlaceholder(normalized(relationship)) {
            return false
        }

        if let helpfulContext, isGenericFieldPlaceholder(normalized(helpfulContext)) {
            return false
        }

        return true
    }

    private func isValidInteractionDecision(_ decision: TranscriptAnalysisDecision, transcript: String) -> Bool {
        guard let summary = cleanedDecisionField(decision.interactionSummary) else { return false }
        guard let evidenceQuote = cleanedDecisionField(decision.evidenceQuote) else { return false }
        guard !isGenericFieldPlaceholder(normalized(summary)) else { return false }
        guard !isGenericFieldPlaceholder(normalized(evidenceQuote)) else { return false }
        guard transcript.localizedCaseInsensitiveContains(evidenceQuote) else { return false }

        if let emotionalContext = cleanedDecisionField(decision.emotionalContext),
           isGenericFieldPlaceholder(normalized(emotionalContext)) {
            return false
        }

        if let followUpContext = cleanedDecisionField(decision.followUpContext),
           isGenericFieldPlaceholder(normalized(followUpContext)) {
            return false
        }

        return true
    }

    private func cleanedDecisionField(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    private func isGenericNamePlaceholder(_ value: String) -> Bool {
        [
            "person",
            "name",
            "relationship",
            "context",
            "speaker",
            "speaker a",
            "conversation",
            "transcript",
            "someone",
            "somebody",
            "unknown",
            "friend"
        ].contains(value)
    }

    private func isGenericFieldPlaceholder(_ value: String) -> Bool {
        [
            "person",
            "name",
            "relationship",
            "context",
            "speaker",
            "speaker a",
            "speaker label",
            "conversation",
            "transcript",
            "someone",
            "somebody",
            "unknown"
        ].contains(value)
    }
}

private struct LocalEpisodicMemoryCandidate {
    var memoryType: String
    var summary: String
    var evidenceQuote: String
    var emotionalContext: String?
    var followUpContext: String?
    var retentionHint: String?
}

private struct LocalPersonProfileCandidate {
    var name: String
    var relationship: String
    var helpfulContext: String
    var summary: String
    var evidenceQuote: String
}

private struct LocalEpisodicMemoryExtractor {
    func extractPersonProfile(from transcript: String) -> LocalPersonProfileCandidate? {
        let cleaned = cleanedTranscript(from: transcript)
        let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= 3 else { return nil }
        guard !containsBlockedLanguage(cleaned) else { return nil }
        guard !isMostlyNoise(cleaned) else { return nil }
        guard isCompleteEnough(cleaned) else { return nil }
        guard !endsWithIncompleteThought(cleaned) else { return nil }

        guard let name = extractName(from: cleaned) else { return nil }
        let remaining = textAfterName(name, in: cleaned)
        let relationship = extractRelationship(from: cleaned, name: name)
        let helpfulContext = extractHelpfulContext(from: remaining)
        guard relationship != nil || helpfulContext != nil else { return nil }

        let normalizedRelationship = relationship ?? "person I met"
        let normalizedHelpfulContext = helpfulContext ?? "was introduced during the conversation"
        let summary = "\(name) was introduced. \(sentenceCased(normalizedHelpfulContext))."

        return LocalPersonProfileCandidate(
            name: name,
            relationship: normalizedRelationship,
            helpfulContext: normalizedHelpfulContext,
            summary: summary,
            evidenceQuote: cleaned
        )
    }

    func extract(from transcript: String) -> LocalEpisodicMemoryCandidate? {
        let cleaned = cleanedTranscript(from: transcript)
        let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= 3 else { return nil }
        guard !containsBlockedLanguage(cleaned) else { return nil }
        guard !isMostlyNoise(cleaned) else { return nil }
        guard isCompleteEnough(cleaned) else { return nil }
        guard !endsWithIncompleteThought(cleaned) else { return nil }

        let lowercased = cleaned.lowercased()
        guard !isLowValueChatter(lowercased) else { return nil }

        if containsAny(lowercased, terms: emotionalTerms) {
            return LocalEpisodicMemoryCandidate(
                memoryType: "emotionalContext",
                summary: "This person shared something emotionally important: \(cleaned).",
                evidenceQuote: cleaned,
                emotionalContext: "sensitive",
                followUpContext: "Bring it up gently if it seems helpful.",
                retentionHint: "recent"
            )
        }

        if containsAny(lowercased, terms: planTerms), !isQuestionOnly(lowercased) {
            return LocalEpisodicMemoryCandidate(
                memoryType: "planOrIntention",
                summary: "This person mentioned a plan: \(cleaned).",
                evidenceQuote: cleaned,
                emotionalContext: nil,
                followUpContext: nil,
                retentionHint: "shortTerm"
            )
        }

        if containsAny(lowercased, terms: preferenceTerms) {
            return LocalEpisodicMemoryCandidate(
                memoryType: "preference",
                summary: "This person mentioned a preference: \(cleaned).",
                evidenceQuote: cleaned,
                emotionalContext: nil,
                followUpContext: nil,
                retentionHint: "longTerm"
            )
        }

        if containsAny(lowercased, terms: relationshipTerms) || containsAny(lowercased, terms: descriptiveTerms) {
            guard !isInsultOnly(lowercased) else { return nil }
            return LocalEpisodicMemoryCandidate(
                memoryType: "lastInteraction",
                summary: "Last interaction note: \(cleaned).",
                evidenceQuote: cleaned,
                emotionalContext: nil,
                followUpContext: nil,
                retentionHint: "recent"
            )
        }

        return nil
    }

    func shouldSendToLLM(_ transcript: String) -> Bool {
        let cleaned = cleanedTranscript(from: transcript)
        guard cleaned.split(whereSeparator: \.isWhitespace).count >= 4 else { return false }
        guard !containsBlockedLanguage(cleaned) else { return false }
        return true
    }

    private func cleanedTranscript(from transcript: String) -> String {
        let withoutTimecode = transcript.replacingOccurrences(
            of: #"^\[\d{2}:\d{2}\]\s*Speaker\s+[A-Z]:\s*"#,
            with: "",
            options: .regularExpression
        )

        return withoutTimecode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private func extractName(from text: String) -> String? {
        let patterns = [
            #"(?i)\bthis\s+is\s+(?:my\s+|our\s+)?(?:friend\s+|neighbor\s+|neighbour\s+|brother\s+|sister\s+|mom\s+|dad\s+|mother\s+|father\s+|cousin\s+|uncle\s+|aunt\s+)?([A-Z][A-Za-z'-]{1,24})\b"#,
            #"(?i)\b(?:i\s+am|i'm|my\s+name\s+is)\s+([A-Z][A-Za-z'-]{1,24})\b"#,
            #"(?i)\bmeet\s+([A-Z][A-Za-z'-]{1,24})\b"#,
            #"(?i)^([A-Z][A-Za-z'-]{1,24}),\s+(?:he|she|they)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else { continue }
            guard let matchRange = Range(match.range(at: 1), in: text) else { continue }

            let name = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlausibleName(name) {
                return name
            }
        }

        return nil
    }

    private func textAfterName(_ name: String, in text: String) -> String {
        guard let range = text.range(of: name, options: [.caseInsensitive]) else { return text }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractRelationship(from text: String, name: String) -> String? {
        let lowercased = text.lowercased()
        let namedFriendPattern = "\(name.lowercased()),"
        let isNamedSubject = lowercased.hasPrefix(namedFriendPattern)

        if lowercased.contains("friend from back home") || lowercased.contains("friend from home") {
            return "friend from back home"
        }

        if lowercased.contains("friend from work") {
            return "friend from work"
        }

        if lowercased.contains("friend from school") {
            return "friend from school"
        }

        if lowercased.contains("neighbor from next door") || lowercased.contains("neighbour from next door") {
            return "neighbor from next door"
        }

        for term in relationshipTerms where lowercased.contains(term) {
            if term == "mom" { return "mother" }
            if term == "dad" { return "father" }
            return isNamedSubject && term == "friend" ? "friend" : term
        }

        return nil
    }

    private func extractHelpfulContext(from text: String) -> String? {
        let pronounPrefixes = [
            "he is ", "he's ", "she is ", "she's ", "they are ", "they're ",
            "he knows ", "she knows ", "they know ", "knows ", "who "
        ]

        if let range = text.range(of: "knows how to ", options: [.caseInsensitive]) {
            let activity = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !activity.isEmpty else { return nil }
            return "knows how to \(activity)"
        }

        if let abilityContext = extractAbilityContext(from: text) {
            return abilityContext
        }

        if let range = text.range(of: "helps ", options: [.caseInsensitive]) {
            let helpful = String(text[range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return helpful.isEmpty ? nil : helpful
        }

        let sentences = text
            .components(separatedBy: CharacterSet(charactersIn: ".?!"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            let lowerSentence = sentence.lowercased()
            guard containsAny(lowerSentence, terms: descriptiveTerms) else { continue }

            for prefix in pronounPrefixes where lowerSentence.hasPrefix(prefix) {
                let context = String(sentence.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                if !context.isEmpty {
                    return context
                }
            }

            return sentence
        }

        return nil
    }

    private func containsBlockedLanguage(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return blockedTerms.contains { lowercased.contains($0) }
    }

    private func isCompleteEnough(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
            return true
        }

        let lowercased = trimmed.lowercased()
        if containsCompleteSkillStatement(lowercased) || containsCompleteAbilityStatement(lowercased) {
            return true
        }

        return completionHints.contains { lowercased.contains($0) }
    }

    private func endsWithIncompleteThought(_ text: String) -> Bool {
        let trimmed = text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        return incompleteEndings.contains { trimmed.hasSuffix($0) }
    }

    private func isLowValueChatter(_ text: String) -> Bool {
        let collapsed = text
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if lowValueExactPhrases.contains(collapsed) {
            return true
        }

        return lowValuePrefixes.contains { collapsed.hasPrefix($0) }
    }

    private func isQuestionOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        return !containsAny(trimmed, terms: statementTerms)
    }

    private func isInsultOnly(_ text: String) -> Bool {
        insultTerms.contains { text.contains($0) }
    }

    private func isMostlyNoise(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        if noiseTerms.contains(where: { lowercased.contains($0) }) {
            return true
        }

        let letters = lowercased.filter(\.isLetter).count
        return letters < 6
    }

    private func isPlausibleName(_ value: String) -> Bool {
        let normalized = value.lowercased()
        guard value.first?.isUppercase == true else { return false }
        guard !nameStopWords.contains(normalized) else { return false }
        return value.count >= 2
    }

    private func extractAbilityContext(from text: String) -> String? {
        let patterns = [
            #"(?i)\b(?:he|she|they)\s+(can|cannot|can't)\s+([A-Za-z][A-Za-z\s'-]{2,80})$"#,
            #"(?i)^\s*(can|cannot|can't)\s+([A-Za-z][A-Za-z\s'-]{2,80})$"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 2 else { continue }
            guard
                let modalRange = Range(match.range(at: 1), in: text),
                let activityRange = Range(match.range(at: 2), in: text)
            else {
                continue
            }

            let modal = String(text[modalRange]).lowercased()
            let activity = String(text[activityRange])
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !activity.isEmpty else { return nil }
            return "\(modal) \(activity)"
        }

        return nil
    }

    private func containsCompleteSkillStatement(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:he|she|they)?\s*knows?\s+how\s+to\s+[a-z][a-z'-]{2,}"#,
            options: .regularExpression
        ) != nil
    }

    private func containsCompleteAbilityStatement(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:he|she|they)\s+(?:can|cannot|can't)\s+[a-z][a-z'-]{2,}"#,
            options: .regularExpression
        ) != nil
    }

    private func sentenceCased(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private let relationshipTerms = [
        "friend", "neighbor", "neighbour", "family", "brother", "sister", "mother", "father",
        "mom", "dad", "son", "daughter", "grandson", "granddaughter", "cousin", "uncle",
        "aunt", "caregiver", "doctor", "nurse", "therapist", "teacher", "roommate"
    ]

    private let emotionalTerms = [
        "funeral", "died", "passed away", "death", "hospital", "surgery", "sick",
        "cancer", "grief", "grieving", "sad", "scared", "worried", "lonely",
        "birthday", "wedding", "anniversary", "graduated", "got back"
    ]

    private let planTerms = [
        "going to", "heading to", "on my way", "i will", "i'll", "we will", "we'll",
        "later", "tomorrow", "tonight", "store", "pharmacy", "appointment", "visit",
        "pick up", "drop off", "bring", "coming back"
    ]

    private let preferenceTerms = [
        "i like", "i love", "i prefer", "favorite", "favourite", "always drink",
        "always eat", "don't like", "do not like"
    ]

    private let descriptiveTerms = [
        "smart", "kind", "helpful", "funny", "nice", "important", "from home",
        "from work", "from church", "from school", "knows how to", "code",
        "coding", "developer", "engineer", "program", "programming", "can ",
        "cannot ", "can't "
    ]

    private let blockedTerms = [
        "fuck", "bitch", "shit", "asshole", "nigga", "nigger", "cunt"
    ]

    private let noiseTerms = [
        "hdmi", "volume", "remote", "settings", "debug session"
    ]

    private let completionHints = [
        "back home", "from home", "from work", "from church", "from school",
        "passed away", "got back", "funeral", "hospital", "appointment",
        "dinner", "store", "pharmacy", "tomorrow", "tonight", "knows how to code",
        "knows how to program"
    ]

    private let lowValueExactPhrases = [
        "hello", "hello hello", "hello hello hi", "hi", "hey",
        "how are you", "how are you doing", "hey how are you doing",
        "are you still saving", "are you still saving me",
        "whats going on", "what is going on"
    ]

    private let lowValuePrefixes = [
        "hey how are you", "how are you doing", "what's what's",
        "whats whats", "are you still saving"
    ]

    private let statementTerms = [
        "i am", "i'm", "he is", "he's", "she is", "she's", "they are",
        "they're", "this is", "my", "our", "going to", "heading to"
    ]

    private let insultTerms = [
        "idiot", "stupid", "dumb"
    ]

    private let incompleteEndings = [
        "this is", "he knows", "she knows", "they know", "knows how", "knows how to",
        "he can", "she can", "they can", "he cannot", "she cannot", "they cannot",
        "he can't", "she can't", "they can't", "he is", "she is", "they are",
        "he's", "she's", "they're", "he's a", "she's a", "they're a", "he's an",
        "she's an", "they're an", "from", "to", "the", "a", "an", "our",
        "my friend from"
    ]

    private let nameStopWords = [
        "this", "that", "there", "here", "friend", "neighbor", "neighbour",
        "home", "work", "school", "speaker"
    ]
}
