//
//  CameraManager.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

@preconcurrency import AVFoundation
import Combine
import CoreGraphics

@MainActor
final class CameraManager: NSObject, ObservableObject {
    enum CameraState: Equatable {
        case idle
        case requestingPermission
        case ready
        case denied
        case unavailable(String)
    }

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isUsingFrontCamera = false

    var onFrame: ((CVPixelBuffer, Bool) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.mindanchor.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.mindanchor.camera.frames", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false

    func requestPermissionAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await start()

        case .notDetermined:
            state = .requestingPermission
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            granted ? await start() : setDenied()

        case .denied, .restricted:
            setDenied()

        @unknown default:
            state = .unavailable("This device does not support camera authorization.")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func setDenied() {
        state = .denied
    }

    private func start() async {
        do {
            try await configureAndStartSession()
            state = .ready
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    private func configureAndStartSession() async throws {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { return }

                do {
                    try self.configureSessionIfNeeded()

                    if !self.session.isRunning {
                        self.session.startRunning()
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configureSessionIfNeeded() throws {
        guard !isConfigured else { return }

        guard let camera = preferredCamera() else {
            throw CameraError.noCamera
        }

        isUsingFrontCamera = false
        configureFrameRate(camera, framesPerSecond: 24)

        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        defer {
            session.commitConfiguration()
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        if let connection = videoOutput.connection(with: .video) {
            configure(connection: connection, mirrored: false)
        }

        if let previewConnection = previewLayer.connection {
            configure(connection: previewConnection, mirrored: false)
        }

        isConfigured = true
    }

    private func preferredCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        ).devices.first
    }

    private func configureFrameRate(_ camera: AVCaptureDevice, framesPerSecond: Int32) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            let frameDuration = CMTime(value: 1, timescale: framesPerSecond)
            camera.activeVideoMinFrameDuration = frameDuration
            camera.activeVideoMaxFrameDuration = frameDuration
        } catch {
            return
        }
    }

    private func configure(connection: AVCaptureConnection, mirrored: Bool) {
        if #available(iOS 17.0, *) {
            let portraitRotationAngle: CGFloat = 90
            if connection.isVideoRotationAngleSupported(portraitRotationAngle) {
                connection.videoRotationAngle = portraitRotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let sendablePixelBuffer = SendablePixelBuffer(value: pixelBuffer)
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.onFrame?(sendablePixelBuffer.value, self.isUsingFrontCamera)
        }
    }
}

private enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera:
            #if targetEnvironment(simulator)
            "The iPhone Simulator is not exposing a camera. Run on a physical iPhone for live camera preview."
            #else
            "The rear camera is not available on this device."
            #endif
        case .cannotAddInput:
            "The app could not connect to the camera."
        case .cannotAddOutput:
            "The app could not stream camera frames."
        }
    }
}

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}
