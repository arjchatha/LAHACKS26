//
//  ContentView.swift
//  LAHACKS26
//
//  Created by Rikhil Rao on 4/24/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var memoryBridge = MockMemoryBridge()

    var body: some View {
        TabView {
            ProfileEnrollmentView(memoryBridge: memoryBridge)
                .tabItem {
                    Label("Profiles", systemImage: "person.crop.rectangle.stack")
                }

            PatientCameraView(memoryBridge: memoryBridge)
                .tabItem {
                    Label("Live", systemImage: "camera.viewfinder")
                }
        }
    }
}
