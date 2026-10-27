// Draws the app icon, a stylized mel spectrogram of a spoken phrase in the magma colormap.
// `./mel` renders it into AppIcon.icns; delete that file to regenerate.
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 pt rounded square centered on the 1024 canvas, with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.03, blue: 0.10, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

/// Matplotlib's magma, from black through purple and orange to pale yellow.
func magma(_ t: Double) -> NSColor {
    let stops: [(Double, Double, Double)] = [
        (0.00, 0.00, 0.02), (0.11, 0.07, 0.24), (0.32, 0.07, 0.43), (0.55, 0.16, 0.51),
        (0.78, 0.24, 0.46), (0.95, 0.38, 0.36), (0.99, 0.62, 0.42), (0.99, 0.99, 0.75),
    ]
    let x = min(max(t, 0), 1) * Double(stops.count - 1)
    let i = min(Int(x), stops.count - 2), f = x - Double(i)
    let (a, b) = (stops[i], stops[i + 1])
    return NSColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
}

// Energy over time (columns) and mel bands (rows, low pitch at the bottom): three syllables whose
// formants drift, the way speech looks in a spectrogram.
let columns = 9, rows = 9
func energy(_ c: Int, _ r: Int) -> Double {
    let t = Double(c) / Double(columns - 1), m = Double(r) / Double(rows - 1)
    let syllables = [(0.18, 0.11), (0.50, 0.13), (0.82, 0.10)]
    let loudness = syllables.map { exp(-pow((t - $0.0) / $0.1, 2)) }.max()!
    let f1 = 0.22 + 0.10 * sin(t * 6), f2 = 0.55 + 0.12 * cos(t * 5)
    let formants = 0.9 * exp(-pow((m - f1) / 0.13, 2)) + 0.65 * exp(-pow((m - f2) / 0.11, 2)) + 0.35 * (1 - m)
    return 0.08 + 0.92 * loudness * formants
}

let inset: CGFloat = 200, gap: CGFloat = 16
let cellW = (size - 2 * inset - gap * CGFloat(columns - 1)) / CGFloat(columns)
let cellH = (size - 2 * inset - gap * CGFloat(rows - 1)) / CGFloat(rows)
for c in 0..<columns {
    for r in 0..<rows {
        let cell = CGRect(x: inset + CGFloat(c) * (cellW + gap), y: inset + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
        ctx.addPath(CGPath(roundedRect: cell, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setFillColor(magma(energy(c, r)).cgColor)
        ctx.fillPath()
    }
}
image.unlockFocus()

let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
