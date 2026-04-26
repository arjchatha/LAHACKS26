//
//  ContentView.swift
//  LAHACKS26
//
//  Created by Rikhil Rao on 4/24/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var memoryBridge = MockMemoryBridge()
    @State private var activeView: RootViewMode = .camera

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch activeView {
                case .camera:
                    PatientCameraView(memoryBridge: memoryBridge)
                        .transition(.opacity)
                case .memoryStudio:
                    MemoryStudioView(memoryBridge: memoryBridge) {
                        withAnimation(.smooth(duration: 0.22)) {
                            activeView = .camera
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()

            rootNavigationBar
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    private var rootNavigationBar: some View {
        HStack(spacing: 8) {
            ForEach(RootViewMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.smooth(duration: 0.22)) {
                        activeView = mode
                    }
                } label: {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(activeView == mode ? .white.opacity(0.18) : .white.opacity(0.06), in: Capsule())
                        .overlay {
                            Capsule()
                                .stroke(.white.opacity(activeView == mode ? 0.28 : 0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(mode.title)")
            }
        }
        .padding(6)
        .background(.black.opacity(0.42), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
        .padding(.bottom, 18)
    }
}

private enum RootViewMode: CaseIterable {
    case camera
    case memoryStudio

    var title: String {
        switch self {
        case .camera:
            "Camera"
        case .memoryStudio:
            "Memories"
        }
    }

    var symbol: String {
        switch self {
        case .camera:
            "camera.viewfinder"
        case .memoryStudio:
            "book.pages.fill"
        }
    }
}
