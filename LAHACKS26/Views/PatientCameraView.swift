//
//  PatientCameraView.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import SwiftUI

struct PatientCameraView: View {
    @ObservedObject var memoryBridge: MockMemoryBridge
    @StateObject private var viewModel = PatientCameraViewModel()
    @StateObject private var speechService = AppleSpeechTranscriptionService()
    @StateObject private var memoryCoordinator: MemoryCoordinator
    @StateObject private var textToSpeechService = TextToSpeechService()
    @State private var saveBanner: SaveBanner?
    @State private var faceGateTask: Task<Void, Never>?
    @State private var stopTranscriptionTask: Task<Void, Never>?
    @State private var transcriptionActive = false

    init(memoryBridge: MockMemoryBridge) {
        self.memoryBridge = memoryBridge
        _memoryCoordinator = StateObject(wrappedValue: MemoryCoordinator(memoryBridge: memoryBridge))
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea(.all)

            CameraPreviewView(previewLayer: viewModel.cameraManager.previewLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all)

            if viewModel.detectionResult.hasFace {
                FaceBoundingBoxOverlay(
                    detection: viewModel.detectionResult
                )
                    .animation(.smooth(duration: 0.16), value: viewModel.detectionResult.boundingBox)
                    .ignoresSafeArea(.all)
                    .allowsHitTesting(false)
            }

            if let cameraMessage = viewModel.cameraMessage {
                CameraMessageView(message: cameraMessage)
                    .padding(.horizontal, 22)
            }

            VStack(alignment: .trailing, spacing: 10) {
                if let saveBanner {
                    SaveBannerView(banner: saveBanner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 16)
            .padding(.trailing, 14)
            .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea(.all))
        .task {
            await viewModel.start()
            await speechService.requestPermissions()
        }
        .onChange(of: viewModel.detectionResult.hasFace) { _, hasFace in
            handleFaceBoundStateChanged(hasFace: hasFace)
        }
        .onChange(of: speechService.transcript) { _, transcript in
            memoryCoordinator.submitTranscript(transcript)
        }
        .onChange(of: memoryCoordinator.latestEvent) { _, event in
            guard let event else { return }
            showSavedBanner(for: event)
            if let response = event.patientSafeResponse {
                textToSpeechService.speak(response)
            }
        }
        .onDisappear {
            faceGateTask?.cancel()
            stopTranscriptionTask?.cancel()
            stopFaceBoundTranscription()
            textToSpeechService.stop()
            viewModel.stop()
        }
    }

    private func handleFaceBoundStateChanged(hasFace: Bool) {
        if hasFace {
            faceGateTask?.cancel()
            guard !transcriptionActive else { return }

            faceGateTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, viewModel.detectionResult.hasFace else { return }

                startFaceBoundTranscription()
            }
        } else {
            faceGateTask?.cancel()
            guard transcriptionActive else { return }

            faceGateTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, !viewModel.detectionResult.hasFace else { return }

                stopFaceBoundTranscription()
            }
        }
    }

    private func startFaceBoundTranscription() {
        guard !transcriptionActive else { return }

        stopTranscriptionTask?.cancel()
        transcriptionActive = true
        speechService.resetTranscript()
        memoryCoordinator.beginFaceBoundConversation()
        speechService.startRecording()
    }

    private func stopFaceBoundTranscription() {
        guard transcriptionActive else { return }

        transcriptionActive = false
        speechService.stopRecording()
        memoryCoordinator.flushCurrentTranscript()

        stopTranscriptionTask?.cancel()
        stopTranscriptionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, !transcriptionActive else { return }

            memoryCoordinator.flushCurrentTranscript()
            memoryCoordinator.endFaceBoundConversation()
        }
    }

    private func showSavedBanner(for event: MemoryCoordinatorEvent) {
        let banner = SaveBanner(id: event.id, title: event.title, subtitle: event.subtitle)

        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            saveBanner = banner
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard saveBanner?.id == banner.id else { return }

            withAnimation(.easeOut(duration: 0.22)) {
                saveBanner = nil
            }
            memoryCoordinator.clearLatestEvent()
        }
    }
}

private struct CameraMessageView: View {
    let message: String

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "camera.viewfinder")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)

            Text(message)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 16)
        .padding(.vertical, 13)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
    }
}

private struct SaveBanner: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String?
}

private struct SaveBannerView: View {
    let banner: SaveBanner

    var body: some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.callout.weight(.bold))
                if let subtitle = banner.subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .opacity(0.85)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(.green.opacity(0.48)), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.28), lineWidth: 1)
                    }
            } else {
                content
                    .background(.green.opacity(0.9), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
    }
}

private struct FaceBoundingBoxOverlay: View {
    let detection: FaceDetectionResult

    var body: some View {
        GeometryReader { geometry in
            let visibleBounds = CGRect(origin: .zero, size: geometry.size)
            let rect = detection.boundingBox
                .aspectFillRect(sourceSize: detection.sourceImageSize, destinationSize: geometry.size)
                .intersection(visibleBounds)
            let insetAmount = max(4, min(rect.width, rect.height) * 0.05)
            let fittedRect = rect.insetBy(dx: insetAmount, dy: insetAmount)

            if !fittedRect.isNull && fittedRect.width > 0 && fittedRect.height > 0 {
                LiquidTrackingBox()
                    .frame(width: fittedRect.width, height: fittedRect.height)
                    .position(x: fittedRect.midX, y: fittedRect.midY)
            }
        }
    }
}

private struct LiquidTrackingBox: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        ZStack(alignment: .topLeading) {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.72),
                            .white.opacity(0.14),
                            .white.opacity(0.32)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            shape
                .strokeBorder(.white.opacity(0.12), lineWidth: 2)

            CornerBracketOverlay()
                .padding(8)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        .shadow(color: .white.opacity(0.08), radius: 12)
    }
}

private struct CornerBracketOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let edgeLength = min(34, min(geometry.size.width, geometry.size.height) * 0.24)

            ZStack {
                cornerPair(edgeLength: edgeLength)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                cornerPair(edgeLength: edgeLength)
                    .rotationEffect(.degrees(90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                cornerPair(edgeLength: edgeLength)
                    .rotationEffect(.degrees(-90))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                cornerPair(edgeLength: edgeLength)
                    .rotationEffect(.degrees(180))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    @ViewBuilder
    private func cornerPair(edgeLength: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(.white.opacity(0.94))
                .frame(width: edgeLength, height: 4)
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(.white.opacity(0.94))
                .frame(width: 4, height: edgeLength)
        }
        .shadow(color: .white.opacity(0.18), radius: 10)
    }
}

private extension CGRect {
    func aspectFillRect(sourceSize: CGSize?, destinationSize: CGSize) -> CGRect {
        guard
            let sourceSize,
            sourceSize.width > 0,
            sourceSize.height > 0,
            destinationSize.width > 0,
            destinationSize.height > 0
        else {
            return CGRect(
                x: minX * destinationSize.width,
                y: minY * destinationSize.height,
                width: width * destinationSize.width,
                height: height * destinationSize.height
            )
        }

        let scale = max(
            destinationSize.width / sourceSize.width,
            destinationSize.height / sourceSize.height
        )
        let displayedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let origin = CGPoint(
            x: (destinationSize.width - displayedSize.width) / 2,
            y: (destinationSize.height - displayedSize.height) / 2
        )

        return CGRect(
            x: origin.x + minX * displayedSize.width,
            y: origin.y + minY * displayedSize.height,
            width: width * displayedSize.width,
            height: height * displayedSize.height
        )
    }
}
