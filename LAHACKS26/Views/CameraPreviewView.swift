//
//  CameraPreviewView.swift
//  LAHACKS26
//
//  Created by Codex on 4/25/26.
//

import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.contentMode = .scaleAspectFill
        view.isOpaque = true
        view.setPreviewLayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {
        uiView.setPreviewLayer(previewLayer)
    }
}

final class PreviewLayerView: UIView {
    private var hostedPreviewLayer: AVCaptureVideoPreviewLayer?

    func setPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        layer.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill

        guard hostedPreviewLayer !== previewLayer else {
            layoutPreviewLayer(previewLayer)
            return
        }

        hostedPreviewLayer?.removeFromSuperlayer()
        hostedPreviewLayer = previewLayer
        layer.addSublayer(previewLayer)
        layoutPreviewLayer(previewLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let hostedPreviewLayer else { return }
        layoutPreviewLayer(hostedPreviewLayer)
    }

    private func layoutPreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
