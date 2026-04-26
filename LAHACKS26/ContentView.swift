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

            rootSwitchButton
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
    }

    private var rootSwitchButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.22)) {
                activeView = activeView == .camera ? .memoryStudio : .camera
            }
        } label: {
            Label(activeView == .camera ? "Memory Studio" : "Patient Camera", systemImage: activeView == .camera ? "book.pages.fill" : "camera.viewfinder")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.38), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(activeView == .camera ? "Open Memory Studio" : "Return to Patient Camera")
        .padding(.bottom, 18)
    }
}

private enum RootViewMode {
    case camera
    case memoryStudio
}
