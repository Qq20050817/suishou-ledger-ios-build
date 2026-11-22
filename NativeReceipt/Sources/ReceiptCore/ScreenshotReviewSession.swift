import Foundation

/// One worker per screenshot. Completion updates memory only, never the Shortcuts host.
public actor ScreenshotReviewSession {
    public struct State: Sendable {
        public let preview: ScreenshotReceiptPreview
        public fileprivate(set) var card: String?
        public fileprivate(set) var message = ""
    }
    public typealias Resolve = @Sendable () async throws -> String
    private struct Entry {
        var state: State
        let resolve: Resolve
        let created = Date()
        var worker: Task<Void, Never>?
        var generation = UUID()
    }
    private var entries: [String: Entry] = [:]
    public init() {}

    public func begin(_ id: String, preview: ScreenshotReceiptPreview, resolve: @escaping Resolve) {
        for key in Array(entries.keys) where entries[key].map({ Date().timeIntervalSince($0.created) >= 3500 }) == true {
            entries.removeValue(forKey: key)?.worker?.cancel()
        }
        if entries[id] == nil { entries[id] = Entry(state: State(preview: preview), resolve: resolve) }
        start(id)
    }

    public func state(_ id: String) -> State? { entries[id]?.state }

    private func start(_ id: String) {
        guard let entry = entries[id], entry.state.card == nil, entry.worker == nil else { return }
        let generation = UUID()
        entries[id]?.generation = generation
        entries[id]?.state.message = ""
        entries[id]?.worker = Task {
            do {
                let card = try await entry.resolve()
                guard entries[id]?.generation == generation else { return }
                entries[id]?.state.card = card
                entries[id]?.state.message = ""
            } catch {
                guard entries[id]?.generation == generation else { return }
                entries[id]?.state.message = (error as? ReceiptError)?.localizedDescription ?? "暂时连不上账本，原图已保存在本机。"
            }
            entries[id]?.worker = nil
        }
    }

    /// A tap may wait briefly. No deferred save is scheduled after this method returns.
    public func review(_ id: String, waiting: Duration = .seconds(4)) async throws -> State {
        guard entries[id] != nil else { throw ReceiptError.message("请运行「继续上张截图记账」重新打开小票。") }
        start(id)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: waiting)
        while entries[id]?.worker != nil && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard var state = entries[id]?.state else { throw ReceiptError.message("这张小票已关闭。") }
        if state.card == nil && state.message.isEmpty {
            state.message = "完整小票还在识别。可以先关闭，稍后继续核对。"
            entries[id]?.state.message = state.message
        }
        return state
    }
}
