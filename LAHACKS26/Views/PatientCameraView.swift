//
//  PatientCameraView.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import SwiftUI

struct PatientCameraView: View {
    @StateObject private var viewModel: PatientCameraViewModel

    init(memoryBridge: MemoryBridge = MockMemoryBridge()) {
        _viewModel = StateObject(wrappedValue: PatientCameraViewModel(memoryBridge: memoryBridge))
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
                    detection: viewModel.detectionResult,
                    title: viewModel.focusedPersonTitle ?? "Unknown person",
                    description: viewModel.detectedPersonDescription ?? "Unknown person.",
                    detailLines: viewModel.detectedPersonDetailLines,
                    onDescriptionTap: {}
                )
                    .animation(.smooth(duration: 0.16), value: viewModel.detectionResult.boundingBox)
                    .ignoresSafeArea(.all)
            }

            LiveFeedStatusView(
                statusText: viewModel.liveStatusText,
                transcript: viewModel.heardSpeechText,
                isListening: viewModel.isListeningForSpeech,
                activeEnrollmentName: viewModel.activeEnrollmentName,
                activeEnrollmentProgress: viewModel.activeEnrollmentProgress,
                activeEnrollmentTarget: viewModel.activeEnrollmentTarget
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
            .frame(maxHeight: .infinity, alignment: .bottom)

            if let cameraMessage = viewModel.cameraMessage {
                CameraMessageView(message: cameraMessage)
                    .padding(.horizontal, 22)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea(.all))
        .task {
            await viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

private struct LiveFeedStatusView: View {
    let statusText: String
    let transcript: String
    let isListening: Bool
    let activeEnrollmentName: String?
    let activeEnrollmentProgress: Int
    let activeEnrollmentTarget: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: isListening ? "waveform.circle.fill" : "waveform.circle")
                    .symbolRenderingMode(.hierarchical)

                Text(primaryText)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if activeEnrollmentName != nil {
                    Text("\(activeEnrollmentProgress)/\(activeEnrollmentTarget)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.16), in: Capsule())
                }
            }

            if !transcript.isEmpty {
                Text(transcript)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
    }

    private var primaryText: String {
        if let activeEnrollmentName {
            return "Learning \(activeEnrollmentName)"
        }

        return statusText
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

private struct FaceBoundingBoxOverlay: View {
    let detection: FaceDetectionResult
    let title: String
    let description: String
    let detailLines: [String]
    let onDescriptionTap: () -> Void

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
                        detailLines: detailLines,
                        containerSize: geometry.size,
                        onTap: onDescriptionTap
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
    let detailLines: [String]
    let containerSize: CGSize
    let onTap: () -> Void

    private let calloutWidth: CGFloat = 220
    private let connectorGap: CGFloat = 18
    private let horizontalInset: CGFloat = 18

    private var calloutHeight: CGFloat {
        detailLines.isEmpty ? 74 : 112
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
                description: description,
                detailLines: detailLines,
                onTap: onTap
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
    let detailLines: [String]
    let onTap: () -> Void

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))

            Text(description)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !detailLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(detailLines.prefix(2), id: \.self) { line in
                        Text(line)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
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
