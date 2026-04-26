//
//  IntroductionSummaryService.swift
//  LAHACKS26
//
//  Created by Codex on 4/26/26.
//

import Foundation

struct IntroductionSummaryService {
    func summary(name: String, transcriptEvidence: [String]) -> String {
        let candidates = transcriptEvidence
            .map { cleanedSentence($0) }
            .filter { !$0.isEmpty }
        guard let bestEvidence = candidates.max(by: { score($0) < score($1) }) else {
            return "This is \(name)."
        }

        return "This is \(name). They introduced themselves by saying: \"\(bestEvidence)\""
    }

    private func cleanedSentence(_ sentence: String) -> String {
        sentence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func score(_ sentence: String) -> Int {
        let words = sentence.split(separator: " ")
        let usefulWords = words.filter { word in
            !Self.lowSignalWords.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }

        return min(sentence.count, 160) + (usefulWords.count * 8)
    }

    private static let lowSignalWords: Set<String> = [
        "i", "am", "i'm", "im", "my", "name", "is", "this", "the", "a", "an",
        "and", "or", "but", "hi", "hello", "hey"
    ]
}
