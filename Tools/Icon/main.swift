// Generates the MCP Manager app icon: the sculpted Orc icon worn as a plug,
// with chrome prongs on the crown and a teal cable trailing from the chin.
//
// usage: make-icon <orc-base-icon-1024.png> <out.png>

import AppKit

let side = 1024
let full = CGRect(x: 0, y: 0, width: side, height: side)
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

// Drawing code works top-down like the artwork; CoreGraphics is bottom-up.
func makeLayer(flipped: Bool = true) -> CGContext {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side * 4, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot allocate a bitmap") }
    ctx.interpolationQuality = .high
    if flipped {
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
    }
    return ctx
}

// Shadow offsets ignore the CTM, so a downward offset is negative in device space.
func drop(_ dx: CGFloat, _ dy: CGFloat) -> CGSize { CGSize(width: dx, height: -dy) }

// A blurred fill: the shape is drawn far off-canvas and only its shadow lands.
func soft(_ ctx: CGContext, _ path: CGPath, blur: CGFloat, _ fill: CGColor) {
    let far: CGFloat = 8192
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: far, height: 0), blur: blur, color: fill)
    ctx.translateBy(x: -far, y: 0)
    ctx.addPath(path)
    ctx.setFillColor(color(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
}

func softStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, blur: CGFloat,
                _ fill: CGColor, dx: CGFloat = 0, dy: CGFloat = 0) {
    var shift = CGAffineTransform(translationX: dx, y: dy)
    let moved = path.copy(using: &shift) ?? path
    soft(ctx, moved.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4),
         blur: blur, fill)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.1) as CFArray,
               locations: stops.map(\.0))!
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xff) / 255 }
    func lerp(_ s: UInt32) -> CGFloat { ch(a, s) + (ch(b, s) - ch(a, s)) * t }
    return CGColor(srgbRed: lerp(16), green: lerp(8), blue: lerp(0), alpha: 1)
}

// MARK: - Base artwork and head mask

let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make-icon <orc-base-icon-1024.png> <out.png>") }
guard let baseData = FileManager.default.contents(atPath: args[1]),
      let baseRep = NSBitmapImageRep(data: baseData),
      let baseImage = baseRep.cgImage,
      baseImage.width == side, baseImage.height == side
else { fail("\(args[1]) is not a \(side)x\(side) image") }

let n = side * side
let source = makeLayer(flipped: false)
source.draw(baseImage, in: full)
let sourcePixels = source.data!.bindMemory(to: UInt8.self, capacity: n * 4)

// The flood from the border crosses only the dark, neutral slab, so the head's
// highlights, eyes and tusks stay inside it; greenness softens its outline.
var solid = [Float](repeating: 0, count: n)
do {
    var edge = [Float](repeating: 0, count: n)
    var passable = [Bool](repeating: false, count: n)
    for i in 0..<n {
        let r = Int(sourcePixels[i * 4]), g = Int(sourcePixels[i * 4 + 1])
        let b = Int(sourcePixels[i * 4 + 2]), a = Int(sourcePixels[i * 4 + 3])
        let green = g - max(r, b)
        let t = Float(min(max(Double(green - 8) / 20, 0), 1))
        edge[i] = t * t * (3 - 2 * t)
        passable[i] = a < 128 || (green < 6 && max(r, g, b) < 120)
    }
    var reached = [Bool](repeating: false, count: n)
    var queue = [Int]()
    for x in 0..<side { queue += [x, (side - 1) * side + x] }
    for y in 0..<side { queue += [y * side, y * side + side - 1] }
    while let i = queue.popLast() {
        guard !reached[i], passable[i] else { continue }
        reached[i] = true
        let x = i % side, y = i / side
        if x > 0 { queue.append(i - 1) }
        if x < side - 1 { queue.append(i + 1) }
        if y > 0 { queue.append(i - side) }
        if y < side - 1 { queue.append(i + side) }
    }
    // The slab's bright rim highlights are unreachable too, so the head is only
    // the enclosed region that holds the middle of the artwork.
    var inHead = [Bool](repeating: false, count: n)
    queue = [(side / 2) * side + side / 2]
    while let i = queue.popLast() {
        guard !inHead[i], !reached[i] else { continue }
        inHead[i] = true
        let x = i % side, y = i / side
        if x > 0 { queue.append(i - 1) }
        if x < side - 1 { queue.append(i + 1) }
        if y > 0 { queue.append(i - side) }
        if y < side - 1 { queue.append(i + side) }
    }
    for i in 0..<n { solid[i] = inHead[i] ? 1 : (reached[i] ? edge[i] : 0) }
}

func distanceField(from seeds: [Bool]) -> [Float] {
    var distance = seeds.map { $0 ? Float(0) : Float.greatestFiniteMagnitude }
    let diagonal = Float(2).squareRoot()
    for y in 0..<side { for x in 0..<side {
        var d = distance[y * side + x]
        if x > 0 { d = min(d, distance[y * side + x - 1] + 1) }
        if y > 0 { d = min(d, distance[(y - 1) * side + x] + 1) }
        if x > 0 && y > 0 { d = min(d, distance[(y - 1) * side + x - 1] + diagonal) }
        if x < side - 1 && y > 0 { d = min(d, distance[(y - 1) * side + x + 1] + diagonal) }
        distance[y * side + x] = d
    } }
    for y in stride(from: side - 1, through: 0, by: -1) {
        for x in stride(from: side - 1, through: 0, by: -1) {
            var d = distance[y * side + x]
            if x < side - 1 { d = min(d, distance[y * side + x + 1] + 1) }
            if y < side - 1 { d = min(d, distance[(y + 1) * side + x] + 1) }
            if x < side - 1 && y < side - 1 { d = min(d, distance[(y + 1) * side + x + 1] + diagonal) }
            if x > 0 && y < side - 1 { d = min(d, distance[(y + 1) * side + x - 1] + diagonal) }
            distance[y * side + x] = d
        }
    }
    return distance
}

// The head is redrawn smaller to make room for the plug, so the slab behind it
// (and the original head's shadow) is rebuilt by push-pull hole filling.
func pushPull(_ color: [SIMD4<Float>], _ weight: [Float], _ w: Int, _ h: Int) -> [SIMD4<Float>] {
    if w == 1 && h == 1 { return color }
    let w2 = (w + 1) / 2, h2 = (h + 1) / 2
    var coarse = [SIMD4<Float>](repeating: .zero, count: w2 * h2)
    var coarseWeight = [Float](repeating: 0, count: w2 * h2)
    for y in 0..<h { for x in 0..<w {
        let j = (y / 2) * w2 + x / 2
        coarse[j] += color[y * w + x] * weight[y * w + x]
        coarseWeight[j] += weight[y * w + x]
    } }
    for j in 0..<(w2 * h2) where coarseWeight[j] > 0 {
        coarse[j] /= coarseWeight[j]
        coarseWeight[j] = min(coarseWeight[j], 1)
    }
    let filled = pushPull(coarse, coarseWeight, w2, h2)
    func at(_ x: Int, _ y: Int) -> SIMD4<Float> {
        filled[min(max(y, 0), h2 - 1) * w2 + min(max(x, 0), w2 - 1)]
    }
    var out = color
    for y in 0..<h { for x in 0..<w {
        let i = y * w + x
        guard weight[i] < 1 else { continue }
        let fx = (Float(x) + 0.5) / 2 - 0.5, fy = (Float(y) + 0.5) / 2 - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
        let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
        out[i] = color[i] * weight[i] + (top * (1 - ty) + bottom * ty) * (1 - weight[i])
    } }
    return out
}

let plate: CGImage = {
    let fromHead = distanceField(from: solid.map { $0 > 0.02 })
    // The slab's bevel is kept as drawn: filling it would smear the rim highlight.
    let fromRim = distanceField(from: (0..<n).map { sourcePixels[$0 * 4 + 3] < 128 })
    var pixels = [SIMD4<Float>](repeating: .zero, count: n)
    var known = [Float](repeating: 0, count: n)
    for i in 0..<n {
        pixels[i] = SIMD4(Float(sourcePixels[i * 4]), Float(sourcePixels[i * 4 + 1]),
                          Float(sourcePixels[i * 4 + 2]), Float(sourcePixels[i * 4 + 3]))
        let opaque = sourcePixels[i * 4 + 3] > 250
        known[i] = opaque && (fromHead[i] > 44 || (fromRim[i] < 48 && fromHead[i] > 14)) ? 1 : 0
    }
    var filled = pushPull(pixels, known, side, side)
    // Where the old ear tips touched the side bevel, the bevel runs vertically,
    // so bridging each column keeps its highlight straight.
    for x in 0..<side {
        var y = 0
        while y < side {
            let i = y * side + x
            guard known[i] < 1, fromRim[i] < 64, y > 0, known[i - side] == 1 else {
                y += 1
                continue
            }
            var end = y
            while end < side - 1 && known[end * side + x] < 1 { end += 1 }
            guard known[end * side + x] == 1 else { y = end + 1; continue }
            let above = pixels[(y - 1) * side + x], below = pixels[end * side + x]
            for k in y..<end {
                let j = k * side + x
                let t = Float(k - y + 1) / Float(end - y + 1)
                let edge = min(max((64 - fromRim[j]) / 24, 0), 1)
                filled[j] = filled[j] * (1 - edge) + (above * (1 - t) + below * t) * edge
            }
            y = end
        }
    }
    let layer = makeLayer(flipped: false)
    let out = layer.data!.bindMemory(to: UInt8.self, capacity: n * 4)
    for i in 0..<n {
        let alpha = Float(sourcePixels[i * 4 + 3])
        guard known[i] < 1, alpha > 250 else {
            for c in 0..<4 { out[i * 4 + c] = sourcePixels[i * 4 + c] }
            continue
        }
        let p = (filled[i] * (alpha / 255)).clamped(lowerBound: .zero,
                                                    upperBound: SIMD4(repeating: 255))
        for c in 0..<3 { out[i * 4 + c] = UInt8(p[c].rounded()) }
        out[i * 4 + 3] = sourcePixels[i * 4 + 3]
    }
    return layer.makeImage()!
}()

let head: CGImage = {
    let layer = makeLayer(flipped: false)
    let out = layer.data!.bindMemory(to: UInt8.self, capacity: n * 4)
    for i in 0..<(n * 4) { out[i] = UInt8((Float(sourcePixels[i]) * solid[i / 4]).rounded()) }
    return layer.makeImage()!
}()

let headScale: CGFloat = 0.85
let headCenterY: CGFloat = 540
// Device space is bottom-up, so the top-down centre is mirrored here.
let headRect = CGRect(x: 512 - 512 * headScale, y: CGFloat(side) - headCenterY - 512 * headScale,
                      width: CGFloat(side) * headScale, height: CGFloat(side) * headScale)

func grayImage(_ bytes: [UInt8]) -> CGImage {
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8,
                   bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                   bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

let headness: [UInt8] = {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                              bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { fail("cannot allocate a mask") }
    ctx.interpolationQuality = .high
    ctx.draw(grayImage(solid.map { UInt8(($0 * 255).rounded()) }), in: headRect)
    let px = ctx.data!.bindMemory(to: UInt8.self, capacity: n)
    return Array(UnsafeBufferPointer(start: px, count: n))
}()

let canvas = makeLayer(flipped: false)
canvas.draw(plate, in: full)
// Everything added sits on the slab, so nothing (shadows included) may spill past it.
canvas.clip(to: full, mask: grayImage((0..<n).map { sourcePixels[$0 * 4 + 3] }))
canvas.saveGState()
canvas.setShadow(offset: drop(14, 30), blur: 46, color: color(0x000000, 0.6))
canvas.draw(head, in: headRect)
canvas.restoreGState()
canvas.saveGState()
canvas.setShadow(offset: drop(3, 7), blur: 9, color: color(0x000000, 0.45))
canvas.draw(head, in: headRect)
canvas.restoreGState()

func isHead(x: Int, y: Int) -> Bool { headness[y * side + x] > 127 }

let outsideHead = grayImage(headness.map { 255 - $0 })

let headSilhouette: CGImage = {
    let layer = makeLayer(flipped: false)
    layer.saveGState()
    layer.clip(to: full, mask: grayImage(headness))
    layer.setFillColor(color(0x000000))
    layer.fill(full)
    layer.restoreGState()
    return layer.makeImage()!
}()

func headTop(atX x: Int) -> Int {
    for y in 0..<side where isHead(x: x, y: y) { return y }
    fail("no head found at x=\(x)")
}

func headBottom(atX x: Int) -> Int {
    for y in stride(from: side - 1, through: 0, by: -1) where isHead(x: x, y: y) { return y }
    fail("no head found at x=\(x)")
}

// MARK: - Cable and connector

let cableWidth: CGFloat = 58
let nodeRadius: CGFloat = 68

func tube(_ ctx: CGContext, _ path: CGPath, width w: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path.copy(strokingWithWidth: w, lineCap: .butt, lineJoin: .round, miterLimit: 4))
    ctx.clip()
    ctx.setLineCap(.round)
    let steps = 40
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps - 1)
        ctx.setLineWidth(w * (1.04 - 0.9 * t))
        ctx.setStrokeColor(t < 0.5 ? mix(0x0b3832, 0x36b3a3, t * 2)
                                    : mix(0x36b3a3, 0x9df0e3, (t - 0.5) * 2))
        ctx.addPath(path)
        ctx.strokePath()
    }
    softStroke(ctx, path, width: w * 0.55, blur: w * 0.3, color(0x0b2421, 0.6),
               dx: w * 0.26, dy: w * 0.3)
    softStroke(ctx, path, width: w * 0.3, blur: w * 0.18, color(0xe8fffb, 0.45),
               dx: -w * 0.16, dy: -w * 0.2)
    softStroke(ctx, path, width: w * 0.09, blur: 1.6, color(0xffffff, 0.9),
               dx: -w * 0.17, dy: -w * 0.22)
    ctx.restoreGState()
}

func chromeBand(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = hypot(dx, dy)
    ctx.saveGState()
    ctx.translateBy(x: a.x, y: a.y)
    ctx.rotate(by: atan2(dy, dx))
    let body = CGPath(roundedRect: CGRect(x: 0, y: -width / 2, width: len, height: width),
                      cornerWidth: 5, cornerHeight: 5, transform: nil)
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xf5f8fa)), (0.22, color(0xd9dfe4)),
                                     (0.55, color(0x8a939b)), (0.8, color(0x5b636b)),
                                     (1, color(0x3a4047))]),
                           start: CGPoint(x: 0, y: -width / 2), end: CGPoint(x: 0, y: width / 2),
                           options: [])
    for ridge in stride(from: len * 0.25, to: len, by: len * 0.25) {
        ctx.setFillColor(color(0x2b3036, 0.35))
        ctx.fill(CGRect(x: ridge - 1.5, y: -width / 2, width: 3, height: width))
    }
    ctx.restoreGState()
}

func node(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat) {
    let disc = CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                      transform: nil)
    ctx.saveGState()
    ctx.addPath(disc)
    ctx.clip()
    let light = CGPoint(x: c.x - r * 0.38, y: c.y - r * 0.42)
    ctx.drawRadialGradient(gradient([(0, color(0xd2f7f1)), (0.35, color(0x52c4b4)),
                                     (0.75, color(0x1f8a7c)), (1, color(0x0f3a35))]),
                           startCenter: light, startRadius: 0, endCenter: c, endRadius: r * 1.08,
                           options: [.drawsAfterEndLocation])
    // Bounce light from the slab keeps the shadow side round instead of flat.
    soft(ctx, CGPath(ellipseIn: CGRect(x: c.x - r * 0.1, y: c.y + r * 0.55, width: r * 1.1,
                                        height: r * 0.7), transform: nil),
         blur: r * 0.25, color(0x8fd1c9, 0.35))
    let ring = CGPath(ellipseIn: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.5, width: r, height: r),
                      transform: nil)
    ctx.addPath(ring)
    ctx.setStrokeColor(color(0x183532, 0.85))
    ctx.setLineWidth(r * 0.12)
    ctx.strokePath()
    var down = CGAffineTransform(translationX: r * 0.035, y: r * 0.05)
    ctx.addPath(ring.copy(using: &down)!)
    ctx.setStrokeColor(color(0xbfe6e0, 0.55))
    ctx.setLineWidth(r * 0.04)
    ctx.strokePath()
    let pin = CGRect(x: c.x - r * 0.17, y: c.y - r * 0.17, width: r * 0.34, height: r * 0.34)
    ctx.addEllipse(in: pin)
    ctx.setFillColor(color(0x13201f))
    ctx.fillPath()
    ctx.addEllipse(in: pin.insetBy(dx: r * 0.05, dy: r * 0.05)
        .offsetBy(dx: r * 0.03, dy: r * 0.04))
    ctx.setStrokeColor(color(0x9fb0ae, 0.5))
    ctx.setLineWidth(1.5)
    ctx.strokePath()
    soft(ctx, CGPath(ellipseIn: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.78, width: r * 0.62,
                                        height: r * 0.4), transform: nil),
         blur: r * 0.1, color(0xffffff, 0.85))
    ctx.restoreGState()
}

let chinX = 530
let chinY = CGFloat(headBottom(atX: chinX))
let cableStart = CGPoint(x: CGFloat(chinX), y: chinY - 60)
let cableEnd = CGPoint(x: 784, y: chinY + 46)
let cableC1 = CGPoint(x: CGFloat(chinX) - 14, y: chinY + 94)
let cableC2 = CGPoint(x: 700, y: chinY + 86)
let tangent: CGPoint = {
    let dx = cableEnd.x - cableC2.x, dy = cableEnd.y - cableC2.y
    let len = hypot(dx, dy)
    return CGPoint(x: dx / len, y: dy / len)
}()
let ferruleLength: CGFloat = 34
let ferruleEnd = CGPoint(x: cableEnd.x + tangent.x * ferruleLength,
                         y: cableEnd.y + tangent.y * ferruleLength)
let nodeCenter = CGPoint(x: ferruleEnd.x + tangent.x * nodeRadius * 0.82,
                         y: ferruleEnd.y + tangent.y * nodeRadius * 0.82)

let cablePath: CGPath = {
    let p = CGMutablePath()
    p.move(to: cableStart)
    p.addCurve(to: cableEnd, control1: cableC1, control2: cableC2)
    return p
}()

let cableLayer: CGImage = {
    let ctx = makeLayer()
    let outline = CGMutablePath()
    outline.addPath(cablePath.copy(strokingWithWidth: cableWidth, lineCap: .butt,
                                   lineJoin: .round, miterLimit: 4))
    outline.addPath(CGPath(roundedRect: CGRect(x: -ferruleLength - 2, y: -cableWidth * 0.62,
                                               width: ferruleLength + 4, height: cableWidth * 1.24),
                           cornerWidth: 5, cornerHeight: 5,
                           transform: [CGAffineTransform(rotationAngle: atan2(tangent.y, tangent.x))
                               .concatenating(CGAffineTransform(translationX: ferruleEnd.x,
                                                                y: ferruleEnd.y))]))
    outline.addEllipse(in: CGRect(x: nodeCenter.x - nodeRadius, y: nodeCenter.y - nodeRadius,
                                  width: nodeRadius * 2, height: nodeRadius * 2))

    // A wide soft shadow plus a tight contact shadow so the cable lies on the slab.
    ctx.saveGState()
    ctx.setShadow(offset: drop(16, 22), blur: 26, color: color(0x000000, 0.6))
    ctx.addPath(outline)
    ctx.setFillColor(color(0x101114))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: drop(3, 5), blur: 5, color: color(0x000000, 0.7))
    ctx.addPath(outline)
    ctx.setFillColor(color(0x101114))
    ctx.fillPath()
    ctx.restoreGState()

    tube(ctx, cablePath, width: cableWidth)
    chromeBand(ctx, from: cableEnd.applying(.init(translationX: -tangent.x * 2, y: -tangent.y * 2)),
               to: ferruleEnd.applying(.init(translationX: tangent.x * 10, y: tangent.y * 10)),
               width: cableWidth * 1.24)
    node(ctx, center: nodeCenter, radius: nodeRadius)

    // The head shades the cable where it slips out from under the chin.
    ctx.saveGState()
    ctx.setBlendMode(.sourceAtop)
    ctx.translateBy(x: 0, y: CGFloat(side))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setShadow(offset: drop(10, 18), blur: 22, color: color(0x000000, 0.75))
    ctx.draw(headSilhouette, in: full)
    ctx.restoreGState()
    return ctx.makeImage()!
}()

canvas.saveGState()
canvas.clip(to: full, mask: outsideHead)
canvas.draw(cableLayer, in: full)
canvas.restoreGState()

// MARK: - Prongs

let prongWidth: CGFloat = 62
let prongTop: CGFloat = 60
let prongSpacing: CGFloat = 88

func prong(_ ctx: CGContext, centerX cx: CGFloat) {
    let baseY = CGFloat(headTop(atX: Int(cx))) + 20
    let w = prongWidth, half = prongWidth / 2
    let footDepth: CGFloat = 8
    let body = CGMutablePath()
    body.move(to: CGPoint(x: cx - half, y: baseY))
    body.addLine(to: CGPoint(x: cx - half, y: prongTop + 16))
    body.addQuadCurve(to: CGPoint(x: cx - half + 16, y: prongTop),
                      control: CGPoint(x: cx - half, y: prongTop))
    body.addLine(to: CGPoint(x: cx + half - 16, y: prongTop))
    body.addQuadCurve(to: CGPoint(x: cx + half, y: prongTop + 16),
                      control: CGPoint(x: cx + half, y: prongTop))
    body.addLine(to: CGPoint(x: cx + half, y: baseY))
    body.addQuadCurve(to: CGPoint(x: cx - half, y: baseY),
                      control: CGPoint(x: cx, y: baseY + footDepth * 2))
    body.closeSubpath()

    soft(ctx, CGPath(ellipseIn: CGRect(x: cx - half - 6, y: baseY - 6, width: w + 30, height: 26),
                     transform: nil),
         blur: 10, color(0x0f2a0c, 0.6))
    ctx.saveGState()
    ctx.setShadow(offset: drop(18, 16), blur: 16, color: color(0x000000, 0.45))
    ctx.addPath(body)
    ctx.setFillColor(color(0x5b636b))
    ctx.fillPath()
    ctx.restoreGState()

    let socket = CGRect(x: cx - half - 8, y: baseY - 9, width: w + 16, height: 22)
    ctx.addEllipse(in: socket)
    ctx.setFillColor(color(0x223d1c))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addEllipse(in: socket)
    ctx.clip()
    softStroke(ctx, CGPath(ellipseIn: socket, transform: nil), width: 4, blur: 2,
               color(0x9ccc6e, 0.7), dx: 1, dy: 3)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0x8d969e)), (0.1, color(0xeef2f5)),
                                     (0.24, color(0xfbfdfe)), (0.42, color(0xbfc7ce)),
                                     (0.62, color(0x7c858e)), (0.78, color(0x9aa3ab)),
                                     (0.92, color(0x575f67)), (1, color(0x363b41))]),
                           start: CGPoint(x: cx - half, y: 0), end: CGPoint(x: cx + half, y: 0),
                           options: [])
    // Green bounce from the head and occlusion where the prong enters it.
    ctx.drawLinearGradient(gradient([(0, color(0x6fae45, 0)), (0.7, color(0x5d9a38, 0.28)),
                                     (1, color(0x1d3417, 0.7))]),
                           start: CGPoint(x: 0, y: baseY - 46), end: CGPoint(x: 0, y: baseY + 8),
                           options: [])
    ctx.drawLinearGradient(gradient([(0, color(0xffffff, 0.75)), (1, color(0xffffff, 0))]),
                           start: CGPoint(x: 0, y: prongTop), end: CGPoint(x: 0, y: prongTop + 14),
                           options: [])
    let streak = CGMutablePath()
    streak.move(to: CGPoint(x: cx - w * 0.27, y: prongTop + 10))
    streak.addLine(to: CGPoint(x: cx - w * 0.27, y: baseY - 26))
    softStroke(ctx, streak, width: 5, blur: 2, color(0xffffff, 0.95))
    let rim = CGMutablePath()
    rim.move(to: CGPoint(x: cx + w * 0.33, y: prongTop + 14))
    rim.addLine(to: CGPoint(x: cx + w * 0.33, y: baseY - 30))
    softStroke(ctx, rim, width: 3, blur: 2, color(0xe4eaee, 0.4))

    let hole = CGRect(x: cx - 10, y: prongTop + 22, width: 20, height: 20)
    ctx.addEllipse(in: hole)
    ctx.setFillColor(color(0x15181c))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addEllipse(in: hole)
    ctx.clip()
    softStroke(ctx, CGPath(ellipseIn: hole, transform: nil), width: 4, blur: 1.5,
               color(0xb8c0c7, 0.75), dx: 2, dy: 3)
    ctx.restoreGState()
    softStroke(ctx, CGPath(ellipseIn: hole.insetBy(dx: -2, dy: -2), transform: nil), width: 2,
               blur: 1, color(0x2e3439, 0.45), dx: -1, dy: -1)

    ctx.addPath(body)
    ctx.setStrokeColor(color(0x1f2428, 0.55))
    ctx.setLineWidth(2)
    ctx.strokePath()
    ctx.restoreGState()
}

do {
    canvas.saveGState()
    canvas.translateBy(x: 0, y: CGFloat(side))
    canvas.scaleBy(x: 1, y: -1)
    prong(canvas, centerX: 512 - prongSpacing)
    prong(canvas, centerX: 512 + prongSpacing)
    canvas.restoreGState()
}

// MARK: - Output

guard let png = NSBitmapImageRep(cgImage: canvas.makeImage()!)
    .representation(using: .png, properties: [:])
else { fail("PNG encoding failed") }
do {
    try png.write(to: URL(fileURLWithPath: args[2]))
} catch {
    fail("cannot write \(args[2]): \(error.localizedDescription)")
}
