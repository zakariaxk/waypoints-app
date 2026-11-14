#!/usr/bin/env swift
// CMP-6: draws the 1024 px app icon from the design tokens (docs/PLAN.md 9.2) and writes it
// into ios/App/Assets.xcassets/AppIcon.appiconset. No dependencies beyond the macOS SDK.
//
//     swift tools/icon/make-icon.swift            (from the repository root)
//
// The mark: a sodium route line climbing from a chalk start dot to a sodium waypoint ring, on
// asphalt. Flat fills only: no gradients, no shadows, no alpha (App Store icons are opaque).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appending(path: "ios/App/Assets.xcassets/AppIcon.appiconset")
let fileName = "AppIcon-1024.png"

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
let asphalt = color(0x0D0D0E)
let sodium = color(0xFFB224)
let chalk = color(0xF3F1EC)

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create the drawing context.")
}
// Draw in top-left coordinates.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

ctx.setFillColor(asphalt)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let start = CGPoint(x: 272, y: 784)
let waypoint = CGPoint(x: 700, y: 330)
let ringRadius: CGFloat = 112
let lineWidth: CGFloat = 64

// Route: an S-curve from the start dot to the bottom of the ring.
let route = CGMutablePath()
route.move(to: start)
route.addCurve(to: CGPoint(x: waypoint.x, y: waypoint.y + ringRadius),
               control1: CGPoint(x: 620, y: 784),
               control2: CGPoint(x: 360, y: 520))
ctx.addPath(route)
ctx.setStrokeColor(sodium)
ctx.setLineWidth(lineWidth)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

// Waypoint ring with a chalk centre.
ctx.setFillColor(asphalt)
ctx.fillEllipse(in: CGRect(x: waypoint.x - ringRadius, y: waypoint.y - ringRadius,
                           width: ringRadius * 2, height: ringRadius * 2))
ctx.setStrokeColor(sodium)
ctx.setLineWidth(lineWidth)
ctx.strokeEllipse(in: CGRect(x: waypoint.x - ringRadius, y: waypoint.y - ringRadius,
                             width: ringRadius * 2, height: ringRadius * 2))
let centre: CGFloat = 40
ctx.setFillColor(chalk)
ctx.fillEllipse(in: CGRect(x: waypoint.x - centre, y: waypoint.y - centre, width: centre * 2, height: centre * 2))

// Start dot.
let dot: CGFloat = 56
ctx.setFillColor(chalk)
ctx.fillEllipse(in: CGRect(x: start.x - dot, y: start.y - dot, width: dot * 2, height: dot * 2))

guard let image = ctx.makeImage() else { fatalError("Could not render the icon.") }
let out = iconSet.appending(path: fileName)
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not write \(out.path).")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(out.path).") }

let contents = """
{
  "images" : [
    {
      "filename" : "\(fileName)",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(to: iconSet.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(out.path)")
