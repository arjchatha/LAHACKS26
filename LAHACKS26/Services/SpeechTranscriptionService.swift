//
//  SpeechTranscriptionService.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import Foundation

@MainActor
protocol SpeechTranscriptionService: AnyObject {
    var transcript: String { get }
    var isRecording: Bool { get }
    var authorizationStatusDescription: String { get }

    func requestPermissions() async
    func startRecording()
    func stopRecording()
    func resetTranscript()
}
