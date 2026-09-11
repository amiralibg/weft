import Foundation
// WeftCore/Rules.swift — window rules (M6). Pure matching; the daemon
// applies outcomes (exclude from layouts, attempt space moves).

/// A rule matches when EVERY specified matcher matches (AND). First matching
/// rule in config order wins.
public struct Rule: Sendable, Equatable {
    /// Exact bundle id, e.g. "com.apple.finder".
    public var bundleID: String?
    /// Regex on the app name, e.g. "^Ghostty$".
    public var app: String?
    /// Regex on the window title, e.g. "Picture.in.Picture".
    public var title: String?
    /// Target space label (move on creation; needs weft-sa until then).
    public var space: String?
    /// False = leave alone entirely (floats free, never tiled).
    public var manage: Bool?

    public init(
        bundleID: String? = nil,
        app: String? = nil,
        title: String? = nil,
        space: String? = nil,
        manage: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.app = app
        self.title = title
        self.space = space
        self.manage = manage
    }
}

public struct RuleOutcome: Sendable, Equatable {
    public var space: String?
    public var manage: Bool

    public init(space: String? = nil, manage: Bool = true) {
        self.space = space
        self.manage = manage
    }
}

private func regexMatches(_ pattern: String, _ text: String) -> Bool {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(text.startIndex..., in: text)
    return re.firstMatch(in: text, range: range) != nil
}

public func ruleMatches(_ rule: Rule, app: String, bundleID: String?, title: String) -> Bool {
    if let b = rule.bundleID, b != (bundleID ?? "") { return false }
    if let pattern = rule.app, !regexMatches(pattern, app) { return false }
    if let pattern = rule.title, !regexMatches(pattern, title) { return false }
    return rule.bundleID != nil || rule.app != nil || rule.title != nil
}

/// First matching rule wins; nil = defaults (managed, no placement).
public func matchRules(
    _ rules: [Rule],
    app: String,
    bundleID: String?,
    title: String
) -> RuleOutcome? {
    guard let rule = rules.first(where: { ruleMatches($0, app: app, bundleID: bundleID, title: title) }) else {
        return nil
    }
    return RuleOutcome(space: rule.space, manage: rule.manage ?? true)
}

/// What a sweep should do about the `space` half of a matched rule.
///
/// Split out of the sweep so the decision can be tested on its own: it is the
/// one part of window placement that does not correct itself on the next pass.
/// Tiling writes frames every time round the loop, so a wrong guess costs a
/// frame; a cross-space move happens once and leaves the window on another
/// desktop, and an app whose sheet or popover was carried off alone stops
/// routing clicks and scrolls to the parent it left behind.
public enum SpaceMoveDecision: Sendable, Equatable {
    /// Move it now.
    case move(String)
    /// AX has not classified the window yet. Do not move, and do not record an
    /// attempt — the reclassify sweep asks again once the answer is in.
    case wait
    /// Nothing to do: no space in the rule, already tried, or not a window a
    /// rule may carry between desktops.
    case skip
}

/// - Parameters:
///   - outcome: the matched rule, or nil when none matched.
///   - isStandardWindow: AX's verdict — `true` a real window, `false` a panel
///     or popover, `nil` not answered yet.
///   - alreadyAttempted: whether this window has had its one move this launch.
///
/// `manage` is deliberately not consulted. The two halves of a rule are
/// independent: `manage = false` says "do not lay this window out", not
/// "leave it on whatever desktop it opened on", and a float with
/// `space = "main"` used to have the space half silently dropped.
public func spaceMoveDecision(
    outcome: RuleOutcome?,
    isStandardWindow: Bool?,
    alreadyAttempted: Bool
) -> SpaceMoveDecision {
    guard let target = outcome?.space, !alreadyAttempted else { return .skip }
    switch isStandardWindow {
    case .some(true): return .move(target)
    case .some(false): return .skip
    case nil: return .wait
    }
}
