//
//  Glyphs.swift
//  Typer+ — custom-drawn brand, mode, and empty-state marks (pure SwiftUI Canvas).
//
//  House style: stroke ≈ 7.5% of the smaller side, round caps + joins, monochrome
//  ink + a single teal accent, ~70% fill with air around it, geometry derived
//  from the rect so everything scales crisp.
//

import SwiftUI

private extension CGRect {
    var glyphStroke: CGFloat { min(width, height) * 0.075 }
}

// MARK: - Brand mark: a keyboard slab with a teal spacebar (matches the app icon)

struct TyperMark: View {
    var accent: Color = Theme.accent          // teal #1C6B5E — the spacebar
    var ink: Color = Theme.textPrimary
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.08, dy: size.height * 0.08)
            let s = r.glyphStroke
            let bodyStyle = StrokeStyle(lineWidth: s, lineCap: .round, lineJoin: .round)

            // Keyboard body: a wide rounded slab (landscape silhouette inside the square).
            let bodyH = r.height * 0.74
            let body = CGRect(x: r.minX, y: r.midY - bodyH / 2, width: r.width, height: bodyH)
            let bodyPath = Path(roundedRect: body, cornerRadius: bodyH * 0.26, style: .continuous)
            ctx.fill(bodyPath, with: .color(ink.opacity(0.05)))
            ctx.stroke(bodyPath, with: .color(ink), style: bodyStyle)

            let pad = bodyH * 0.20
            let inner = body.insetBy(dx: pad, dy: pad)
            let gapY = inner.height * 0.16
            let rowH = (inner.height - gapY * 2) / 3
            let keyR = rowH * 0.34
            let keyFill = GraphicsContext.Shading.color(ink.opacity(0.16))
            func keyTile(_ rect: CGRect) {
                ctx.fill(Path(roundedRect: rect, cornerRadius: keyR, style: .continuous), with: keyFill)
            }

            // Row 0: 3 keys. Row 1: 2 keys (staggered). Row 2: teal spacebar.
            tiles(in: inner, y: inner.minY, height: rowH, count: 3, gap: inner.width * 0.12, draw: keyTile)
            let mid = inner.insetBy(dx: inner.width * 0.14, dy: 0)
            tiles(in: mid, y: inner.minY + rowH + gapY, height: rowH, count: 2, gap: mid.width * 0.16, draw: keyTile)
            let row2Y = inner.minY + (rowH + gapY) * 2
            let space = CGRect(x: inner.minX, y: row2Y, width: inner.width, height: rowH)
            ctx.fill(Path(roundedRect: space, cornerRadius: keyR, style: .continuous), with: .color(accent))
        }
    }

    private func tiles(in box: CGRect, y: CGFloat, height: CGFloat, count: Int,
                       gap: CGFloat, draw: (CGRect) -> Void) {
        guard count > 0 else { return }
        let keyW = (box.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            draw(CGRect(x: box.minX + CGFloat(i) * (keyW + gap), y: y, width: keyW, height: height))
        }
    }
}

// MARK: - Mode glyph: one speed gauge for every mode (needle position = pace)
//
// A 270° dial, open at the bottom: a faint track, a tinted arc filled up to the needle,
// and a short needle on a hub. Same drawing everywhere (dashboard cards, bubble header and
// menu), so the four modes read as one family.

extension TypingProfile.Mode {
    /// 0…1 position of the needle along the dial.
    var gaugeLevel: Double {
        switch self {
        case .careful:    return 0.22
        case .maxStealth: return 0.45   // a natural, mid-dial rhythm
        case .ultraFast:  return 0.72
        case .maxSpeed:   return 1.0
        }
    }
}

struct ModeGlyph: View {
    let mode: TypingProfile.Mode
    var tint: Color? = nil
    var ink: Color = Theme.textPrimary

    var body: some View {
        let color = tint ?? Theme.modeTint(mode)
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            let side = min(r.width, r.height)
            let stroke = side * 0.12
            let radius = side / 2 - stroke / 2 - side * 0.04
            let c = CGPoint(x: r.midX, y: r.midY + side * 0.03)
            let start = 135.0, sweep = 270.0
            let style = StrokeStyle(lineWidth: stroke, lineCap: .round)

            func arc(_ fraction: Double) -> Path {
                var p = Path()
                p.addArc(center: c, radius: radius, startAngle: .degrees(start),
                         endAngle: .degrees(start + sweep * fraction), clockwise: false)
                return p
            }
            ctx.stroke(arc(1), with: .color(ink.opacity(0.18)), style: style)
            ctx.stroke(arc(mode.gaugeLevel), with: .color(color), style: style)

            let a = Angle.degrees(start + sweep * mode.gaugeLevel).radians
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: CGPoint(x: c.x + cos(a) * radius * 0.66, y: c.y + sin(a) * radius * 0.66))
            ctx.stroke(needle, with: .color(ink), style: StrokeStyle(lineWidth: stroke * 0.85, lineCap: .round))
            let hub = stroke * 0.55
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)),
                     with: .color(ink))
        }
        .accessibilityHidden(true)
    }

    /// Rasterized glyph for AppKit-backed menu items (which can't host a SwiftUI Canvas).
    @MainActor static func image(_ mode: TypingProfile.Mode, size: CGFloat = 16) -> NSImage {
        let renderer = ImageRenderer(content: ModeGlyph(mode: mode).frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }
}

// MARK: - "Remove newlines" glyph: a `\n` key-cap with a "remove" badge
//
// A rounded key-cap holding the newline escape `\n`, plus the usual "item − minus-badge"
// mark in the accent colour at its corner. The text stays fully legible (a slash through it
// turned to mush), and it reads as an icon rather than loose text down to ~16pt.

struct RemoveNewlinesGlyph: View {
    var ink: Color = Theme.textPrimary
    var accent: Color = Theme.teal

    var body: some View {
        GeometryReader { g in
            let side = min(g.size.width, g.size.height)
            let line = max(1.2, side * 0.085)
            let cap = side * 0.88                    // key-cap leaves room for the badge
            let badge = side * 0.46
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cap * 0.26, style: .continuous)
                    .strokeBorder(ink, lineWidth: line)
                    .frame(width: cap, height: cap)
                    .overlay(
                        Text("\\n")
                            .font(.system(size: cap * 0.48, weight: .bold, design: .monospaced))
                            .foregroundStyle(ink)
                            .fixedSize()
                    )
                Canvas { ctx, size in
                    let c = CGPoint(x: side - badge / 2, y: side - badge / 2)
                    let disc = CGRect(x: c.x - badge / 2, y: c.y - badge / 2, width: badge, height: badge)
                    ctx.fill(Path(ellipseIn: disc.insetBy(dx: -line * 0.9, dy: -line * 0.9)), with: .color(Theme.panel))
                    ctx.fill(Path(ellipseIn: disc), with: .color(accent))
                    var minus = Path()
                    minus.move(to: CGPoint(x: c.x - badge * 0.22, y: c.y))
                    minus.addLine(to: CGPoint(x: c.x + badge * 0.22, y: c.y))
                    ctx.stroke(minus, with: .color(.white), style: StrokeStyle(lineWidth: max(1.3, badge * 0.17), lineCap: .round))
                }
                .frame(width: side, height: side)
            }
            .frame(width: side, height: side, alignment: .topLeading)
            .frame(width: g.size.width, height: g.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Empty-state illustrations

struct EmptyHistoryArt: View {
    var ink: Color = Theme.textSecondary
    var accent: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            let s = max(1.4, min(size.width, size.height) * 0.018)
            let faint = StrokeStyle(lineWidth: s, lineCap: .round)
            let style = StrokeStyle(lineWidth: s * 1.15, lineCap: .round, lineJoin: .round)
            for i in 0..<3 {
                let y = r.minY + r.height * (0.30 + Double(i) * 0.10)
                let inset = r.width * (0.30 + Double(i) * 0.06)
                var line = Path()
                line.move(to: CGPoint(x: r.minX + inset, y: y)); line.addLine(to: CGPoint(x: r.maxX - inset, y: y))
                ctx.stroke(line, with: .color(ink.opacity(0.18)), style: faint)
            }
            let c = CGPoint(x: r.midX, y: r.midY + r.height * 0.06)
            let radius = min(r.width, r.height) * 0.26
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(ink.opacity(0.55)), style: style)
            var hands = Path()
            hands.move(to: CGPoint(x: c.x, y: c.y - radius * 0.62)); hands.addLine(to: c)
            hands.addLine(to: CGPoint(x: c.x + radius * 0.50, y: c.y + radius * 0.30))
            ctx.stroke(hands, with: .color(accent), style: style)
        }
    }
}


// MARK: - Typing dots (in-button liveness)

struct TypingDots: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 4, height: 4).foregroundStyle(.white)
                    .phaseAnimator([0.35, 1.0, 0.35]) { dot, opacity in dot.opacity(opacity) }
                        animation: { _ in .easeInOut(duration: 0.5).delay(Double(i) * 0.12) }
            }
        }
    }
}
