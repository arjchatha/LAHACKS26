//
//  LLMDecisionEngine.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum MemoryType: String, Equatable {
    case person
    case lastinteraction
    case recentevent
    case emotionalcontext
    case planorintention
    case preference
    case importantlifefact
    case routine
    case none
}

enum MemoryImportance: String, Equatable {
    case low
    case medium
    case high
}

struct TranscriptAnalysisDecision: Equatable {
    let shouldStore: Bool
    let memoryType: MemoryType
    let importance: MemoryImportance
    let storageConfidence: Double
    let extractedName: String?
    let extractedRelationship: String?
    let extractedHelpfulContext: String?
    let interactionSummary: String?
    let evidenceQuote: String?
    let emotionalContext: String?
    let followUpContext: String?
    let retentionHint: String?
    let patientPrompt: String?
    let patientSafeResponse: String?
}

struct TimestampedTranscriptSegment: Identifiable, Equatable {
    let id = UUID()
    let elapsedTime: TimeInterval
    let speakerLabel: String
    let text: String

    var formattedLine: String {
        "[\(Self.timecode(from: elapsedTime))] \(speakerLabel): \(text)"
    }

    private static func timecode(from elapsedTime: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsedTime.rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

struct ConversationPersonCandidate: Equatable {
    var speakerLabel: String?
    var possibleName: String?
    var role: String?
    var relationship: String?
    var confidence: Double

    nonisolated var jsonObject: [String: Any] {
        [
            "speakerLabel": speakerLabel ?? NSNull(),
            "possibleName": possibleName ?? NSNull(),
            "role": role ?? NSNull(),
            "relationship": relationship ?? NSNull(),
            "confidence": confidence
        ]
    }

    nonisolated init(
        speakerLabel: String?,
        possibleName: String?,
        role: String?,
        relationship: String?,
        confidence: Double
    ) {
        self.speakerLabel = speakerLabel
        self.possibleName = possibleName
        self.role = role
        self.relationship = relationship
        self.confidence = confidence
    }

    nonisolated init?(jsonObject: [String: Any]) {
        let confidence = jsonObject["confidence"] as? Double ?? Double(jsonObject["confidence"] as? Int ?? 0)
        self.init(
            speakerLabel: jsonObject["speakerLabel"] as? String,
            possibleName: jsonObject["possibleName"] as? String,
            role: jsonObject["role"] as? String,
            relationship: jsonObject["relationship"] as? String,
            confidence: confidence
        )
    }
}

struct ConversationState: Equatable {
    var people: [ConversationPersonCandidate]
    var openQuestions: [String]
    var importantFacts: [String]
    var revisionNotes: [String]

    static let empty = ConversationState(
        people: [],
        openQuestions: [],
        importantFacts: [],
        revisionNotes: []
    )

    nonisolated var promptJSON: String {
        let object: [String: Any] = [
            "people": people.map(\.jsonObject),
            "openQuestions": openQuestions,
            "importantFacts": importantFacts,
            "revisionNotes": revisionNotes
        ]

        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return json
    }

    nonisolated static func decoded(from json: String) -> ConversationState? {
        guard let data = json.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let peopleObjects = object["people"] as? [[String: Any]] ?? []
        let people = peopleObjects.compactMap(ConversationPersonCandidate.init(jsonObject:))

        return ConversationState(
            people: people,
            openQuestions: object["openQuestions"] as? [String] ?? [],
            importantFacts: object["importantFacts"] as? [String] ?? [],
            revisionNotes: object["revisionNotes"] as? [String] ?? []
        )
    }
}

struct ConversationAnalysisResult: Equatable {
    let conversationState: ConversationState
    let decision: TranscriptAnalysisDecision
}

extension TranscriptAnalysisDecision: CustomStringConvertible {
    nonisolated var description: String {
        [
            "shouldStore=\(shouldStore)",
            "memoryType=\(memoryType.rawValue)",
            "importance=\(importance.rawValue)",
            "storageConfidence=\(String(format: "%.2f", storageConfidence))",
            "extractedName=\(extractedName ?? "nil")",
            "extractedRelationship=\(extractedRelationship ?? "nil")",
            "extractedHelpfulContext=\(extractedHelpfulContext ?? "nil")",
            "interactionSummary=\(interactionSummary ?? "nil")",
            "evidenceQuote=\(evidenceQuote ?? "nil")",
            "emotionalContext=\(emotionalContext ?? "nil")",
            "followUpContext=\(followUpContext ?? "nil")",
            "retentionHint=\(retentionHint ?? "nil")",
            "patientPrompt=\(patientPrompt ?? "nil")",
            "patientSafeResponse=\(patientSafeResponse ?? "nil")"
        ].joined(separator: ", ")
    }
}

protocol LLMDecisionEngine {
    func analyzeTranscript(_ transcript: String) async -> TranscriptAnalysisDecision
    func updateConversationState(
        previousState: ConversationState,
        recentTranscript: String
    ) async -> ConversationAnalysisResult
    func reconcileConversationState(
        previousState: ConversationState,
        transcriptWindow: String
    ) async -> ConversationAnalysisResult
    func finalizeConversation(
        previousState: ConversationState,
        fullTranscript: String
    ) async -> ConversationAnalysisResult
}

struct UnavailableLLMDecisionEngine: LLMDecisionEngine {
    let reason: String

    func analyzeTranscript(_ transcript: String) async -> TranscriptAnalysisDecision {
        TranscriptAnalysisDecision.ignored(patientSafeResponse: nil)
    }

    func updateConversationState(
        previousState: ConversationState,
        recentTranscript: String
    ) async -> ConversationAnalysisResult {
        ConversationAnalysisResult(
            conversationState: previousState,
            decision: .ignored(patientSafeResponse: nil)
        )
    }

    func reconcileConversationState(
        previousState: ConversationState,
        transcriptWindow: String
    ) async -> ConversationAnalysisResult {
        ConversationAnalysisResult(
            conversationState: previousState,
            decision: .ignored(patientSafeResponse: nil)
        )
    }

    func finalizeConversation(
        previousState: ConversationState,
        fullTranscript: String
    ) async -> ConversationAnalysisResult {
        ConversationAnalysisResult(
            conversationState: previousState,
            decision: .ignored(patientSafeResponse: nil)
        )
    }
}

extension TranscriptAnalysisDecision {
    nonisolated static func ignored(patientSafeResponse: String?) -> TranscriptAnalysisDecision {
        TranscriptAnalysisDecision(
            shouldStore: false,
            memoryType: .none,
            importance: .low,
            storageConfidence: 0,
            extractedName: nil,
            extractedRelationship: nil,
            extractedHelpfulContext: nil,
            interactionSummary: nil,
            evidenceQuote: nil,
            emotionalContext: nil,
            followUpContext: nil,
            retentionHint: nil,
            patientPrompt: nil,
            patientSafeResponse: patientSafeResponse
        )
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
actor AppleFoundationModelsDecisionEngine: LLMDecisionEngine {
    private let model = SystemLanguageModel(useCase: .general)
    private let session: LanguageModelSession
    private var isGenerationInFlight = false

    init() {
        Self.log("initializing Apple Foundation Models decision engine; useCase=general")
        session = LanguageModelSession(
            model: model,
            instructions: """
            You extract one useful memory from a live transcript for an on-device memory aid.
            Copy facts from the transcript. Do not invent facts. If a field is unknown, return null.
            Never return placeholder words such as name, relationship, context, person, memory, sentence, response, or patientPrompt.
            """
        )
        Self.log("session initialized; model.isAvailable=\(model.isAvailable)")
    }

    func analyzeTranscript(_ transcript: String) async -> TranscriptAnalysisDecision {
        Self.log("analyzeTranscript requested; transcriptChars=\(transcript.count); model.isAvailable=\(model.isAvailable)")
        guard model.isAvailable else {
            Self.log("analyzeTranscript skipped because model.isAvailable=false")
            return .ignored(patientSafeResponse: nil)
        }

        await waitForGenerationTurn(label: "analyzeTranscript")
        isGenerationInFlight = true
        defer {
            isGenerationInFlight = false
            Self.log("analyzeTranscript generation turn released")
        }

        let prompt = prompt(for: transcript)
        Self.log("analyzeTranscript sending request; promptChars=\(prompt.count)")
        Self.logPrompt("analyzeTranscript", prompt)
        do {
            let response = try await session.respond(
                to: prompt,
                schema: Self.extractionSchema,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0,
                    maximumResponseTokens: 220
                )
            )

            Self.log("analyzeTranscript response received; parsing structured content")
            let decision = try makeDecision(from: response.content)
            Self.log("analyzeTranscript parsed decision: \(decision)")
            return decision
        } catch {
            Self.log("analyzeTranscript failed: \(Self.errorDescription(error))")
            return .ignored(patientSafeResponse: nil)
        }
    }

    func updateConversationState(
        previousState: ConversationState,
        recentTranscript: String
    ) async -> ConversationAnalysisResult {
        await analyzeConversation(
            phase: "live",
            previousState: previousState,
            transcript: recentTranscript,
            instructions: """
            Extract a memory only if the current live transcript already contains a clear name, relationship, useful context, plan, preference, recent event, or important fact.
            Name-only introductions are valid weak person memories.
            """
        )
    }

    func reconcileConversationState(
        previousState: ConversationState,
        transcriptWindow: String
    ) async -> ConversationAnalysisResult {
        await analyzeConversation(
            phase: "reconciliation",
            previousState: previousState,
            transcript: transcriptWindow,
            instructions: """
            Re-read the wider transcript and extract the single clearest patient-useful memory.
            Prefer a named person memory when a person introduction appears.
            """
        )
    }

    func finalizeConversation(
        previousState: ConversationState,
        fullTranscript: String
    ) async -> ConversationAnalysisResult {
        await analyzeConversation(
            phase: "final",
            previousState: previousState,
            transcript: fullTranscript,
            instructions: """
            This is the final pass after the face-bound conversation ended.
            Extract the single best memory from the whole transcript. Prefer the introduced person's identity and useful context.
            """
        )
    }

    private func analyzeConversation(
        phase: String,
        previousState: ConversationState,
        transcript: String,
        instructions: String
    ) async -> ConversationAnalysisResult {
        Self.log("conversation \(phase) requested; transcriptChars=\(transcript.count); previousState=\(previousState.promptJSON); model.isAvailable=\(model.isAvailable)")
        guard model.isAvailable else {
            Self.log("conversation \(phase) skipped because model.isAvailable=false")
            return ConversationAnalysisResult(
                conversationState: previousState,
                decision: .ignored(patientSafeResponse: nil)
            )
        }

        await waitForGenerationTurn(label: "conversation \(phase)")
        isGenerationInFlight = true
        defer {
            isGenerationInFlight = false
            Self.log("conversation \(phase) generation turn released")
        }

        let prompt = conversationPrompt(
            phase: phase,
            previousState: previousState,
            transcript: transcript,
            instructions: instructions
        )
        Self.log("conversation \(phase) sending request; promptChars=\(prompt.count)")
        Self.logPrompt("conversation \(phase)", prompt)
        do {
            let response = try await session.respond(
                to: prompt,
                schema: Self.extractionSchema,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0,
                    maximumResponseTokens: 220
                )
            )
            Self.log("conversation \(phase) response received; parsing extraction")
            let decision = try makeDecision(from: response.content)
            Self.log("conversation \(phase) parsed decision: \(decision)")

            return ConversationAnalysisResult(
                conversationState: previousState,
                decision: decision
            )
        } catch {
            Self.log("conversation \(phase) failed: \(Self.errorDescription(error))")
            return ConversationAnalysisResult(
                conversationState: previousState,
                decision: .ignored(patientSafeResponse: nil)
            )
        }
    }

    private func prompt(for transcript: String) -> String {
        """
        Extract one memory from this transcript.

        Transcript:
        \(transcript)

        Return action "storePerson" for introductions like "This is Maya", "I am David", or "my name is Rishab".
        Return action "storePerson" when the transcript gives a real person's name plus useful context.
        Return action "storeFact" only for a clear patient-useful fact, event, preference, plan, routine, or emotional context.
        Return action "ignore" for vague, negative, or unsupported comments unless there is a real name or relationship.

        Required behavior:
        - name must be a real name copied from the transcript, otherwise null.
        - relationship must be copied or directly paraphrased from the transcript, otherwise null.
        - context must be a short useful phrase supported by the transcript, otherwise null.
        - evidenceQuote must be an exact quote from the transcript when action is not ignore.
        - patientPrompt should be one short sentence for recognizing the person later, such as "This is Maya." or "This is Akshay, your grandson."
        - Never output placeholder values.
        """
    }

    private func conversationPrompt(
        phase: String,
        previousState: ConversationState,
        transcript: String,
        instructions: String
    ) -> String {
        """
        \(instructions)

        Previous conversation context, if any:
        \(previousState.promptJSON)

        New \(phase) transcript:
        \(transcript)

        Extract exactly one memory using the same rules:
        - action: ignore, storePerson, storeFact, storePlan, storePreference, storeRecentEvent, storeEmotionalContext, or storeRoutine.
        - For storePerson, name must be a real name from the transcript.
        - For non-person actions, summary and evidenceQuote are required.
        - Use null for unknown fields.
        - Never output placeholder values like name, relationship, context, person, memory, sentence, response, or patientPrompt.
        """
    }

    private func makeDecision(from content: GeneratedContent) throws -> TranscriptAnalysisDecision {
        let action = try cleaned(content.value(String.self, forProperty: "action")) ?? "ignore"
        let normalizedAction = normalized(action)
        let confidence = try content.value(Double.self, forProperty: "storageConfidence")

        let extractedName = try cleaned(content.value(String?.self, forProperty: "name"))
        let extractedRelationship = try cleaned(content.value(String?.self, forProperty: "relationship"))
        let extractedHelpfulContext = try cleaned(content.value(String?.self, forProperty: "context"))
        let interactionSummary = try cleaned(content.value(String?.self, forProperty: "summary"))
        let evidenceQuote = try cleaned(content.value(String?.self, forProperty: "evidenceQuote"))
        let patientPrompt = try cleaned(content.value(String?.self, forProperty: "patientPrompt"))

        let memoryType = memoryType(for: normalizedAction)
        let shouldStore = memoryType != .none
        let importance = importance(for: memoryType, confidence: confidence)
        let emotionalContext = memoryType == .emotionalcontext ? (extractedHelpfulContext ?? interactionSummary) : nil
        let followUpContext: String? = nil
        let retentionHint = retentionHint(for: memoryType)
        let patientSafeResponse: String? = nil
        Self.log(
            """
            raw extraction fields: action=\(action), mappedMemoryType=\(memoryType.rawValue), confidence=\(confidence), name=\(extractedName ?? "nil"), relationship=\(extractedRelationship ?? "nil"), context=\(extractedHelpfulContext ?? "nil"), summary=\(interactionSummary ?? "nil"), evidenceQuote=\(evidenceQuote ?? "nil"), patientPrompt=\(patientPrompt ?? "nil")
            """
        )

        let rejectedDecision = TranscriptAnalysisDecision(
            shouldStore: false,
            memoryType: memoryType,
            importance: importance,
            storageConfidence: confidence,
            extractedName: extractedName,
            extractedRelationship: extractedRelationship,
            extractedHelpfulContext: extractedHelpfulContext,
            interactionSummary: interactionSummary,
            evidenceQuote: evidenceQuote,
            emotionalContext: emotionalContext,
            followUpContext: followUpContext,
            retentionHint: retentionHint,
            patientPrompt: patientPrompt,
            patientSafeResponse: patientSafeResponse
        )

        let minimumConfidence = memoryType == .person && extractedName != nil ? 0.45 : 0.75
        guard shouldStore, memoryType != .none, confidence >= minimumConfidence else {
            Self.log("decision rejected by minimum gate; shouldStore=\(shouldStore), memoryType=\(memoryType.rawValue), confidence=\(confidence), minimumConfidence=\(minimumConfidence)")
            return rejectedDecision
        }

        if memoryType == .person {
            guard let extractedName, !isPlaceholderValue(extractedName) else {
                Self.log("decision rejected because person memory has no extractedName")
                return rejectedDecision
            }
        } else {
            guard
                let interactionSummary,
                let evidenceQuote,
                !isPlaceholderValue(interactionSummary),
                !isPlaceholderValue(evidenceQuote)
            else {
                Self.log("decision rejected because non-person memory lacks summary or evidenceQuote")
                return rejectedDecision
            }
        }

        return TranscriptAnalysisDecision(
            shouldStore: true,
            memoryType: memoryType,
            importance: importance,
            storageConfidence: confidence,
            extractedName: extractedName,
            extractedRelationship: extractedRelationship,
            extractedHelpfulContext: extractedHelpfulContext,
            interactionSummary: interactionSummary,
            evidenceQuote: evidenceQuote,
            emotionalContext: emotionalContext,
            followUpContext: followUpContext,
            retentionHint: retentionHint,
            patientPrompt: patientPrompt,
            patientSafeResponse: patientSafeResponse
        )
    }

    private func enumValue<T: RawRepresentable>(
        _ type: T.Type,
        _ rawValue: String,
        fallback: T
    ) -> T where T.RawValue == String {
        T(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? fallback
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func memoryType(for action: String) -> MemoryType {
        switch action {
        case "storeperson":
            return .person
        case "storeplan":
            return .planorintention
        case "storepreference":
            return .preference
        case "storerecentevent":
            return .recentevent
        case "storeemotionalcontext":
            return .emotionalcontext
        case "storeroutine":
            return .routine
        case "storefact":
            return .importantlifefact
        default:
            return .none
        }
    }

    private func importance(for memoryType: MemoryType, confidence: Double) -> MemoryImportance {
        if memoryType == .none || confidence < 0.65 {
            return .low
        }
        if confidence >= 0.85 || memoryType == .emotionalcontext || memoryType == .importantlifefact {
            return .high
        }
        return .medium
    }

    private func retentionHint(for memoryType: MemoryType) -> String? {
        switch memoryType {
        case .planorintention:
            return "shortTerm"
        case .recentevent, .lastinteraction:
            return "recent"
        case .person, .preference, .importantlifefact, .routine, .emotionalcontext:
            return "longTerm"
        case .none:
            return nil
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func isPlaceholderValue(_ value: String) -> Bool {
        [
            "name",
            "relationship",
            "context",
            "person",
            "memory",
            "sentence",
            "response",
            "patientprompt",
            "summary",
            "evidencequote",
            "unknown",
            "none"
        ].contains(normalized(value))
    }

    private func waitForGenerationTurn(label: String) async {
        var waitCount = 0
        while isGenerationInFlight || session.isResponding {
            waitCount += 1
            Self.log("\(label) waiting for previous Foundation Models response; waitCount=\(waitCount), session.isResponding=\(session.isResponding)")
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    nonisolated private static func log(_ message: String) {
        print("MindAnchor local LLM:", message)
    }

    nonisolated private static func logPrompt(_ label: String, _ prompt: String) {
        let maxCharacters = 12_000
        let loggedPrompt = prompt.count > maxCharacters
            ? String(prompt.prefix(maxCharacters)) + "\n[truncated \(prompt.count - maxCharacters) chars]"
            : prompt
        print("MindAnchor local LLM prompt BEGIN [\(label)]\n\(loggedPrompt)\nMindAnchor local LLM prompt END [\(label)]")
    }

    nonisolated private static func errorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), failureReason=\(nsError.localizedFailureReason ?? "nil"), recoverySuggestion=\(nsError.localizedRecoverySuggestion ?? "nil"), userInfo=\(nsError.userInfo)"
    }

    private static let extractionSchema = GenerationSchema(
        type: GeneratedContent.self,
        description: "One simple memory extraction from a transcript.",
        properties: [
            GenerationSchema.Property(
                name: "action",
                description: "What to do with the transcript.",
                type: String.self,
                guides: [.anyOf(["ignore", "storePerson", "storeFact", "storePlan", "storePreference", "storeRecentEvent", "storeEmotionalContext", "storeRoutine"])]
            ),
            GenerationSchema.Property(
                name: "storageConfidence",
                description: "Confidence from 0.0 to 1.0 that this extraction is supported by the transcript.",
                type: Double.self,
                guides: [.minimum(0), .maximum(1)]
            ),
            GenerationSchema.Property(name: "name", description: "A real person's name copied from the transcript, or null.", type: String?.self),
            GenerationSchema.Property(name: "relationship", description: "The person's relationship or social context supported by the transcript, or null.", type: String?.self),
            GenerationSchema.Property(name: "context", description: "A short useful context phrase supported by the transcript, or null.", type: String?.self),
            GenerationSchema.Property(name: "summary", description: "One short patient-useful summary for non-person memories, or null.", type: String?.self),
            GenerationSchema.Property(name: "evidenceQuote", description: "An exact quote copied from the transcript that supports the memory, or null.", type: String?.self),
            GenerationSchema.Property(name: "patientPrompt", description: "For person memories only, one clean recognition sentence supported by the transcript, or null.", type: String?.self)
        ]
    )
}
#endif

enum DefaultLLMDecisionEngineFactory {
    static func make() -> LLMDecisionEngine {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return AppleFoundationModelsDecisionEngine()
        }
        #endif

        return UnavailableLLMDecisionEngine(
            reason: "No local LLM decision engine is available on this OS."
        )
    }
}
