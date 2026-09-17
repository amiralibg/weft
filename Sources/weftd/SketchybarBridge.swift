import Foundation
import WeftPlatform
import WeftConfig
import WeftCore

public struct WindowContext: Sendable {
    public var wid: WindowID
    public var app: String?
    public var bundleID: String?
    public var title: String?
    public var stackIndex: Int?
    public var stackCount: Int?

    public init(
        wid: WindowID,
        app: String? = nil,
        bundleID: String? = nil,
        title: String? = nil,
        stackIndex: Int? = nil,
        stackCount: Int? = nil
    ) {
        self.wid = wid
        self.app = app
        self.bundleID = bundleID
        self.title = title
        self.stackIndex = stackIndex
        self.stackCount = stackCount
    }
}

public struct StateSummary: Sendable {
    public var spaceID: SpaceID?
    public var spaceLabel: String?
    public var layout: LayoutKind?
    public var windowCount: Int
    public var displayUUID: String?
    public var displayIndex: Int?
    public var focused: WindowContext?
    public var mode: String

    public init(
        spaceID: SpaceID? = nil,
        spaceLabel: String? = nil,
        layout: LayoutKind? = nil,
        windowCount: Int = 0,
        displayUUID: String? = nil,
        displayIndex: Int? = nil,
        focused: WindowContext? = nil,
        mode: String = "default"
    ) {
        self.spaceID = spaceID
        self.spaceLabel = spaceLabel
        self.layout = layout
        self.windowCount = windowCount
        self.displayUUID = displayUUID
        self.displayIndex = displayIndex
        self.focused = focused
        self.mode = mode
    }

    /// The state as environment variables — the same set for every consumer
    /// that gets one.
    ///
    /// A bar plugin and an `exec` keybind want exactly the same answers, and a
    /// second hand-rolled list of these would drift from this one on the first
    /// field either gained. Absent rather than empty when there is nothing to
    /// say: a script can test `[ -n "$WEFT_FOCUSED_APP" ]` and mean it.
    public var environment: [String: String] {
        var env: [String: String] = ["WEFT_MODE": mode, "WEFT_SPACE_WINDOWS": "\(windowCount)"]
        if let spaceID { env["WEFT_SPACE_ID"] = "\(spaceID)" }
        if let spaceLabel { env["WEFT_SPACE_LABEL"] = spaceLabel }
        if let layout { env["WEFT_SPACE_LAYOUT"] = layout.rawValue }
        if let displayUUID { env["WEFT_DISPLAY_UUID"] = displayUUID }
        if let displayIndex { env["WEFT_DISPLAY_INDEX"] = "\(displayIndex)" }
        if let f = focused {
            env["WEFT_FOCUSED_WID"] = "\(f.wid)"
            if let app = f.app { env["WEFT_FOCUSED_APP"] = app }
            if let bundle = f.bundleID { env["WEFT_FOCUSED_BUNDLE"] = bundle }
            if let title = f.title { env["WEFT_FOCUSED_TITLE"] = title }
            if let idx = f.stackIndex, let count = f.stackCount {
                env["WEFT_STACK_INDEX"] = "\(idx)"
                env["WEFT_STACK_COUNT"] = "\(count)"
            }
        }
        return env
    }
}

final class SketchybarBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var config = SketchybarIntegrationConfig()
    private let queue = DispatchQueue(label: "weft.sketchybar", qos: .utility)
    /// The arguments last sent per event. Touched only on `queue`.
    private var lastArgs: [String: [String]] = [:]

    func updateConfig(_ config: SketchybarIntegrationConfig) {
        lock.withLock { self.config = config }
        // A reload can change what the bar's scripts do with the same
        // payload, so the next trigger of each event goes out regardless.
        queue.async { [self] in lastArgs.removeAll() }
    }

    /// Honours `bar-name`, so a fork or a renamed binary works, and actually
    /// searches PATH — see ExternalBinary.
    private func findSketchybarBinary() -> String? {
        let name = lock.withLock { config.barName }
        return ExternalBinary.find(name.isEmpty ? "sketchybar" : name)
    }

    func trigger(event: String, state: StateSummary) {
        let (enabled, configuredEvents) = lock.withLock {
            (config.enabled, config.events)
        }
        guard enabled else { return }
        if !configuredEvents.isEmpty && !configuredEvents.contains(event) {
            return
        }
        guard let bin = findSketchybarBinary() else { return }

        queue.async { [self] in
            // Sorted, so a trigger's argument list is the same every time for
            // the same state — which is what makes the dedupe below able to
            // compare two of them, and what makes a log line diffable.
            let args = ["--trigger", event]
                + state.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }

            // A trigger is a fork + exec of sketchybar, which then runs every
            // item script subscribed to the event. Focus churn repeats the
            // same event with the same payload many times over, and each
            // repeat told the bar nothing it did not already have.
            guard lastArgs[event] != args else { return }
            lastArgs[event] = args

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            try? proc.run()
        }
    }
}
