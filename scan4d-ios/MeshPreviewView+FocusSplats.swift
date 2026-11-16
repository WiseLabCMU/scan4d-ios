import SceneKit
import simd
import SwiftUI
import UIKit

// MARK: - Focus splats in the room's 3D preview and in AR (REQ-041)
//
// The room preview draws the space's focus scans on whichever generation is on screen, not only
// the room scan each was captured against: a focus scan is its own time slice of a region. It
// draws each one's box and, once its splat is on this phone, the splat in place of the mesh inside
// the box (the mesh's fragments inside a shown splat's box are discarded by a shader modifier). AR
// (FocusSplatAR.swift) draws the space's focus splats over the camera instead, in the frame of the
// room scan it relocalized into, with a chip over each box, and reads nothing until it has. Splats
// on the phone show by themselves, newest first, within the budget; a legend row (or, in AR, a
// box) shows, hides or downloads its splat, and the one asked for last always wins the budget.
// Boxes over the same place, one region scanned at different times, show one splat at a time.

/// A focus scan the preview or AR can show, snapshotted on the main actor.
struct PreviewFocusScan: Identifiable, Equatable {
    let id: UUID
    let name: String
    let capturedAt: Date
    let scanDirectory: URL
    let region: FocusRegion

    /// The location's focus scans that can be drawn over room scan `roomId`'s mesh, newest first:
    /// every one whose box is in that mesh's frame (`isDrawable`), whichever room scan it was
    /// captured against.
    static func shown(on roomId: UUID?, in location: ScanLocation?) -> [PreviewFocusScan] {
        all(in: location).filter { isDrawable($0.region, on: roomId) }
    }

    /// Whether `region`'s box is in the frame of room scan `roomId`'s mesh in the preview. Every
    /// registered generation's mesh is in the space's canonical frame, so a canonical box is in
    /// all of them. A box drawn on a scan whose registration did not apply is in that scan's raw
    /// frame, so it is drawn on that scan only.
    static func isDrawable(_ region: FocusRegion, on roomId: UUID?) -> Bool {
        if region.frameIsCanonical { return true }
        guard let roomId else { return false }
        return region.frameScanId == roomId
    }

    /// Every focus scan of the location that has a region, newest first.
    static func all(in location: ScanLocation?) -> [PreviewFocusScan] {
        guard let location else { return [] }
        return location.scans
            .filter { $0.isFocusScan }
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

/// Where the overlay draws its boxes and splats.
enum FocusSplatStage {
    /// The room preview: the room mesh's frame (canonical, moved by the mesh's centring offset);
    /// the mesh is cut away inside shown splats.
    case preview
    /// AR: the session's world, which is the raw frame of room scan `mapScanId` once the session
    /// has relocalized into its map; `registration` takes that frame into the canonical one (nil
    /// when none was applied). Nothing is read, decoded or drawn until `aligned` is first true:
    /// relocalizing is work enough for a phone, and outside the map's frame splats would sit
    /// metres off. When it goes false again, what is drawn hides and stays loaded.
    case world(mapScanId: UUID, registration: simd_float4x4?, aligned: Bool)

    var isWorld: Bool {
        if case .world = self { return true }
        return false
    }

    /// The box of `region` into this stage's frame. In AR, the same placement focus capture uses
    /// for its box (`FocusRegion.placement(inRawFrameOf:appliedRegistration:)`).
    func boxFrame(_ region: FocusRegion) -> simd_float4x4 {
        switch self {
        case .preview:
            return region.transform
        case let .world(mapScanId, registration, _):
            return region.placement(inRawFrameOf: mapScanId, appliedRegistration: registration).boxToMap
        }
    }

    /// The canonical frame into this stage's frame.
    var fromCanonical: simd_float4x4 {
        switch self {
        case .preview:
            return matrix_identity_float4x4
        case let .world(_, registration, _):
            return (registration ?? matrix_identity_float4x4).inverse
        }
    }

    /// Whether two boxes (box to frame, half extents) are over the same place: either's centre lies
    /// inside the other. Regions side by side never are; one region scanned twice is.
    static func overlap(_ first: simd_float4x4, _ firstHalf: SIMD3<Float>,
                        _ second: simd_float4x4, _ secondHalf: SIMD3<Float>) -> Bool {
        func inside(_ point: SIMD4<Float>, _ box: simd_float4x4, _ half: SIMD3<Float>) -> Bool {
            let local = box.inverse * point
            return abs(local.x) <= half.x && abs(local.y) <= half.y && abs(local.z) <= half.z
        }
        return inside(second.columns.3, first, firstHalf) || inside(first.columns.3, second, secondHalf)
    }
}

/// The focus boxes and splats in a SceneKit view (the preview's, or AR's), and what each legend
/// row says.
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
        /// On the phone, not drawn: a newer splat (or one asked for since) of the same place is.
        case covered
        /// Larger than the whole budget: this phone never draws it.
        case tooLarge(count: Int)
        /// Larger than the budget left while the phone is hot.
        case cooling
        /// On the phone, in AR before it has found the space: nothing is read until then.
        case waiting
        case failed(String)
        /// Not on the phone: the card's splat line (on the server, downloading, failed).
        case server(ScanLayers.Line)
        /// No splat on the server or the phone.
        case noSplat
    }

    /// The splats asked for and switched off; switching between the preview and AR carries it.
    struct Selection: Equatable {
        var askedFor: [UUID] = []
        var switchedOff: Set<UUID> = []
    }

    /// A splat decoded elsewhere (the other mode, the focus viewer), drawn without decoding again.
    struct Decoded {
        let version: String
        let cloud: SplatCloud
    }

    private(set) var states: [UUID: RowState] = [:]
    /// Gaussians drawn now, against `budget`.
    private(set) var drawnCount = 0
    /// The share of `AppConstants.splatPreviewBudget` in use: below 1 while the phone is hot (AR).
    private(set) var budgetScale: Double = 1
    /// Every splat's opacity, 0...1 (AR's fade and hold).
    @ObservationIgnored var opacity: Float = 1 {
        didSet { for entry in loaded.values { entry.renderer.opacity = opacity } }
    }

    /// Gaussians that may be drawn at once.
    var budget: Int { Int(Double(AppConstants.splatPreviewBudget) * max(0, min(1, budgetScale))) }

    var selection: Selection {
        get { Selection(askedFor: askedFor, switchedOff: switchedOff) }
        set {
            askedFor = newValue.askedFor
            switchedOff = newValue.switchedOff
        }
    }

    private var switchedOff: Set<UUID> = []
    /// Scans whose splat was asked for, most recent first: they win the budget in that order.
    private var askedFor: [UUID] = []
    private var failures: [UUID: String] = [:]

    private struct Loaded {
        let version: String
        let renderer: SplatRenderer
        let node: SCNNode
    }

    private static let hitPrefix = "focusHit:"
    private static let chipPrefix = "focusChip:"

    @ObservationIgnored private weak var view: SCNView?
    @ObservationIgnored private var scans: [PreviewFocusScan] = []
    @ObservationIgnored private var mode: FocusOverlayMode = .off
    @ObservationIgnored private var stage: FocusSplatStage = .preview
    @ObservationIgnored private var group: SCNNode?
    @ObservationIgnored private var boxes: [UUID: SCNNode] = [:]
    @ObservationIgnored private var chips: [UUID: String] = [:]
    @ObservationIgnored private var loaded: [UUID: Loaded] = [:]
    @ObservationIgnored private var opening: [UUID: String] = [:]
    @ObservationIgnored private var preloaded: [UUID: Decoded] = [:]
    @ObservationIgnored private var cutInstalled = false

    /// Brings the scene up to date with `scans`, `mode` and `stage`. Call whenever one changes, a
    /// copy lands on the phone, or a generation loads. In the preview, nothing until the room mesh
    /// is in the scene.
    func sync(view: SCNView?, scans: [PreviewFocusScan], mode: FocusOverlayMode, stage: FocusSplatStage = .preview) {
        self.view = view
        self.scans = scans
        self.mode = mode
        self.stage = stage
        apply()
    }

    /// A legend row's tap (or a box's, in AR): shows or hides a splat on the phone, or downloads one
    /// from the server (it shows once it lands).
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

    /// Shrinks (or restores) the budget, unloading what no longer fits.
    func setBudgetScale(_ scale: Double) {
        guard scale != budgetScale else { return }
        budgetScale = scale
        apply()
    }

    /// Splats decoded elsewhere, drawn by the next sync instead of decoded again; those it does not
    /// draw are dropped.
    func adopt(_ decoded: [UUID: Decoded]) {
        preloaded.merge(decoded) { _, newer in newer }
    }

    /// The splats drawn now, and those handed over and not drawn yet (AR closed before it found the
    /// space), for the other mode to take.
    func decodedSplats() -> [UUID: Decoded] {
        preloaded.merging(loaded.mapValues { Decoded(version: $0.version, cloud: $0.renderer.cloud) }) { _, drawn in drawn }
    }

    /// The focus scan whose chip or box is at `point` in the view (AR only), a chip first, then the
    /// nearest box.
    func scanId(at point: CGPoint) -> UUID? {
        guard stage.isWorld, let view, let group, !group.isHidden else { return nil }
        let hits = view.hitTest(point, options: [
            .rootNode: group,
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .backFaceCulling: false,
            .ignoreHiddenNodes: true,
        ])
        var nearestBox: UUID?
        for hit in hits {
            guard let name = hit.node.name else { continue }
            if name.hasPrefix(Self.chipPrefix) {
                return UUID(uuidString: String(name.dropFirst(Self.chipPrefix.count)))
            }
            if nearestBox == nil, name.hasPrefix(Self.hitPrefix) {
                nearestBox = UUID(uuidString: String(name.dropFirst(Self.hitPrefix.count)))
            }
        }
        return nearestBox
    }

    /// Takes everything out of the scene (the view is closing, or the other mode takes over).
    func tearDown() {
        for entry in loaded.values { Self.release(entry) }
        loaded = [:]
        opening = [:]
        preloaded = [:]
        group?.removeFromParentNode()
        group = nil
        boxes = [:]
        chips = [:]
        if !stage.isWorld { view?.rendersContinuously = false }
        drawnCount = 0
        states = [:]
    }

    // MARK: Applying

    private func apply() {
        guard let view, let scene = view.scene else { return }
        let layers = ScanLayers.shared
        if case .world(_, _, false) = stage {
            // Not in the map's frame. Before AR first finds the space nothing is built, opened or
            // drawn (handed-over splats wait in `preloaded`); after, what is drawn hides and stays.
            self.group?.isHidden = true
            if self.group == nil {
                var waiting: [UUID: RowState] = [:]
                for scan in scans {
                    if layers.local[ScanLayers.key(scan.id, ScanLayer.splat)] != nil {
                        waiting[scan.id] = .waiting
                    } else {
                        waiting[scan.id] = layers.line(for: scan.id).map { RowState.server($0) } ?? RowState.noSplat
                    }
                }
                states = waiting
            }
            return
        }
        let mesh = scene.rootNode.childNode(withName: "mesh", recursively: true)
        if !stage.isWorld, mesh == nil { return }
        let group = groupNode(in: scene)
        // The preview: the mesh's own centring offset, so boxes and splats are in the frame the
        // mesh is in. AR: the session's world.
        group.simdTransform = stage.isWorld ? matrix_identity_float4x4 : mesh?.simdWorldTransform ?? matrix_identity_float4x4
        group.isHidden = false

        let ids = Set(scans.map(\.id))
        for (id, node) in boxes where !ids.contains(id) {
            node.removeFromParentNode()
            boxes[id] = nil
            chips[id] = nil
        }
        var frames: [UUID: simd_float4x4] = [:]
        for scan in scans {
            let frame = stage.boxFrame(scan.region)
            frames[scan.id] = frame
            let box = boxes[scan.id] ?? makeBox(scan, in: group)
            box.simdTransform = frame
            box.isHidden = mode == .off
        }

        // Which splats to draw: those asked for, then the newest, while the budget lasts; of boxes
        // over the same place, only the first.
        let order = scans.sorted { rank($0.id) < rank($1.id) }
        var left = budget
        var wanted: [UUID: ScanLayer] = [:]
        var drawnBoxes: [(frame: simd_float4x4, half: SIMD3<Float>)] = []
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
            let frame = frames[scan.id] ?? scan.region.transform
            let half = scan.region.halfExtents
            if drawnBoxes.contains(where: { FocusSplatStage.overlap($0.frame, $0.half, frame, half) }) {
                next[scan.id] = .covered
                continue
            }
            let count = local.meta?.count ?? 0
            if count > AppConstants.splatPreviewBudget {
                next[scan.id] = .tooLarge(count: count)
                continue
            }
            if count > budget {
                next[scan.id] = .cooling
                continue
            }
            guard count <= left else {
                next[scan.id] = .overBudget
                continue
            }
            left -= count
            wanted[scan.id] = local
            drawnBoxes.append((frame, half))
        }

        for (id, entry) in loaded where wanted[id]?.version != entry.version {
            Self.release(entry)
            loaded[id] = nil
        }
        for scan in order {
            guard let local = wanted[scan.id] else { continue }
            if loaded[scan.id] == nil, let ready = preloaded[scan.id], ready.version == local.version {
                install(ready.cloud, scanId: scan.id, version: local.version, in: group)
            }
            if let entry = loaded[scan.id] {
                guard let placement = placement(scan, local) else { continue }
                entry.node.simdTransform = placement
                next[scan.id] = .shown(count: entry.renderer.cloud.count)
            } else {
                if opening[scan.id] != local.version { open(scan, local) }
                next[scan.id] = failures[scan.id].map { RowState.failed($0) } ?? .opening
            }
        }
        // Decoded splats not drawn now are not kept.
        preloaded = [:]

        states = next
        drawnCount = loaded.values.reduce(0) { $0 + $1.renderer.cloud.count }
        for scan in scans {
            guard let box = boxes[scan.id] else { continue }
            var shown = false
            if case .shown? = next[scan.id] { shown = true }
            // A drawn splat keeps a faint box: an offset between the two is a placement error.
            box.geometry?.firstMaterial?.transparency = shown ? 0.35 : 1
            if stage.isWorld {
                updateChip(scan, state: FocusSplatLegend.live(next[scan.id], scanId: scan.id), on: box)
            }
        }
        applyCut(in: scene, group: group, frames: frames)
        if !stage.isWorld {
            // AR's view draws every camera frame anyway.
            view.rendersContinuously = !loaded.isEmpty
        }
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
        if stage.isWorld { node.addChildNode(Self.hitVolume(scan)) }
        group.addChildNode(node)
        boxes[scan.id] = node
        return node
    }

    /// The splat in the stage's frame: its box's transform times `to_box` (the box drawn here and
    /// the splat share the region), else the server's `to_canonical`.
    private func placement(_ scan: PreviewFocusScan, _ local: ScanLayer) -> simd_float4x4? {
        let remote = ScanLayers.shared.layer(scan.id, kind: ScanLayer.splat)
        let placement = remote?.version == local.version ? (remote?.placement ?? local.placement) : local.placement
        if let toBox = SplatScene.matrix(placement?.toBox) { return stage.boxFrame(scan.region) * toBox }
        return SplatScene.matrix(placement?.toCanonical).map { stage.fromCanonical * $0 }
    }

    private func open(_ scan: PreviewFocusScan, _ local: ScanLayer) {
        guard let url = LayerCache.fileURL(scanDirectory: scan.scanDirectory, layer: local) else { return }
        guard placement(scan, local) != nil else {
            failures[scan.id] = "The server sent no placement for this splat."
            return
        }
        let id = scan.id, version = local.version
        let context = stage.isWorld ? "in AR" : "in the room preview"
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
                PerfDiag.log(String(format: "[Splat] %@ %@: %ld Gaussians opened in %.1f s (%@)",
                                    id.uuidString, context, cloud.count, CFAbsoluteTimeGetCurrent() - started,
                                    cloud.decodeNote))
                if let group { install(cloud, scanId: id, version: version, in: group) }
            case .failure(let error):
                failures[id] = error.localizedDescription
                PerfDiag.log("[Splat] \(id.uuidString) \(context): not opened: \(error.localizedDescription)")
            }
            apply()
        }
    }

    private func install(_ cloud: SplatCloud, scanId: UUID, version: String, in group: SCNNode) {
        // A decode still running for this version is not needed any more.
        opening[scanId] = nil
        let renderer = SplatRenderer(cloud: cloud)
        renderer.opacity = opacity
        let node = renderer.makeNode()
        group.addChildNode(node)
        loaded[scanId] = Loaded(version: version, renderer: renderer, node: node)
    }

    /// SceneKit holds a node's renderer unretained and may be drawing with it on its render
    /// thread, so the renderer outlives the node by a moment.
    private static func release(_ entry: Loaded) {
        entry.node.rendererDelegate = nil
        entry.node.removeFromParentNode()
        let renderer = entry.renderer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = renderer }
    }

    // MARK: AR: chips and tap targets

    /// An invisible box filling the region, so a tap anywhere on it finds its scan.
    private static func hitVolume(_ scan: PreviewFocusScan) -> SCNNode {
        let size = scan.region.size
        let geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.colorBufferWriteMask = []
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.isDoubleSided = true
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        node.name = hitPrefix + scan.id.uuidString
        return node
    }

    /// The label over a box, facing the camera: the scan's name, when it was captured and how long
    /// ago, and what its splat is doing. Redrawn only when its text changes.
    private func updateChip(_ scan: PreviewFocusScan, state: RowState, on box: SCNNode) {
        let look = FocusSplatLegend.look(state, mode: mode)
        let detail = FocusSplatLegend.dateLine(scan.capturedAt) + " · " + look.text
        let key = scan.name + "\n" + detail
        guard chips[scan.id] != key else { return }
        chips[scan.id] = key
        for old in box.childNodes where old.name?.hasPrefix(Self.chipPrefix) == true {
            old.removeFromParentNode()
        }
        let image = SplatChip.image(title: scan.name, detail: detail, detailColor: UIColor(look.color))
        let height = CGFloat(AppConstants.splatChipHeightM)
        let plane = SCNPlane(width: height * image.size.width / max(image.size.height, 1), height: height)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.isDoubleSided = true
        material.readsFromDepthBuffer = false
        material.writesToDepthBuffer = false
        plane.materials = [material]
        let chip = SCNNode(geometry: plane)
        chip.name = Self.chipPrefix + scan.id.uuidString
        // After the splats, which write no depth, so the chip stays readable over its own splat.
        chip.renderingOrder = 2_000
        chip.simdPosition = SIMD3<Float>(0, scan.region.halfExtents.y + AppConstants.splatChipHeightM, 0)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        chip.constraints = [billboard]
        box.addChildNode(chip)
    }

    // MARK: The cut

    /// Discards the mesh's fragments inside a shown splat's box: the room mesh in the preview, the
    /// room scan's ghost in AR. Each box is a matrix from the scene's world into the box's unit
    /// cube; shader modifiers take no arrays, hence the names.
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

    private func applyCut(in scene: SCNScene, group: SCNNode, frames: [UUID: simd_float4x4]) {
        let cuts: [simd_float4x4] = scans.compactMap { scan in
            guard loaded[scan.id] != nil else { return nil }
            let half = scan.region.halfExtents
            let scale = simd_float4x4(diagonal: SIMD4<Float>(half.x, half.y, half.z, 1))
            let frame = frames[scan.id] ?? stage.boxFrame(scan.region)
            return (group.simdWorldTransform * frame * scale).inverse
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

    /// The room meshes: the opened scan's (full, proxy, dynamic) and each timeline generation's in
    /// the preview, the ghost's in AR.
    private static func meshNodes(in scene: SCNScene) -> [SCNNode] {
        var nodes: [SCNNode] = []
        for name in ["mesh", "proxyMesh", "dynamicMesh", GhostWireframe.sceneNodeName] {
            nodes += scene.rootNode.childNodes(passingTest: { node, _ in node.name == name && node.geometry != nil })
        }
        for slot in scene.rootNode.childNodes(passingTest: { node, _ in node.name == "timelineSlot" }) {
            nodes += slot.childNodes.filter { $0.geometry != nil }
        }
        return nodes
    }
}

/// The image on a box's chip in AR: a title line and a coloured detail line on a dark rounded card.
enum SplatChip {
    static func image(title: String, detail: String, detailColor: UIColor) -> UIImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: UIColor.white,
            .paragraphStyle: paragraph,
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .regular),
            .foregroundColor: detailColor,
            .paragraphStyle: paragraph,
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let detailSize = (detail as NSString).size(withAttributes: detailAttributes)
        let pad: CGFloat = 16, gap: CGFloat = 4, maxWidth: CGFloat = 900
        let width = ceil(min(max(titleSize.width, detailSize.width) + 2 * pad, maxWidth))
        let height = ceil(titleSize.height + gap + detailSize.height + 2 * pad * 0.75)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 0, alpha: 0.6).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 14).fill()
            (title as NSString).draw(in: CGRect(x: pad, y: pad * 0.75, width: width - 2 * pad, height: titleSize.height),
                                     withAttributes: titleAttributes)
            (detail as NSString).draw(in: CGRect(x: pad, y: pad * 0.75 + titleSize.height + gap,
                                                 width: width - 2 * pad, height: detailSize.height),
                                      withAttributes: detailAttributes)
        }
    }
}

/// The legend's focus rows: one per focus scan, with what its splat is doing; a tap shows, hides or
/// downloads it.
struct FocusSplatLegend: View {
    let scans: [PreviewFocusScan]
    let overlay: FocusSplatOverlay
    let mode: FocusOverlayMode
    /// Each row names when its scan was captured (AR, where scans of several dates are listed).
    var dated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text("Focus scans")
                if mode == .splats, overlay.drawnCount > 0 {
                    Text(Self.millions(overlay.drawnCount) + " of " + Self.millions(overlay.budget))
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
                        Text(dated ? scan.name + " · " + Self.shortDate(scan.capturedAt) : scan.name)
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
        case .covered:
            return ("square.on.square.dashed", "tap to show instead", .white.opacity(0.6), true)
        case .tooLarge(let count):
            return ("exclamationmark.triangle", millions(count) + ", too large for this phone", .orange, false)
        case .cooling:
            return ("thermometer.high", "paused while the phone is hot", .orange, false)
        case .waiting:
            return ("location.magnifyingglass", "waiting for AR to find the space", .white.opacity(0.6), false)
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

    /// "Nov 2".
    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Nov 2 · 13 days ago": the age is what makes a splat laid over the space as it is now worth
    /// looking at.
    static func dateLine(_ date: Date) -> String {
        shortDate(date) + " · " + date.formatted(.relative(presentation: .named))
    }
}
