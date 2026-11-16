import SwiftUI

@main
struct PhysioAINativeApp: App {
    @StateObject private var app = NativeAppModel()

    var body: some Scene {
        WindowGroup {
            NativeRootView()
                .environmentObject(app)
        }
    }
}
