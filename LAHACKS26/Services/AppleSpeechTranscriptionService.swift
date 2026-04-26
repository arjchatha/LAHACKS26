//
//  AppleSpeechTranscriptionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

@MainActor
final class AppleSpeechTranscriptionService: NSObject, ObservableObject, SpeechTranscriptionService {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var authorizationStatusDescription = "Speech permissions have not been requested yet."

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechAuthorized = false
    private var microphoneAuthorized = false
    private var committedFinalTranscript = ""
    private var lastBestTranscription = ""
    private var retainedIntroPhrase = ""

    func requestPermissions() async {
        let speechStatus = await requestSpeechAuthorization()
        let microphoneGranted = await requestMicrophonePermission()

        speechAuthorized = speechStatus == .authorized
        microphoneAuthorized = microphoneGranted
        authorizationStatusDescription = authorizationDescription(
            speechStatus: speechStatus,
            microphoneGranted: microphoneGranted
        )
    }

    func startRecording() {
        guard speechAuthorized, microphoneAuthorized else {
            authorizationStatusDescription = "Speech and microphone access are needed before recording."
            return
        }

        guard !audioEngine.isRunning else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        committedFinalTranscript = ""
        lastBestTranscription = ""
        retainedIntroPhrase = ""

        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if #available(iOS 16.0, *) {
                request.addsPunctuation = true
            }
            request.contextualStrings = [
                "friend", "neighbor", "family", "caregiver", "doctor", "nurse",
                "funeral", "hospital", "pharmacy", "store", "appointment",
                "birthday", "wedding", "coffee", "mail"
            ]
            if speechRecognizer?.supportsOnDeviceRecognition == true {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 512, format: recordingFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.recognitionRequest?.append(buffer)
                }
            }

	            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let result {
                        self.handleRecognitionResult(result)
                    }

                    if let error {
                        self.authorizationStatusDescription = "Speech recognition stopped: \(error.localizedDescription)"
                        self.stopRecording()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            authorizationStatusDescription = "Recording conversation audio."
        } catch {
            authorizationStatusDescription = "Could not start recording: \(error.localizedDescription)"
            stopRecording()
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            authorizationStatusDescription = "Recording stopped."
        }
    }

    func resetTranscript() {
        transcript = ""
        committedFinalTranscript = ""
        lastBestTranscription = ""
        retainedIntroPhrase = ""
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
        let bestTranscription = result.bestTranscription.formattedString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let introPhrase = extractedIntroPhrase(from: bestTranscription) {
            retainedIntroPhrase = introPhrase
            print("MindAnchor speech retained intro phrase: \(introPhrase)")
        }

        let mergedTranscript = mergedTranscript(
            committedTranscript: committedFinalTranscript,
            partialTranscript: bestTranscription
        )

        logRecognitionUpdate(
            bestTranscription: bestTranscription,
            mergedTranscript: mergedTranscript,
            isFinal: result.isFinal
        )

        transcript = mergedTranscript
        lastBestTranscription = bestTranscription

        if result.isFinal {
            committedFinalTranscript = mergedTranscript
        }
    }

    private func mergedTranscript(committedTranscript: String, partialTranscript: String) -> String {
        let committed = committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        var partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if !retainedIntroPhrase.isEmpty,
           !containsIntroPhraseOrName(in: partial, introPhrase: retainedIntroPhrase) {
            partial = [retainedIntroPhrase, partial]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
        }

        guard !committed.isEmpty else { return partial }
        guard !partial.isEmpty else { return committed }

        if partial.localizedCaseInsensitiveContains(committed) {
            return partial
        }

        if committed.localizedCaseInsensitiveContains(partial) {
            return committed
        }

        let overlap = suffixPrefixOverlap(
            leftWords: words(in: committed),
            rightWords: words(in: partial)
        )
        if overlap > 0 {
            let partialWords = words(in: partial)
            let remainder = partialWords.dropFirst(overlap).joined(separator: " ")
            return [committed, remainder]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return "\(committed) \(partial)"
    }

    private func extractedIntroPhrase(from text: String) -> String? {
        let pattern = #"(?i)\b(?:this\s+is|i\s+am|i'm|my\s+name\s+is)\s+([a-z][a-z'-]{1,24}(?:\s+[a-z][a-z'-]{1,24})?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              let matchRange = Range(match.range(at: 0), in: text)
        else {
            return nil
        }

        var phrase = String(text[matchRange])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !phrase.isEmpty else { return nil }
        phrase = phrase.prefix(1).uppercased() + phrase.dropFirst()
        return phrase
    }

    private func containsIntroPhraseOrName(in text: String, introPhrase: String) -> Bool {
        guard !introPhrase.isEmpty else { return true }
        if text.localizedCaseInsensitiveContains(introPhrase) {
            return true
        }

        let introWords = words(in: introPhrase)
        guard let name = introWords.last, name.count > 1 else { return false }
        return words(in: text).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func suffixPrefixOverlap(leftWords: [String], rightWords: [String]) -> Int {
        guard !leftWords.isEmpty, !rightWords.isEmpty else { return 0 }

        let maxOverlap = min(leftWords.count, rightWords.count)
        for count in stride(from: maxOverlap, through: 1, by: -1) {
            let leftSuffix = leftWords.suffix(count).map { $0.lowercased() }
            let rightPrefix = rightWords.prefix(count).map { $0.lowercased() }
            if Array(leftSuffix) == Array(rightPrefix) {
                return count
            }
        }

        return 0
    }

    private func words(in text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                String(token)
                    .trimmingCharacters(in: .punctuationCharacters)
            }
            .filter { !$0.isEmpty }
    }

    private func logRecognitionUpdate(
        bestTranscription: String,
        mergedTranscript: String,
        isFinal: Bool
    ) {
        let droppedPrefix = droppedPrefix(
            previous: lastBestTranscription,
            current: bestTranscription
        )

        print("MindAnchor speech bestTranscription isFinal=\(isFinal): \(bestTranscription)")
        if !droppedPrefix.isEmpty {
            print("MindAnchor speech recognizer revised/dropped prefix: \(droppedPrefix)")
        }
        print("MindAnchor speech mergedTranscript: \(mergedTranscript)")
    }

    private func droppedPrefix(previous: String, current: String) -> String {
        let previousWords = words(in: previous)
        let currentWords = words(in: current)
        guard previousWords.count > currentWords.count else { return "" }

        let lowerCurrent = currentWords.map { $0.lowercased() }
        var prefix: [String] = []
        for word in previousWords {
            if lowerCurrent.contains(word.lowercased()) {
                break
            }
            prefix.append(word)
        }

        return prefix.joined(separator: " ")
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func authorizationDescription(
        speechStatus: SFSpeechRecognizerAuthorizationStatus,
        microphoneGranted: Bool
    ) -> String {
        guard microphoneGranted else {
            return "Microphone access is off. Turn it on in Settings to capture conversations."
        }

        switch speechStatus {
        case .authorized:
            return "Ready to transcribe conversations."
        case .denied:
            return "Speech recognition access is off. Turn it on in Settings to transcribe."
        case .restricted:
            return "Speech recognition is restricted on this device."
        case .notDetermined:
            return "Speech recognition permission has not been decided yet."
        @unknown default:
            return "Speech recognition is unavailable."
        }
    }
}
