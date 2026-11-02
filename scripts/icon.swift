import AppKit
let image = NSImage(size:NSSize(width:1024,height:1024))
let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
NSColor(calibratedRed:0.045,green:0.065,blue:0.07,alpha:1).setFill(); NSBezierPath(rect:NSRect(x:0,y:0,width:1024,height:1024)).fill()
for i in 0..<9 {
    let heights: [CGFloat] = [220,370,490,350,180,350,490,370,220]
    let h = heights[i]
    let p = NSBezierPath(roundedRect:NSRect(x:CGFloat(183+i*75),y:(1024-h)/2,width:42,height:h),xRadius:21,yRadius:21)
    NSColor(calibratedRed:0.69,green:0.94,blue:0.76,alpha:1).setFill(); p.fill()
}
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
