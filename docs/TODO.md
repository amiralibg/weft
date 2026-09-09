# weft — what's next

Written 2026-09-09, against v0.2.2. Each item says what is actually there
today and where, so none of this has to be re-derived before picking it up.
`docs/DESIGN.md` is the why; this is the queue.

---

## Tier 1 — ship quality

### 1. There is no CI

`.github/workflows/` holds `release.yml` and nothing else, so `swift test`
runs exactly once: at tag time, inside the job that publishes. A broken `main`
is therefore discovered at the worst possible moment — mid-release — and a
regression can sit on `main` unnoticed for as long as nobody tags.

- [ ] Add `.github/workflows/ci.yml`: `swift build` + `swift test` on push and
      pull request. Reuse the Xcode-selection step from `release.yml` verbatim,
      which already fails loudly on a toolchain older than Swift 6.2 rather
      than half-building against it.

Highest value per line of effort on this page.

### 2. A runtime layout choice does not survive a restart

`SpaceState.layouts` is documented as "Missing = not yet visited this launch"
(`Sources/WeftCore/Spaces.swift:107`), and the `space layout` handler
(`Sources/weftd/main.swift:1580`) mutates the in-memory state and stops there.
Labels persist through `saveLabels()` → `~/.config/weft/labels.json`; the
parked set persists through `parked.json`; layouts have no equivalent.

So `⌥⇧N` into scroll, then reboot — or `weftctl service restart`, or install an
update — and the space is back to `bsp` with no indication why. This lands
hardest immediately after onboarding, because Setup's **Finish** restarts the
engine by design.

- [ ] Persist the per-space layout *kind* next to `labels.json`, keyed the same
      way (by ordinal — sids die on reboot, §5.3).
- [ ] Decide what config-declared `[[space]] layout` means when a saved choice
      disagrees. Saved choice wins, or config wins on every load? Whichever, say
      so in the README, because silently picking one is how "my layout keeps
      resetting" bug reports start.
- [ ] Later, the bigger version: persist the whole tree — splits, ratios,
      stacks. That is M7's "crash-safe state restore", and it is what makes a
      daemon restart invisible rather than merely survivable.

### 3. Self-update

WeftBar asks GitHub once a day whether a newer release exists and adds a
menu-bar item that opens the release page — then the user re-runs the curl
one-liner by hand. Meanwhile `scripts/install-release.sh` already does the hard
parts: checksum verification, quarantine clearing, the stable self-signed
identity that keeps grants alive across updates, and (as of `4814ccd`) a
download progress bar.

- [ ] `weftctl update`, and/or a WeftBar menu item, that runs the same script.
- [ ] Restart the service afterwards and say what version it landed on.
- [ ] Respect `check-for-updates = false` — someone who turned the check off did
      not ask for an updater either.

---

## Tier 2 — distribution and trust

### 4. Notarisation

`release.yml` already contains the entire signing and notarising path, gated on
four secrets. Nothing is missing but a paid Apple Developer account. Setting it
up deletes, in one move: the "damaged app" class of bug report, the
quarantine-stripping step in the installer, and the long README section
explaining the self-signed keychain — the section that makes the install
instructions read most defensively.

- [ ] Enrol, then set `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PWD`,
      `MACOS_NOTARY_APPLE_ID`, `MACOS_NOTARY_PASSWORD`, `MACOS_TEAM_ID`.
- [ ] Trim the README and the release notes once a signed build ships; the
      workflow already writes different notes when an identity is present.

### 5. A Homebrew tap

`brew install amiralibg/tap/weft` answers the "I am not piping curl into bash"
objection outright, and gives update-by-brew for free. The audience is people
migrating from yabai and skhd, both of which are installed exactly that way, so
it is the first place they will look.

- [ ] Tap repo with a formula for the CLI binaries and a cask for `WeftBar.app`.
- [ ] Have the release workflow bump the formula's version and SHA on publish —
      a tap that lags the releases is worse than no tap.
- [ ] Keep the installer working. The tap cannot do the stable-identity signing
      or the yabai/skhd hand-off, so `install.sh` stays the recommended path
      until the builds are notarised.

---

## Tier 3 — risks already written down, not yet implemented

### 6. Stage Manager is not detected

`docs/DESIGN.md` §11 risk 9: "Stage Manager must be off — detect and warn at
startup." Nothing in `Sources/` mentions it. With it on, macOS and weft fight
over the same windows and the symptom — windows snapping back after a tile —
reads as a weft bug, so the report arrives pointing at the wrong thing.

- [ ] Read `com.apple.WindowManager GloballyEnabled` at startup.
- [ ] Report it in `weftctl doctor` and as a one-line banner in WeftBar. Name
      the setting and where it lives, the way the permission rows do.

### 7. `weftctl rescue` is invisible

The daemon handles `rescue` (`Sources/weftd/main.swift:1391`) and `weftctl`
forwards any unrecognised verb, so it works today. It appears in neither
`usage()` (`Sources/weftctl/main.swift:6`) nor the README. It is the recovery
for §11 risk 3 — a window stranded off-screen at −5000 with its app unaware —
which means it is undiscoverable at precisely the moment someone needs it.

- [ ] Add it to `usage()` and the command-line section of the README.
- [ ] Have `doctor` notice stranded windows and name the command, rather than
      waiting for the user to find it.

### 8. Bug reports have nowhere to land

`weftctl doctor` is thorough — permissions read from the daemon itself, config
validated with line numbers, cross-checks against live desktops — but
`.github/` has no issue templates, and there is no way to get doctor's output
out of the app for someone who never opens a terminal.

- [ ] A **Copy diagnostics** item in WeftBar: doctor's output plus version,
      macOS build and capability set, straight to the clipboard.
- [ ] An issue template that asks for exactly that and nothing else.

---

## Tier 4 — planned features not yet shipped

### 9. Scratchpads

Specified in `docs/DESIGN.md` §7 as `scratchpad <name>` — a named window made
sticky and floating, toggled show/hide. Spike S3 verified the sticky bit
(`SLSSetWindowTags`, `Sources/SkyLightShim/include/SkyLightShim.h:81`) and the
`sticky` command already works. There is no `scratchpad` command. Most of the
machinery exists; what is missing is the naming, the toggle and the config
surface.

- [ ] `scratchpad <name>` command and a `[[scratchpad]]` config block.
- [ ] Settings editor support, so it is not terminal-only.

### 10. `weft-sa` — decide, rather than leave open

Still the functional ceiling. Without yabai's scripting addition loaded,
`space focus` degrades to the ⌃N keystroke (desktops 1–9 only), background
window moves fail, and sticky does not work. It is also named as the single
largest ongoing maintenance cost in the whole design: the payload finds Dock
internals by byte-pattern scan and must be re-derived on most macOS releases.

- [ ] Make the call explicitly — ship our own addition, keep depending on
      yabai's, or say publicly that we will not. All three are defensible; the
      current state, "still open", is the one that is not, because users cannot
      plan around it.

### 11. Vertical scroll layout

`docs/DESIGN.md` §12, open question: niri has columns only, some people want
rows. Nobody has asked yet.

- [ ] Leave until someone does.

---

## Suggested order

**CI, then layout persistence.** CI first because every later change is safer
once `main` is verified continuously. Layout persistence second because the
engine restart is now a routine part of installing and updating — Setup
performs one itself — and a restart currently throws away a choice the user
deliberately made.
