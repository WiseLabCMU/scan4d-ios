import SceneKit
import simd
import SwiftUI
import UIKit

// MARK: - Focus viewer: the splat and the photos (REQ-041)

/// A focus scan's viewer, opened from its card: the splat the Scan4D server made of it, and its
/// photos. It opens on the splat when the scan has one, on this phone or on the server; a scan
/// without one shows its photos as before, with no switch.
struct FocusScanView: View {
    let scan: CapturedScan
    @State private var tab: Tab

    enum Tab: Hashable {
        case splat
        case photos
    }

    init(scan: CapturedScan) {
        self.scan = scan
        _tab = State(initialValue: ScanLayers.shared.line(for: scan.id) != nil ? .splat : .photos)
    }

    private var hasSplat: Bool { ScanLayers.shared.line(for: scan.id) != nil }

    var body: some View {
        Group {
            if tab == .splat && hasSplat {
                FocusSplatPane(scan: scan)
            } else {
                FocusScanPhotosView(scan: scan)
            }
        }
        .toolbar {
            if hasSplat {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        Text("Splat").tag(Tab.splat)
                        Text("Photos").tag(Tab.photos)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
        }
        .task(id: scan.id) {
            await ScanLayers.shared.readLocal(scanId: scan.id, scanDirectory: scan.scanDirectory)
        }
    }
}

/// The splat in its focus box, with no room around it: drag to orbit the box, pinch to zoom. A
/// splat not yet on this phone waits for Download (the card's splat line, repeated here).
struct FocusSplatPane: View {
    let scan: CapturedScan

    @State private var cloud: SplatCloud?
    @State private var cloudVersion: String?
    @State private var opening = false
    @State private var failure: String?
    @State private var showBox = true
    @State private var ar: FocusARPresentation?

    var body: some View {
        let layers = ScanLayers.shared
        let local = layers.local[ScanLayers.key(scan.id, ScanLayer.splat)]
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            // Out of the scene while AR is open (the decoded splat stays, and AR draws it): two
            // splat views drawing at once is too much for a low-end phone.
            if let cloud, let local, ar == nil {
                SplatSceneView(cloud: cloud,
                               placement: SplatScene.placementInBox(local: local,
                                                                    remote: layers.layer(scan.id, kind: ScanLayer.splat),
                                                                    cloud: cloud),
                               halfExtents: scan.focusRegion?.halfExtents,
                               showBox: showBox)
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                status(local: local)
            }
            .padding()
        }
        .navigationTitle(scan.name)
        .task(id: local?.version) { await open(local) }
        .fullScreenCover(item: $ar) { presentation in
            FocusSplatARView(request: presentation.request, overlay: presentation.overlay, close: { ar = nil })
        }
    }

    /// AR over the space, with this splat asked for first and its decoded copy handed over.
    private func openAR() {
        guard let request = FocusARRequest.make(location: scan.location) else { return }
        let overlay = FocusSplatOverlay()
        overlay.selection = FocusSplatOverlay.Selection(askedFor: [scan.id])
        if let cloud, let cloudVersion {
            overlay.adopt([scan.id: FocusSplatOverlay.Decoded(version: cloudVersion, cloud: cloud)])
        }
        ar = FocusARPresentation(request: request, overlay: overlay)
    }

    private func status(local: ScanLayer?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if opening {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Opening the splat…")
                }
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.yellow)
            } else if let cloud, let local {
                HStack(spacing: 8) {
                    Text(SplatScene.summary(count: cloud.count, version: local.version))
                    Spacer()
                    if FocusARRequest.isAvailable(in: scan.location) {
                        Button {
                            openAR()
                        } label: {
                            Label("AR", systemImage: "arkit")
                        }
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                        .accessibilityLabel("View in AR")
                    }
                    if scan.focusRegion != nil {
                        Button {
                            showBox.toggle()
                        } label: {
                            Label("Box", systemImage: showBox ? "cube" : "cube.transparent")
                        }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                    }
                }
            }
            LayerLine(scan: scan)
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    /// Decodes the copy on this phone (off the main thread), once per version.
    private func open(_ local: ScanLayer?) async {
        guard let local, let url = LayerCache.fileURL(scanDirectory: scan.scanDirectory, layer: local) else {
            cloud = nil
            cloudVersion = nil
            return
        }
        guard cloud == nil || cloudVersion != local.version else { return }
        opening = true
        failure = nil
        let id = scan.id.uuidString
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let made = try await Task.detached(priority: .userInitiated) { try SOGReader.read(url) }.value
            cloud = made
            cloudVersion = local.version
            PerfDiag.log(String(format: "[Splat] %@: %ld Gaussians opened in %.1f s (%@)",
                                id, made.count, CFAbsoluteTimeGetCurrent() - started, made.decodeNote))
        } catch {
            cloud = nil
            cloudVersion = nil
            failure = error.localizedDescription
            PerfDiag.log("[Splat] \(id): not opened: \(error.localizedDescription)")
        }
        opening = false
    }
}

/// A SceneKit view of one splat in its box's frame (origin at the box centre, +Y up), with the
/// box's outline. Orbits the box centre.
struct SplatSceneView: UIViewRepresentable {
    let cloud: SplatCloud
    /// The splat's own coordinates into the view's.
    let placement: simd_float4x4
    var halfExtents: SIMD3<Float>?
    var showBox = true

    final class Coordinator {
        var renderer: SplatRenderer?
        var splatNode: SCNNode?
        var boxNode: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.antialiasingMode = .none
        // A finished sort only reaches the screen on the next frame.
        view.rendersContinuously = true
        view.allowsCameraControl = true
        let scene = SCNScene()
        view.scene = scene

        let extent = halfExtents ?? (cloud.boundsMax - cloud.boundsMin) / 2
        let radius = max(simd_length(extent), 0.1)
        let camera = SCNCamera()
        // The splat node has no geometry, so SceneKit's automatic range wouldn't include it.
        camera.automaticallyAdjustsZRange = false
        camera.zNear = 0.01
        camera.zFar = Double(max(50, radius * 20))
        camera.fieldOfView = 55
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let distance = radius * 2.6
        cameraNode.simdPosition = SIMD3<Float>(0, distance * 0.45, distance)
        cameraNode.simdLook(at: .zero)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3Zero

        if let halfExtents {
            let box = SCNNode(geometry: SplatScene.boxOutline(halfExtents: halfExtents))
            box.name = "focusBox"
            box.isHidden = !showBox
            scene.rootNode.addChildNode(box)
            context.coordinator.boxNode = box
        }
        install(cloud, in: scene, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let coordinator = context.coordinator
        coordinator.boxNode?.isHidden = !showBox
        if coordinator.renderer?.cloud !== cloud, let scene = view.scene {
            Self.release(coordinator)
            install(cloud, in: scene, coordinator: coordinator)
        }
        coordinator.splatNode?.simdTransform = placement
    }

    static func dismantleUIView(_ view: SCNView, coordinator: Coordinator) {
        view.rendersContinuously = false
        release(coordinator)
    }

    private func install(_ cloud: SplatCloud, in scene: SCNScene, coordinator: Coordinator) {
        let renderer = SplatRenderer(cloud: cloud)
        let node = renderer.makeNode()
        node.simdTransform = placement
        scene.rootNode.addChildNode(node)
        coordinator.renderer = renderer
        coordinator.splatNode = node
    }

    /// Takes the splat out of the scene. SceneKit holds its renderer unretained and may be drawing
    /// a frame with it on its render thread, so the renderer is kept a moment longer.
    private static func release(_ coordinator: Coordinator) {
        coordinator.splatNode?.rendererDelegate = nil
        coordinator.splatNode?.removeFromParentNode()
        let renderer = coordinator.renderer
        coordinator.splatNode = nil
        coordinator.renderer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { _ = renderer }
    }
}

// MARK: - Helpers

nonisolated enum SplatScene {
    /// A 4x4 column-major matrix as the server sends it, or nil.
    static func matrix(_ values: [Float]?) -> simd_float4x4? {
        guard let flat = values, flat.count == 16, flat.allSatisfy(\.isFinite) else { return nil }
        return simd_float4x4(columns: (SIMD4(flat[0], flat[1], flat[2], flat[3]), SIMD4(flat[4], flat[5], flat[6], flat[7]),
                                       SIMD4(flat[8], flat[9], flat[10], flat[11]), SIMD4(flat[12], flat[13], flat[14], flat[15])))
    }

    /// The splat into its focus box's frame. The server's placement for the version on the phone:
    /// the sync's when it is the same version (it follows box edits), else the one downloaded with
    /// it. Without `to_box`, the splat is stood upright (`to_capture`) and centred on its bounds.
    static func placementInBox(local: ScanLayer, remote: ScanLayer?, cloud: SplatCloud) -> simd_float4x4 {
        let placement = remote?.version == local.version ? (remote?.placement ?? local.placement) : local.placement
        if let toBox = matrix(placement?.toBox) { return toBox }
        let upright = matrix(placement?.toCapture) ?? matrix_identity_float4x4
        let center = upright * SIMD4<Float>(cloud.center, 1)
        var recentre = matrix_identity_float4x4
        recentre.columns.3 = SIMD4<Float>(-center.x, -center.y, -center.z, 1)
        return recentre * upright
    }

    /// "1,052,472 Gaussians · made Nov 15".
    static func summary(count: Int, version: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let made = parser.date(from: version).map { " · made " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? ""
        return "\(count.formatted()) Gaussians" + made
    }

    /// A box's 12 edges, centred on the origin.
    static func boxOutline(halfExtents half: SIMD3<Float>, color: UIColor = .systemYellow) -> SCNGeometry {
        // Corner k takes x from bit 0, y from bit 1, z from bit 2: edges join corners one bit apart.
        let corners = (0..<8).map { corner in
            SCNVector3(corner & 1 == 0 ? -half.x : half.x, corner & 2 == 0 ? -half.y : half.y,
                       corner & 4 == 0 ? -half.z : half.z)
        }
        var indices: [UInt16] = []
        for corner in 0..<8 {
            for bit in [1, 2, 4] where corner & bit == 0 {
                indices.append(UInt16(corner))
                indices.append(UInt16(corner | bit))
            }
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .line)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }
}
