// WeftCore/FocusSink.swift — the window keyboard focus goes to when there is
// nothing to focus.

/// WeftBar keeps one invisible window, this many points square, on every
/// desktop. Switching to an empty workspace gives it keyboard focus, so typing
/// goes nowhere rather than into the window that was just hidden.
///
/// The size is how weftd finds it: nothing else weft reads is 3×3, and the
/// window list says who owns a window and how big it is without asking the
/// app anything.
public enum FocusSink {
    public static let side = 3.0
}
