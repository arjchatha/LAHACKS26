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
                FacePinOverlay(
                    detection: viewModel.detectionResult,
                    title: viewModel.focusedPersonTitle ?? "Unknown",
                    subtitle: viewModel.focusedPersonTitle == "Unknown" ? viewModel.detectedPersonDescription : nil
                )
                .ignoresSafeArea(.all)
            }

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

private struct FacePinOverlay: View {
    let detection: FaceDetectionResult
    let title: String
    let subtitle: String?

    var body: some View {
        GeometryReader { geometry in
            let visibleBounds = CGRect(origin: .zero, size: geometry.size)
            let rect = detection.boundingBox
                .aspectFillRect(sourceSize: detection.sourceImageSize, destinationSize: geometry.size)
                .intersection(visibleBounds)
            let insetAmount = max(4, min(rect.width, rect.height) * 0.05)
            let fittedRect = rect.insetBy(dx: insetAmount, dy: insetAmount)

            if !fittedRect.isNull && fittedRect.width > 0 && fittedRect.height > 0 {
                FacePinLabel(
                    title: title,
                    subtitle: subtitle
                )
                .position(x: fittedRect.midX, y: fittedRect.midY)
            }
        }
    }
}

private struct FacePinLabel: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 14, height: 14)
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

            VStack(spacing: 2) {
                Text(title)
                    .font(.callout.weight(.bold))
                    .lineLimit(1)

                if let subtitle, subtitle != title, subtitle != "Unknown" {
                    Text(subtitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.black.opacity(0.72), in: Capsule())
        }
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
