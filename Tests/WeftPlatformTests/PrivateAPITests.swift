import Foundation
import SkyLightShim
import Testing
@testable import WeftPlatform

// Private symbols are resolved by name at load rather than linked, so a macOS
// that drops one costs the feature that uses it instead of the launch. These
// pin both halves: the table is complete, and a missing entry reads as an
// ordinary failed call.

/// Serialized: one test takes a symbol away for its duration, and the others
/// would see it gone.
@Suite(.serialized) struct PrivateAPITests {
    @Test func everyPrivateSymbolIsListedExactlyOnce() {
        let names = PrivateAPI.symbols.map { $0.name }
        #expect(names.count == Int(weft_private_symbol_count()))
        #expect(Set(names).count == names.count)
        // Everything doctor explains is a symbol weft actually uses.
        #expect(Set(PrivateAPI.impact.keys).isSubset(of: Set(names)))
    }

    /// A canary rather than a unit test: on a macOS that no longer exports one of
    /// these, this is the first thing to go red, on the CI job that builds against
    /// the next SDK — before any user meets it.
    @Test func everyPrivateSymbolResolvesOnThisMacOS() {
        let missing = PrivateAPI.symbols.filter { !$0.present }.map { $0.name }
        #expect(missing.isEmpty, "not exported by this macOS: \(missing)")
    }

    @Test func aMissingSymbolFailsItsCallInsteadOfCrashing() {
        // The suite is serialized, so nothing else in it can observe the gap.
        // Nothing outside it calls SLSTransactionCreate.
        #expect(weft_private_symbol_simulate_missing("SLSTransactionCreate", true))
        defer { weft_private_symbol_simulate_missing("SLSTransactionCreate", false) }

        #expect(SLSTransactionCreate(SLSMainConnectionID()) == nil)
        let report = PrivateAPI.selfTest()
        #expect(report.symbols.first { $0.name == "SLSTransactionCreate" }?.present == false)
        #expect(report.missing.contains("SLSTransactionCreate"))
        #expect(!report.passed(.transaction))
        #expect(report.summary.contains("SLSTransactionCreate"))
    }

    /// Without SkyLight's topology, weft still sees every display, each with
    /// one desktop that is showing — the degraded mode it tiles in.
    @Test func withoutTheTopologyEachDisplayHasOneDesktop() {
        #expect(weft_private_symbol_simulate_missing("SLSCopyManagedDisplaySpaces", true))
        defer { weft_private_symbol_simulate_missing("SLSCopyManagedDisplaySpaces", false) }
        #expect(PublicPaths.isMissing("SLSCopyManagedDisplaySpaces"))
        let (displays, spaces) = WorldReader.readDisplaysAndSpaces(cid: SLSMainConnectionID())
        #expect(displays.count == SpaceControl.displayLayout().count)
        for d in displays {
            #expect(d.spaces == [PublicPaths.syntheticDesktop(for: d.uuid)])
            #expect(d.currentSpace == d.spaces.first)
        }
        #expect(spaces.allSatisfy { $0.isCurrent && !$0.isFullscreen })
    }

    @Test func aSymbolThatIsPresentIsNotMissing() {
        #expect(!PublicPaths.isMissing("SLSCopyManagedDisplaySpaces"))
        #expect(!PublicPaths.isMissing("no such symbol"))
    }

    /// Needs a logged-in WindowServer session, which a CI runner is not promised.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func theSelfTestPassesOnADeveloperMac() {
        let report = PrivateAPI.selfTest()
        #expect(report.failed.isEmpty, "\(report.summary)")
    }
}
