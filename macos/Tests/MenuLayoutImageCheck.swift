// Compare actual rendered text anchors in paired screenshots, without Bluetooth or app access.
// Usage: swift MenuLayoutImageCheck.swift on.jpg off.jpg 'Label=left,top,right,bottom' ...
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3,
      let first = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[0]))),
      let second = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    fatalError("Supply two screenshots and at least one named text region.")
}
guard first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
    fatalError("Screenshots must have the same size and menu anchor.")
}

func anchor(_ image: NSBitmapImageRep, _ bounds: [Int]) -> (Int, Int)? {
    var left = Int.max
    var top = Int.max
    for y in bounds[1]..<bounds[3] {
        for x in bounds[0]..<bounds[2] {
            guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  min(color.redComponent, color.greenComponent, color.blueComponent) > 160.0 / 255 else { continue }
            left = min(left, x)
            top = min(top, y)
        }
    }
    return left == .max ? nil : (left, top)
}

var failed = false
for specification in args.dropFirst(2) {
    let parts = specification.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else { fatalError("Use Label=left,top,right,bottom.") }
    let bounds = parts[1].split(separator: ",").compactMap { Int($0) }
    guard bounds.count == 4, bounds[0] >= 0, bounds[1] >= 0,
          bounds[2] <= first.pixelsWide, bounds[3] <= first.pixelsHigh,
          bounds[0] < bounds[2], bounds[1] < bounds[3],
          let before = anchor(first, bounds), let after = anchor(second, bounds) else {
        fatalError("Invalid region or no bright text found: \(parts[0])")
    }
    let dx = after.0 - before.0
    let dy = after.1 - before.1
    print("\(parts[0]): delta x=\(dx), y=\(dy) pixels")
    failed = failed || dx != 0 || dy != 0
}
exit(failed ? 1 : 0)
