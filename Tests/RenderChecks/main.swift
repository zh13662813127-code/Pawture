import CoreGraphics
import CoreText
import DesktopCatsCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

try checkVisibleFur()
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let poses: [(CatMotion, String)] = [
    (.idle, "原姿"), (.loaf, "侧卧"), (.curlSleep, "蜷睡"), (.petRub, "蹭脸"), (.bellyUp, "翻肚皮")
]
let waking: [(CatMotion, Double, String)] = [
    (.curlSleep,0,"蜷睡"), (.sleepMurmur,0.13,"转耳"), (.sleepMurmur,0.44,"抬脸"),
    (.wakeStretch,0.36,"先伸前爪"), (.wakeStretch,0.61,"贴地伸展"), (.wakeStretch,1,"收爪侧卧")
]
let rubs: [(CatMotion,Double,String)] = [
    (.loaf,0,"侧卧"),(.loafNuzzle,0.48,"靠过来"),(.loafNuzzle,1,"歇一会"),
    (.bellyUp,0,"仰躺"),(.bellyNuzzle,0.48,"收拢前爪"),(.bellyNuzzle,1,"放松")
]
let cell = 180
let height = 388
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func makeCanvas(_ columns: Int) -> CGContext {
    let width = cell*columns
    let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                       space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    canvas.setFillColor(red: 0.92, green: 0.94, blue: 0.93, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
    canvas.interpolationQuality = .high
    return canvas
}
let canvas = makeCanvas(poses.count), sequence = makeCanvas(waking.count), touches = makeCanvas(rubs.count)
let greeting: [(CatMotion, Double, String)] = [
    (.greetSniff, 0, "对望"), (.greetSniff, 0.23, "探鼻"), (.greetSniff, 1, "停顿"),
    (.greetRub, 0.33, "侧颊轻碰"), (.greetRub, 0.59, "蹭过"), (.greetRub, 1, "松开")
]
let pairCell = 252
let pairSheet = CGContext(data: nil, width: pairCell * 3, height: 2 * (cell + 32),
                          bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
pairSheet.setFillColor(red: 0.92, green: 0.94, blue: 0.93, alpha: 1)
pairSheet.fill(CGRect(x: 0, y: 0, width: pairSheet.width, height: pairSheet.height))
pairSheet.interpolationQuality = .high
var pairFrames: [(frames: [CGImage], nose: CGPoint, sourceLooksRight: Bool)] = []

func pixels(_ image: CGImage) -> [UInt8] {
    let n = 120
    var rgba = [UInt8](repeating: 0, count: n*n*4)
    rgba.withUnsafeMutableBytes { storage in
        let c = CGContext(data: storage.baseAddress, width: n, height: n, bitsPerComponent: 8,
                          bytesPerRow: n*4, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    }
    return rgba
}

func title(_ name: String, column: Int, on canvas: CGContext) {
    let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, 15, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.2, alpha: 1)] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, name as CFString, attributes)!)
    let length = CTLineGetTypographicBounds(line, nil, nil, nil)
    canvas.textPosition = CGPoint(x: CGFloat(column * cell) + (CGFloat(cell)-length)/2, y: CGFloat(height-23))
    CTLineDraw(line, canvas)
}

func place(_ image: CGImage, column: Int, row: Int, on canvas: CGContext) {
    let scale = CGFloat(cell)/CGFloat(max(image.width, image.height))
    let w = CGFloat(image.width)*scale, h = CGFloat(image.height)*scale
    let x = CGFloat(column*cell) + (CGFloat(cell)-w)/2
    let y = CGFloat((1-row)*cell) + (CGFloat(cell)-h)/2
    canvas.draw(image, in: CGRect(x: x,y: y,width: w,height: h))
}
for (column, pose) in poses.enumerated() { title(pose.1,column:column,on:canvas) }
for (column, pose) in waking.enumerated() { title(pose.2,column:column,on:sequence) }
for (column, pose) in rubs.enumerated() { title(pose.2,column:column,on:touches) }
for (row, file) in ["cat-sitting.png", "cat-walking.png"].enumerated() {
    let url = input.appendingPathComponent(file)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let photo = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let rig = try CatPoseAnalyzer.analyzeSynchronously(url)
    let upright = StandingRenderer(image: photo, blueprint: rig)
    let nose = rig.joints[.nose]!
    let social = greeting.map { step in upright.frame(for: step.0, phase: step.1) }
    func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        (a.dataProvider?.data as Data?) == (b.dataProvider?.data as Data?)
    }
    precondition(samePixels(social[2], upright.frame(for: .greetRub, phase: 0)),
                 "Greeting must start a cheek rub without jumping out of the sniff pose")
    precondition(samePixels(social[0], social[5]), "Greeting must return to the original stance")
    precondition(!samePixels(social[0], social[2]) && !samePixels(social[2], social[3]),
                 "A sniff and cheek rub must render distinct poses")
    pairFrames.append((social, CGPoint(x: nose.x, y: nose.y), !rig.facesLeft))
    guard let rest = CatRestRenderer(image: photo, blueprint: rig) else { fatalError("No rest model for " + file) }
    var restOutlines = [[Bool]]()
    for (column, pose) in poses.enumerated() {
        let useRest = [.loaf, .curlSleep, .bellyUp].contains(pose.0)
        func frame(_ phase: Double) -> CGImage {
            if useRest {
                guard let image = rest.frame(for: pose.0, phase: phase) else { fatalError("Missing pose " + pose.1) }
                return image
            }
            return upright.frame(for: pose.0, phase: phase)
        }
        let image = frame(0.45)
        let a = pixels(image)
        let occupied = stride(from: 3, to: a.count, by: 4).map { a[$0] > 64 }
        let area = occupied.filter { $0 }.count
        precondition((800..<13000).contains(area), "Expected a visible cat with transparent surroundings")
        if useRest { restOutlines.append(occupied) }
        precondition(a != pixels(frame(0.05)), "Frozen pose: " + pose.1)
        place(image,column:column,row:row,on:canvas)
    }
    let distinct = zip(restOutlines[0], restOutlines[1]).filter { $0.0 != $0.1 }.count
    precondition(distinct > 320, "Awake and curled poses need distinct silhouettes")
    for (col,step) in waking.enumerated() {
        guard let image = rest.frame(for:step.0,phase:step.1) else { fatalError("Missing " + step.2) }
        place(image,column:col,row:row,on:sequence)
    }
    for (col,step) in rubs.enumerated() {
        guard let image = rest.frame(for:step.0,phase:step.1) else { fatalError("Missing " + step.2) }
        place(image,column:col,row:row,on:touches)
    }
    func pose(_ motion: CatMotion,_ t: Double) -> [UInt8] { pixels(rest.frame(for:motion,phase:t)!) }
    let curled = pose(.curlSleep,0), awake = pose(.loaf,0)
    precondition(pose(.wakeStretch,0)==curled && pose(.wakeStretch,1)==awake,
                 "Stretch must join existing sleep and awake silhouettes at both ends")
    precondition(pose(.sleepMurmur,0)==curled, "Taking a stroke must not reset the sleeping posture")
    for t in [0.13,0.44] {
        let calm = pose(.curlSleep,t), response = pose(.sleepMurmur,t)
        func changed(_ x: Range<Int>,_ y: Range<Int>) -> Int {
            y.reduce(0) { sum,row in sum+x.filter { column in
                let i = (120*row+column)*4
                return (0..<4).contains { abs(Int(calm[i+$0])-Int(response[i+$0]))>7 }
            }.count }
        }
        precondition(changed(0..<52,35..<88)==0 && changed(54..<110,24..<80)>16,
                     "Only the head and ears should respond on a sleeping cat")
    }
    func extent(_ a: [UInt8],x: Range<Int>,y: Range<Int>) -> (minY:Int,maxX:Int) {
        var top = 120, right = -1
        for row in y { for col in x where a[(row*120+col)*4+3]>132 {
            top = min(row,top); right = max(col,right)
        }}
        return (top,right)
    }
    let stretch = pose(.wakeStretch,0.60)
    let hindTop = extent(stretch,x:22..<49,y:15..<83).minY
    let sleepingTop = extent(curled,x:22..<49,y:15..<83).minY
    precondition(hindTop >= sleepingTop-1, "The cat must stay grounded instead of lifting its rump")
    let waistDepth = (30..<90).filter { stretch[($0*120+54)*4+3]>132 }.count
    precondition(waistDepth > 24, "The belly and back must keep their volume during the reach")
    precondition(extent(stretch,x:70..<120,y:72..<94).maxX > extent(curled,x:70..<120,y:72..<94).maxX+8,
                 "The planted front paws should reach forward")
    let leading = pose(.wakeStretch,0.36)
    let lowBand = 79..<84, farBand = 69..<74
    precondition(extent(leading,x:70..<120,y:lowBand).maxX > extent(curled,x:70..<120,y:lowBand).maxX+7 &&
                 extent(stretch,x:70..<120,y:farBand).maxX > extent(leading,x:70..<120,y:farBand).maxX+6,
                 "The near paw must reach while the far paw is still folded, then the far paw follows")
    for (base,rub) in [(CatMotion.loaf,CatMotion.loafNuzzle),(.bellyUp,.bellyNuzzle)] {
        for t in [0.0,1.0] {
            precondition(pose(base,t)==pose(rub,t), "A resting nuzzle must join the original posture")
        }
        let a = pose(base,0.46), b = pose(rub,0.46)
        let rear = (0..<120).flatMap { y in (0..<43).map { x in 4*(y*120+x) } }
        precondition(rear.allSatisfy { a[$0..<$0+4] == b[$0..<$0+4] },
                     "Touch must not move the resting hindquarters")
        precondition(a != b,"Touch must visibly change the resting face or paws")
    }
    print("\(file): \(rig.joints.count) landmarks; grounded stretch with intact waist, in-pose pet responses")
}
for (index, step) in greeting.enumerated() {
    let centerX = CGFloat((index % 3) * pairCell) + CGFloat(pairCell) / 2
    let rowBottom = CGFloat((1 - index / 3) * (cell + 32))
    let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, 15, nil)
    let attrs = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.2, alpha: 1)] as CFDictionary
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, step.2 as CFString, attrs)!)
    pairSheet.textPosition = CGPoint(x: centerX - CTLineGetTypographicBounds(line, nil, nil, nil) / 2,
                                    y: rowBottom + CGFloat(cell + 14))
    CTLineDraw(line, pairSheet)
    for (side, cat) in pairFrames.enumerated() {
        let image = cat.frames[index]
        let w = CGFloat(cell) * CGFloat(image.width) / CGFloat(image.height)
        let orientation: CGFloat = (side == 0) == cat.sourceLooksRight ? 1 : -1
        let forward: CGFloat = side == 0 ? 1 : -1
        let noseX = (cat.nose.x - 0.5) * 0.91 * w * orientation
        let noseY = (cat.nose.y - 0.5) * 0.91 * CGFloat(cell)
        let noseDistance: CGFloat = 19
        pairSheet.saveGState()
        pairSheet.translateBy(x: centerX - noseDistance * forward - noseX,
                              y: rowBottom + 95 + noseY + 27)
        pairSheet.scaleBy(x: orientation, y: 1)
        pairSheet.draw(image, in: CGRect(x: -w / 2, y: -90, width: w, height: 180))
        pairSheet.restoreGState()
    }
}
let folder = output.deletingLastPathComponent()
for (sheet,url) in [(canvas,output),(sequence,folder.appendingPathComponent("sleep-and-stretch.png")),
                    (touches,folder.appendingPathComponent("resting-touch.png")),
                    (pairSheet,folder.appendingPathComponent("social-greeting.png"))] {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest,sheet.makeImage()!,nil)
    precondition(CGImageDestinationFinalize(dest))
    print(url.path)
}
