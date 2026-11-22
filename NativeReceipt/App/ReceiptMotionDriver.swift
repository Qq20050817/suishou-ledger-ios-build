import AppIntents
import UIKit
import ReceiptCore

/// Rendering remains read-only. Printing starts after the first result;
/// confirmation awaits the tear before returning the retained result card.
enum ReceiptMotionDriver {
    /// The app's own sheet observes local state. Its buttons must never summon a Shortcuts snippet.
    static func refresh(inApp: Bool, host: @escaping @Sendable () async -> Void = { ReceiptSnippetIntent.reload() }) -> @Sendable () async -> Void {
        { if !inApp { await host() } }
    }

    /// The first rendered frame claims its user-initiated feed. A data refresh cannot replay it.
    /// Publish a single target pose; SwiftUI interpolates the full paper movement on the rendering host.
    static func presentScreenshot(_ id: String, generation: String, inApp: Bool = false,
                                  sound: @escaping @Sendable (ReceiptMotion) async -> Void = { await ReceiptSound.play($0) },
                                  host: @escaping @Sendable () async -> Void = { ReceiptSnippetIntent.reload() }) async {
        let store = ReceiptStore.shared
        guard await store.claimScreenshotFeed(id, generation: generation) else { return }
        let reduceMotion = await MainActor.run { UIAccessibility.isReduceMotionEnabled }
        if reduceMotion {
            if (try? await store.advanceMotion(id, generation: generation, progress: 1)) == true { await sound(.printing) }
            return
        }
        Task {
            // Allow the host to install the initial pose before sending the one animated change.
            try? await Task.sleep(for: .milliseconds(190))
            guard !Task.isCancelled, (try? await store.advanceMotion(id, generation: generation, progress: 1)) == true else { return }
            await sound(.printing)
            if !inApp { await host() }
        }
    }

    static func start(_ id: String, motion: ReceiptMotion,
                      refresh: @escaping @Sendable () async -> Void = { ReceiptSnippetIntent.reload() }) async {
        let reduceMotion = await MainActor.run { UIAccessibility.isReduceMotionEnabled }
        guard let generation = try? await ReceiptStore.shared.beginMotion(id, motion) else { return }
        if reduceMotion {
            _ = try? await ReceiptStore.shared.advanceMotion(id, generation: generation, progress: 1)
            await ReceiptSound.play(motion)
            return
        }
        if motion == .tearing {
            await animate(id, generation: generation, motion: motion, refresh: refresh)
        } else {
            Task { await animate(id, generation: generation, motion: motion, refresh: refresh) }
        }
    }

    private static func animate(_ id: String, generation: String, motion: ReceiptMotion,
                                refresh: @escaping @Sendable () async -> Void) async {
        do {
            await refresh()
            try await Task.sleep(for: .milliseconds(motion == .printing ? 500 : 350))
            // The tear is one continuous host-side interpolation. Repeated
            // intent reloads previously interrupted it and duplicated success.
            let frames = motion == .printing ? ReceiptMotionTiming.feedFrames : 1
            let duration = motion == .printing ? ReceiptMotionTiming.feedDuration : ReceiptMotionTiming.tearDuration
            // One uninterrupted clip and one monotonic timeline. Schedule the
            // next pose at the start of its interpolation interval, not after
            // sleeping an extra interval beyond the audible start.
            await ReceiptSound.play(motion)
            let clock = ContinuousClock()
            let started = clock.now
            for frame in 1...frames {
                try await clock.sleep(until: started.advanced(by: .seconds(duration * Double(frame - 1) / Double(frames))))
                guard try await ReceiptStore.shared.advanceMotion(id, generation: generation, progress: Double(frame) / Double(frames), completing: false) else { return }
                await refresh()
            }
            // Keep the final moving pose alive until its interpolation and
            // the whole audio clip have both reached the common end time.
            try await clock.sleep(until: started.advanced(by: .seconds(duration)))
            _ = try await ReceiptStore.shared.advanceMotion(id, generation: generation, progress: 1)
            // A completed button automatically refreshes its retained snippet.
            // Only the background print task needs an explicit final refresh.
            if motion == .printing { await refresh() }
        } catch {
            _ = try? await ReceiptStore.shared.advanceMotion(id, generation: generation, progress: 1)
            if motion == .printing { await refresh() }
        }
    }
}
