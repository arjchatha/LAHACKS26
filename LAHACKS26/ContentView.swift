//
//  ContentView.swift
//  LAHACKS26
//
//  Created by Rikhil Rao on 4/24/26.
//

import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ContentView: View {
    @State private var cameraService = CameraService()

    var body: some View {
        CameraPreview(session: cameraService.session)
            .ignoresSafeArea()
            .task {
                await cameraService.configure()
            }
    }
}

@MainActor
private final class CameraService {
    let session = AVCaptureSession()

    func configure() async {
        guard hasAvailableCamera else {
            return
        }

        let isAuthorized: Bool

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }

        guard isAuthorized else {
            return
        }

        configureSessionIfNeeded()

        if !session.isRunning {
            session.startRunning()
        }
    }

    private func configureSessionIfNeeded() {
        guard session.inputs.isEmpty, let camera = preferredCamera else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            return
        }

        session.addInput(input)
    }

    private var preferredCamera: AVCaptureDevice? {
        let cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices

        return cameras.first(where: { $0.position == .front }) ?? cameras.first
    }

    private var hasAvailableCamera: Bool {
        preferredCamera != nil
    }
}

private struct CameraPreview: PlatformViewRepresentable {
    let session: AVCaptureSession

    func makePlatformView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = session
        return view
    }

    func updatePlatformView(_ platformView: PreviewView, context: Context) {
        platformView.previewLayer.session = session
    }
}

#if canImport(UIKit)
private typealias PlatformViewRepresentable = UIViewRepresentable
private typealias PlatformView = UIView

private final class PreviewView: PlatformView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private extension CameraPreview {
    func makeUIView(context: Context) -> PreviewView {
        makePlatformView(context: context)
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        updatePlatformView(uiView, context: context)
    }
}
#elseif canImport(AppKit)
private typealias PlatformViewRepresentable = NSViewRepresentable
private typealias PlatformView = NSView

private final class PreviewView: PlatformView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVCaptureVideoPreviewLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

private extension CameraPreview {
    func makeNSView(context: Context) -> PreviewView {
        makePlatformView(context: context)
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        updatePlatformView(nsView, context: context)
    }
}
#endif

#Preview {
    ContentView()
}
