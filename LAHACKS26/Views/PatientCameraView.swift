//
//  PatientCameraView.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import SwiftUI
import UIKit

struct PatientCameraView: View {
    @ObservedObject var memoryBridge: MockMemoryBridge
    @StateObject private var viewModel: PatientCameraViewModel
    @StateObject private var speechService = AppleSpeechTranscriptionService()
    @StateObject private var memoryCoordinator: MemoryCoordinator
    @StateObject private var textToSpeechService = TextToSpeechService()
    @State private var saveBanner: SaveBanner?
    @State private var saveBannerExpanded = false
    @State private var saveBannerContentVisible = false
    @State private var saveBannerTask: Task<Void, Never>?
    @State private var faceGateTask: Task<Void, Never>?
    @State private var stopTranscriptionTask: Task<Void, Never>?
    @State private var transcriptionActive = false
    @State private var activeTranscriptionFaceProfileId: String?

    init(memoryBridge: MockMemoryBridge) {
        self.memoryBridge = memoryBridge
        _viewModel = StateObject(wrappedValue: PatientCameraViewModel(memoryBridge: memoryBridge))
        _memoryCoordinator = StateObject(wrappedValue: MemoryCoordinator(memoryBridge: memoryBridge))
    }

    var body: some View {
        let profileDisplay = viewModel.detectionResult.faceProfileId.map {
            memoryBridge.profileDisplay(for: $0)
        } ?? .unknown("Unknown face")
        let cameraLabelTitle = viewModel.activeEnrollmentName ?? profileDisplay.cameraLabelTitle
        let cameraLabelDescription = viewModel.activeEnrollmentName == nil
            ? profileDisplay.cameraLabelDescription
            : "Learning this face"

        GeometryReader { geometry in
            let islandTopOffset = dynamicIslandTopOffset(in: geometry)
            let islandExpandedWidth = min(geometry.size.width - 36, 356)

            ZStack {
                Color.black
                    .ignoresSafeArea(.all)

                CameraPreviewView(previewLayer: viewModel.cameraManager.previewLayer)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .ignoresSafeArea(.all)

                if viewModel.detectionResult.hasFace {
                    FaceBoundingBoxOverlay(
                        detection: viewModel.detectionResult,
                        title: cameraLabelTitle,
                        description: cameraLabelDescription
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .animation(.smooth(duration: 0.16), value: viewModel.detectionResult.boundingBox)
                        .ignoresSafeArea(.all)
                        .allowsHitTesting(false)
                }

                if let cameraMessage = viewModel.cameraMessage {
                    CameraMessageView(message: cameraMessage)
                        .padding(.horizontal, 22)
                }

                if let activeEnrollmentName = viewModel.activeEnrollmentName {
                    VStack {
                        Spacer()
                        EnrollmentStatusPill(
                            name: activeEnrollmentName,
                            progress: viewModel.activeEnrollmentProgress,
                            target: viewModel.activeEnrollmentTarget
                        )
                        .padding(.bottom, 92)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    if let saveBanner {
                        SaveBannerView(
                            banner: saveBanner,
                            isExpanded: saveBannerExpanded,
                            isContentVisible: saveBannerContentVisible,
                            expandedWidth: islandExpandedWidth
                        )
                            .transition(.identity)
                    }

                    Spacer()
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .padding(.top, islandTopOffset + 15)
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.all)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea(.all))
        .task {
            await viewModel.start()
            await speechService.requestPermissions()
        }
        .onChange(of: viewModel.detectionResult.hasFace) { _, _ in
            handleFaceBoundStateChanged()
        }
        .onChange(of: viewModel.detectionResult.faceProfileId) { _, faceProfileId in
            handleFaceProfileChanged(to: faceProfileId)
        }
        .onChange(of: speechService.transcript) { _, transcript in
            viewModel.handleTranscriptUpdate(transcript)
            if activeTranscriptionFaceProfileId != nil {
                memoryCoordinator.submitTranscript(transcript)
            }
        }
        .onChange(of: memoryCoordinator.latestEvent) { _, event in
            guard let event else { return }
            showSavedBanner(for: event)
            if let response = event.patientSafeResponse {
                textToSpeechService.speak(response)
            }
        }
        .onDisappear {
            saveBannerTask?.cancel()
            faceGateTask?.cancel()
            stopTranscriptionTask?.cancel()
            stopFaceBoundTranscription()
            textToSpeechService.stop()
            viewModel.stop()
        }
    }

    private func handleFaceBoundStateChanged() {
        let hasFace = viewModel.detectionResult.hasFace

        if hasFace {
            faceGateTask?.cancel()
            guard !transcriptionActive else { return }

            faceGateTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard
                    !Task.isCancelled,
                    viewModel.detectionResult.hasFace
                else {
                    return
                }

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

    private func handleFaceProfileChanged(to faceProfileId: String?) {
        memoryCoordinator.updateActiveFaceProfileId(faceProfileId)

        guard transcriptionActive else {
            handleFaceBoundStateChanged()
            return
        }

        guard faceProfileId != activeTranscriptionFaceProfileId else {
            return
        }

        if activeTranscriptionFaceProfileId != nil {
            memoryCoordinator.flushCurrentTranscript()
            memoryCoordinator.endFaceBoundConversation()
        }

        activeTranscriptionFaceProfileId = faceProfileId
        guard let faceProfileId else { return }

        memoryCoordinator.updateActiveFaceProfileId(faceProfileId)
        memoryCoordinator.beginFaceBoundConversation()
        let existingTranscript = speechService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingTranscript.isEmpty {
            memoryCoordinator.submitTranscript(existingTranscript)
        }
    }

    private func startFaceBoundTranscription() {
        guard !transcriptionActive else { return }

        stopTranscriptionTask?.cancel()
        transcriptionActive = true
        activeTranscriptionFaceProfileId = viewModel.detectionResult.faceProfileId
        speechService.resetTranscript()
        if let activeTranscriptionFaceProfileId {
            memoryCoordinator.updateActiveFaceProfileId(activeTranscriptionFaceProfileId)
            memoryCoordinator.beginFaceBoundConversation()
        }
        speechService.startRecording()
    }

    private func stopFaceBoundTranscription() {
        guard transcriptionActive else { return }

        let hadActiveFaceProfile = activeTranscriptionFaceProfileId != nil
        transcriptionActive = false
        activeTranscriptionFaceProfileId = nil
        speechService.stopRecording()
        if hadActiveFaceProfile {
            memoryCoordinator.flushCurrentTranscript()
        }

        stopTranscriptionTask?.cancel()
        stopTranscriptionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, !transcriptionActive else { return }

            if hadActiveFaceProfile {
                memoryCoordinator.flushCurrentTranscript()
                memoryCoordinator.endFaceBoundConversation()
            }
        }
    }

    private func showSavedBanner(for event: MemoryCoordinatorEvent) {
        let title: String

        switch event.kind {
        case .saving:
            title = "Saving Memory"
        case .stored, .noted:
            title = "Memory Saved"
        }

        showSaveBanner(SaveBanner(id: event.id, title: title, subtitle: event.subtitle))
        memoryCoordinator.clearLatestEvent()
    }

    private func showSaveBanner(_ banner: SaveBanner) {
        saveBannerTask?.cancel()
        saveBanner = banner
        saveBannerExpanded = false
        saveBannerContentVisible = false

        withAnimation(.smooth(duration: 0.42, extraBounce: 0.10)) {
            saveBannerExpanded = true
        }

        saveBannerTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard saveBanner?.id == banner.id else { return }

            withAnimation(.easeOut(duration: 0.16)) {
                saveBannerContentVisible = true
            }

            try? await Task.sleep(for: .seconds(2.25))
            guard saveBanner?.id == banner.id else { return }

            withAnimation(.easeInOut(duration: 0.14)) {
                saveBannerContentVisible = false
            }

            try? await Task.sleep(for: .milliseconds(150))
            guard saveBanner?.id == banner.id else { return }

            withAnimation(.smooth(duration: 0.36, extraBounce: 0.02)) {
                saveBannerExpanded = false
            }

            try? await Task.sleep(for: .milliseconds(360))
            guard saveBanner?.id == banner.id else { return }

            withAnimation(.easeOut(duration: 0.10)) {
                saveBanner = nil
            }
            saveBannerTask = nil
            memoryCoordinator.clearLatestEvent()
        }
    }

    private func dynamicIslandTopOffset(in geometry: GeometryProxy) -> CGFloat {
        let modelName = UIDevice.current.name.lowercased()
        let hasDynamicIslandNameHint = modelName.contains("iphone 14 pro")
            || modelName.contains("iphone 15")
            || modelName.contains("iphone 16")
            || modelName.contains("iphone 17")
        let likelyDynamicIsland = hasDynamicIslandNameHint || geometry.safeAreaInsets.top >= 54

        if likelyDynamicIsland {
            return max(54, geometry.safeAreaInsets.top + 2)
        }

        return max(12, geometry.safeAreaInsets.top - 18)
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

private struct EnrollmentStatusPill: View {
    let name: String
    let progress: Int
    let target: Int

    private var progressFraction: CGFloat {
        guard target > 0 else { return 0 }
        return min(1, max(0, CGFloat(progress) / CGFloat(target)))
    }

    var body: some View {
        let content = HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.10))

                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 4)

                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.96),
                                Color(red: 0.52, green: 1.0, blue: 0.62),
                                Color(red: 0.22, green: 0.78, blue: 0.36)
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Learning...")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Spacer(minLength: 8)

                    Text("\(progress)/\(max(target, 1))")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.13))
                            .overlay(alignment: .top) {
                                Capsule()
                                    .fill(.white.opacity(0.16))
                                    .frame(height: 2)
                                    .padding(.horizontal, 1)
                            }

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.96),
                                        Color(red: 0.49, green: 0.96, blue: 0.58),
                                        Color(red: 0.20, green: 0.74, blue: 0.34)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(7, geometry.size.width * progressFraction))
                    }
                }
                .frame(height: 7)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: 272)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.15),
                            .white.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.46), .white.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .overlay(alignment: .topLeading) {
                        Capsule()
                            .fill(.white.opacity(0.22))
                            .frame(width: 92, height: 1)
                            .padding(.top, 8)
                            .padding(.leading, 22)
                    }
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    }
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.32), radius: 20, y: 9)
        .shadow(color: .white.opacity(0.08), radius: 10)
        .animation(.smooth(duration: 0.24), value: progressFraction)
    }
}

private struct SaveBanner: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String?
}

private struct SaveBannerView: View {
    let banner: SaveBanner
    let isExpanded: Bool
    let isContentVisible: Bool
    let expandedWidth: CGFloat

    private let compactWidth: CGFloat = 92
    private let compactHeight: CGFloat = 26
    private let expandedHeight: CGFloat = 118

    private var shapeWidth: CGFloat { isExpanded ? expandedWidth : compactWidth }
    private var shapeHeight: CGFloat { isExpanded ? expandedHeight : compactHeight }
    private var shapeRadius: CGFloat { isExpanded ? 46 : 18 }

    private var titleText: String {
        banner.title.localizedCaseInsensitiveCompare("memory saved") == .orderedSame ? "Memory Saved" : banner.title
    }

    private var subtitleText: String {
        if let subtitle = banner.subtitle, !subtitle.isEmpty {
            return subtitle
        }

        return "Saved for later recall"
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: shapeRadius, style: .continuous)
                .fill(.black)
                .frame(width: shapeWidth, height: shapeHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: shapeRadius, style: .continuous)
                        .stroke(.white.opacity(isExpanded ? 0.07 : 0), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.34), radius: 18, y: 8)

            expandedContent
                .opacity(isContentVisible ? 1 : 0)
                .scaleEffect(isContentVisible ? 1 : 0.985, anchor: .center)
                .offset(y: isContentVisible ? 0 : -2)
                .allowsHitTesting(false)
        }
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: isContentVisible)
    }

    private var expandedContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.20, green: 0.78, blue: 0.35))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }

                Image(systemName: "checkmark")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 1) {
                Text(titleText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Text(subtitleText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .frame(width: expandedWidth, height: expandedHeight, alignment: .top)
    }
}

private struct FaceBoundingBoxOverlay: View {
    let detection: FaceDetectionResult
    let title: String
    let description: String

    var body: some View {
        GeometryReader { geometry in
            let visibleBounds = CGRect(origin: .zero, size: geometry.size)
            let rect = detection.boundingBox
                .aspectFillRect(sourceSize: detection.sourceImageSize, destinationSize: geometry.size)
                .intersection(visibleBounds)
            let insetAmount = max(4, min(rect.width, rect.height) * 0.05)
            let fittedRect = rect.insetBy(dx: insetAmount, dy: insetAmount)

            if !fittedRect.isNull && fittedRect.width > 0 && fittedRect.height > 0 {
                ZStack {
                    LiquidTrackingBox()
                        .frame(width: fittedRect.width, height: fittedRect.height)
                        .position(x: fittedRect.midX, y: fittedRect.midY)

                    PersonDescriptionCallout(
                        faceRect: fittedRect,
                        title: title,
                        description: description,
                        containerSize: geometry.size
                    )
                }
            }
        }
    }
}

private struct PersonDescriptionCallout: View {
    let faceRect: CGRect
    let title: String
    let description: String
    let containerSize: CGSize

    private let connectorGap: CGFloat = 18
    private let horizontalInset: CGFloat = 18

    private var calloutWidth: CGFloat {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let longestTextCount = max(cleanedTitle.count, cleanedDescription.count)
        let estimatedTextWidth = CGFloat(longestTextCount) * 7.8 + 38
        let minimumWidth: CGFloat = cleanedDescription.isEmpty ? 98 : 140
        return estimatedTextWidth.clamped(min: minimumWidth, max: 244)
    }

    private var calloutHeight: CGFloat {
        description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 64 : 86
    }

    var body: some View {
        let placement = placementMetrics()

        ZStack {
            ConnectorLine(
                start: placement.connectorStart,
                end: placement.connectorEnd
            )

            PersonDescriptionBubble(
                title: title,
                description: description
            )
                .frame(width: calloutWidth)
                .position(placement.calloutCenter)
        }
    }

    private func placementMetrics() -> CalloutPlacement {
        let placeAbove = faceRect.minY > calloutHeight + connectorGap + 24
        let calloutCenterX = faceRect.midX.clamped(
            min: horizontalInset + (calloutWidth / 2),
            max: containerSize.width - horizontalInset - (calloutWidth / 2)
        )
        let connectorTarget = CGPoint(
            x: faceRect.midX,
            y: placeAbove ? faceRect.minY : faceRect.maxY
        )
        let connectorStartY = placeAbove
            ? connectorTarget.y - connectorGap
            : connectorTarget.y + connectorGap
        let calloutCenterY = placeAbove
            ? connectorStartY - (calloutHeight / 2)
            : connectorStartY + (calloutHeight / 2)
        let connectorStart = CGPoint(
            x: calloutCenterX,
            y: connectorStartY
        )

        return CalloutPlacement(
            calloutCenter: CGPoint(x: calloutCenterX, y: calloutCenterY),
            connectorStart: connectorStart,
            connectorEnd: connectorTarget
        )
    }
}

private struct PersonDescriptionBubble: View {
    let title: String
    let description: String

    var body: some View {
        let cleanedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if !cleanedDescription.isEmpty {
                Text(cleanedDescription)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        Group {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 1)
                    }
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

private struct ConnectorLine: View {
    let start: CGPoint
    let end: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(.black.opacity(0.2), style: StrokeStyle(lineWidth: 5, lineCap: .round))

            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0.92), .white.opacity(0.44)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )

            Circle()
                .fill(.white.opacity(0.96))
                .frame(width: 8, height: 8)
                .position(end)
                .shadow(color: .white.opacity(0.2), radius: 8)
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

private struct CalloutPlacement {
    let calloutCenter: CGPoint
    let connectorStart: CGPoint
    let connectorEnd: CGPoint
}

private extension CGFloat {
    func clamped(min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, minimum), maximum)
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
