import SwiftUI
import UIKit

@main
struct TrackGaugeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = TelemetryStore.shared

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environment(store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        store.appDidBecomeActive()
                    } else {
                        // App quittée ou iPhone verrouillé : on rend la luminosité d'origine.
                        store.exitBlackScreen()
                    }
                }
        }
    }
}

/// Point d'entrée garanti à chaque lancement, même quand iOS lance l'app en arrière-plan
/// (raccourci CarPlay, reconnexion de l'adaptateur Bluetooth).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TelemetryStore.shared.bootstrap()
        return true
    }
}
