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
}

final class SketchybarBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var config = SketchybarIntegrationConfig()
    private let queue = DispatchQueue(label: "weft.sketchybar", qos: .utility)

    func updateConfig(_ config: SketchybarIntegrationConfig) {
        lock.withLock { self.config = config }
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

        queue.async {
            var args = ["--trigger", event]
            if let sid = state.spaceID {
                args.append("WEFT_SPACE_ID=\(sid)")
            }
            if let label = state.spaceLabel {
                args.append("WEFT_SPACE_LABEL=\(label)")
            }
            if let layout = state.layout {
                args.append("WEFT_SPACE_LAYOUT=\(layout.rawValue)")
            }
            args.append("WEFT_SPACE_WINDOWS=\(state.windowCount)")
            if let duuid = state.displayUUID {
                args.append("WEFT_DISPLAY_UUID=\(duuid)")
            }
            if let dindex = state.displayIndex {
                args.append("WEFT_DISPLAY_INDEX=\(dindex)")
            }
            if let f = state.focused {
                args.append("WEFT_FOCUSED_WID=\(f.wid)")
                if let app = f.app { args.append("WEFT_FOCUSED_APP=\(app)") }
                if let bundle = f.bundleID { args.append("WEFT_FOCUSED_BUNDLE=\(bundle)") }
                if let title = f.title { args.append("WEFT_FOCUSED_TITLE=\(title)") }
                if let idx = f.stackIndex, let count = f.stackCount {
                    args.append("WEFT_STACK_INDEX=\(idx)")
                    args.append("WEFT_STACK_COUNT=\(count)")
                }
            }
            args.append("WEFT_MODE=\(state.mode)")

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = args
            try? proc.run()
        }
    }
}
