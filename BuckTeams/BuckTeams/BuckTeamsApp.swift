import SwiftUI
import ApplicationServices

@main
struct BuckTeamsApp: App {
    @StateObject private var coordinator = TeamsCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 700)
    }
}

struct ContentView: View {
    @EnvironmentObject var coordinator: TeamsCoordinator

    var body: some View {
        HSplitView {
            // Column 1 — Sidebar
            SidebarView()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 280)

            // Column 2 — Chat (expands to fill available space)
            ChatView()
                .frame(minWidth: 400)
                .layoutPriority(1)

            // Column 3 — Decisions
            DecisionsView()
                .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
        }
    }
}
