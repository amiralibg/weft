import Testing
@testable import WeftCore

private let window = Frame(x: 100, y: 50, width: 1000, height: 800)

private func overlaps(_ a: Frame, _ b: Frame) -> Bool {
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

private func area(_ pieces: [BorderGeometry.Piece]) -> Double {
    pieces.reduce(0) { $0 + $1.frame.width * $1.frame.height }
}

@Test func roundedBorderIsFourStripsAndFourCorners() {
    let p = BorderGeometry.pieces(around: window, width: 2, radius: 12)
    let strips = p.prefix(4).allSatisfy(\.isStrip)
    let corners = p.suffix(4).allSatisfy { !$0.isStrip && $0.frame.width == 14 && $0.frame.height == 14 }
    #expect(p.count == 8)
    #expect(strips)
    #expect(corners)
}

@Test func noPieceReachesIntoTheWindowOutsideItsCorners() {
    for piece in BorderGeometry.pieces(around: window, width: 2, radius: 12) where piece.isStrip {
        #expect(!overlaps(piece.frame, window))
    }
}

@Test func piecesNeverOverlapEachOther() {
    for radius in [0.0, 12] {
        let p = BorderGeometry.pieces(around: window, width: 3, radius: radius)
        for i in p.indices {
            for j in p.indices where j > i {
                #expect(!overlaps(p[i].frame, p[j].frame), "radius \(radius): \(i) overlaps \(j)")
            }
        }
    }
}

@Test func squareBorderCoversExactlyTheRing() {
    let w = 2.0
    let p = BorderGeometry.pieces(around: window, width: w, radius: 0)
    let allStrips = p.allSatisfy(\.isStrip)
    #expect(p.count == 4 && allStrips)
    let outer = BorderGeometry.outer(of: window, width: w)
    #expect(area(p) == outer.width * outer.height - window.width * window.height)
}

/// The point of the design: the compositor carries about a percent of the
/// window's area, not all of it.
@Test func aBorderCoversAboutOnePercentOfItsWindow() {
    let covered = area(BorderGeometry.pieces(around: window, width: 2, radius: 12))
    #expect(covered / (window.width * window.height) < 0.015)
}

@Test func aResizeKeepsTheCornersTheSameSize() {
    let before = BorderGeometry.pieces(around: window, width: 2, radius: 12)
    let after = BorderGeometry.pieces(
        around: Frame(x: 100, y: 50, width: 600, height: 400), width: 2, radius: 12
    )
    #expect(before.count == after.count)
    for i in 4..<8 {
        #expect(before[i].frame.width == after[i].frame.width)
        #expect(before[i].frame.height == after[i].frame.height)
    }
}

@Test func tinyTargetsFallBackToOnePiece() {
    let p = BorderGeometry.pieces(around: Frame(x: 0, y: 0, width: 10, height: 10), width: 2, radius: 12)
    #expect(p.count == 1 && !p[0].isStrip)
    #expect(BorderGeometry.pieces(around: window, width: 0, radius: 12).isEmpty)
}
