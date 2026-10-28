import SwiftUI

@main
struct InkwellApp: App {
    @State private var library = Library()

    init() {
        CrashLog.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
        }
    }
}

private struct RootView: View {
    private let appearance = Appearance.shared

    var body: some View {
        LibraryView()
            .tint(Theme.accent)
            .fontDesign(.rounded)
            .preferredColorScheme(appearance.scheme.scheme)
            .onChange(of: appearance.accent, initial: true) {
                // UIKit pieces (menus, link chips, alerts) follow the window tint
                for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                    for window in scene.windows { window.tintColor = Theme.uiAccent }
                }
            }
    }
}
