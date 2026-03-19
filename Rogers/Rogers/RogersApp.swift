import SwiftUI
import ApplicationServices

@main
struct RogersApp: App {
    @StateObject private var coordinator = RogersCoordinator()

    var body: some Scene {
        MenuBarExtra {
            SessionListView(coordinator: coordinator)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .overlay(alignment: .topTrailing) {
                    if coordinator.activeTurnCount > 0 {
                        Text("\(coordinator.activeTurnCount)")
                            .font(.system(size: 8, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundColor(.white)
                            .offset(x: 6, y: -4)
                    }
                }
        }

        Window("Rogers — Sessions", id: "sessions") {
            SessionsWindowView(coordinator: coordinator)
        }
        .defaultSize(width: 500, height: 400)
    }
}
