import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var pipeline = FaceRecognitionPipeline()
    @State private var screen: AppScreen = .home
    @State private var trainingName = ""
    @State private var savedAlertName: String?

    var body: some View {
        ZStack {
            switch screen {
            case .home:
                HomeView(
                    onTrain: { screen = .train },
                    onLive: { screen = .live }
                )
            case .train:
                TrainingView(
                    pipeline: pipeline,
                    name: $trainingName,
                    onStart: {
                        pipeline.startTraining(named: trainingName)
                    },
                    onBack: {
                        pipeline.cancelTraining()
                        screen = .home
                    }
                )
            case .live:
                LiveView(
                    pipeline: pipeline,
                    onBack: {
                        pipeline.stop()
                        screen = .home
                    }
                )
            }
        }
        .onAppear {
            syncPipeline(for: screen)
        }
        .onChange(of: screen) { _, newValue in
            syncPipeline(for: newValue)
        }
        .onReceive(pipeline.$enrollmentSavedName) { name in
            guard let name else { return }
            savedAlertName = name
            trainingName = ""
        }
        .alert("Saved name \(savedAlertName ?? "")", isPresented: Binding(
            get: { savedAlertName != nil },
            set: { if !$0 { savedAlertName = nil; pipeline.enrollmentSavedName = nil } }
        )) {
            Button("OK", role: .cancel) {
                savedAlertName = nil
                pipeline.enrollmentSavedName = nil
            }
        }
    }

    private func syncPipeline(for screen: AppScreen) {
        switch screen {
        case .home:
            pipeline.stop()
        case .train, .live:
            Task {
                await pipeline.start()
            }
        }
    }
}

private enum AppScreen {
    case home
    case train
    case live
}

private struct HomeView: View {
    let onTrain: () -> Void
    let onLive: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Text("Face Recognition MVP")
                .font(.largeTitle.bold())
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Choose a path")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: onTrain) {
                    Label("Train Face", systemImage: "person.crop.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: .blue))

                Button(action: onLive) {
                    Label("Live Detection", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: .green))
            }

            Spacer()
        }
        .padding(24)
    }
}

private struct TrainingView: View {
    let pipeline: FaceRecognitionPipeline
    @Binding var name: String
    let onStart: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(pipeline: pipeline)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Button(action: onBack) {
                    Label("Home", systemImage: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Text("Train a Face")
                    .font(.title.bold())
                    .foregroundStyle(.white)

                Text("Capture 20 clean images of one face.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))

                if !isTrainingActive {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(onStart)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.70))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())

                    Button(action: onStart) {
                        Label(buttonTitle, systemImage: buttonIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: .blue))
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Text("Training in progress...")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                ProgressView(value: pipeline.trainingProgress)
                    .tint(.green)

                Text(pipeline.trainingLabel.isEmpty ? "Ready" : pipeline.trainingLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Text(pipeline.statusMessage)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(3)

                if let result = pipeline.trainingResultMessage {
                    Text(result)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.72))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                Text("Samples: \(Int((pipeline.trainingProgress * 20.0).rounded(.down)))/20")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
            .background(.black.opacity(0.34))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(16)
        }
        .onDisappear {
            pipeline.cancelTraining()
        }
    }

    private var buttonTitle: String {
        if pipeline.trainingLabel == "Complete" || pipeline.trainingCompleteName == name {
            return "Complete"
        }
        return "Start Training"
    }

    private var buttonIcon: String {
        if pipeline.trainingLabel == "Complete" || pipeline.trainingCompleteName == name {
            return "checkmark.circle.fill"
        }
        return "arrow.triangle.2.circlepath"
    }

    private var isTrainingActive: Bool {
        pipeline.trainingLabel.hasPrefix("Training ") && pipeline.trainingLabel != "Complete"
    }
}

private struct LiveView: View {
    let pipeline: FaceRecognitionPipeline
    let onBack: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(pipeline: pipeline)
                .ignoresSafeArea()

            Button(action: onBack) {
                Label("Home", systemImage: "chevron.left")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(16)

            ForEach(pipeline.faces) { face in
                let rect = pipeline.overlayRect(for: face.boundingBox)
                FacePinOverlay(label: face.label)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }
}

private struct CameraPreview: PlatformViewRepresentable {
    let pipeline: FaceRecognitionPipeline

    func makePlatformView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = pipeline.session
        pipeline.attachPreviewLayer(view.previewLayer)
        return view
    }

    func updatePlatformView(_ platformView: PreviewView, context: Context) {
        platformView.previewLayer.session = pipeline.session
        pipeline.attachPreviewLayer(platformView.previewLayer)
    }
}

#if canImport(UIKit)
private typealias PlatformViewRepresentable = UIViewRepresentable
private typealias PlatformView = UIView

private final class PreviewView: PlatformView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private extension CameraPreview {
    func makeUIView(context: Context) -> PreviewView { makePlatformView(context: context) }
    func updateUIView(_ uiView: PreviewView, context: Context) { updatePlatformView(uiView, context: context) }
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

    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private extension CameraPreview {
    func makeNSView(context: Context) -> PreviewView { makePlatformView(context: context) }
    func updateNSView(_ nsView: PreviewView, context: Context) { updatePlatformView(nsView, context: context) }
}
#endif

#Preview {
    ContentView()
}

private struct FacePinOverlay: View {
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)

                Circle()
                    .strokeBorder(.green, lineWidth: 3)
                    .frame(width: 18, height: 18)
            }

            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.75))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(tint.opacity(configuration.isPressed ? 0.75 : 0.95))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }
}
