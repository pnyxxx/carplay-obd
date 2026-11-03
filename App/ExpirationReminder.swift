import Foundation
import UserNotifications

/// Rappels avant l'expiration de l'app (compte Apple gratuit : signature valable 7 jours).
///
/// La date vient du profil de signature embarqué dans l'app (embedded.mobileprovision).
/// Notifications sur l'iPhone uniquement : l'app n'étant pas une app CarPlay, iOS ne les affiche pas dans CarPlay.
enum ExpirationReminder {
    private static let identifiers = ["expiration.2days", "expiration.1day", "expiration.soon"]

    /// Date de fin de validité de l'installation (nil si introuvable, par ex. version de développement).
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    /// (Re)programme les rappels. À appeler à chaque lancement : une réinstallation donne une nouvelle date.
    static func schedule() async {
        guard let expiry = expirationDate else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        let calendar = Calendar.current
        let when = expiry.formatted(.dateTime.weekday(.wide).hour().minute())
        let body = "Rebranche l'iPhone au PC et réinstalle avec iloader (Import IPA). Tes réglages sont conservés."

        // 2 jours et 1 jour avant, à 19 h (jamais en pleine nuit).
        for (index, days) in [2, 1].enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -days, to: expiry),
                  let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day) else { continue }
            await add(center, id: identifiers[index], at: evening,
                      title: "TrackData expire \(days == 1 ? "demain" : "dans 2 jours")",
                      body: "Fin de validité \(when). \(body)")
        }
        // 3 h avant, seulement en journée.
        let soon = expiry.addingTimeInterval(-3 * 3600)
        if (8...21).contains(calendar.component(.hour, from: soon)) {
            await add(center, id: identifiers[2], at: soon,
                      title: "TrackData expire dans 3 heures",
                      body: body)
        }
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, at date: Date, title: String, body: String) async {
        guard date > Date().addingTimeInterval(60) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
