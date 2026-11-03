import SwiftUI

@main
struct TrackGaugeApp: App {
    @State private var store = TelemetryStore.shared

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }
}
