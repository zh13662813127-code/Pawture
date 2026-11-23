import CoreGraphics
import Foundation
import DesktopCatsCore
import simd

private typealias V = SIMD2<Double>
private typealias Ink = SIMD4<Double>

private func mix<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ t: T) -> T { a + (b - a) * t }
private func unit(_ v: V) -> V { v / max(0.001, simd_length(v)) }
private func normal(_ v: V) -> V { V(-v.y, v.x) }
private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
private func soft(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = clamp01((x-a)/(b-a))
    return t*t*(3-2*t)
}

private let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
private let rgba = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big)

/// Texture coordinates and rig landmarks both use a top-left origin.
private struct Coat {
    let pixels: [UInt8], width: Int, height: Int
    let joints: [CatJoint: V]
    let hip: V, neck: V, flank: V, along: V, across: V, length: Double
    let safeX, safeY: ClosedRange<Double>
    let eyeCenter: V, eyeAxis: V, eyeDown: V, eyeDistance: Double

    init?(image: CGImage, blueprint: CatRigBlueprint) {
        let reduction = min(1.0, 900.0 / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width)*reduction)), h = max(1, Int(Double(image.height)*reduction))
        var data = [UInt8](repeating: 0, count: 4*w*h)
        let ok = data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w*4, space: rgb,
                                          bitmapInfo: rgba.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w; height = h; pixels = data
        let points = blueprint.joints.mapValues { V($0.x*Double(w), $0.y*Double(h)) }
        joints = points
        guard let muzzle = points[.nose] ?? points[.neck] else { return nil }
        let estimated = Double(min(w,h))*0.115
        let midEar = (points[.leftEarBottom] ?? muzzle) + (points[.rightEarBottom] ?? muzzle)
        let estimateCenter = points[.leftEarBottom] != nil && points[.rightEarBottom] != nil
            ? (muzzle + midEar * 0.5)*0.5 : muzzle - V(0,estimated*0.38)
        var left = points[.rightEye] ?? estimateCenter - V(estimated*0.5,0)
        var right = points[.leftEye] ?? estimateCenter + V(estimated*0.5,0)
        if right.x < left.x { swap(&right, &left) }
        eyeCenter = (left+right)*0.5
        let separation = simd_distance(left,right)
        eyeDistance = max(estimated * 0.6, separation)
        eyeAxis = separation > 2 ? unit(right-left) : V(1,0)
        eyeDown = normal(eyeAxis)
        neck = points[.neck] ?? (muzzle + eyeDown * eyeDistance * 0.8)
        hip = points[.tailBottom] ?? points[.leftBackElbow] ?? (neck + V(-0.18*Double(w),0.22*Double(h)))
        along = unit(neck-hip)
        var perpendicular = normal(along)
        if perpendicular.y < 0 { perpendicular = -perpendicular }
        across = perpendicular
        length = max(simd_distance(hip,neck), eyeDistance*2)
        let center = (hip+neck)*0.5 + perpendicular*length*0.105
        flank = center
        let torsoLength = length
        func travel(_ axis: V) -> Double {
            var safe = 0.01
            for i in 1...60 {
                let distance = Double(i)/100
                let p = center+axis*distance*torsoLength
                guard p.x >= 0, p.x < Double(w), p.y >= 0, p.y < Double(h) else { break }
                let index = (Int(p.y)*w+Int(p.x))*4
                if data[index+3] < 244 { break }
                safe = distance
            }
            return safe*0.75
        }
        let fore = unit(neck-hip)
        safeX = -travel(-fore)...travel(fore)
        safeY = -travel(-perpendicular)...travel(perpendicular)
    }

    func inside(_ p: V) -> Bool { p.x >= 0 && p.x < Double(width) && p.y >= 0 && p.y < Double(height) }

    func sample(_ p: V) -> Ink {
        let x = min(width-1, max(0, Int(p.x))), y = min(height-1, max(0, Int(p.y)))
        let i = (x+y*width)*4
        let opacity = Double(pixels[i+3])/255
        let divisor = max(opacity, 0.001)
        return Ink(Double(pixels[i])/divisor, Double(pixels[i+1])/divisor,
                   Double(pixels[i+2])/divisor, opacity)
    }

    func fur(_ u: Double, _ v: Double) -> Ink {
        func bounded(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            let limit = max(0.008, value < 0 ? -range.lowerBound : range.upperBound)
            return limit*tanh(value/limit)
        }
        let offset = length * (along*bounded(u*0.78,safeX) + across*bounded(v*0.46,safeY))
        var col = sample(flank + offset)
        if col.w < 0.9 { col = sample(flank+offset*0.45) }
        if col.w < 0.9 { col = sample(neck) }
        return col
    }

    func face(_ local: V, eyelid: Double) -> Ink {
        let p = eyeCenter + eyeDistance * (eyeAxis * local.x + eyeDown * local.y)
        guard inside(p) else { return .zero }
        var col = sample(p)
        if col.w < 0.012 { return .zero }
        // The upper row follows the original transparent ear silhouette. Below
        // the cheeks an ellipse tapers the neck softly into the posed shoulder.
        let side = local.x / 1.37, chin = (local.y+0.05) / 1.10
        let cheekMask = 1-soft(0.84,1.07, sqrt(side*side + max(chin,0)*max(chin,0)))
        let earMask = 1-soft(1.27,1.54,abs(local.x))
        let mask = mix(earMask,cheekMask,soft(-0.65,-0.10,local.y))
        col.w *= mask
        if eyelid > 0 {
            // Re-project fur from the brow down onto each lid. A narrow curved
            // crease closes the photographic eyes while preserving coat markings.
            let dx = abs(local.x) - simd_distance(
                joints[.rightEye] ?? (eyeCenter-eyeAxis*eyeDistance*0.5), eyeCenter
            )/eyeDistance
            let dy = local.y
            let r = sqrt(pow(dx/0.295,2) + pow(dy/0.23,2))
            if r < 1.14 {
                let underLid = sample(p - eyeDown*eyeDistance*(0.37 + dy*0.5))
                let blend = eyelid*(1-soft(0.89,1.14,r))
                let creaseY = 0.030 - 0.65*dx*dx - dx*0.05
                let crease = (1-soft(0.003,0.024,abs(dy-creaseY))) * (1-soft(0.16,0.245,abs(dx)))
                let shade = (1-crease*0.74) * (0.94+0.08*soft(-0.15,0.15,dy))
                for channel in 0..<3 { col[channel] = mix(col[channel], underLid[channel]*shade, blend) }
            }
        }
        return col
    }

    var earHinge: (V, V)? {
        let names: [(CatJoint,CatJoint)] = [(.rightEarBottom,.rightEarTop),(.leftEarBottom,.leftEarTop)]
        for (base,tip) in names {
            guard let b = joints[base], let e = joints[tip], simd_length(b-e)>eyeDistance*0.21 else { continue }
            func local(_ p: V) -> V {
                let v = (p-eyeCenter)/eyeDistance
                return V(simd_dot(v,eyeAxis),simd_dot(v,eyeDown))
            }
            return (local(b),local(e))
        }
        return nil
    }
}

private func bitmap(_ size: Int, paint: (V) -> Ink) -> CGImage? {
    var bytes = [UInt8](repeating: 0, count: size*size*4)
    for y in 0..<size {
        for x in 0..<size {
            let color = paint(V(Double(x)+0.5,Double(y)+0.5))
            let alpha = clamp01(color.w)
            let i = 4*(x+y*size)
            for c in 0..<3 { bytes[i+c] = UInt8(min(255,max(0,color[c]*alpha))) }
            bytes[i+3] = UInt8(255*alpha)
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: size*4, space: rgb, bitmapInfo: rgba, provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// A cubic centreline carries the texture down each folded limb or around the
/// resting torso. Thickness and surface lighting vary from root to tip.
private struct Tube {
    struct Segment { let p: V, d: V, invLengthSquared: Double, start: Double }
    let segments: [Segment], steps = 28
    let root: Double, tip: Double, bulge: Double, wrist: Double
    let origin: V, end: V, endDirection: V
    let bounds: CGRect

    init(_ a: V,_ b: V,_ c: V,_ d: V, root: Double, tip: Double, bulge: Double = 0, wrist: Double = 0) {
        self.root = root; self.tip = tip; self.bulge = bulge; self.wrist = wrist
        origin = a; end = d; endDirection = unit(d-c)
        let count = 28
        var segments = [Segment](), previous = a
        for i in 1...count {
            let t = Double(i)/Double(count), s = 1-t
            let first = a * (s*s*s) + b * (3*s*s*t)
            let end = first + c * (3*s*t*t) + d * (t*t*t)
            let delta = end-previous
            segments.append(Segment(p: previous, d: delta, invLengthSquared: 1/max(0.00001,simd_length_squared(delta)), start: Double(i-1)/Double(count)))
            previous = end
        }
        self.segments = segments
        let r = max(root,tip)+abs(bulge)+2
        let points = [a,b,c,d]
        let x = points.map(\.x), y = points.map(\.y)
        bounds = CGRect(x: x.min()!-r,y: y.min()!-r,width: x.max()!-x.min()!+2*r,height: y.max()!-y.min()!+2*r)
    }

    func surface(_ p: V) -> (t: Double, side: Double, thickness: Double, alpha: Double)? {
        guard bounds.contains(CGPoint(x:p.x,y:p.y)) else { return nil }
        var best = Double.infinity, t = 0.0, side = 0.0, radius = 1.0
        var shape = Double.infinity
        for s in segments {
            let fraction = clamp01(simd_dot(p-s.p,s.d) * s.invLengthSquared)
            let u = s.start + fraction/Double(steps)
            let wristStation = max(0,1-abs(u-0.78)/0.20)
            let r = mix(root,tip,u) + bulge*4*u*(1-u) - wrist*wristStation*wristStation
            let delta = p-(s.p+s.d*fraction)
            let distance = simd_length_squared(delta)
            shape = min(shape, distance/(r*r))
            if distance < best {
                best = distance; t = u; radius = r
                side = simd_dot(delta,normal(s.d)) * sqrt(s.invLengthSquared)/r
            }
        }
        let normalized = sqrt(shape)
        guard normalized < 1+2/radius else { return nil }
        let edge = (1-normalized)*radius
        return (t,side,normalized,soft(-0.9,0.75,edge+0.60*nap(p)))
    }
}

/// A small oriented irregularity along the coat outline; texture and lighting
/// come from the photograph rather than procedural stripes.
private func nap(_ p: V) -> Double {
    0.58*sin(p.x*1.10-p.y*0.77+1.1*sin(p.x*0.24)) + 0.32*sin(p.x*2.13+p.y*1.91)
}

/// Resting torsos use an asymmetrical outline through the rump, withers,
/// breast and grounded underside. Its smooth section is sampled only once.
private struct Ribcage {
    var top = Array(repeating: Double.infinity, count: 320)
    var bottom = Array(repeating: -Double.infinity, count: 320)
    init(_ contour: [V]) {
        let n = contour.count
        for i in contour.indices {
            let p = contour[(i+n-1)%n], a = contour[i], b = contour[(i+1)%n], q = contour[(i+2)%n]
            let m = (b-p)*0.42, k = (q-a)*0.42
            var previous = a
            for step in 1...15 {
                let t = Double(step)/15, t2 = t*t, t3 = t2*t
                let base = a*(2*t3-3*t2+1) + b*(-2*t3+3*t2)
                let point = base + m*(t3-2*t2+t) + k*(t3-t2)
                let lo = max(0,Int(ceil(min(previous.x,point.x)-0.5)))
                let hi = min(319,Int(floor(max(previous.x,point.x)-0.5)))
                if lo <= hi, abs(previous.x-point.x)>0.00001 {
                    for column in lo...hi {
                        let f = (Double(column)+0.5-previous.x)/(point.x-previous.x)
                        let y = mix(previous.y,point.y,f)
                        top[column] = min(top[column],y); bottom[column] = max(bottom[column],y)
                    }
                }
                previous = point
            }
        }
    }
    func section(_ p: V) -> (depth: Double, alpha: Double)? {
        let x = min(318,max(1,Int(p.x)))
        let high = top[x], low = bottom[x]
        guard high < low-1 else { return nil }
        let upper = p.y-high, lower = low-p.y
        let section = upper < lower ? top : bottom
        let slope = section[x+1]-section[x-1]
        let distance = min(upper,lower)/sqrt(1+0.25*(slope.isFinite ? slope*slope : 100))
        guard distance > -2.4 else { return nil }
        let grain = 0.48*nap(p)+0.18*sin(0.7*p.x+0.25*p.y+sin(0.086*p.x))
        let alpha = soft(-0.9,0.75,distance+grain)
        return (clamp01(upper/(low-high)),alpha)
    }
}

private enum Surface { case tail, leg(CatJoint, CatJoint) }

private struct EarTurn {
    let pivot, direction: V
    let length: Double

    init?(coat: Coat) {
        guard let (base,tip) = coat.earHinge else { return nil }
        pivot = base; direction = unit(tip-base); length = simd_distance(base,tip)
    }

    func samplePoint(_ p: V, turn: Double) -> V {
        let d = p-pivot
        let t = simd_dot(d,direction)/length
        let across = abs(simd_dot(d,normal(direction)))/length
        let angle = turn*0.34*soft(-0.12,0.58,t)*(1-soft(0.46,0.85,across))
        return pivot + V(d.x*cos(angle)-d.y*sin(angle),d.x*sin(angle)+d.y*cos(angle))
    }
}

private struct PosePiece {
    let image: CGImage
    var anchor = V(160,160)
    var breathing = V.zero
    var sway = 0.0
    var phase = 0.0
    var shift = V.zero
    var enterShift = V.zero
    var enterScale = V.zero
    var enterAngle = 0.0
    var settle = 0.0...1.0
    var eyelids = false
    var isHead = false
    var earTurns: [CGImage] = []
    var pawFold = 0.0
}

/// Original face and photographed fur are used for both views of the rig.
/// Parts are built once; only their small joint transforms are updated per frame.
struct CatRestRenderer: Sendable {
    private let coat: Coat
    private let sleep, loaf, belly: [PosePiece]
    private static let size = 320

    init?(image: CGImage, blueprint: CatRigBlueprint) {
        guard let coat = Coat(image: image, blueprint: blueprint) else { return nil }
        self.coat = coat
        sleep = Self.pieces(coat, pose: .curlSleep)
        loaf = Self.pieces(coat, pose: .loaf)
        belly = Self.pieces(coat, pose: .bellyUp)
        if sleep.isEmpty || belly.isEmpty || loaf.isEmpty { return nil }
    }

    func frame(for motion: CatMotion, phase: Double, unfold: Double = 0) -> CGImage? {
        let parts: [PosePiece]
        switch motion {
        case .curlSleep, .sleepMurmur: parts = sleep
        case .loaf, .loafNuzzle: parts = loaf
        case .bellyUp, .bellyNuzzle: parts = belly
        case .wakeStretch:
            if phase <= 0 { return frame(for:.curlSleep,phase:0) }
            if phase >= 1 { return frame(for:.loaf,phase:0) }
            parts = Self.pieces(coat, pose:motion, stretch:phase)
        default: return nil
        }
        let size = Self.size
        guard let c = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,
                                bytesPerRow:4*size,space:rgb,bitmapInfo:rgba.rawValue) else { return nil }
        c.interpolationQuality = .high
        let murmur = motion == .sleepMurmur
        let restingRub = motion == .loafNuzzle || motion == .bellyNuzzle
        let nuzzle = murmur ? soft(0.10,0.36,phase)*(1-soft(0.58,0.95,phase))
            : (restingRub ? soft(0.06,0.42,phase)*(1-soft(0.58,0.97,phase)) : 0)
        let ear = murmur ? soft(0.00,0.13,phase)*(1-soft(0.16,0.32,phase)) : 0
        for part in parts {
            let opening = 1-soft(part.settle.lowerBound,part.settle.upperBound,1-unfold)
            let wave = sin(((motion == .wakeStretch ? 0 : phase) + part.phase)*2*Double.pi)
            let x = part.anchor.x, y = Double(size)-part.anchor.y
            c.saveGState()
            if part.eyelids {
                if motion == .curlSleep || murmur {
                    c.setAlpha(soft(0.39,0.83,1-unfold))
                } else if motion == .wakeStretch {
                    c.setAlpha(1-soft(0.10,0.34,phase))
                } else {
                    let at = phase-floor(phase)
                    let blink = soft(0.55,0.60,at)*(1-soft(0.63,0.71,at))
                    let atRest = motion == .bellyUp || motion == .bellyNuzzle ? 0 : blink
                    c.setAlpha(max(atRest,restingRub ? 0.85*nuzzle : 0))
                }
            }
            c.translateBy(x:x+part.shift.x*wave+part.enterShift.x*opening, y:y-part.shift.y*wave-part.enterShift.y*opening)
            if part.isHead && nuzzle > 0 {
                let reach = motion == .loafNuzzle ? V(8.4,3.2) : (motion == .bellyNuzzle ? V(-3.2,4.7) : V(3.3,3.8))
                c.translateBy(x:reach.x*nuzzle,y:reach.y*nuzzle)
                c.rotate(by:(restingRub ? 0.145 : 0.082)*nuzzle)
            }
            if motion == .bellyNuzzle && part.pawFold != 0 {
                c.rotate(by:-part.pawFold*nuzzle)
                c.scaleBy(x:1-0.10*nuzzle,y:1-0.10*nuzzle)
            }
            c.rotate(by:-part.sway*wave-part.enterAngle*opening)
            c.scaleBy(x:1+part.breathing.x*wave+part.enterScale.x*opening,y:1+part.breathing.y*wave+part.enterScale.y*opening)
            c.translateBy(x:-x,y:-y)
            let index = Int((ear*Double(part.earTurns.count)).rounded())
            let image = index == 0 ? part.image : part.earTurns[index-1]
            c.draw(image, in:CGRect(x:0,y:0,width:size,height:size))
            c.restoreGState()
        }
        return c.makeImage()
    }

    private static func pieces(_ coat: Coat, pose: CatMotion, stretch: Double = 0) -> [PosePiece] {
        var result = [PosePiece]()
        let sleeping = pose == .curlSleep
        let supine = pose == .bellyUp
        let waking = pose == .wakeStretch
        let progress = waking ? stretch : (sleeping ? 0.0 : 1.0)
        func blend(_ a: V, _ b: V, _ c: V, _ clock: V = V(0.10,0.55),
                   _ release: V = V(0.68,0.97)) -> V {
            let extended = a+(b-a)*soft(clock.x,clock.y,progress)
            return extended+(c-extended)*soft(release.x,release.y,progress)
        }
        func curve(_ a: [V], _ b: [V], _ c: [V], _ widths: [V], bulge: Double = 0,
                   clock: V = V(0.10,0.55), release: V = V(0.68,0.97), wrist: Double = 0) -> Tube {
            let p = (0..<4).map { blend(a[$0], b[$0], c[$0], clock,release) }
            let radii = blend(widths[0],widths[1],widths[2],clock,release)
            return Tube(p[0],p[1],p[2],p[3],root:radii.x,tip:radii.y,bulge:bulge,
                        wrist:wrist*soft(clock.x,clock.y,progress)*(1-soft(release.x,release.y,progress)))
        }
        func shadow(center: V, width: Double, height: Double) {
            guard let image = bitmap(size, paint: { p in
                let broad = pow((p.x-center.x)/width,2) + pow((p.y-center.y)/height,2)
                let close = pow((p.x-center.x+4)/(width*0.8),2) + pow((p.y-center.y+1)/(height*0.39),2)
                let alpha = 0.09*exp(-broad*2.8) + 0.15*exp(-close*2.3)
                return Ink(56,43,40,alpha > 0.005 ? alpha : 0)
            }) else { return }
            result.append(PosePiece(image:image))
        }
        func torso(_ contour: [V], rump: V, shoulder: V, ground: Double) {
            let outline = Ribcage(contour), axis = shoulder-rump
            let lengthSquared = simd_length_squared(axis)
            func chestWeight(_ p: V) -> Double {
                let u = simd_dot(p-rump,axis)/lengthSquared
                return soft(0.29,0.82,u)
            }
            guard let skin = bitmap(size, paint: { p in
                guard let surface = outline.section(p), surface.alpha > 0 else { return .zero }
                let u = simd_dot(p-rump,axis)/lengthSquared
                let v = surface.depth
                let field = u - 0.07*sin((v-0.16)*Double.pi) + 0.035*cos(u*Double.pi)
                var col = coat.fur(field-0.47, (v-0.47)*0.97)
                let upper = 0.11*exp(-pow((v-0.31)/0.26,2))
                let lower = 0.23*soft(0.63,1.0,v)
                let crease = soft(0.31,0.70,v)*exp(-pow((u-(0.27+0.18*(1-v)))/0.13,2))
                let shade = 0.96 + upper - lower - 0.068*crease
                if supine {
                    let mid = 0.88*exp(-pow((u-0.5)/0.37,4)-pow((v-0.43)/0.33,4))
                    let chest = coat.sample(coat.neck + coat.across*coat.length*(0.14+v*0.04)
                                            + coat.along*coat.length*(u-0.5)*0.16)
                    if chest.w > 0.85 {
                        let luminance = col.x*0.21+col.y*0.72+col.z*0.07
                        for k in 0..<3 { col[k] = mix(col[k],chest[k]*0.30+luminance*0.54+54,mid) }
                    }
                }
                return Ink(col.x*shade,col.y*shade,col.z*shade,surface.alpha)
            }) else { return }
            let anchor = V(shoulder.x,ground)
            var flank = PosePiece(image:skin,anchor:anchor)
            flank.enterScale = V(supine ? 0.04 : 0.035,-0.055)
            flank.settle = 0.20...0.72
            result.append(flank)
            // Reuse the same skin with a feathered chest mask. The hips and
            // planted paws remain still when the rib cage expands at the withers.
            guard let mask = bitmap(size, paint: { p in
                let weight = chestWeight(p)
                return Ink(255,255,255,weight)
            }), let context = CGContext(data:nil,width:size,height:size,bitsPerComponent:8,
                                        bytesPerRow:4*size,space:rgb,bitmapInfo:rgba.rawValue) else { return }
            let rect = CGRect(x:0,y:0,width:size,height:size)
            context.draw(skin,in:rect); context.setBlendMode(.destinationIn); context.draw(mask,in:rect)
            if let image = context.makeImage() {
                var chest = PosePiece(image:image,anchor:anchor,breathing:V(0.003,0.021),phase:0.13)
                chest.enterScale = flank.enterScale; chest.settle = flank.settle
                result.append(chest)
            }
        }
        func tube(_ tube: Tube, _ surface: Surface, anchor: V = V(160,160), breath: V = .zero,
                  sway: Double = 0, phase: Double = 0, light: Double = 1, showPads: Bool = false) {
            guard let texture = bitmap(size, paint: { p in
                guard let s = tube.surface(p) else { return .zero }
                let t = s.t, side = s.side, round = s.thickness
                let shade = light*(1.01 - 0.24*pow(min(1,round),2.8) - 0.045*side)
                let axis = unit(tube.end-tube.origin)
                let along = simd_dot(p-tube.origin,axis)
                let cross = simd_dot(p-tube.origin,normal(axis))
                var col = coat.fur((p.x-151)/220,(p.y-154)/129)
                var alpha = s.alpha
                switch surface {
                case .tail:
                    if let root = coat.joints[.tailBottom], let mid = coat.joints[.tailMiddle], let tip = coat.joints[.tailTop] {
                        let section = t < 0.5 ? (root,mid,t*2) : (mid,tip,2*t-1)
                        let d = section.1-section.0
                        let run = (t < 0.5 ? mix(-0.03,1,section.2) : section.2*0.94)
                        let tail = coat.sample(section.0 + d*run + normal(unit(d))*side*coat.eyeDistance*0.17)
                        let take = soft(0.70,0.97,tail.w)*soft(-0.1,0.32,t)
                        for k in 0..<3 { col[k] = mix(col[k],tail[k],take) }
                        alpha *= soft(-tube.root,tube.root*0.8,along)
                    }
                case let .leg(kneeJoint, pawJoint):
                    if let knee = coat.joints[kneeJoint], let paw = coat.joints[pawJoint] {
                        let d = paw-knee
                        let chord = max(1,simd_distance(tube.origin,tube.end))
                        let base = knee + d * min(1.07,along/chord)
                        let normalOffset = normal(unit(d)) * cross * coat.eyeDistance*0.20 / max(tube.tip,tube.root)
                        let texel = coat.sample(base + normalOffset)
                        alpha *= soft(-tube.root*0.8,tube.root*1.40,along)
                        let coverage = soft(0.74,0.98,texel.w)
                        let leg = coat.sample(knee + d*min(1.08,along/chord))
                        let useLeg = soft(0.55,0.96,leg.w)
                        for k in 0..<3 {
                            let texture = mix(mix(col[k],leg[k],useLeg),texel[k],coverage)
                            col[k] = mix(col[k],texture,soft(-0.06,0.55,t))
                        }
                        // Landmarks mark the pad centre, not the toe tips.
                        // Pick up the actual sock edge and toes further along
                        // the photographed paw instead of stretching one texel
                        // over the rounded end of the leg.
                        let nearToe = simd_dot(p-tube.end,tube.endDirection)/tube.tip
                        if !showPads && nearToe > -1.1 && t > 0.62 {
                            let toeSide = simd_dot(p-tube.end,normal(tube.endDirection))/tube.tip
                            let map = unit(d)*nearToe + normal(unit(d))*toeSide
                            let toe = coat.sample(paw + map*coat.eyeDistance*0.34)
                            let peak = soft(-1.1,0.0,nearToe)*soft(0.62,0.95,t)
                            for k in 0..<3 { col[k] = mix(col[k],toe[k],peak*toe.w) }
                            alpha *= 1 - peak*(1-toe.w)
                        }
                    }
                }
                if showPads, case .leg = surface {
                    // Pads face the viewer on the near paws, which makes the
                    // rotation from side-lying to belly-up legible.
                    let o = p - tube.end
                    let front = simd_dot(o,tube.endDirection)/tube.tip
                    let spread = simd_dot(o,normal(tube.endDirection))/tube.tip
                    var pad = 1-soft(0.80,1.07,hypot((front+0.06)/0.31,spread/0.40))
                    for (f,w) in [(0.46,-0.43),(0.58,-0.14),(0.57,0.16),(0.43,0.43)] {
                        let radial = hypot((front-f)/0.19,(spread-w)/0.13)
                        pad = max(pad,1-soft(0.73,1.16,radial))
                    }
                    if pad > 0, let nose = coat.joints[.nose] {
                        let pink = coat.sample(nose + V(spread,front)*coat.eyeDistance*0.035)
                        if pink.w > 0.8 {
                            for k in 0..<3 { col[k] = mix(col[k],pink[k]*0.82,pad*0.87) }
                        }
                    }
                }
                return Ink(col.x*shade,col.y*shade,col.z*shade,alpha)
            }) else { return }
            var part = PosePiece(image:texture,anchor:anchor,breathing:breath,sway:sway,phase:phase)
            switch surface {
            case .tail:
                part.enterAngle = sleeping ? 0.17 : (supine ? -0.32 : -0.10)
                part.settle = 0.55...1.0
            case let .leg(_,paw):
                part.enterAngle = supine ? -0.40 : (sleeping ? -0.14 : -0.10)
                part.enterShift = supine ? .zero : V(3,0)
                part.settle = 0...0.58
                if paw == .rightFrontPaw { part.pawFold = 0.27 }
                if paw == .leftFrontPaw { part.pawFold = -0.18 }
            }
            result.append(part)
        }
        func head(at location: V, scale: Double, rotation: Double, shift: V) {
            let x = V(cos(rotation),sin(rotation)), y = normal(x)
            let chestCenter = location + y*scale*0.7 - x*scale*0.34
            if let chest = bitmap(size, paint: { p in
                let delta = (p-chestCenter)/scale
                let u = simd_dot(delta,x), v = simd_dot(delta,y)
                let alpha = 1-soft(0.44,1.0,hypot(u/0.92,v/0.83))
                guard alpha > 0 else { return .zero }
                let pos = coat.eyeCenter + coat.eyeDistance * (coat.eyeAxis*(u-0.25) + coat.eyeDown*(v+1.13))
                let sample = coat.sample(pos)
                let shade = 0.91 + 0.08*soft(-0.4,0.34,v)
                return Ink(sample.x*shade,sample.y*shade,sample.z*shade,sample.w*alpha)
            }) {
                result.append(PosePiece(image:chest,anchor:location,breathing:V(0.004,0.012),shift:shift*0.5,
                                        enterShift:V(1,-4),settle:0.28...0.75))
            }
            for lid in [false,true] {
                let hinge = sleeping && !lid ? EarTurn(coat:coat) : nil
                func faceImage(turn: Double) -> CGImage? { bitmap(size, paint: { p in
                    let d = (p-location)/scale
                    var local = V(simd_dot(d,x),simd_dot(d,y))
                    guard abs(local.x) < 1.85 && abs(local.y)<2.7 else { return .zero }
                    if lid && (abs(local.y)>0.29 || abs(abs(local.x)-0.5)>0.37) { return .zero }
                    if turn>0, let hinge { local = hinge.samplePoint(local,turn:turn) }
                    return coat.face(local,eyelid:lid ? 1 : 0)
                }) }
                guard let face = faceImage(turn:0) else { continue }
                var part = PosePiece(image:face,anchor:location,sway:0.009,shift:shift)
                part.enterAngle = supine ? -0.60 : (sleeping ? -0.28 : -0.12)
                part.enterShift = supine ? V(1,-7) : V(4,-10)
                part.settle = 0.31...0.87; part.eyelids = lid; part.isHead = true
                if hinge != nil { part.earTurns = (1...4).compactMap { faceImage(turn:Double($0)/4) } }
                result.append(part)
            }
        }
        if !supine {
            // The visible hip/neck span supplies a conservative body proportion:
            // a foreshortened portrait stays compact; a side view can reach farther.
            let long = soft(3.1,5.3,simd_distance(coat.neck,coat.hip)/coat.eyeDistance)
            let stretchLength = mix(-5.0,9.0,long)
            let spineClock = V(0.19,0.57)
            shadow(center:blend(V(153,221),V(155,218),V(158,221)),width:126,height:13)
            let farHind = curve([V(84,178),V(95,193),V(119,202),V(139,199)],
                                [V(82,179),V(75,196),V(98,206),V(124,203)],
                                [V(83,186),V(95,201),V(126,204),V(146,205)],
                                [V(15,7),V(17,8),V(19,9)],clock:spineClock)
            tube(farHind,.leg(.leftBackKnee,.leftBackPaw),anchor:farHind.origin,light:0.84)
            let farFore = curve([V(207,188),V(205,201),V(211,205),V(222,208)],
                                [V(209,166),V(215,185),V(244+stretchLength,191),V(265+stretchLength,193)],
                                [V(208,174),V(226,188),V(246,191),V(260,195)],
                                [V(15,8),V(13,8),V(15,8)],clock:V(0.28,0.62),release:V(0.65,0.86),wrist:2.1)
            tube(farFore,.leg(.leftFrontKnee,.leftFrontPaw),anchor:farFore.origin,light:0.89)
            // Corresponding rump, spine, shoulder, sternum and belly outline
            // stations keep the rib cage full as the shoulders lean forward.
            let curl = [V(47,191),V(51,158),V(77,126),V(105,112),V(144,107),V(166,111),
                        V(185,117),V(207,131),V(220,143),V(230,154),V(239,173),V(225,203),
                        V(201,212),V(164,215),V(131,216),V(110,217),V(92,217),V(66,209)]
            let longBody = [V(35,182),V(39,157),V(59,137),V(86,127),V(115,126),V(147,129),
                            V(169,133),V(191,130),V(204,127),V(219,135),V(232,159),V(228,180),
                            V(211,197),V(182,200),V(150,203),V(118,210),V(76,211),V(48,203)]
            let compact = [V(47,181),V(51,156),V(67,131),V(94,117),V(124,114),V(149,117),
                           V(171,122),V(188,125),V(201,123),V(215,130),V(227,152),V(225,179),
                           V(204,197),V(176,207),V(146,210),V(119,211),V(82,212),V(60,201)]
            let reaching = zip(compact,longBody).map { $0+($1-$0)*long }
            let awake = [V(30,183),V(36,156),V(64,132),V(97,123),V(131,128),V(157,135),
                         V(184,133),V(202,123),V(215,126),V(223,146),V(237,162),V(230,184),
                         V(207,202),V(180,207),V(145,206),V(112,212),V(76,213),V(45,205)]
            let contour = curl.indices.map { blend(curl[$0],reaching[$0],awake[$0],spineClock) }
            torso(contour,rump:blend(V(68,179),V(74-14*long,174),V(51,174),spineClock),
                  shoulder:blend(V(206,159),V(202+6*long,159),V(210,158),spineClock),ground:215)
            let hind = curve([V(91,166),V(85,194),V(116,207),V(146,195)],
                             [V(81-8*long,171),V(63-7*long,191),V(86,207),V(116,205)],
                             [V(70,173),V(66,201),V(104,207),V(127,207)],
                             [V(24,11),V(23,9),V(23,10)],bulge:1.4,clock:spineClock)
            tube(hind,.leg(.rightBackKnee,.rightBackPaw),anchor:hind.origin,light:0.94)
            let fore = curve([V(213,172),V(202,188),V(182,206),V(161,203)],
                             [V(195,166),V(185,196),V(232+stretchLength,209),V(273+stretchLength,213)],
                             [V(202,165),V(196,193),V(227,209),V(259,208)],
                             [V(15,9),V(15,8.6),V(16,9)],bulge:1,clock:V(0.06,0.43),release:V(0.78,1),wrist:2.4)
            tube(fore,.leg(.rightFrontKnee,.rightFrontPaw),anchor:fore.origin,light:0.97)
            let headShape = blend(V(34,0.53),V(31-long,0.13+0.07*long),V(29,0.12),V(0.10,0.54))
            head(at:blend(V(207,170),V(209+5*long,148+5*long),V(218,143),spineClock),
                 scale:headShape.x,rotation:headShape.y,shift:V(0.15,0.48))
            let closed = [V(57,180),V(51,223),V(136,240),V(184,201)]
            let relaxed = [V(48-9*long,178),V(37-12*long,205),V(77-19*long,225),V(135-18*long,214)]
            let loose = [V(37,179),V(23,210),V(52,225),V(94,218)]
            let tailLine = closed.indices.map {
                blend(closed[$0],relaxed[$0],loose[$0],V(0.25,0.64),V(0.79,1))
            }
            let r = blend(V(15,8),V(14,7),V(13,6))
            let tail = Tube(tailLine[0],tailLine[1],tailLine[2],tailLine[3],root:r.x,tip:r.y,bulge:1.5)
            tube(tail,.tail,anchor:tail.origin,sway:0.008)
        } else {
            shadow(center:V(154,219),width:117,height:15)
            tube(Tube(V(102,188),V(91,228),V(54,236),V(32,211),root:14,tip:7),.tail,
                 anchor:V(101,188),sway:0.032,phase:0.24)
            tube(Tube(V(108,191),V(76,160),V(84,130),V(76,114),root:22,tip:11,bulge:1),
                 .leg(.leftBackKnee,.leftBackPaw),anchor:V(108,189),sway:0.035,light:0.85,showPads:true)
            tube(Tube(V(191,153),V(188,129),V(198,115),V(186,109),root:16,tip:9),
                 .leg(.leftFrontKnee,.leftFrontPaw),anchor:V(192,151),sway:0.035,light:0.9)
            torso([V(67,187),V(80,158),V(111,143),V(139,141),V(167,132),V(194,124),
                   V(218,129),V(237,142),V(241,159),V(225,176),V(203,182),V(181,197),
                   V(152,211),V(123,217),V(89,217),V(71,206)],
                  rump:V(85,189),shoulder:V(213,150),ground:217)
            tube(Tube(V(104,201),V(74,199),V(47,180),V(53,166),root:22,tip:12,bulge:2),
                 .leg(.rightBackKnee,.rightBackPaw),anchor:V(104,201),sway:0.044,phase:0.2,showPads:true)
            tube(Tube(V(204,166),V(181,162),V(145,142),V(153,128),root:15,tip:10,bulge:1.4),
                 .leg(.rightFrontKnee,.rightFrontPaw),anchor:V(204,166),sway:0.047,phase:0.1,showPads:true)
            head(at:V(232,162),scale:28,rotation:0.97,shift:V(0.3,0.54))
        }
        return result
    }
}
