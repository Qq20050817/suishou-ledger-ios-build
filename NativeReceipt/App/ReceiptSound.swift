import AudioToolbox
import Foundation
import ReceiptCore

/// UI effects use the system sound policy, without a playback audio session,
/// background-audio entitlement, volume override, alert or vibration.
@MainActor enum ReceiptSound {
    private static var sounds: [String: SystemSoundID] = [:]
    static func play(_ motion: ReceiptMotion) {
        guard ProcessInfo.processInfo.environment["RECEIPT_RENDER_TESTS"] == nil else { return }
        if let sound = soundID(for: motion) { AudioServicesPlaySystemSound(sound) }
    }

    static func soundID(for motion: ReceiptMotion) -> SystemSoundID? {
        guard motion != .idle else { return nil }
        let name = motion == .printing ? "paper_feed" : "paper_tear"
        if let sound = sounds[name] { return sound }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == noErr else { return nil }
        // IsUISound defaults to 1. The default already respects the user's system sound policy.
        sounds[name] = sound
        return sound
    }
}
