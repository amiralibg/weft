import Foundation
import Testing
import WeftCore
@testable import WeftPlatform

// The visible switch test flickers a display, so it runs once per macOS build
// and its answer is kept. These pin when a kept answer is used. Nothing here
// switches anything: `allowVisible` is false throughout, and the invisible
// tests that do run act on a never-shown window of the test's own.

private func tempCache() -> NativeRoutesCache {
    NativeRoutesCache(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("weft-routes-\(UUID().uuidString).json"))
}

@Test func aResultFromAnotherBuildIsNotUsed() {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache.url) }
    cache.save(NativeRoutes(macOSBuild: "OLD1", routes: [.switchDesktop: RouteStatus(.passed, "old")]))
    let routes = NativeSelfTest.routes(cache: cache, allowVisible: false)
    #expect(routes.macOSBuild == NativeSelfTest.macOSBuild)
    #expect(routes[.switchDesktop].state == .untested)
    #expect(cache.load(build: "OLD1") == nil, "the new build's results replace the old")
}

@Test func thisBuildsSwitchResultIsKeptWithoutRunningAgain() {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache.url) }
    let build = NativeSelfTest.macOSBuild
    cache.save(NativeRoutes(macOSBuild: build, routes: [.switchDesktop: RouteStatus(.passed, "kept")]))
    let routes = NativeSelfTest.routes(cache: cache, allowVisible: false)
    #expect(routes[.switchDesktop] == RouteStatus(.passed, "kept"))
    #expect(routes[.dockSwipe].state == .untested)
    #expect(routes.switchMethod == .bridged)
    #expect(cache.load(build: build)?[.switchDesktop] == RouteStatus(.passed, "kept"))
}

@Test func aFailedSwitchKeepsItsFallbackResult() {
    let cache = tempCache()
    defer { try? FileManager.default.removeItem(at: cache.url) }
    cache.save(NativeRoutes(macOSBuild: NativeSelfTest.macOSBuild, routes: [
        .switchDesktop: RouteStatus(.failed, "the display still shows desktop 3"),
        .dockSwipe: RouteStatus(.passed, "swiped"),
    ]))
    let routes = NativeSelfTest.routes(cache: cache, allowVisible: false)
    #expect(routes[.dockSwipe] == RouteStatus(.passed, "swiped"))
    #expect(routes.switchMethod == .dockSwipe)
}
