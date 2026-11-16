import SwiftUI

// MARK: - Focus scan capture HUD (docs/design/capture-modes.md)

/// What the operator sees during a focus scan: the region and detail level, the photo count
/// against the target with a bar filling toward it (Splat, which also saves repeats, adds its new
/// angles), one plain-language status line, and a coverage dial of the directions the region has
/// been photographed from. The target is a soft limit for Detail and Splat: at it the bar turns
/// green and the status says there are enough, and capture runs on until Stop. Drawn near the top
/// of the capture view; ignores touches.
struct FocusCaptureHUD: View {
    let region: FocusRegion
    let stats: ARStillCaptureSession.LiveStats
    let isCapturing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            FocusCoverageDial(counts: stats.coverageCounts,
                              perCellTarget: perCellTarget,
                              cameraAzimuthDeg: stats.regionInView ? stats.regionAzimuthDeg : nil,
                              cameraElevationDeg: stats.regionElevationDeg)
                .frame(width: AppConstants.focusHUDDialSize, height: AppConstants.focusHUDDialSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: region.detail.systemImage)
                    Text(region.displayName).lineLimit(1)
                }
                .font(.subheadline.bold())
                Text(countLine)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
                ProgressView(value: Double(min(stats.stillsSaved, target)), total: Double(target))
                    .tint(reachedTarget ? .green : .cyan)
                    .frame(width: AppConstants.focusHUDProgressWidth)
                Label(status.text, systemImage: status.symbol)
                    .labelStyle(.tintedIcon(status.tint))
                    .font(.caption.bold())
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(AppConstants.focusHUDBackgroundOpacity))
        .cornerRadius(14)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Photos, every one counted (Check stops here; Detail and Splat say there are enough).
    private var target: Int { max(1, stats.targetStills, region.detail.targetStills) }
    private var reachedTarget: Bool { stats.stillsSaved >= target }

    /// Photos against the target. Splat also saves repeats, so it adds the new angles, which are
    /// what the dial shows.
    private var countLine: String {
        let photos = "\(region.detail.title) · \(stats.stillsSaved) of \(target) photos"
        return region.detail.waitsForSpacing ? photos : photos + " · \(stats.newAnglesSaved) angles"
    }

    /// New angles per dial cell that read as "covered": the target spread over the cells.
    private var perCellTarget: Int {
        let cells = max(1, stats.coverageCounts.count)
        return max(1, Int((Double(target) / Double(cells)).rounded(.up)))
    }

    private var status: (text: String, symbol: String, tint: Color) {
        guard isCapturing else {
            return ("Line up on the box, then tap record", "scope", .cyan)
        }
        switch stats.hold {
        case .none, .saving:
            // Past the soft limit capture goes on (a missed side can still be filled), but say so.
            if reachedTarget {
                return ("Enough photos, tap stop when ready", "checkmark.circle.fill", .green)
            }
            // Splat keeps taking stills from where the operator stands; say when they add no angle.
            if stats.lastReason == ARStillCaptureGates.repeatReason {
                return ("Capturing, move to add angles", "camera.fill", .green)
            }
            return ("Capturing", "camera.fill", .green)
        case .tracking: return ("Hold on, finding tracking", "hourglass", .yellow)
        case .motion: return ("Hold steadier", "hand.raised.fill", .yellow)
        case .outOfView: return ("Point at the box", "viewfinder", .orange)
        case .tooFar: return ("Move closer", "arrow.down.right.and.arrow.up.left", .orange)
        case .sameView: return ("Move to a new angle", "arrow.triangle.2.circlepath", .white)
        }
    }
}

/// The directions the region has been photographed from, seen from above: sectors around the
/// region (sector 0, the region's +Z side, at the top), rings from low (outer) to high (inner).
/// A cell fills green as stills from that direction land; the dot is where the camera is now.
struct FocusCoverageDial: View {
    let counts: [Int]
    let perCellTarget: Int
    var cameraAzimuthDeg: Double?
    var cameraElevationDeg: Double = 0

    var body: some View {
        Canvas { context, size in
            let sectors = AppConstants.focusCoverageAzimuthBins
            let rings = AppConstants.focusCoverageElevationEdgesDeg.count + 1
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let inner = outer * AppConstants.focusHUDDialHoleFraction
            let ringWidth = (outer - inner) / CGFloat(rings)
            let sweep = 360.0 / Double(sectors)
            for ring in 0..<rings {
                // Ring 0 (low views) is the outer band; higher views sit nearer the middle.
                let r1 = outer - CGFloat(ring) * ringWidth
                let r0 = r1 - ringWidth + AppConstants.focusHUDDialGap
                for sector in 0..<sectors {
                    let index = ring * sectors + sector
                    let count = index < counts.count ? counts[index] : 0
                    let fill = min(1, Double(count) / Double(max(1, perCellTarget)))
                    // Screen angle: sector 0 at the top, increasing clockwise.
                    let start = Angle.degrees(Double(sector) * sweep - 90 + AppConstants.focusHUDDialGapDeg / 2)
                    let end = Angle.degrees(Double(sector + 1) * sweep - 90 - AppConstants.focusHUDDialGapDeg / 2)
                    var cell = Path()
                    cell.addArc(center: centre, radius: r1, startAngle: start, endAngle: end, clockwise: false)
                    cell.addArc(center: centre, radius: r0, startAngle: end, endAngle: start, clockwise: true)
                    cell.closeSubpath()
                    let color = count == 0 ? Color.white.opacity(AppConstants.focusHUDEmptyCellOpacity)
                        : Color.green.opacity(AppConstants.focusHUDFilledCellMinOpacity
                                              + (1 - AppConstants.focusHUDFilledCellMinOpacity) * fill)
                    context.fill(cell, with: .color(color))
                }
            }
            if let azimuth = cameraAzimuthDeg {
                let edges = AppConstants.focusCoverageElevationEdgesDeg
                let ring = edges.filter { cameraElevationDeg >= $0 }.count
                let radius = outer - (CGFloat(ring) + 0.5) * ringWidth
                let angle = (azimuth - 90) * .pi / 180
                let dot = CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
                let dotSize = AppConstants.focusHUDDialDotSize
                context.fill(Path(ellipseIn: CGRect(x: dot.x - dotSize / 2, y: dot.y - dotSize / 2, width: dotSize, height: dotSize)),
                             with: .color(.white))
            }
            // The region itself, in the middle.
            let box = inner * AppConstants.focusHUDDialBoxFraction
            context.stroke(Path(CGRect(x: centre.x - box, y: centre.y - box, width: box * 2, height: box * 2)),
                           with: .color(.yellow), lineWidth: 1.5)
        }
        // Azimuth runs from the region's +Z toward its +X, which seen from above (+Z at the top)
        // is counterclockwise; the cells are laid out clockwise, so mirror the dial to match a
        // walk around the region.
        .scaleEffect(x: -1, y: 1)
        .accessibilityLabel("Coverage: \(counts.filter { $0 > 0 }.count) of \(counts.count) directions photographed")
    }
}

#Preview("Focus HUD, capturing") {
    var stats = ARStillCaptureSession.LiveStats()
    stats.hasRegion = true
    stats.detailLevel = .detail
    stats.targetStills = 30
    stats.stillsSaved = 11
    stats.regionInView = true
    stats.regionAzimuthDeg = 70
    stats.regionElevationDeg = 25
    stats.hold = .sameView
    var counts = [Int](repeating: 0, count: 36)
    for cell in [0, 1, 2, 13, 14, 15, 26] { counts[cell] = 2 }
    stats.coverageCounts = counts
    let region = FocusRegion(center: .zero, size: SIMD3(1.2, 0.5, 0.8), label: "work table", detail: .detail)
    return ZStack {
        Color.gray
        FocusCaptureHUD(region: region, stats: stats, isCapturing: true)
    }
}

#Preview("Focus HUD, Splat repeating") {
    var stats = ARStillCaptureSession.LiveStats()
    stats.hasRegion = true
    stats.detailLevel = .splat
    stats.targetStills = 150
    stats.stillsSaved = 97
    stats.newAnglesSaved = 64
    stats.regionInView = true
    stats.regionAzimuthDeg = 140
    stats.regionElevationDeg = 35
    stats.lastReason = ARStillCaptureGates.repeatReason
    var counts = [Int](repeating: 0, count: 36)
    for cell in [0, 1, 2, 3, 4, 13, 14, 15, 16, 17, 18] { counts[cell] = 5 }
    stats.coverageCounts = counts
    let region = FocusRegion(center: .zero, size: SIMD3(1.2, 0.5, 0.8), label: "work table", detail: .splat)
    return ZStack {
        Color.gray
        FocusCaptureHUD(region: region, stats: stats, isCapturing: true)
    }
}

#Preview("Focus HUD, Splat past its soft limit") {
    var stats = ARStillCaptureSession.LiveStats()
    stats.hasRegion = true
    stats.detailLevel = .splat
    stats.targetStills = 150
    stats.stillsSaved = 163
    stats.newAnglesSaved = 118
    stats.regionInView = true
    stats.regionAzimuthDeg = 250
    stats.regionElevationDeg = 10
    var counts = [Int](repeating: 0, count: 36)
    for cell in 0..<30 { counts[cell] = 4 }
    stats.coverageCounts = counts
    let region = FocusRegion(center: .zero, size: SIMD3(1.2, 0.5, 0.8), label: "work table", detail: .splat)
    return ZStack {
        Color.gray
        FocusCaptureHUD(region: region, stats: stats, isCapturing: true)
    }
}

#Preview("Focus HUD, before start") {
    FocusCaptureHUD(region: FocusRegion(center: .zero, size: SIMD3(0.5, 0.4, 0.5), detail: .check),
                    stats: ARStillCaptureSession.LiveStats(), isCapturing: false)
        .padding()
        .background(Color.gray)
}
