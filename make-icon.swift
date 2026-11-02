// Draws YTD's app icon at every size an .iconset needs: a single red play
// triangle with soft corners on a whitish rounded square, placed on Apple's
// icon grid (the square takes 824 of 1024 points, leaving room for its
// shadow). Run by build.sh: make-icon <folder>.iconset
import CoreGraphics
import Foundation
import ImageIO

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // the square: white at the top, a breath of grey at the bottom, with a
    // soft shadow beneath and a hairline edge so it holds up on a white Dock
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let square = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.22))
    context.addPath(square)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(square)
    context.clip()
    let shade = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xECECEF)] as CFArray,
                           locations: [0, 1])!
    context.drawLinearGradient(shade, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY),
                               options: [])
    context.restoreGState()
    context.addPath(square)
    context.setStrokeColor(color(0x000000, 0.08))
    context.setLineWidth(3)
    context.strokePath()

    // the play triangle, nudged right of centre so it looks centred; a wide
    // round-joined stroke in the same red gives it soft corners
    let height: CGFloat = 330
    let width = height * 0.9
    let left = 512 - width / 2 + 22
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: left, y: 512 + height / 2))
    triangle.addLine(to: CGPoint(x: left + width, y: 512))
    triangle.addLine(to: CGPoint(x: left, y: 512 - height / 2))
    triangle.closeSubpath()
    context.addPath(triangle)
    context.setFillColor(color(0xFF3B30))
    context.setStrokeColor(color(0xFF3B30))
    context.setLineWidth(60)
    context.setLineJoin(.round)
    context.drawPath(using: .fillStroke)

    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("wrote \(folder.path)")
