import CoreImage

/// CRT television effect using built-in CIFilters.
/// Combines phosphor blur, scanlines, a rolling hum bar, and vignette.
enum CRTKernel {

    /// Applies the CRT effect to a source image at a given time.
    ///
    /// - Parameters:
    ///   - source: The input video frame (should be `.clampedToExtent()`).
    ///   - time: Elapsed seconds (from `compositionTime`).
    /// - Returns: The filtered image with CRT treatment.
    static func apply(to source: CIImage, time: Double) -> CIImage {
        let extent = source.extent
        var output = source

        // --- 1. Phosphor blur (soft CRT glow) ---
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(output, forKey: kCIInputImageKey)
            blur.setValue(0.8, forKey: kCIInputRadiusKey)
            if let blurred = blur.outputImage {
                output = blurred.cropped(to: extent)
            }
        }

        // --- 2. Horizontal scanlines ---
        let lineSpacing: CGFloat = 3.5

        if let stripes = CIFilter(name: "CIStripesGenerator") {
            let scrollOffset = CGFloat(time * 60.0).truncatingRemainder(dividingBy: lineSpacing * 2)
            stripes.setValue(CIVector(x: 0, y: scrollOffset), forKey: "inputCenter")
            stripes.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0.3), forKey: "inputColor0")
            stripes.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0.0), forKey: "inputColor1")
            stripes.setValue(lineSpacing, forKey: "inputWidth")
            stripes.setValue(NSNumber(value: 0.85), forKey: "inputSharpness")

            if var stripesImage = stripes.outputImage {
                let rotation = CGAffineTransform(rotationAngle: .pi / 2)
                stripesImage = stripesImage.transformed(by: rotation)
                stripesImage = stripesImage.cropped(to: extent)

                if let composite = CIFilter(name: "CISourceAtopCompositing") {
                    composite.setValue(stripesImage, forKey: kCIInputImageKey)
                    composite.setValue(output, forKey: kCIInputBackgroundImageKey)
                    if let result = composite.outputImage {
                        output = result.cropped(to: extent)
                    }
                }
            }
        }

        // --- 3. Rolling bright hum bar ---
        let barSpeed: Double = 80.0
        let barHeight: CGFloat = 80.0
        let barIntensity: CGFloat = 0.08

        let frameHeight = extent.height
        let barY = CGFloat((time * barSpeed).truncatingRemainder(dividingBy: Double(frameHeight + barHeight * 2))) - barHeight

        let barBottom = extent.origin.y + barY
        let barTop = barBottom + barHeight

        if let gradient1 = CIFilter(name: "CILinearGradient"),
           let gradient2 = CIFilter(name: "CILinearGradient") {
            let barColor = CIColor(red: 1, green: 1, blue: 1, alpha: barIntensity)
            let clearColor = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            let midY = (barBottom + barTop) / 2

            gradient1.setValue(CIVector(x: 0, y: barBottom), forKey: "inputPoint0")
            gradient1.setValue(clearColor, forKey: "inputColor0")
            gradient1.setValue(CIVector(x: 0, y: midY), forKey: "inputPoint1")
            gradient1.setValue(barColor, forKey: "inputColor1")

            gradient2.setValue(CIVector(x: 0, y: midY), forKey: "inputPoint0")
            gradient2.setValue(barColor, forKey: "inputColor0")
            gradient2.setValue(CIVector(x: 0, y: barTop), forKey: "inputPoint1")
            gradient2.setValue(clearColor, forKey: "inputColor1")

            if let grad1 = gradient1.outputImage?.cropped(to: CGRect(x: extent.origin.x, y: barBottom, width: extent.width, height: midY - barBottom)),
               let grad2 = gradient2.outputImage?.cropped(to: CGRect(x: extent.origin.x, y: midY, width: extent.width, height: barTop - midY)) {

                if let addComposite = CIFilter(name: "CIAdditionCompositing") {
                    addComposite.setValue(grad1, forKey: kCIInputImageKey)
                    addComposite.setValue(grad2, forKey: kCIInputBackgroundImageKey)
                    if let barImage = addComposite.outputImage?.cropped(to: extent) {
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

        // --- 4. Vignette for CRT edge darkening ---
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
