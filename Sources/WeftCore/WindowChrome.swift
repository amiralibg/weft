/// What a window's title bar says about it, read through Accessibility, and
/// what weft concludes from that. Pure, so the judgement can be tested
/// without an app on the other end.
public struct WindowChrome: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var hasClose: Bool
    /// Present *and* enabled. A dialog often has the button, greyed out.
    public var canMinimize: Bool
    public var hasFullScreen: Bool
    /// `AXModal`: the app blocks its other windows until this one is done.
    public var modal: Bool

    public init(
        width: Double, height: Double, hasClose: Bool, canMinimize: Bool,
        hasFullScreen: Bool, modal: Bool
    ) {
        self.width = width
        self.height = height
        self.hasClose = hasClose
        self.canMinimize = canMinimize
        self.hasFullScreen = hasFullScreen
        self.modal = modal
    }

    public enum Verdict: Sendable, Equatable {
        case window
        /// Modal: a sign-in, a passkey prompt, a save panel turned window.
        case modal
        /// Small, and neither minimisable nor able to go full screen: the
        /// title bar of a dialog, whatever subrole the app reports.
        case dialog
        /// No title-bar buttons at all on a small window: a popup.
        case panel
    }

    /// Below this a window with dialog chrome is a dialog. A document window
    /// with no full-screen button and no working minimise button is rare;
    /// one that is also this small is a sign-in sheet, a passkey or
    /// permission prompt, an About box. Large chromeless windows (a game, a
    /// kiosk view) are left to tile: floating one of those is much worse
    /// than tiling a badge.
    public static let dialogMaxWidth = 900.0
    public static let dialogMaxHeight = 760.0
    /// Below this, no buttons at all means a popup (the older, narrower test).
    public static let panelMaxWidth = 480.0
    public static let panelMaxHeight = 320.0

    public var verdict: Verdict {
        if modal { return .modal }
        let small = width < Self.panelMaxWidth || height < Self.panelMaxHeight
        if small, !hasClose, !canMinimize, !hasFullScreen { return .panel }
        let dialogSized = width < Self.dialogMaxWidth && height < Self.dialogMaxHeight
        // The close button is what tells a dialog from a window whose title
        // bar is hidden on purpose (a terminal set to no chrome), which has
        // no buttons at all and is a perfectly good tile.
        if dialogSized, hasClose, !canMinimize, !hasFullScreen { return .dialog }
        return .window
    }
}
