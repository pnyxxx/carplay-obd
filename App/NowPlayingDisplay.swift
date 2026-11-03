import AVFoundation
import MediaPlayer
import UIKit

/// Affichage CarPlay **sans droit Apple** : l'écran « À l'écoute » de CarPlay montre le titre, l'artiste et la
/// pochette de n'importe quelle app qui joue du son. On joue donc un son silencieux en boucle et on publie
/// les mesures comme « morceau en cours », avec une pochette redessinée (cadran de turbo, régime, eau).
///
/// Expérimental : la vitesse à laquelle CarPlay redessine la pochette n'est pas documentée, à mesurer dans la voiture.
/// Effet de bord : la musique d'une autre app est coupée tant que ce mode est actif.
@MainActor
final class NowPlayingDisplay {
    private var player: AVAudioPlayer?
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var interruptionObserver: NSObjectProtocol?
    private var lastSent = Date.distantPast
    private var latest: GaugeSnapshot?
    private var flushTask: Task<Void, Never>?
    private var sentTimes: [Date] = []

    private(set) var isActive = false
    /// Intervalle minimal entre deux pochettes (s).
    var minInterval: TimeInterval = 0.5
    /// Bouton « suivant » de CarPlay : remise à zéro du pic de turbo.
    var onNextTrack: (() -> Void)?

    var updatesLastMinute: Int {
        let limit = Date().addingTimeInterval(-60)
        return sentTimes.filter { $0 > limit }.count
    }

    func start() throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        // Catégorie « lecture » non mixable : c'est ce qui fait de l'app le lecteur affiché par CarPlay.
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)

        let player = try AVAudioPlayer(data: Self.silentWAV())
        player.numberOfLoops = -1
        player.prepareToPlay()
        player.play()
        self.player = player

        setUpRemoteCommands()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            // Après un appel ou une alerte, on relance le silence pour rester « À l'écoute ».
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            MainActor.assumeIsolated {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.player?.play()
            }
        }
        isActive = true
        lastSent = .distantPast
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        flushTask?.cancel()
        flushTask = nil
        player?.stop()
        player = nil
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Transmet les dernières mesures ; la pochette est redessinée au plus toutes les `minInterval` secondes.
    func submit(_ snapshot: GaugeSnapshot) {
        guard isActive else { return }
        latest = snapshot
        let elapsed = Date().timeIntervalSince(lastSent)
        if elapsed >= minInterval {
            flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.01, (self?.minInterval ?? 0.5) - elapsed)))
                self?.flushTask = nil
                self?.flush()
            }
        }
    }

    private func flush() {
        guard isActive, let snapshot = latest else { return }
        latest = nil
        lastSent = Date()
        sentTimes.append(lastSent)
        if sentTimes.count > 600 { sentTimes.removeFirst(sentTimes.count - 600) }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "\(Format.boost(snapshot.boostBar)) bar · \(Format.rpm(snapshot.rpm)) tr/min",
            MPMediaItemPropertyArtist: "Eau \(Format.temp(snapshot.coolantC)) · Air \(Format.temp(snapshot.intakeAirC))" + (snapshot.peakBoostBar.map { " · MAX \(Format.boost($0))" } ?? ""),
            MPMediaItemPropertyAlbumTitle: "TrackData",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let image = GaugeRenderer.artwork(snapshot) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Lecture / pause : sans effet, l'affichage reste actif.
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            command.isEnabled = true
            let target = command.addTarget { _ in .success }
            commandTargets.append((command, target))
        }
        center.nextTrackCommand.isEnabled = true
        let next = center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onNextTrack?() }
            return .success
        }
        commandTargets.append((center.nextTrackCommand, next))
        center.previousTrackCommand.isEnabled = false
    }

    /// La pochette est demandée par le système sur une file quelconque : fermeture non isolée.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// 1 s de silence (WAV PCM 16 bits mono 8 kHz), joué en boucle.
    nonisolated private static func silentWAV(seconds: Double = 1, sampleRate: UInt32 = 8000) -> Data {
        let dataSize = UInt32(Double(sampleRate) * seconds) * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))            // PCM, mono
        append(sampleRate); append(sampleRate * 2)      // fréquence, octets / s
        append(UInt16(2)); append(UInt16(16))           // alignement, bits
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        data.append(Data(count: Int(dataSize)))
        return data
    }
}
