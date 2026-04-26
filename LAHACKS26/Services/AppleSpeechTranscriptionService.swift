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

        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if speechRecognizer?.supportsOnDeviceRecognition == true {
                request.requiresOnDeviceRecognition = true
            }
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { [weak self] buffer, _ in
                Task { @MainActor in
                    self?.recognitionRequest?.append(buffer)
                }
            }

            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }

                    if let result {
                        self.transcript = result.bestTranscription.formattedString
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
