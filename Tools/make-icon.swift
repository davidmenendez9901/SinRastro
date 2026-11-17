// Genera el icono de SinRastro: una app que se deshace en píxeles.
// Uso: swift Tools/make-icon.swift <salida.png>
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Fondo: la forma estándar de macOS (824 pt centrados) con sombra suave.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(color(0x1B1F4B))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x2A2470), color(0x1F6FA8), color(0x19B8A6)] as CFArray,
    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(
    gradient, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
// Brillo superior.
let shine = CGGradient(
    colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    shine, start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.midY), options: [])

// La "app": un azulejo blanco cuya mitad derecha se deshace en píxeles.
let tile = CGRect(x: 212, y: 322, width: 380, height: 380)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 92, cornerHeight: 92, transform: nil)
let cut: CGFloat = 440
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: cut, height: 1024))
ctx.addPath(tilePath)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

var seed: UInt64 = 0x5EED_2026
func random() -> CGFloat {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return CGFloat((seed >> 33) % 10_000) / 10_000
}

let cell: CGFloat = 38
let rows = 10
let columns = 10
for column in 0..<columns {
    let progress = CGFloat(column) / CGFloat(columns - 1)
    for row in 0..<rows {
        let x = cut + CGFloat(column) * cell
        let y = tile.minY + CGFloat(row) * cell
        let center = CGPoint(x: x + cell / 2, y: y + cell / 2)
        // Dentro del azulejo los píxeles siguen su forma; fuera, se dispersan.
        let inside = tilePath.contains(center)
        if !inside && center.x < tile.maxX { continue }
        let keep = column < 2 ? 1 : 1 - progress * 0.88
        guard random() < keep else { continue }
        let side = (cell - 4) * (1 - progress * 0.62)
        let drift = progress * progress * 26 * (random() - 0.35)
        let lift = progress * 30 * (random() - 0.5)
        let rect = CGRect(x: center.x - side / 2 + drift, y: center.y - side / 2 + lift, width: side, height: side)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.22, cornerHeight: side * 0.22, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 1 - progress * 0.78))
        ctx.fillPath()
    }
}
ctx.restoreGState()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
