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
        PatientCameraView(memoryBridge: memoryBridge)
    }
}
