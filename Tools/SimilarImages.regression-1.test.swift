// Regression: ISSUE-002 — Similar Images chained unrelated images into one big group (A≈B, B≈C ⇒ A,C grouped)
// Found by /qa on 2026-10-20
// Report: .gstack/qa-reports/qa-report-mac-cleaner-2026-10-20.md
//   swiftc -parse-as-library $(ls Sources/*.swift | grep -v Main.swift) Tools/SimilarImages.regression-1.test.swift -o build/similar-regression && build/similar-regression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SplitMix {
    var state: UInt64
    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// Seeded abstract picture: an opaque background with 40 coloured ellipses. Many of these sit just inside
/// the default threshold of each other, which is exactly what used to chain into one big group.
func picture(seed: UInt64) -> CGImage {
    var rng = SplitMix(state: seed)
    let w = 2000, h = 1500
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for _ in 0..<40 {
        ctx.setFillColor(CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fillEllipse(in: CGRect(x: rng.unit() * Double(w), y: rng.unit() * Double(h),
                                   width: rng.unit() * Double(w) / 2, height: rng.unit() * Double(h) / 2))
    }
    return ctx.makeImage()!
}

@main
struct SimilarImagesRegression {
    @MainActor static func main() async {
        let dir = NSTemporaryDirectory() + "maccleaner-qa-similar-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for i in 0..<200 {
            let url = URL(fileURLWithPath: "\(dir)/image-\(i).png")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, picture(seed: UInt64(1000 + i)), nil)
            precondition(CGImageDestinationFinalize(dest))
        }

        let model = SimilarImagesModel()
        model.folders = [dir]
        await model.scan()

        let raw = similarImageEdges(in: [dir], maxDistance: Float(SimilarImagesModel.maxThreshold), progress: { _ in })
        var close = Set<String>()
        for e in raw.edges where Double(e.distance) <= model.threshold {
            close.insert(raw.paths[e.a] + "|" + raw.paths[e.b])
            close.insert(raw.paths[e.b] + "|" + raw.paths[e.a])
        }
        precondition(!close.isEmpty, "fixture produced no similar pairs; the test would prove nothing")
        for group in model.groups {
            for i in group.indices {
                for j in group.indices where j > i {
                    precondition(close.contains(group[i] + "|" + group[j]),
                                 "group of \(group.count) contains a pair that is not similar: \(group[i]) / \(group[j])")
                }
            }
        }
        print("SimilarImages regression OK (\(model.groups.count) groups, largest \(model.groups.map(\.count).max() ?? 0))")
    }
}
