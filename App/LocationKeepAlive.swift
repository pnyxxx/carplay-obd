import CoreLocation
import Foundation

/// Garde l'app active en arrière-plan grâce au GPS (comme une app de navigation).
///
/// Le mode Bluetooth en arrière-plan suffit en théorie, mais si une réponse de l'adaptateur se perd,
/// iOS peut suspendre l'app et la lecture s'arrête. Avec le GPS actif, l'app n'est jamais suspendue,
/// et on récupère au passage la vitesse GPS (utile plus tard pour le chrono au tour).
final class LocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private(set) var isRunning = false

    /// Vitesse GPS en km/h (appelé sur le fil principal).
    var onSpeed: ((Double) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // « Toujours » permet de relancer le GPS quand l'app démarre seule en arrière-plan (CarPlay).
            manager.requestAlwaysAuthorization()
        default:
            break
        }
        // Nécessite UIBackgroundModes = location dans Info.plist (sinon plantage).
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        backgroundSession = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.stopUpdatingLocation()
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.speed >= 0 else { return }
        onSpeed?(last.speed * 3.6)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
