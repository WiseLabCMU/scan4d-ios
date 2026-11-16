import SceneKit
import simd
import SwiftUI

// MARK: - Focus splats in the room's 3D preview (REQ-041)
//
// The room preview draws the focus scans made against the generation on screen: each one's box,
// and, once its splat is on this phone, the splat in place of the mesh inside the box (the mesh's
// fragments inside a shown splat's box are discarded by a shader modifier). Splats on the phone show
// by themselves, newest first, within `AppConstants.splatPreviewBudget`; a legend row per scan shows,
// hides or downloads its splat, and the one asked for last always wins the budget.

/// A focus scan the room preview can show, snapshotted on the main actor.
struct PreviewFocusScan: Identifiable, Equatable {
    let id: UUID
    let name: String
    let capturedAt: Date
    let scanDirectory: URL
    let region: FocusRegion

    /// The location's focus scans made against room scan `roomId`, newest first.
    static func made(against roomId: UUID?, in location: ScanLocation?) -> [PreviewFocusScan] {
        guard let roomId, let location else { return [] }
        return location.scans
            .filter { $0.isFocusScan && $0.parentScanId == roomId }
            .compactMap { scan in
                scan.focusRegion.map {
                    PreviewFocusScan(id: scan.id, name: scan.name, capturedAt: scan.capturedAt,
                                     scanDirectory: scan.scanDirectory, region: $0)
                }
            }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}

/// The preview's focus button: off, the boxes, or the boxes and their splats.
enum FocusOverlayMode: Equatable {
    case off
    case boxes
    case splats

    var next: FocusOverlayMode {
        switch self {
        case .off: return .boxes
        case .boxes: return .splats
        case .splats: return .off
        }
    }

    var iconName: String {
        switch self {
        case .off, .boxes: return "scope"
        case .splats: return "cube.transparent.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .off: return "Focus scans hidden"
        case .boxes: return "Focus scan boxes"
        case .splats: return "Focus scan boxes and splats"
        }
    }
}

/// The focus boxes and splats in the preview's scene, and what each legend row says.
@Observable
@MainActor
final class FocusSplatOverlay {
    /// What a focus scan's legend row says.
    enum RowState: Equatable {
        case shown(count: Int)
        case opening
        /// On the phone, not drawn: switched off, or the focus button is on boxes.
        case hidden
        /// On the phone, not drawn: the splats asked for since fill the budget.
        case overBudget
        case failed(String)
        /// Not on the phone: the card's splat line (on the server, downloading, failed).
        case server(ScanLayers.Line)
        /// No splat on the server or the phone.
        case noSplat
    }

    private(set) var states: [UUID: RowState] = [:]
    /// Gaussians drawn now, against `AppConstants.splatPreviewBudget`.
    private(set) var drawnCount = 0

    private var switchedOff: Set<UUID> = []
    /// Scans whose splat was asked for, most recent first: they win the budget in that order.
    private var askedFor: [UUID] = []
    private var failures: [UUID: String] = [:]

    private struct Loaded {
        let version: String
        let renderer: SplatRenderer
        let node: SCNNode
    }

    @ObservationIgnored private weak var view: SCNView?
    @ObservationIgnored private var scans: [PreviewFocusScan] = []
    @ObservationIgnored private var mode: FocusOverlayMode = .off
    @ObservationIgnored private var group: SCNNode?
    @ObservationIgnored private var boxes: [UUID: SCNNode] = [:]
    @ObservationIgnored private var loaded: [UUID: Loaded] = [:]
    @ObservationIgnored private var opening: [UUID: String] = [:]
    @ObservationIgnored private var cutInstalled = false

    /// Brings the scene up to date with `scans` and `mode`. Call whenever either changes, a copy
    /// lands on the phone, or a generation loads. Nothing until the room mesh is in the scene.
    func sync(view: SCNView?, scans: [PreviewFocusScan], mode: FocusOverlayMode) {
        self.view = view
        self.scans = scans
        self.mode = mode
        apply()
    }

    /// A legend row's tap: shows or hides a splat on the phone, or downloads one from the server
    /// (it shows once it lands).
    func tap(_ scan: PreviewFocusScan) {
        let layers = ScanLayers.shared
        if layers.local[ScanLayers.key(scan.id, ScanLayer.splat)] != nil {
            failures[scan.id] = nil
            if loaded[scan.id] != nil {
                switchedOff.insert(scan.id)
            } else {
                switchedOff.remove(scan.id)
                askedFor.removeAll { $0 == scan.id }
                askedFor.insert(scan.id, at: 0)
            }
        } else if layers.layer(scan.id, kind: ScanLayer.splat) != nil {
            askedFor.removeAll { $0 == scan.id }
            askedFor.insert(scan.id, at: 0)
            layers.download(scanId: scan.id, scanDirectory: scan.scanDirectory)
        }
        apply()
    }

    /// Takes everything out of the scene (the preview is closing).
    func tearDown() {
        for entry in loaded.values { Self.release(entry) }
        loaded = [:]
        opening = [:]
        group?.removeFromParentNode()
        group = nil
        boxes = [:]
        view?.rendersContinuously = false
        drawnCount = 0
        states = [:]
    }

    // MARK: Applying

    private func apply() {
        guard let view, let scene = view.scene,
              let mesh = scene.rootNode.childNode(withName: "mesh", recursively: true) else { return }
        let group = groupNode(in: scene)
        // The mesh's own centring offset: boxes and splats are in the frame the mesh is in.
        group.simdTransform = mesh.simdWorldTransform
        let layers = ScanLayers.shared

        let ids = Set(scans.map(\.id))
        for (id, node) in boxes where !ids.contains(id) {
            node.removeFromParentNode()
            boxes[id] = nil
        }
        for scan in scans {
            let box = boxes[scan.id] ?? makeBox(scan, in: group)
            box.simdTransform = scan.region.transform
            box.isHidden = mode == .off
        }

        // Which splats to draw: those asked for, then the newest, while the budget lasts.
        let order = scans.sorted { rank($0.id) < rank($1.id) }
        var budget = AppConstants.splatPreviewBudget
        var wanted: [UUID: ScanLayer] = [:]
        var next: [UUID: RowState] = [:]
        for scan in order {
            guard let local = layers.local[ScanLayers.key(scan.id, ScanLayer.splat)] else {
                next[scan.id] = layers.line(for: scan.id).map { RowState.server($0) } ?? RowState.noSplat
                continue
            }
            if let failure = failures[scan.id] {
                next[scan.id] = .failed(failure)
                continue
            }
            guard mode == .splats, !switchedOff.contains(scan.id) else {
                next[scan.id] = .hidden
                continue
            }
            let count = local.meta?.count ?? 0
            guard count <= budget else {
                next[scan.id] = .overBudget
                continue
            }
            budget -= count
            wanted[scan.id] = local
        }

        for (id, entry) in loaded where wanted[id]?.version != entry.version {
            Self.release(entry)
            loaded[id] = nil
        }
        for scan in order {
            guard let local = wanted[scan.id] else { continue }
            if let entry = loaded[scan.id] {
                guard let placement = placement(scan, local) else { continue }
                entry.node.simdTransform = placement
                next[scan.id] = .shown(count: entry.renderer.cloud.count)
            } else {
                if opening[scan.id] != local.version { open(scan, local) }
                next[scan.id] = failures[scan.id].map { RowState.failed($0) } ?? .opening
            }
        }

        states = next
        drawnCount = loaded.values.reduce(0) { $0 + $1.renderer.cloud.count }
        applyCut(in: scene, group: group)
        view.rendersContinuously = !loaded.isEmpty
    }

    /// Asked for (most recent first), then newest.
    private func rank(_ id: UUID) -> Int {
        if let index = askedFor.firstIndex(of: id) { return index }
        return askedFor.count + (scans.firstIndex { $0.id == id } ?? 0)
    }

    private func groupNode(in scene: SCNScene) -> SCNNode {
        if let group, group.parent != nil { return group }
        let node = SCNNode()
        node.name = "focusOverlay"
        scene.rootNode.addChildNode(node)
        group = node
        return node
    }

    private func makeBox(_ scan: PreviewFocusScan, in group: SCNNode) -> SCNNode {
        let node = SCNNode(geometry: SplatScene.boxOutline(halfExtents: scan.region.halfExtents))
        node.name = "focusBox"
        group.addChildNode(node)
        boxes[scan.id] = node
        return node
    }

    /// The splat in the room: its box's transform times `to_box` (the box drawn here and the splat
    /// share the region), else the server's `to_canonical`.
    private func placement(_ scan: PreviewFocusScan, _ local: ScanLayer) -> simd_float4x4? {
        let remote = ScanLayers.shared.layer(scan.id, kind: ScanLayer.splat)
        let placement = remote?.version == local.version ? (remote?.placement ?? local.placement) : local.placement
        if let toBox = SplatScene.matrix(placement?.toBox) { return scan.region.transform * toBox }
        return SplatScene.matrix(placement?.toCanonical)
    }

    private func open(_ scan: PreviewFocusScan, _ local: ScanLayer) {
        guard let url = LayerCache.fileURL(scanDirectory: scan.scanDirectory, layer: local) else { return }
        guard placement(scan, local) != nil else {
            failures[scan.id] = "The server sent no placement for this splat."
            return
        }
        let id = scan.id, version = local.version
        opening[id] = version
        let started = CFAbsoluteTimeGetCurrent()
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<SplatCloud, Error> in
                Result { try SOGReader.read(url) }
            }.value
            guard opening[id] == version else { return }
            opening[id] = nil
            switch result {
            case .success(let cloud):
                PerfDiag.log(String(format: "[Splat] %@ in the room preview: %ld Gaussians opened in %.1f s (%@)",
                                    id.uuidString, cloud.count, CFAbsoluteTimeGetCurrent() - started, cloud.decodeNote))
                if let group {
                    let renderer = SplatRenderer(cloud: cloud)
                    let node = renderer.makeNode()
                    group.addChildNode(node)
                    loaded[id] = Loaded(version: version, renderer: renderer, node: node)
                }
            case .failure(let error):
                failures[id] = error.localizedDescription
                PerfDiag.log("[Splat] \(id.uuidString) in the room preview: not opened: \(error.localizedDescription)")
            }
            apply()
        }
    }

    /// SceneKit holds a node's renderer unretained and may be drawing with it on its render
    /// thread, so the renderer outlives the node by a moment.
    private static func release(_ entry: Loaded) {
        entry.node.rendererDelegate = nil
        entry.node.removeFromParentNode()
        let renderer = entry.renderer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = renderer }
    }

    // MARK: The cut

    /// Discards the mesh's fragments inside a shown splat's box. Each box is a matrix from the
    /// scene's world into the box's unit cube; shader modifiers take no arrays, hence the names.
    static let cutModifier: String = {
        var source = "#pragma arguments\n"
        for index in 0..<AppConstants.splatPreviewMaxCuts { source += "float4x4 splatCut\(index);\n" }
        source += "float splatCutCount;\n\n#pragma body\n"
        source += "float4 splatWorld = scn_frame.inverseViewTransform * float4(_surface.position, 1.0);\n"
        for index in 0..<AppConstants.splatPreviewMaxCuts {
            source += "if (splatCutCount > \(index).5) { float3 splatLocal = (splatCut\(index) * splatWorld).xyz; "
                + "if (all(abs(splatLocal) <= float3(1.0))) { discard_fragment(); } }\n"
        }
        return source
    }()

    private func applyCut(in scene: SCNScene, group: SCNNode) {
        let cuts: [simd_float4x4] = scans.compactMap { scan in
            guard loaded[scan.id] != nil else { return nil }
            let half = scan.region.halfExtents
            let scale = simd_float4x4(diagonal: SIMD4<Float>(half.x, half.y, half.z, 1))
            return (group.simdWorldTransform * scan.region.transform * scale).inverse
        }
        guard !cuts.isEmpty || cutInstalled else { return }
        cutInstalled = true
        let count = min(cuts.count, AppConstants.splatPreviewMaxCuts)
        for node in Self.meshNodes(in: scene) {
            for material in node.geometry?.materials ?? [] {
                if material.shaderModifiers?[.surface] != Self.cutModifier {
                    material.shaderModifiers = [.surface: Self.cutModifier]
                }
                material.setValue(NSNumber(value: Float(count)), forKey: "splatCutCount")
                for index in 0..<AppConstants.splatPreviewMaxCuts {
                    let matrix = index < count ? cuts[index] : matrix_identity_float4x4
                    material.setValue(NSValue(scnMatrix4: SCNMatrix4(matrix)), forKey: "splatCut\(index)")
                }
            }
        }
    }

    /// The room meshes: the opened scan's (full, proxy, dynamic) and each timeline generation's.
    private static func meshNodes(in scene: SCNScene) -> [SCNNode] {
        var nodes: [SCNNode] = []
        for name in ["mesh", "proxyMesh", "dynamicMesh"] {
            nodes += scene.rootNode.childNodes(passingTest: { node, _ in node.name == name && node.geometry != nil })
        }
        for slot in scene.rootNode.childNodes(passingTest: { node, _ in node.name == "timelineSlot" }) {
            nodes += slot.childNodes.filter { $0.geometry != nil }
        }
        return nodes
    }
}

/// The legend's focus rows: one per focus scan made against the generation on screen, with what
/// its splat is doing; a tap shows, hides or downloads it.
struct FocusSplatLegend: View {
    let scans: [PreviewFocusScan]
    let overlay: FocusSplatOverlay
    let mode: FocusOverlayMode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text("Focus scans")
                if mode == .splats, overlay.drawnCount > 0 {
                    Text(Self.millions(overlay.drawnCount) + " of " + Self.millions(AppConstants.splatPreviewBudget))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .font(.caption2.bold())
            .foregroundColor(.yellow)
            ForEach(scans) { scan in
                let look = Self.look(Self.live(overlay.states[scan.id], scanId: scan.id), mode: mode)
                Button {
                    overlay.tap(scan)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: look.icon)
                            .foregroundColor(.yellow)
                            .frame(width: 12)
                        Text(scan.name)
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(look.text)
                            .foregroundColor(look.color)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!look.tappable)
            }
        }
    }

    /// The overlay's state, with a splat that isn't on the phone read live (its download's progress).
    static func live(_ state: FocusSplatOverlay.RowState?, scanId: UUID) -> FocusSplatOverlay.RowState {
        switch state {
        case .server?, .noSplat?, nil:
            return ScanLayers.shared.line(for: scanId).map { .server($0) } ?? .noSplat
        case let known?:
            return known
        }
    }

    static func look(_ state: FocusSplatOverlay.RowState, mode: FocusOverlayMode)
        -> (icon: String, text: String, color: Color, tappable: Bool) {
        switch state {
        case .shown(let count):
            return ("cube.transparent.fill", millions(count), .green.opacity(0.9), true)
        case .opening:
            return ("cube.transparent", "opening…", .cyan, false)
        case .hidden:
            return ("cube.transparent", mode == .splats ? "hidden · tap to show" : "on this phone", .white.opacity(0.6),
                    mode == .splats)
        case .overBudget:
            return ("cube.transparent", "tap to show (hides another)", .orange, true)
        case .failed(let message):
            return ("exclamationmark.triangle", message, .yellow, true)
        case .server(let line):
            let card = LayerLine.look(line)
            if let action = card.action, ControlPlaneSync.shared.client != nil {
                return ("icloud.and.arrow.down", action, .cyan, true)
            }
            return ("icloud", card.text, card.color, false)
        case .noSplat:
            return ("square.dashed", "no splat", .white.opacity(0.4), false)
        }
    }

    /// 1052472 -> "1.05M".
    static func millions(_ count: Int) -> String {
        String(format: "%.2fM", Double(count) / 1_000_000)
    }
}
