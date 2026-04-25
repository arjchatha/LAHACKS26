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
        guard hostedPreviewLayer !== previewLayer else {
            previewLayer.frame = bounds
            return
        }

        hostedPreviewLayer?.removeFromSuperlayer()
        hostedPreviewLayer = previewLayer
        layer.addSublayer(previewLayer)
        previewLayer.frame = bounds
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedPreviewLayer?.frame = bounds
    }
}
