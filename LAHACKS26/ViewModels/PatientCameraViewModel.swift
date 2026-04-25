//
//  PatientCameraViewModel.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class PatientCameraViewModel: ObservableObject {
    @Published private(set) var detectionResult: FaceDetectionResult = .none
    @Published private(set) var cameraMessage: String?

    let cameraManager = CameraManager()

    private let faceDetectionService = AppleVisionFaceDetectionService()
    private var isProcessingFrame = false
    private var lastFrameProcessDate = Date.distantPast
    private var faceMissStreak = 0
    private var smoothedBoundingBox: CGRect?
    private let minimumFrameInterval: TimeInterval = 0.05

    init() {
        cameraManager.onFrame = { [weak self] pixelBuffer, isUsingFrontCamera in
            self?.processFrame(pixelBuffer, isUsingFrontCamera: isUsingFrontCamera)
        }
    }

    func start() async {
        await faceDetectionService.prepare()
        await cameraManager.requestPermissionAndStart()

        switch cameraManager.state {
        case .ready:
            cameraMessage = nil
        case .denied:
            cameraMessage = "Camera access is off. You can turn it on in Settings."
        case .unavailable(let message):
            cameraMessage = message
        case .idle, .requestingPermission:
            cameraMessage = "Camera is starting."
        }
    }

    func stop() {
        cameraManager.stop()
    }

    private func processFrame(_ pixelBuffer: CVPixelBuffer, isUsingFrontCamera: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameProcessDate) >= minimumFrameInterval else { return }
        guard !isProcessingFrame else { return }

        lastFrameProcessDate = now
        isProcessingFrame = true

        let sendablePixelBuffer = SendableFramePixelBuffer(value: pixelBuffer)
        Task { [weak self] in
            guard let self else { return }

            let result = await self.faceDetectionService.detectFace(
                in: sendablePixelBuffer.value,
                isUsingFrontCamera: isUsingFrontCamera
            )

            await MainActor.run {
                self.handleDetectionResult(result)
                self.isProcessingFrame = false
            }
        }
    }

    private func handleDetectionResult(_ result: FaceDetectionResult) {
        if result.hasFace {
            faceMissStreak = 0

            let smoothedResult = FaceDetectionResult.detected(
                confidence: result.confidence,
                boundingBox: smoothedRect(toward: result.boundingBox),
                sourceImageSize: result.sourceImageSize
            )

            withAnimation(.smooth(duration: 0.16)) {
                applyDetection(smoothedResult)
            }
            return
        }

        faceMissStreak += 1

        if detectionResult.hasFace {
            guard faceMissStreak >= 8 else { return }
        } else {
            guard faceMissStreak >= 2 else { return }
        }

        smoothedBoundingBox = nil

        withAnimation(.easeOut(duration: 0.2)) {
            applyDetection(.none)
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

    private func applyDetection(_ result: FaceDetectionResult) {
        detectionResult = result
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
}
