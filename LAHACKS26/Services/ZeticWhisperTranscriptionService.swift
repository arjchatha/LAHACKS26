//
//  ZeticWhisperTranscriptionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Combine
import Foundation

@MainActor
final class ZeticWhisperTranscriptionService: ObservableObject, SpeechTranscriptionService {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var authorizationStatusDescription = "ZETIC Whisper transcription is not wired yet."

    func requestPermissions() async {
        authorizationStatusDescription = "TODO: request microphone permission before running ZETIC Melange Whisper."
    }

    func startRecording() {
        // Future path: local audio -> Whisper feature extractor -> encoder -> decoder -> transcript.
        // Keep this interface identical to AppleSpeechTranscriptionService so the app can swap
        // Apple Speech for ZETIC Melange Whisper without changing the conversation UI.
        authorizationStatusDescription = "TODO: stream microphone audio into ZETIC Melange Whisper."
    }

    func stopRecording() {
        isRecording = false
    }

    func resetTranscript() {
        transcript = ""
    }
}
