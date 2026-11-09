import SwiftUI

@main
struct ImageSearchApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { app.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { app.refreshPhotoStatus() }
                }
        }
    }
}
