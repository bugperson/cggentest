// Copyright (c) 2017 Yandex LLC. All rights reserved.
// Author: Alfred Zien <zienag@yandex-team.ru>

import Foundation
import Base

struct DrawStepToObjcCommandGenerator {
  let uniqIDProvider: () -> String
  let contextVarName: String
  let globalDeviceRGBContextName: String

  func command(step: DrawStep,
               gradients: [String: Gradient],
               subroutes: [String: DrawRoute]) -> [String] {
    switch step {
    case .saveGState:
      return [cmd("SaveGState")]
    case .restoreGState:
      return [cmd("RestoreGState")]
    case let .moveTo(p):
      return [cmd("MoveToPoint", points: [p])]
    case let .curveTo(c1, c2, end):
      return [cmd("AddCurveToPoint", points: [c1, c2, end])]
    case let .lineTo(p):
      return [cmd("AddLineToPoint", points: [p])]
    case .closePath:
      return [cmd("ClosePath")]
    case let .clip(rule):
      switch rule {
      case .winding:
        return [cmd("Clip")]
      case .evenOdd:
        return [cmd("EOClip")]
      }
    case .endPath:
      return []
    case let .flatness(flatness):
      return [cmd("SetFlatness", float: flatness)]
    case .fillColorSpace:
      return []
    case let .appendRectangle(rect):
      return [cmd("AddRect", rect: rect)]
    case .strokeColorSpace:
      return []
    case let .concatCTM(transform):
      return [cmd("ConcatCTM", "CGAffineTransformMake(\(transform.a), \(transform.b), \(transform.c), \(transform.d), \(transform.tx), \(transform.ty))")]
    case let .lineWidth(w):
      return [cmd("SetLineWidth", float: w)]
    case let .colorRenderingIntent(intent):
      return [cmd("SetRenderingIntent", intent.objcConstName)]
    case let .paintWithGradient(gradientKey):
      let gradient = gradients[gradientKey]!
      let colors = gradient.locationAndColors.map { $0.1 }
      let locations = gradient.locationAndColors.map { $0.0 }
      let lines = with(colors: colors) { (colorNames) -> [String] in
        let colorString = colorNames.map { "(__bridge id)\($0)" }.joined(separator: ", ")
        let colorsArrayVarName = "colors\(uniqIDProvider())"
        let colorArray = "  CFArrayRef \(colorsArrayVarName) = CFBridgingRetain(@[ \(colorString) ]);"
        let locationList = locations.map { "(CGFloat)\($0)" }.joined(separator: ", ")
        let locationArray = "(CGFloat []){\(locationList)}"
        let gradientName = "gradient\(uniqIDProvider())"
        let gradientDef = "  CGGradientRef \(gradientName) = CGGradientCreateWithColors(\(globalDeviceRGBContextName), \(colorsArrayVarName), \(locationArray));"
        let colorArrayRelease = "  CFRelease(\(colorsArrayVarName));"

        var optionsStrings: [String] = []
        if gradient.options.contains(.drawsBeforeStartLocation) {
          optionsStrings.append("kCGGradientDrawsBeforeStartLocation")
        }
        if gradient.options.contains(.drawsAfterEndLocation) {
          optionsStrings.append("kCGGradientDrawsAfterEndLocation")
        }
        if optionsStrings.isEmpty {
          optionsStrings.append("0")
        }
        let optionsVarName = "gradientOptions\(uniqIDProvider())"
        let optionsLine = "  CGGradientDrawingOptions \(optionsVarName) = (CGGradientDrawingOptions)(\(optionsStrings.joined(separator: " | ")));"
        let startPoint = "CGPointMake((CGFloat)\(gradient.startPoint.x), (CGFloat)\(gradient.startPoint.y))"
        let endPoint = "CGPointMake((CGFloat)\(gradient.endPoint.x), (CGFloat)\(gradient.endPoint.y))"
        let drawGradientLine = "  CGContextDrawLinearGradient(\(contextVarName), \(gradientName), \(startPoint), \(endPoint), \(optionsVarName));"
        let releaseGradient = "  CGGradientRelease(\(gradientName));"
        return [colorArray, gradientDef, colorArrayRelease, optionsLine, drawGradientLine, releaseGradient]
      }
      return lines
    case let .dash(pattern):
      let args = "\(pattern.phase), \(ObjCGen.cgFloatArray(pattern.lengths)), \(pattern.lengths.count)"
      return [cmd("SetLineDash", args)]
    case let .clipToRect(rect):
      return [cmd("ClipToRect", rect: rect)]
    case .beginTransparencyLayer:
      return [cmd("BeginTransparencyLayer", "NULL")]
    case .endTransparencyLayer:
      return [cmd("EndTransparencyLayer")]
    case let .globalAlpha(a):
      return [cmd("SetAlpha", float: a)]
    case let .fill(rule):
      switch rule {
      case .winding:
        return [cmd("FillPath")]
      case .evenOdd:
        return [cmd("EOFillPath")]
      }
    case .lineJoinStyle(_):
      fatalError()
    case let .lineCapStyle(style):
      return [cmd("SetLineCap", style.objcConstName)]
    case let .subrouteWithName(name):
      return ["  \(subrouteBlockName(subrouteName: name))(\(contextVarName));"]
    case let .strokeColor(color):
      return cmd("SetStrokeColorWithColor", color: color)
    case .stroke:
      return [cmd("StrokePath")]
    case let .fillColor(color):
      return cmd("SetFillColorWithColor", color: color)
    case let .composite(steps):
      return steps.flatMap {
        command(step: $0, gradients: gradients, subroutes: subroutes)
      }
    }
  }

  private func cmd(_ name: String, _ args: String? = nil) -> String {
    let argStr: String
    if let args = args {
      argStr = ", \(args)"
    } else {
      argStr = ""
    }
    return "  CGContext\(name)(\(contextVarName)\(argStr));"
  }

  private func cmd(_ name: String, points: [CGPoint]) -> String {
    return cmd(name, points.map { "(CGFloat)\($0.x), (CGFloat)\($0.y)" }.joined(separator: ", "))
  }

  private func cmd(_ name: String, rect: CGRect) -> String {
    let w = cmd(name, "CGRectMake((CGFloat)\(rect.x), (CGFloat)\(rect.y), (CGFloat)\(rect.size.width), (CGFloat)\(rect.size.height))")
    return w
  }

  private func cmd(_ name: String, float: CGFloat) -> String {
    return cmd(name, "(CGFloat)\(float)")
  }

  private func cmd(_ name: String, color: RGBAColor) -> [String] {
    let (colorVarName, createColor) = define(color: color)
    let cmdStr = cmd(name, "\(colorVarName)")
    let releaseLine = release(colorVarName: colorVarName)
    return [createColor, cmdStr, releaseLine]
  }

  private func with(colors: [RGBAColor], block: ([String]) -> [String]) -> [String] {
    let colorNamesAndLines = colors.map { define(color: $0) }
    let colorNames = colorNamesAndLines.map { $0.0 }
    let colorDefLines = colorNamesAndLines.map { $0.1 }
    let releaseLines = colorNames.map { release(colorVarName: $0) }
    return colorDefLines + block(colorNames) + releaseLines
  }

  private func define(color: RGBAColor) -> (String, String) {
    let colorVarName = "color\(uniqIDProvider())"
    let createColor = "  CGColorRef \(colorVarName) = CGColorCreate(\(globalDeviceRGBContextName), (CGFloat []){(CGFloat)\(color.red), (CGFloat)\(color.green), (CGFloat)\(color.blue), (CGFloat)\(color.alpha)});"
    return (colorVarName, createColor)
  }

  private func release(colorVarName: String) -> String {
    return "  CGColorRelease(\(colorVarName));"
  }
}


extension CGLineCap {
  var objcConstName: String {
    switch self {
    case .butt:
      return "kCGLineCapButt"
    case .round:
      return "kCGLineCapRound"
    case .square:
      return "kCGLineCapSquare"
    }
  }
}

extension CGColorRenderingIntent {
  var objcConstName: String {
    switch self {
    case .absoluteColorimetric:
      return "kCGRenderingIntentAbsoluteColorimetric"
    case .defaultIntent:
      return "kCGRenderingIntentDefault"
    case .perceptual:
      return "kCGRenderingIntentPerceptual"
    case .relativeColorimetric:
      return "kCGRenderingIntentRelativeColorimetric"
    case .saturation:
      return "kCGRenderingIntentSaturation"
    }
  }
}