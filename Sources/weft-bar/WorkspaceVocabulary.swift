import Foundation
import WeftBarConfig

/// The one place that decides whether weft's UI says "desktop" or "workspace".
///
/// The two modes name the same thing differently and mean it: under `native` a
/// space *is* a macOS desktop, so "desktop" is exact; under `virtual` several
/// of them share one desktop, so "desktop" is wrong in the specific way that
/// sends someone to Mission Control to fix a setting that lives in Settings.
///
/// It is a stored flag rather than a lookup because the callers are `static`
/// helpers deep inside view bodies — `ShortcutRowView.summary(for:)` is used
/// by three search filters as well as by the row — and threading the mode
/// through all of them would put a parameter on code that only ever wants the
/// current answer. Both loaders that already parse weft.toml refresh it:
/// `ConfigStore.readAll()` and `CheatsheetModel.load()`.
@MainActor
enum WorkspaceVocabulary {
    /// Defaults to the parser's default, so the first frame drawn before any
    /// config is read is right for a fresh install rather than wrong for one.
    private(set) static var virtual = true

    static func refresh(from document: TomlDocument) {
        let section = document.firstIndex(ofHeader: "[general]").map { document.sections[$0] }
        virtual = section?.string("workspaces") != "native"
    }

    /// Lower case, for the middle of a sentence.
    static var noun: String { virtual ? "workspace" : "desktop" }

    /// Title case, for a heading.
    static var plural: String { virtual ? "Workspaces" : "Desktops" }

    /// weft's commands are all spelled `space …`, and every description of one
    /// comes out of `CheatsheetModel.describe`. This is the one rewrite that
    /// turns that vocabulary into the user's.
    static func rephrase(_ text: String) -> String {
        text.replacingOccurrences(of: "space", with: noun)
    }
}
