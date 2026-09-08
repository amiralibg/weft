#!/usr/bin/env swift
// Draws WeftBar's app icon and writes build/WeftBar.iconset.
//
// Generated rather than committed as a binary: the icon IS the layout weft
// produces — a Fibonacci spiral of panes — so it should follow the real
// tiling rule rather than be redrawn by hand when that rule changes.

import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/WeftBar.iconset"
try? FileManager.default.createDirectory(
    atPath: out, withIntermediateDirectories: true
)

/// Split `rect` the way bsp does: alternate axis, each new pane taking half
/// of what is left. Four panes is enough to read as a spiral at 16px.
func panes(in rect: NSRect, depth: Int) -> [NSRect] {
    guard depth > 0 else { return [rect] }
    var r = rect
    var out: [NSRect] = []
    var vertical = true
    for _ in 0..<depth {
        let (a, b) = vertical
            ? (NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height),
               NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height))
            : (NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2),
               NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2))
        out.append(a)
        r = b
        vertical.toggle()
    }
    out.append(r)
    return out
}

func draw(size: Int) -> NSImage {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = s * 0.22

    // Ground: the same blue the borders integration uses for bsp (0xff7aa2f7),
    // darkened, so the icon and the focus ring read as one product.
    let bg = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.09, green: 0.11, blue: 0.18, alpha: 1).setFill()
    bg.fill()
    bg.addClip()

    let gap = max(s * 0.028, 0.6)
    let accent = NSColor(srgbRed: 0.478, green: 0.635, blue: 0.968, alpha: 1)  // 7aa2f7
    for (i, pane) in panes(in: body.insetBy(dx: s * 0.10, dy: s * 0.10), depth: 3).enumerated() {
        let r = pane.insetBy(dx: gap, dy: gap)
        guard r.width > 0, r.height > 0 else { continue }
        // The focused pane is solid; the rest recede. Same visual grammar as
        // the borders highlight.
        // The trailing panes must stay visible at 16px against a near-black
        // ground, so they bottom out well above transparent.
        accent.withAlphaComponent(i == 0 ? 1.0 : 0.46 - Double(i) * 0.06).setFill()
        NSBezierPath(
            roundedRect: r, xRadius: max(s * 0.045, 1), yRadius: max(s * 0.045, 1)
        ).fill()
    }
    image.unlockFocus()
    return image
}

for size in sizes {
    for (scale, suffix) in [(1, ""), (2, "@2x")] {
        let px = size * scale
        guard px <= 1024 else { continue }
        let img = draw(size: px)
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { continue }
        let name = "\(out)/icon_\(size)x\(size)\(suffix).png"
        try? png.write(to: URL(fileURLWithPath: name))
    }
}
print("wrote \(out)")
