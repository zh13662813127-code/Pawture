import AppKit
import CoreImage
import ImageIO
import Vision

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make-cutout.swift input-image output-png")
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fatalError("Could not read input image")
}

let request = VNGenerateForegroundInstanceMaskRequest()
let requestHandler = VNImageRequestHandler(cgImage: sourceImage, orientation: .up)
try requestHandler.perform([request])
guard let observation = request.results?.first else {
    fatalError("No foreground subject was found")
}

let maskBuffer = try observation.generateScaledMaskForImage(
    forInstances: observation.allInstances,
    from: requestHandler
)
let original = CIImage(cgImage: sourceImage)
let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
    .cropped(to: original.extent)
let cutout = original.applyingFilter(
    "CIBlendWithMask",
    parameters: [
        kCIInputBackgroundImageKey: clear,
        kCIInputMaskImageKey: CIImage(cvPixelBuffer: maskBuffer)
    ]
)
let context = CIContext(options: [.useSoftwareRenderer: false])
guard let rendered = context.createCGImage(cutout, from: original.extent) else {
    fatalError("Could not render transparent cutout")
}
let bitmap = NSBitmapImageRep(cgImage: rendered)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode cutout")
}
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL)
print("Wrote \(outputURL.path)")
