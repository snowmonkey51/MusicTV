import CoreImage

/// Builds a rolling-scanlines CRT effect using built-in CIFilters.
/// Uses CIStripesGenerator for fine horizontal lines and a bright rolling bar,
/// composited over the source frame. Animated via compositionTime.
enum ScanlinesKernel {

    /// Applies the rolling scanlines effect to a source image at a given time.
    ///
    /// - Parameters:
    ///   - source: The input video frame.
    ///   - time: Elapsed seconds (from `compositionTime`).
    /// - Returns: The filtered image with scanlines + rolling hum bar.
    static func apply(to source: CIImage, time: Double) -> CIImage {
        let extent = source.extent
        var output = source

        // --- 1. Horizontal scanlines ---
        // CIStripesGenerator produces vertical stripes; we rotate 90° for horizontal.
        let lineSpacing: CGFloat = 3.5  // pixel width of each stripe pair

        if let stripes = CIFilter(name: "CIStripesGenerator") {
            // Animate the Y offset of the center to make lines roll slowly
            let scrollOffset = CGFloat(time * 0.5).truncatingRemainder(dividingBy: lineSpacing * 2)
            stripes.setValue(CIVector(x: 0, y: scrollOffset), forKey: "inputCenter")
            stripes.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0.3), forKey: "inputColor0")
            stripes.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0.0), forKey: "inputColor1")
            stripes.setValue(lineSpacing, forKey: "inputWidth")
            stripes.setValue(NSNumber(value: 0.85), forKey: "inputSharpness")

            if var stripesImage = stripes.outputImage {
                // Rotate 90° to make horizontal lines
                let rotation = CGAffineTransform(rotationAngle: .pi / 2)
                stripesImage = stripesImage.transformed(by: rotation)

                // Crop to source bounds
                stripesImage = stripesImage.cropped(to: extent)

                // Composite over source using source-atop (multiply the darkness)
                if let composite = CIFilter(name: "CISourceAtopCompositing") {
                    composite.setValue(stripesImage, forKey: kCIInputImageKey)
                    composite.setValue(output, forKey: kCIInputBackgroundImageKey)
                    if let result = composite.outputImage {
                        output = result.cropped(to: extent)
                    }
                }
            }
        }

        // --- 2. Rolling bright hum bar ---
        // A soft bright band that scrolls vertically at ~80px/s
        let barSpeed: Double = 80.0
        let barHeight: CGFloat = 80.0
        let barIntensity: CGFloat = 0.08

        // Calculate bar position (wrapping around the frame height)
        let frameHeight = extent.height
        let barY = CGFloat((time * barSpeed).truncatingRemainder(dividingBy: Double(frameHeight + barHeight * 2))) - barHeight

        // Create a soft gradient bar using CILinearGradient
        // Build a soft horizontal band: transparent → bright → transparent
        let barBottom = extent.origin.y + barY
        let barTop = barBottom + barHeight

        if let gradient1 = CIFilter(name: "CILinearGradient"),
           let gradient2 = CIFilter(name: "CILinearGradient") {
            let barColor = CIColor(red: 1, green: 1, blue: 1, alpha: barIntensity)
            let clearColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            let midY = (barBottom + barTop) / 2

            // Bottom half: transparent at bottom → bright at middle
            gradient1.setValue(CIVector(x: 0, y: barBottom), forKey: "inputPoint0")
            gradient1.setValue(clearColor, forKey: "inputColor0")
            gradient1.setValue(CIVector(x: 0, y: midY), forKey: "inputPoint1")
            gradient1.setValue(barColor, forKey: "inputColor1")

            // Top half: bright at middle → transparent at top
            gradient2.setValue(CIVector(x: 0, y: midY), forKey: "inputPoint0")
            gradient2.setValue(barColor, forKey: "inputColor0")
            gradient2.setValue(CIVector(x: 0, y: barTop), forKey: "inputPoint1")
            gradient2.setValue(clearColor, forKey: "inputColor1")

            if let grad1 = gradient1.outputImage?.cropped(to: CGRect(x: extent.origin.x, y: barBottom, width: extent.width, height: midY - barBottom)),
               let grad2 = gradient2.outputImage?.cropped(to: CGRect(x: extent.origin.x, y: midY, width: extent.width, height: barTop - midY)) {

                // Combine both gradient halves
                if let addComposite = CIFilter(name: "CIAdditionCompositing") {
                    addComposite.setValue(grad1, forKey: kCIInputImageKey)
                    addComposite.setValue(grad2, forKey: kCIInputBackgroundImageKey)
                    if let barImage = addComposite.outputImage?.cropped(to: extent) {
                        // Composite the bar over the output using screen blend
                        if let screenBlend = CIFilter(name: "CIScreenBlendMode") {
                            screenBlend.setValue(barImage, forKey: kCIInputImageKey)
                            screenBlend.setValue(output, forKey: kCIInputBackgroundImageKey)
                            if let result = screenBlend.outputImage {
                                output = result.cropped(to: extent)
                            }
                        }
                    }
                }
            }
        }

        // --- 3. Subtle vignette for CRT edge darkening ---
        if let vignette = CIFilter(name: "CIVignette") {
            vignette.setValue(output, forKey: kCIInputImageKey)
            vignette.setValue(1.5, forKey: kCIInputRadiusKey)
            vignette.setValue(0.5, forKey: kCIInputIntensityKey)
            if let result = vignette.outputImage {
                output = result.cropped(to: extent)
            }
        }

        return output
    }
}
