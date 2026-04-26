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
    var description: String {
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
            patientSafeResponse: patientSafeResponse
        )
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
actor AppleFoundationModelsDecisionEngine: LLMDecisionEngine {
    private let model = SystemLanguageModel(useCase: .contentTagging)
    private let session: LanguageModelSession

    init() {
        session = LanguageModelSession(
            model: model,
            instructions: """
            You are MindAnchor's local memory coordinator. Decide whether a live speech transcript contains information worth storing in a private memory wiki for a person with early memory loss.

            Be conservative. Most conversation should not be stored. Your output is a semantic analysis signal; a separate local MemoryCapturePolicy will make the final save/no-save decision using your fields plus transcript evidence.

            Store explicit facts that are likely to help the patient later. This includes person identity, recent interactions, recent events, plans or intentions, preferences, important life facts, and emotional context.

            Treat face-bound introductions as important. A name-only introduction such as "I am David" is a weak person candidate: store it as a low-confidence memory that can be enriched later. A name paired with relationship, role, school/work context, neighborhood context, caregiving context, or useful life context should be a stronger person memory.

            Do not store greetings, jokes, acknowledgements, filler, uncertain guesses, or vague impressions. Store temporary information only when it is useful soon, such as plans, errands, travel, or recent events. If uncertain, set shouldStore to false. Keep patient responses short, calm, and safe. Do not make medical claims.
            """
        )
    }

    func analyzeTranscript(_ transcript: String) async -> TranscriptAnalysisDecision {
        guard model.isAvailable else {
            return .ignored(patientSafeResponse: nil)
        }

        do {
            let response = try await session.respond(
                to: prompt(for: transcript),
                schema: Self.decisionSchema,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0,
                    maximumResponseTokens: 130
                )
            )

            return try makeDecision(from: response.content)
        } catch {
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
            This is a fast live layer while the patient is looking at the person.
            Update provisional beliefs, and set shouldStore true as soon as the transcript contains a clear patient-useful memory. Focus on semantic classification and extraction; a separate policy layer will handle final storage.
            Useful memories include introductions, weak name-only person candidates, plans, errands, recent events, deaths or funerals, travel, caregiving context, preferences, emotional context, or what this person last talked about.
            Keep shouldStore false for partial, ambiguous, or merely social speech. Never invent placeholder values such as "person", "relationship", "context", or "name". Every stored memory must include an exact evidenceQuote copied from the transcript.
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
            This is a periodic reconciliation layer over a wider rolling transcript window.
            Correct earlier misunderstandings, merge duplicate entities, revise confidence scores, and remove weak facts. Focus on semantic classification and extraction; a separate policy layer will handle final storage.
            Set shouldStore true for any clear patient-useful memory: identity, last interaction, recent event, plan, preference, important life fact, or emotional context.
            Every stored memory must include an exact evidenceQuote copied from the transcript.
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
            This is the final full-context pass after the face-bound conversation ended.
            Produce the cleanest relationship graph, interaction summary, and semantic storage recommendation. A separate policy layer will handle final storage.
            Set shouldStore true for any clear patient-useful memory: identity, last interaction, recent event, plan, preference, important life fact, or emotional context.
            Every stored memory must include an exact evidenceQuote copied from the transcript.
            """
        )
    }

    private func analyzeConversation(
        phase: String,
        previousState: ConversationState,
        transcript: String,
        instructions: String
    ) async -> ConversationAnalysisResult {
        guard model.isAvailable else {
            return ConversationAnalysisResult(
                conversationState: previousState,
                decision: .ignored(patientSafeResponse: nil)
            )
        }

        do {
            let response = try await session.respond(
                to: conversationPrompt(
                    phase: phase,
                    previousState: previousState,
                    transcript: transcript,
                    instructions: instructions
                ),
                schema: Self.conversationSchema,
                options: GenerationOptions(
                    sampling: .greedy,
                    temperature: 0,
                    maximumResponseTokens: 420
                )
            )
            let stateJSON = try response.content.value(String.self, forProperty: "conversationStateJSON")
            let updatedState = ConversationState.decoded(from: stateJSON) ?? previousState

            return ConversationAnalysisResult(
                conversationState: updatedState,
                decision: try makeDecision(from: response.content)
            )
        } catch {
            return ConversationAnalysisResult(
                conversationState: previousState,
                decision: .ignored(patientSafeResponse: nil)
            )
        }
    }

    private func prompt(for transcript: String) -> String {
        """
        Analyze this transcript and return only the requested structured decision.

        Transcript:
        \(transcript)

        The transcript may combine nearby speech fragments from the same active face profile. Treat them as one face-bound conversation. For example, "I am David" followed by "We go to the same school" should become one saved person memory for David with helpful context "goes to the same school".

        Field requirements:
        - shouldStore: true only when the transcript contains explicit durable memory information worth saving for later patient support.
        - memoryType: one of person, lastInteraction, recentEvent, emotionalContext, planOrIntention, preference, importantLifeFact, routine, none.
        - importance: one of low, medium, high.
        - storageConfidence: number from 0.0 to 1.0 for confidence this should be stored.
        - extractedName: person name when available, otherwise null.
        - extractedRelationship: relationship or social context when available, otherwise null.
        - extractedHelpfulContext: practical helpful context when available, otherwise null.
        - interactionSummary: one short sentence summarizing what the patient should remember, otherwise null.
        - evidenceQuote: exact quote copied from the transcript that supports the memory, otherwise null.
        - emotionalContext: short emotional context such as "grieving", "excited", or "stressed", otherwise null.
        - followUpContext: gentle future reminder or follow-up context, otherwise null.
        - retentionHint: one of shortTerm, recent, longTerm, otherwise null.
        - patientSafeResponse: short spoken response if storing, otherwise null.

        Conservative storage policy:
        - Set shouldStore false unless the transcript contains a complete, useful memory.
        - A named person introduction is a useful weak person candidate in this face-bound capture flow, even if relationship or context is not known yet.
        - A named self-introduction with school, work, role, neighborhood, caregiving, or practical life context is a complete useful memory.
        - A recent event, plan, preference, emotionally important life event, or last-interaction detail can be useful even without a person name.
        - For person memories, extractedName must be non-null. extractedRelationship and extractedHelpfulContext can be null if only the name was captured.
        - For non-person memories, interactionSummary and evidenceQuote must be non-null.
        - Use storageConfidence 0.45 to 0.65 for weak name-only person candidates.
        - Use storageConfidence below 0.8 whenever the transcript is ambiguous, incomplete, or merely social unless it is a clear name-only introduction.
        - Never use placeholders such as "person", "relationship", "context", or "name" as extracted values.
        - Examples of store-worthy memories:
          "This is Akshay, he's my grandson" -> memoryType person.
          "I am David" -> shouldStore true, memoryType person, importance low, extractedName "David", extractedRelationship null, extractedHelpfulContext null, storageConfidence 0.55.
          "I am David. We go to the same school" -> shouldStore true, memoryType person, extractedName "David", extractedHelpfulContext "goes to the same school".
          "Hello, I'm Rishab. I go to school." -> memoryType person, extractedName "Rishab", extractedHelpfulContext "goes to school", storageConfidence at least 0.85.
          "I just got back from my brother's funeral" -> memoryType emotionalContext or recentEvent.
          "I'm heading to the store, do you need anything?" -> memoryType planOrIntention with shortTerm retention.
          "I love black coffee in the morning" -> memoryType preference.
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

        Previous structured conversation state JSON:
        \(previousState.promptJSON)

        New \(phase) transcript input:
        \(transcript)

        This input may include nearby fragments from the same active face profile. Combine them before deciding. If one fragment gives the name and a later fragment gives school, neighborhood, work, caregiver, or helpful context, store/update one person memory.

        Return:
        - conversationStateJSON: valid compact JSON with this shape:
          {
            "people": [
              {
                "speakerLabel": "Speaker A",
                "possibleName": null,
                "role": null,
                "relationship": null,
                "confidence": 0.0
              }
            ],
            "openQuestions": [],
            "importantFacts": [],
            "revisionNotes": []
          }
        - Decision fields using the storage rules below.

        Treat live beliefs as provisional. Use wording and confidence that allow revision. Prefer "may be" relationships in state unless confirmed by later context.

        Storage rules:
        - shouldStore should be true during live, reconciliation, or final when the transcript contains clear patient-useful memory.
        - Person memories require a clear name. A relationship, role, school/work context, neighborhood context, caregiving context, or helpful practical context is useful but not required.
        - Last interaction, recent event, emotional context, plan, preference, important life fact, or routine memories require interactionSummary and exact evidenceQuote.
        - Use storageConfidence 0.45 to 0.65 for weak name-only person candidates.
        - Use storageConfidence below 0.8 for ambiguous, partial, social, or temporary statements unless it is a clear name-only introduction.
        - Never use placeholders such as "person", "relationship", "context", or "name" as extracted values.
        - Examples of outputs that should store:
          "This is Akshay, he's my grandson" -> shouldStore true, memoryType person, extractedName "Akshay", extractedRelationship "grandson", storageConfidence at least 0.85.
          "This is Maya, my neighbor from next door" -> shouldStore true, memoryType person, extractedName "Maya", extractedRelationship "neighbor from next door", storageConfidence at least 0.85.
          "I am David" -> shouldStore true, memoryType person, importance low, extractedName "David", extractedRelationship null, extractedHelpfulContext null, storageConfidence 0.55.
          "I am David. We go to the same school" -> shouldStore true, memoryType person, extractedName "David", extractedHelpfulContext "goes to the same school", storageConfidence at least 0.75.
          "Hello, I'm Rishab. I go to school." -> shouldStore true, memoryType person, extractedName "Rishab", extractedHelpfulContext "goes to school", storageConfidence at least 0.85.
          "I just got back from my brother's funeral" -> shouldStore true, memoryType emotionalContext, interactionSummary "They recently got back from their brother's funeral.", evidenceQuote "I just got back from my brother's funeral".
          "I'm going to the store" -> shouldStore true, memoryType planOrIntention, interactionSummary "They said they were going to the store.", retentionHint shortTerm.
        """
    }

    private func makeDecision(from content: GeneratedContent) throws -> TranscriptAnalysisDecision {
        let shouldStore = try content.value(Bool.self, forProperty: "shouldStore")
        let memoryType = try enumValue(
            MemoryType.self,
            content.value(String.self, forProperty: "memoryType"),
            fallback: .none
        )
        let importance = try enumValue(
            MemoryImportance.self,
            content.value(String.self, forProperty: "importance"),
            fallback: .low
        )
        let confidence = try content.value(Double.self, forProperty: "storageConfidence")

        let extractedName = try cleaned(content.value(String?.self, forProperty: "extractedName"))
        let extractedRelationship = try cleaned(content.value(String?.self, forProperty: "extractedRelationship"))
        let extractedHelpfulContext = try cleaned(content.value(String?.self, forProperty: "extractedHelpfulContext"))
        let interactionSummary = try cleaned(content.value(String?.self, forProperty: "interactionSummary"))
        let evidenceQuote = try cleaned(content.value(String?.self, forProperty: "evidenceQuote"))
        let emotionalContext = try cleaned(content.value(String?.self, forProperty: "emotionalContext"))
        let followUpContext = try cleaned(content.value(String?.self, forProperty: "followUpContext"))
        let retentionHint = try cleaned(content.value(String?.self, forProperty: "retentionHint"))
        let patientSafeResponse = try cleaned(content.value(String?.self, forProperty: "patientSafeResponse"))

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
            patientSafeResponse: patientSafeResponse
        )

        let minimumConfidence = memoryType == .person && extractedName != nil ? 0.45 : 0.75
        guard shouldStore, memoryType != .none, confidence >= minimumConfidence else {
            return rejectedDecision
        }

        if memoryType == .person {
            guard extractedName != nil else {
                return rejectedDecision
            }
        } else {
            guard interactionSummary != nil, evidenceQuote != nil else {
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

    private static let decisionSchema = GenerationSchema(
        type: GeneratedContent.self,
        description: "A structured MindAnchor transcript storage decision.",
        properties: [
            GenerationSchema.Property(name: "shouldStore", description: "Whether the transcript should be stored as memory.", type: Bool.self),
            GenerationSchema.Property(
                name: "memoryType",
                description: "The type of memory represented by the transcript.",
                type: String.self,
                guides: [.anyOf(["person", "lastInteraction", "recentEvent", "emotionalContext", "planOrIntention", "preference", "importantLifeFact", "routine", "none"])]
            ),
            GenerationSchema.Property(
                name: "importance",
                description: "How important the memory is for future support.",
                type: String.self,
                guides: [.anyOf(["low", "medium", "high"])]
            ),
            GenerationSchema.Property(
                name: "storageConfidence",
                description: "Confidence from 0.0 to 1.0 that this transcript should be stored.",
                type: Double.self,
                guides: [.minimum(0), .maximum(1)]
            ),
            GenerationSchema.Property(name: "extractedName", description: "The person's name, if the transcript introduces someone.", type: String?.self),
            GenerationSchema.Property(name: "extractedRelationship", description: "The person's relationship or social context, if present.", type: String?.self),
            GenerationSchema.Property(name: "extractedHelpfulContext", description: "A helpful practical context phrase, if present.", type: String?.self),
            GenerationSchema.Property(name: "interactionSummary", description: "A short patient-useful summary of the memory, or null.", type: String?.self),
            GenerationSchema.Property(name: "evidenceQuote", description: "An exact quote copied from the transcript that supports the memory, or null.", type: String?.self),
            GenerationSchema.Property(name: "emotionalContext", description: "Brief emotional context, or null.", type: String?.self),
            GenerationSchema.Property(name: "followUpContext", description: "Gentle future reminder or follow-up context, or null.", type: String?.self),
            GenerationSchema.Property(name: "retentionHint", description: "shortTerm, recent, longTerm, or null.", type: String?.self),
            GenerationSchema.Property(name: "patientSafeResponse", description: "A short spoken response for the patient, or null.", type: String?.self)
        ]
    )

    private static let conversationSchema = GenerationSchema(
        type: GeneratedContent.self,
        description: "A structured MindAnchor conversation state update and storage decision.",
        properties: [
            GenerationSchema.Property(name: "conversationStateJSON", description: "Valid compact JSON for the updated provisional conversation state.", type: String.self),
            GenerationSchema.Property(name: "shouldStore", description: "Whether this pass should store a patient-facing memory.", type: Bool.self),
            GenerationSchema.Property(
                name: "memoryType",
                description: "The type of memory represented by the transcript.",
                type: String.self,
                guides: [.anyOf(["person", "lastInteraction", "recentEvent", "emotionalContext", "planOrIntention", "preference", "importantLifeFact", "routine", "none"])]
            ),
            GenerationSchema.Property(
                name: "importance",
                description: "How important the memory is for future support.",
                type: String.self,
                guides: [.anyOf(["low", "medium", "high"])]
            ),
            GenerationSchema.Property(
                name: "storageConfidence",
                description: "Confidence from 0.0 to 1.0 that this transcript should be stored.",
                type: Double.self,
                guides: [.minimum(0), .maximum(1)]
            ),
            GenerationSchema.Property(name: "extractedName", description: "The person's name, if the transcript introduces someone.", type: String?.self),
            GenerationSchema.Property(name: "extractedRelationship", description: "The person's relationship or social context, if present.", type: String?.self),
            GenerationSchema.Property(name: "extractedHelpfulContext", description: "A helpful practical context phrase, if present.", type: String?.self),
            GenerationSchema.Property(name: "interactionSummary", description: "A short patient-useful summary of the memory, or null.", type: String?.self),
            GenerationSchema.Property(name: "evidenceQuote", description: "An exact quote copied from the transcript that supports the memory, or null.", type: String?.self),
            GenerationSchema.Property(name: "emotionalContext", description: "Brief emotional context, or null.", type: String?.self),
            GenerationSchema.Property(name: "followUpContext", description: "Gentle future reminder or follow-up context, or null.", type: String?.self),
            GenerationSchema.Property(name: "retentionHint", description: "shortTerm, recent, longTerm, or null.", type: String?.self),
            GenerationSchema.Property(name: "patientSafeResponse", description: "A short spoken response for the patient, or null.", type: String?.self)
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
