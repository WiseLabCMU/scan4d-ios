import ARKit
import Combine
import SceneKit
import simd
import SwiftUI
import UIKit

// MARK: - Focus splats in AR (REQ-041)
//
// The space's focus splats over the camera, where they were captured. The session relocalizes into
// the latest room scan's world map, as Rescan Space does, and reads, decodes and draws no splat
// until it has: relocalizing is work enough for a low-end phone. Then each splat goes in at its box
// (the box in that scan's raw frame, `FocusRegion.placement`, as focus capture places it) times its
// `to_box`. No room mesh: it is too rough to lay over the room itself, and the point is a past
// state of a region over the region as it is now. The room is there as Rescan Space's ghost
// instead (`FocusARGhost`, the map scan's wireframe), which shows how well AR found the room.
//
// Its own ARSCNView and ARSession, never the capture's ARView (custom Metal in that RealityKit view
// crashes on iOS 18, see Wireframe.metal), so the splats are drawn by the same SceneKit node
// renderer as in the 3D preview (`FocusSplatOverlay`, `SplatRenderer`). Starting it interrupts the
// capture tab's warm session if that is still running; ARKit resumes that one when this one pauses.

/// What AR needs from a space, snapshotted on the main actor.
struct FocusARRequest {
    let mapScanId: UUID
    let mapScanName: String
    let worldMapURL: URL
    /// The map scan's raw frame into the space's canonical frame; nil when none was applied.
    let registration: simd_float4x4?
    /// The space's focus scans with a splat, on the server or this phone, newest first.
    let scans: [PreviewFocusScan]
    /// Where the map scan's ghost is read from; nil draws none.
    var ghost: Ghost?

    /// The files of a room scan's ghost (`GhostWireframe.readArtifacts`).
    struct Ghost {
        let scanId: UUID
        let scanDirectory: URL
        let proxyCandidates: [URL]
        let meshURL: URL
    }

    /// Whether `location` can open AR: a device with world tracking, a room scan with a map, and a
    /// focus scan with a splat. Cheap enough for a button's visibility.
    static func isAvailable(in location: ScanLocation?) -> Bool {
        guard ARWorldTrackingConfiguration.isSupported, let location, let map = location.latestRoomScan,
              FileManager.default.fileExists(atPath: map.worldMapURL.path) else { return false }
        return location.scans.contains { $0.isFocusScan && ScanLayers.shared.line(for: $0.id) != nil }
    }

    /// Reads the map scan's registration, so call it on a tap, not in a body.
    static func make(location: ScanLocation?) -> FocusARRequest? {
        guard isAvailable(in: location), let map = location?.latestRoomScan else { return nil }
        return FocusARRequest(
            mapScanId: map.id,
            mapScanName: map.name,
            worldMapURL: map.worldMapURL,
            registration: SaveRegistration.appliedTransform(scanDirectory: map.scanDirectory),
            scans: PreviewFocusScan.all(in: location).filter { ScanLayers.shared.line(for: $0.id) != nil },
            ghost: Ghost(scanId: map.id, scanDirectory: map.scanDirectory,
                         proxyCandidates: [map.scanDirectory.appendingPathComponent("mesh_proxy.obj"),
                                           map.rawDataPath.appendingPathComponent("mesh_proxy.obj")],
                         meshURL: map.meshFileURL))
    }

    func stage(aligned: Bool) -> FocusSplatStage {
        .world(mapScanId: mapScanId, registration: registration, aligned: aligned)
    }
}

/// AR opened over a view that keeps its own state underneath (the focus viewer's cover).
struct FocusARPresentation: Identifiable {
    let id = UUID()
    let request: FocusARRequest
    let overlay: FocusSplatOverlay
}

/// ARKit's tracking state, reduced to what AR needs; made on the delegate queue.
nonisolated enum FocusARTracking: Equatable, Sendable {
    case notAvailable
    case initializing
    case relocalizing
    case normal
    case excessiveMotion
    case insufficientFeatures
    case other

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable: self = .notAvailable
        case .normal: self = .normal
        case .limited(.initializing): self = .initializing
        case .limited(.relocalizing): self = .relocalizing
        case .limited(.excessiveMotion): self = .excessiveMotion
        case .limited(.insufficientFeatures): self = .insufficientFeatures
        default: self = .other
        }
    }
}

/// Whether the session is in the map's frame, by focus capture's rule (`ARCoverageView`'s
/// `updateMapFrame`): out at a (re)initialization and while relocalizing, in once a relocalization
/// completes. Tracking that comes back normal without relocalizing is a fresh frame, not the map's.
/// Excessive motion and too few features keep the frame.
nonisolated struct FocusARMapFrame: Equatable, Sendable {
    private(set) var aligned = false
    /// Tracking restarted outside the map: only Try Again gets back into it.
    private(set) var freshFrame = false
    private var relocalizedSinceInit = false

    mutating func update(_ tracking: FocusARTracking) {
        switch tracking {
        case .notAvailable, .initializing:
            relocalizedSinceInit = false
            aligned = false
        case .relocalizing:
            relocalizedSinceInit = true
            aligned = false
            freshFrame = false
        case .normal:
            aligned = relocalizedSinceInit
            freshFrame = !relocalizedSinceInit
        case .excessiveMotion, .insufficientFeatures, .other:
            break
        }
    }
}

/// The AR session's state for the view: the map, relocalization, and Try Again. Main actor; the
/// session's delegate passes tracking changes here from its own queue.
@Observable
@MainActor
final class FocusARSession {
    enum Status: Equatable {
        case loadingMap
        case failed(String)
        /// Relocalizing; `lost` once it had been aligned.
        case finding(since: Date, lost: Bool)
        case aligned(note: String?)
        case freshFrame
    }

    private(set) var status: Status = .loadingMap
    /// In the map's frame: splats are drawn.
    private(set) var aligned = false
    private(set) var hasView = false
    private(set) var hasMap = false

    @ObservationIgnored private(set) weak var view: ARSCNView?
    @ObservationIgnored private var configuration: ARWorldTrackingConfiguration?
    @ObservationIgnored private var frame = FocusARMapFrame()
    @ObservationIgnored private var tracking: FocusARTracking = .notAvailable
    @ObservationIgnored private var failure: String?
    @ObservationIgnored private var everAligned = false
    @ObservationIgnored private var findingSince = Date()
    @ObservationIgnored private var running = false
    @ObservationIgnored private var closed = false

    func attach(_ view: ARSCNView) {
        self.view = view
        hasView = true
        if configuration != nil, !running { run() }
    }

    /// Reads the room scan's map off the main thread, then starts relocalizing into it.
    func start(mapURL: URL) async {
        guard configuration == nil, !closed else { return }
        guard ARWorldTrackingConfiguration.isSupported else {
            fail("This device can't run AR world tracking.")
            return
        }
        let begun = CFAbsoluteTimeGetCurrent()
        let loaded = await Task.detached(priority: .userInitiated) { () -> LoadedWorldMap? in
            guard let data = try? Data(contentsOf: mapURL),
                  let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
            else { return nil }
            return LoadedWorldMap(map: map)
        }.value
        guard !closed else { return }
        guard let loaded else {
            PerfDiag.log("[SplatAR] map not read: \(mapURL.lastPathComponent)")
            fail("The room scan's map couldn't be read.")
            return
        }
        PerfDiag.log(String(format: "[SplatAR] map read in %.1f s (%ld anchors)",
                            CFAbsoluteTimeGetCurrent() - begun, loaded.map.anchors.count))
        let configuration = ARWorldTrackingConfiguration()
        configuration.initialWorldMap = loaded.map
        self.configuration = configuration
        hasMap = true
        if view != nil { run() }
    }

    /// Relocalizes from scratch: after a fresh frame, a wrong alignment, or a session failure.
    func tryAgain() {
        guard configuration != nil else { return }
        PerfDiag.log("[SplatAR] try again")
        run()
    }

    /// The view is closing: the camera stops and the map is released.
    func stop() {
        closed = true
        view?.session.pause()
        configuration = nil
    }

    func trackingChanged(_ tracking: FocusARTracking) {
        guard !closed else { return }
        self.tracking = tracking
        let was = frame.aligned
        frame.update(tracking)
        if frame.aligned != was {
            if frame.aligned {
                PerfDiag.log(String(format: "[SplatAR] aligned, %.1f s after %@",
                                    Date().timeIntervalSince(findingSince), everAligned ? "losing the frame" : "starting"))
                everAligned = true
            } else {
                findingSince = Date()
                PerfDiag.log("[SplatAR] out of the map's frame (\(tracking))")
            }
        }
        publish()
    }

    func interrupted() {
        PerfDiag.log("[SplatAR] session interrupted")
    }

    func interruptionEnded() {
        PerfDiag.log("[SplatAR] session interruption ended; relocalizing")
    }

    func sessionFailed(_ message: String) {
        guard !closed else { return }
        PerfDiag.log("[SplatAR] session failed: \(message)")
        fail(message)
    }

    private func fail(_ message: String) {
        failure = message
        running = false
        publish()
    }

    private func run() {
        guard !closed, let view, let configuration else { return }
        running = true
        failure = nil
        frame = FocusARMapFrame()
        tracking = .notAvailable
        findingSince = Date()
        publish()
        view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func publish() {
        aligned = failure == nil && frame.aligned
        if let failure {
            status = .failed(failure)
        } else if configuration == nil {
            status = .loadingMap
        } else if frame.aligned {
            switch tracking {
            case .excessiveMotion: status = .aligned(note: "move slower")
            case .insufficientFeatures: status = .aligned(note: "too little detail in view")
            default: status = .aligned(note: nil)
            }
        } else if frame.freshFrame {
            status = .freshFrame
        } else {
            status = .finding(since: findingSince, lost: everAligned)
        }
    }
}

/// An `ARWorldMap` handed from the decoding task to the main actor.
private nonisolated struct LoadedWorldMap: @unchecked Sendable {
    let map: ARWorldMap
}

/// The map scan's ghost in AR: Rescan Space's wireframe of the room (`GhostWireframe`), at identity
/// in the session's world, which is the map scan's raw frame. It shows how well AR found the room,
/// and gives the splats the room around them (the mesh itself is too rough to lay over the room).
/// Like the splats, it is read and built only once AR first finds the space, off the main thread,
/// and drawn only while AR is in the map's frame.
@Observable
@MainActor
final class FocusARGhost {
    enum State: Equatable {
        case notLoaded
        case loading
        case ready
        /// The map scan has no mesh to draw.
        case missing
    }

    private(set) var state: State = .notLoaded
    @ObservationIgnored private var node: SCNNode?
    @ObservationIgnored private var closed = false

    /// Reads and builds the ghost once, then adds it to `view`'s scene, hidden (`setVisible`).
    func load(_ source: FocusARRequest.Ghost, into view: SCNView) async {
        guard state == .notLoaded, !closed else { return }
        state = .loading
        let begun = CFAbsoluteTimeGetCurrent()
        let built = await withCheckedContinuation { (continuation: CheckedContinuation<BuiltGhost, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let artifacts = GhostWireframe.readArtifacts(
                    scanDirectory: source.scanDirectory, proxyCandidates: source.proxyCandidates,
                    meshFileURL: source.meshURL, withProxy: true, context: "splat AR", scanId: source.scanId)
                guard let data = artifacts.data else {
                    continuation.resume(returning: BuiltGhost(node: nil, isProxy: false))
                    return
                }
                let outline = GhostWireframe.outlinePlanes(isProxy: artifacts.isProxy, planes: artifacts.planes,
                                                           levelYs: artifacts.levelYs)
                let parts = GhostWireframe.build(data: data, isProxy: artifacts.isProxy, outlinePlanes: outline)
                continuation.resume(returning: BuiltGhost(node: GhostWireframe.sceneNode(parts), isProxy: artifacts.isProxy))
            }
        }
        guard !closed else { return }
        guard let node = built.node, let scene = view.scene else {
            state = .missing
            PerfDiag.log("[SplatAR] no room scan mesh to draw as the ghost")
            return
        }
        node.isHidden = true
        scene.rootNode.addChildNode(node)
        self.node = node
        state = .ready
        PerfDiag.log(String(format: "[SplatAR] ghost (%@) built in %.1f s",
                            built.isProxy ? "proxy" : "full mesh", CFAbsoluteTimeGetCurrent() - begun))
    }

    func setVisible(_ visible: Bool) {
        node?.isHidden = !visible
    }

    /// The view is closing.
    func tearDown() {
        closed = true
        node?.removeFromParentNode()
        node = nil
    }
}

/// A ghost built off the main thread, handed to the main actor (nothing in it is in a scene yet).
private nonisolated struct BuiltGhost: @unchecked Sendable {
    let node: SCNNode?
    let isProxy: Bool
}

/// The camera, and the scene the splats are drawn in (ARKit's world, metres).
struct FocusARSceneView: UIViewRepresentable {
    let session: FocusARSession
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: session) }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.scene = SCNScene()
        view.automaticallyUpdatesLighting = false
        view.rendersCameraGrain = false
        view.rendersMotionBlur = false
        view.antialiasingMode = .none
        // Off the main thread (CONTRIBUTING: the ARSession delegate must run off main).
        view.session.delegateQueue = context.coordinator.queue
        view.session.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.onTap = onTap
        session.attach(view)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.onTap = onTap
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        view.session.pause()
        view.session.delegate = nil
    }

    final class Coordinator: NSObject, ARSessionDelegate {
        let model: FocusARSession
        let queue = DispatchQueue(label: "org.arenaxr.scan4d.splat-ar", qos: .userInitiated)
        var onTap: ((CGPoint) -> Void)?

        init(model: FocusARSession) {
            self.model = model
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap?(recognizer.location(in: recognizer.view))
        }

        // Delegate queue: everything goes to the main actor, in order.

        nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            let tracking = FocusARTracking(camera.trackingState)
            DispatchQueue.main.async { [model] in
                MainActor.assumeIsolated { model.trackingChanged(tracking) }
            }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            DispatchQueue.main.async { [model] in
                MainActor.assumeIsolated { model.interrupted() }
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            DispatchQueue.main.async { [model] in
                MainActor.assumeIsolated { model.interruptionEnded() }
            }
        }

        /// After an interruption, back into the same frame rather than a new one.
        nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            let message = error.localizedDescription
            DispatchQueue.main.async { [model] in
                MainActor.assumeIsolated { model.sessionFailed(message) }
            }
        }
    }
}

/// AR: the space's focus splats over the camera, with the room scan's ghost. A status pill
/// (Relocalizing, Aligned, Lost) with Try Again; a chip over each box, and a tap on a box or its row
/// shows, hides or downloads its splat; a fade slider and a press-and-hold that hides the splats, to
/// compare a past state with the space as it is now; a Room button for the ghost. The budget shrinks
/// while the phone is hot.
struct FocusSplatARView: View {
    let request: FocusARRequest
    /// Owned by the presenter, which hands its selection and decoded splats in and takes them back.
    let overlay: FocusSplatOverlay
    let close: () -> Void

    @State private var session = FocusARSession()
    @State private var ghost = FocusARGhost()
    @State private var showRoom = true
    @State private var fade: Double = 1
    @State private var holding = false
    @State private var showRegions = true
    @State private var slowFind = false
    @State private var toast: String?
    @State private var idleTimerWasDisabled = false

    private var shownOpacity: Float { holding ? 0 : Float(fade) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            FocusARSceneView(session: session) { point in tapped(point) }
                .ignoresSafeArea()
            VStack(spacing: 8) {
                topBar
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 420)
                }
                Spacer()
                if let toast {
                    Label(toast, systemImage: "thermometer.high")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
                bottomBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .statusBarHidden()
        .task { await session.start(mapURL: request.worldMapURL) }
        .task(id: syncKey) {
            overlay.sync(view: session.view, scans: request.scans, mode: .splats,
                         stage: request.stage(aligned: session.aligned))
        }
        .task(id: request.scans.map(\.id)) {
            for scan in request.scans {
                await ScanLayers.shared.readLocal(scanId: scan.id, scanDirectory: scan.scanDirectory)
            }
        }
        // The ghost, like the splats, once AR has found the space.
        .task(id: session.aligned) {
            guard session.aligned, let source = request.ghost, let view = session.view else { return }
            await ghost.load(source, into: view)
        }
        .onChange(of: ghostVisible, initial: true) { _, visible in ghost.setVisible(visible) }
        .task(id: session.status) {
            slowFind = false
            guard case .finding = session.status else { return }
            try? await Task.sleep(for: .seconds(AppConstants.splatARSlowFindSeconds))
            if !Task.isCancelled { slowFind = true }
        }
        .onChange(of: fade) { _, _ in overlay.opacity = shownOpacity }
        .onChange(of: holding) { _, _ in overlay.opacity = shownOpacity }
        // Out of the map's frame the hold button is disabled, so a hold's release would never come.
        .onChange(of: session.aligned) { _, aligned in
            if !aligned { holding = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            applyThermalState()
        }
        .onAppear {
            idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
            overlay.opacity = shownOpacity
            applyThermalState()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
            session.stop()
            overlay.tearDown()
            ghost.tearDown()
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close AR")
            Spacer(minLength: 0)
            statusPill
            Spacer(minLength: 0)
            Button {
                session.tryAgain()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Try Again")
            .disabled(!session.hasMap)
        }
        .foregroundColor(.white)
    }

    private var statusPill: some View {
        let look = Self.pill(session.status)
        return HStack(spacing: 6) {
            if case .loadingMap = session.status {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.8)
            } else {
                Image(systemName: look.icon)
                    .foregroundColor(look.color)
            }
            Text(look.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hint: String? {
        switch session.status {
        case .loadingMap, .aligned:
            return nil
        case .failed(let message):
            return message
        case .finding(_, let lost):
            if lost { return "Point the camera back at the space." }
            return slowFind
                ? "Still looking. Stand where the room was scanned, and look at walls and furniture in good light."
                : "Point the camera at the space and move slowly, so AR can recognize it."
        case .freshFrame:
            return "Tracking restarted outside the space's map. Tap Try Again."
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            regionsPanel
            Spacer(minLength: 0)
            VStack(spacing: 12) {
                if request.ghost != nil, ghost.state != .missing {
                    roomButton
                }
                holdButton
            }
        }
    }

    /// The room scan's ghost: shown once loaded, while AR is in the map's frame, unless switched off.
    private var ghostVisible: Bool {
        session.aligned && showRoom && ghost.state == .ready
    }

    /// Shows or hides the room scan's ghost, the check on how well AR found the room.
    private var roomButton: some View {
        Button {
            showRoom.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: showRoom ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                Text("Room")
                    .font(.caption2)
            }
            .foregroundColor(.white)
        }
        .accessibilityLabel(showRoom ? "Hide the room scan" : "Show the room scan")
        .disabled(!session.aligned)
        .opacity(session.aligned ? 1 : 0.4)
    }

    /// The regions, also those off screen or behind you, and the fade.
    private var regionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRegions.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up")
                    Text("Regions")
                    Image(systemName: showRegions ? "chevron.down" : "chevron.up")
                }
                .font(.caption.bold())
                .foregroundColor(.white)
            }
            .accessibilityLabel(showRegions ? "Hide the regions" : "Show the regions")
            if showRegions {
                if request.scans.count > 5 {
                    ScrollView {
                        legend
                    }
                    .frame(maxHeight: 160)
                } else {
                    legend
                }
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                    Slider(value: $fade, in: 0...1)
                }
                .font(.caption)
                .foregroundColor(.white)
                .accessibilityLabel("Splat opacity")
            }
        }
        .padding(10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
    }

    private var legend: some View {
        FocusSplatLegend(scans: request.scans, overlay: overlay, mode: .splats, dated: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Press and hold: the splats go, and the space shows as it is now.
    private var holdButton: some View {
        VStack(spacing: 4) {
            Image(systemName: holding ? "eye" : "eye.slash")
                .font(.title2)
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial, in: Circle())
            Text("Hold to see now")
                .font(.caption2)
        }
        .foregroundColor(.white)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 60, perform: {}, onPressingChanged: { pressing in
            holding = pressing
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hide the splats")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { holding.toggle() }
        // Nothing is drawn before AR finds the space.
        .disabled(!session.aligned)
        .opacity(session.aligned ? 1 : 0.4)
    }

    // MARK: Behaviour

    /// Everything the scene follows; a change re-syncs it.
    private var syncKey: String {
        let layers = ScanLayers.shared
        let rows = request.scans.map { scan -> String in
            let key = ScanLayers.key(scan.id, ScanLayer.splat)
            return "\(scan.id):\(layers.local[key]?.version ?? "-"):"
                + "\(layers.layer(scan.id, kind: ScanLayer.splat)?.version ?? "-"):\(Self.lineKey(layers.line(for: scan.id)))"
        }
        // The ghost's arrival re-syncs too: the overlay cuts it inside shown splats' boxes.
        return "\(session.aligned)|\(session.hasView)|\(ghost.state)|" + rows.joined(separator: ",")
    }

    /// A splat line, with a download's progress in whole percent (the chips show it).
    private static func lineKey(_ line: ScanLayers.Line?) -> String {
        guard let line else { return "-" }
        if case .downloading(let fraction) = line { return "d\(Int(fraction * 100))" }
        return String(describing: line)
    }

    private func tapped(_ point: CGPoint) {
        guard let id = overlay.scanId(at: point), let scan = request.scans.first(where: { $0.id == id }) else { return }
        overlay.tap(scan)
    }

    /// Hot: the budget shrinks (half at serious when there is a budget, none at critical), and a
    /// note names what went.
    private func applyThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        let scale: Double
        switch state {
        case .serious: scale = AppConstants.splatARSeriousBudgetShare
        case .critical: scale = 0
        default: scale = 1
        }
        guard scale != overlay.budgetScale else { return }
        let before = shownIds
        overlay.setBudgetScale(scale)
        PerfDiag.log("[SplatAR] thermal state \(state.rawValue): budget \(overlay.budget.map(String.init) ?? "none")")
        let hidden = request.scans.filter { before.contains($0.id) && !shownIds.contains($0.id) }.map(\.name)
        guard !hidden.isEmpty else { return }
        withAnimation { toast = "The phone is hot: hid " + hidden.joined(separator: ", ") }
        Task {
            try? await Task.sleep(for: .seconds(AppConstants.splatARToastSeconds))
            withAnimation { toast = nil }
        }
    }

    private var shownIds: Set<UUID> {
        Set(overlay.states.compactMap { entry -> UUID? in
            if case .shown = entry.value { return entry.key }
            return nil
        })
    }

    static func pill(_ status: FocusARSession.Status) -> (icon: String, text: String, color: Color) {
        switch status {
        case .loadingMap:
            return ("map", "Loading the map…", .cyan)
        case .failed:
            return ("exclamationmark.triangle.fill", "AR stopped", .red)
        case .finding(_, let lost):
            return lost ? ("location.slash", "Lost", .red) : ("location.magnifyingglass", "Relocalizing…", .yellow)
        case .aligned(let note):
            return ("checkmark.circle.fill", note.map { "Aligned · " + $0 } ?? "Aligned", .green)
        case .freshFrame:
            return ("location.slash", "Lost", .red)
        }
    }
}

// A compile and layout check only: AR needs a device with a camera, and this map file is empty, so
// the canvas shows the failure state.
#Preview {
    FocusSplatARView(
        request: FocusARRequest(mapScanId: UUID(), mapScanName: "Lab", worldMapURL: URL(fileURLWithPath: "/dev/null"),
                                registration: nil, scans: []),
        overlay: FocusSplatOverlay(),
        close: {})
}
