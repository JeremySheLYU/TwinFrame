import SwiftUI

@main
struct TwinFrameApp: App {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen(model: camera)
                .preferredColorScheme(.dark)
                .onAppear {
                    if scenePhase == .active { camera.activate() }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: camera.activate()
                    case .background: camera.deactivate()
                    default: break
                    }
                }
        }
    }
}
