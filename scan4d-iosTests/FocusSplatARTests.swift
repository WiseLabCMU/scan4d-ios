import ARKit
import SceneKit
import simd
import XCTest
@testable import scan4d_ios

/// Focus splats in AR (REQ-041): when the session counts as in the map's frame, where a box goes in
/// that frame, which boxes are over the same place, and what the rows and the pill say.
final class FocusSplatARTests: XCTestCase {

    private func assertEqual(_ lhs: simd_float4x4, _ rhs: simd_float4x4, file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(lhs[column][row], rhs[column][row], accuracy: 1e-5, file: file, line: line)
            }
        }
    }

    func testTrackingStatesReduceToWhatARNeeds() {
        XCTAssertEqual(FocusARTracking(.normal), .normal)
        XCTAssertEqual(FocusARTracking(.notAvailable), .notAvailable)
        XCTAssertEqual(FocusARTracking(.limited(.initializing)), .initializing)
        XCTAssertEqual(FocusARTracking(.limited(.relocalizing)), .relocalizing)
        XCTAssertEqual(FocusARTracking(.limited(.excessiveMotion)), .excessiveMotion)
        XCTAssertEqual(FocusARTracking(.limited(.insufficientFeatures)), .insufficientFeatures)
    }

    /// Aligned only after a relocalization completes; motion keeps it; a re-initialization that comes
    /// back without relocalizing is a fresh frame, and only another relocalization ends that.
    func testTheMapFrameFollowsRelocalization() {
        var frame = FocusARMapFrame()
        XCTAssertFalse(frame.aligned)
        frame.update(.initializing)
        frame.update(.relocalizing)
        XCTAssertFalse(frame.aligned)
        frame.update(.normal)
        XCTAssertTrue(frame.aligned)
        frame.update(.excessiveMotion)
        frame.update(.insufficientFeatures)
        XCTAssertTrue(frame.aligned)

        frame.update(.initializing)
        XCTAssertFalse(frame.aligned)
        frame.update(.normal)
        XCTAssertFalse(frame.aligned)
        XCTAssertTrue(frame.freshFrame)

        frame.update(.relocalizing)
        XCTAssertFalse(frame.freshFrame)
        frame.update(.normal)
        XCTAssertTrue(frame.aligned)
    }

    /// AR puts a canonical box in the map scan's raw frame through the inverse of its registration,
    /// as focus capture does; a box drawn raw on that same scan is already there. The preview keeps
    /// the region's own frame.
    func testABoxGoesIntoTheMapScansRawFrame() {
        let mapScan = UUID()
        var registration = simd_float4x4(simd_quatf(angle: 0.4, axis: SIMD3<Float>(0, 1, 0)))
        registration.columns.3 = SIMD4<Float>(1, 0, -2, 1)
        let canonical = FocusRegion(center: SIMD3(0.5, 0.4, 1), yaw: 0.2, size: SIMD3(1, 0.8, 0.6))
        let raw = FocusRegion(center: SIMD3(0.5, 0.4, 1), yaw: 0.2, size: SIMD3(1, 0.8, 0.6),
                              frameScanId: mapScan, frameIsCanonical: false)

        let world = FocusSplatStage.world(mapScanId: mapScan, registration: registration, aligned: true)
        assertEqual(world.boxFrame(canonical), registration.inverse * canonical.transform)
        assertEqual(world.boxFrame(raw), raw.transform)
        assertEqual(world.fromCanonical, registration.inverse)

        let unregistered = FocusSplatStage.world(mapScanId: mapScan, registration: nil, aligned: false)
        assertEqual(unregistered.boxFrame(canonical), canonical.transform)
        assertEqual(FocusSplatStage.preview.boxFrame(canonical), canonical.transform)
        XCTAssertTrue(world.isWorld)
        XCTAssertFalse(FocusSplatStage.preview.isWorld)
    }

    /// One region scanned twice is the same place; regions side by side are not.
    func testBoxesOverTheSamePlaceOverlap() {
        let half = SIMD3<Float>(0.4, 0.3, 0.4)
        let first = FocusRegion(center: SIMD3(0, 0.3, 0), size: half * 2).transform
        let redrawn = FocusRegion(center: SIMD3(0.15, 0.3, -0.1), yaw: 0.3, size: half * 2).transform
        let beside = FocusRegion(center: SIMD3(1.0, 0.3, 0), size: half * 2).transform
        XCTAssertTrue(FocusSplatStage.overlap(first, half, redrawn, half))
        XCTAssertFalse(FocusSplatStage.overlap(first, half, beside, half))
        // A small box inside a large one: the small one's centre is inside.
        let large = SIMD3<Float>(1.5, 1, 1.5)
        XCTAssertTrue(FocusSplatStage.overlap(first, large, beside, SIMD3(0.1, 0.1, 0.1)))
    }

    /// A focus scan is its own time slice: its box shows on every generation it is in the frame of,
    /// not only on the room scan it was captured against.
    func testAFocusBoxShowsOnEveryGenerationInItsFrame() {
        let drawnOn = UUID(), other = UUID()
        let canonical = FocusRegion(center: .zero, size: SIMD3(1, 1, 1), frameScanId: drawnOn)
        let raw = FocusRegion(center: .zero, size: SIMD3(1, 1, 1), frameScanId: drawnOn, frameIsCanonical: false)
        XCTAssertTrue(PreviewFocusScan.isDrawable(canonical, on: drawnOn))
        XCTAssertTrue(PreviewFocusScan.isDrawable(canonical, on: other))
        XCTAssertTrue(PreviewFocusScan.isDrawable(canonical, on: nil))
        XCTAssertTrue(PreviewFocusScan.isDrawable(raw, on: drawnOn))
        XCTAssertFalse(PreviewFocusScan.isDrawable(raw, on: other))
        XCTAssertFalse(PreviewFocusScan.isDrawable(raw, on: nil))
    }

    /// AR builds, opens and draws nothing until the session is in the map's frame; lost after
    /// that, what it drew hides.
    func testNothingIsBuiltBeforeARFindsTheSpace() {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        view.scene = SCNScene()
        let scan = PreviewFocusScan(id: UUID(), name: "Desk", capturedAt: Date(),
                                    scanDirectory: FileManager.default.temporaryDirectory,
                                    region: FocusRegion(center: .zero, size: SIMD3(1, 1, 1)))
        let request = FocusARRequest(mapScanId: UUID(), mapScanName: "Lab", worldMapURL: URL(fileURLWithPath: "/dev/null"),
                                     registration: nil, scans: [scan])
        let overlay = FocusSplatOverlay()

        overlay.sync(view: view, scans: [scan], mode: .splats, stage: request.stage(aligned: false))
        XCTAssertNil(view.scene?.rootNode.childNode(withName: "focusOverlay", recursively: false))
        XCTAssertNotNil(overlay.states[scan.id])

        overlay.sync(view: view, scans: [scan], mode: .splats, stage: request.stage(aligned: true))
        let group = view.scene?.rootNode.childNode(withName: "focusOverlay", recursively: false)
        XCTAssertEqual(group?.isHidden, false)
        XCTAssertEqual(group?.childNodes.filter { $0.name == "focusBox" }.count, 1)

        overlay.sync(view: view, scans: [scan], mode: .splats, stage: request.stage(aligned: false))
        XCTAssertEqual(group?.isHidden, true)
        overlay.tearDown()
    }

    /// AR draws Rescan's ghost from the same lines, as SceneKit nodes named for the overlay's cut.
    func testTheGhostBecomesSceneKitLines() {
        let triangle = Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        let parts = GhostWireframe.build(data: triangle, isProxy: false, outlinePlanes: [])
        XCTAssertFalse(parts.mesh.isEmpty)
        XCTAssertTrue(parts.outline.isEmpty)
        let node = GhostWireframe.sceneNode(parts)
        XCTAssertEqual(node?.childNodes.count, 1)
        XCTAssertEqual(node?.childNodes.first?.name, GhostWireframe.sceneNodeName)
        // Three edges, each a thin quad of four vertices.
        XCTAssertEqual(node?.childNodes.first?.geometry?.sources(for: .vertex).first?.vectorCount, 12)
        XCTAssertNil(GhostWireframe.sceneNode(GhostWireframe.Parts()))
        XCTAssertTrue(GhostWireframe.outlinePlanes(isProxy: false, planes: [], levelYs: []).isEmpty)
    }

    func testRowsSayWhatCanBeTapped() {
        XCTAssertFalse(FocusSplatLegend.look(.waiting, mode: .splats).tappable)
        XCTAssertTrue(FocusSplatLegend.look(.covered, mode: .splats).tappable)
        XCTAssertFalse(FocusSplatLegend.look(.tooLarge(count: 4_000_000), mode: .splats).tappable)
        XCTAssertTrue(FocusSplatLegend.look(.tooLarge(count: 4_000_000), mode: .splats).text.hasPrefix("4.00M"))
        XCTAssertFalse(FocusSplatLegend.look(.cooling, mode: .splats).tappable)
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(FocusSplatLegend.dateLine(day).hasPrefix(FocusSplatLegend.shortDate(day) + " · "))
    }

    func testThePillNamesTheState() {
        XCTAssertEqual(FocusSplatARView.pill(.finding(since: Date(), lost: false)).text, "Relocalizing…")
        XCTAssertEqual(FocusSplatARView.pill(.finding(since: Date(), lost: true)).text, "Lost")
        XCTAssertEqual(FocusSplatARView.pill(.freshFrame).text, "Lost")
        XCTAssertEqual(FocusSplatARView.pill(.aligned(note: nil)).text, "Aligned")
        XCTAssertEqual(FocusSplatARView.pill(.aligned(note: "move slower")).text, "Aligned · move slower")
    }

    /// The budget shrinks while the phone is hot and never goes below nothing. With no budget set,
    /// there is no limit until the phone is critically hot, and then nothing is drawn.
    func testTheBudgetFollowsItsScale() {
        let overlay = FocusSplatOverlay()
        XCTAssertEqual(overlay.budget, AppConstants.splatPreviewBudget)
        overlay.setBudgetScale(AppConstants.splatARSeriousBudgetShare)
        XCTAssertEqual(overlay.budget, AppConstants.splatPreviewBudget.map {
            Int(Double($0) * AppConstants.splatARSeriousBudgetShare)
        })
        overlay.setBudgetScale(0)
        XCTAssertEqual(overlay.budget, 0)
        overlay.selection = .init(askedFor: [UUID()])
        XCTAssertEqual(overlay.selection.askedFor.count, 1)
    }
}
