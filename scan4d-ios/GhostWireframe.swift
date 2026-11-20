import Foundation
import RealityKit
import SceneKit
import simd
import UIKit

// MARK: - The ghost: a room scan drawn as lines over the camera
//
// Rescan Space's ghost, shared with AR's splat view. A room scan's light proxy mesh
// (`mesh_proxy.obj`: the content mesh with RoomPlan wall and floor quads baked in as a ~1 m
// lattice) when it has one, else its full mesh, in the scan's RAW capture frame, the frame its
// world map relocalizes into. The mesh is drawn as thin lines, the proxy's lattice bolder, and the
// room's outline (wall corners, wall-floor seams, the ceiling line) boldest and lighter. Rescan
// Space (ARCoverageView) draws it in RealityKit; AR's splat view (FocusSplatAR) draws the same
// lines in SceneKit.

enum GhostWireframe {
    /// A room scan's ghost files, read and put back in its raw capture frame.
    struct Artifacts {
        var data: Data?
        var isProxy = false
        /// The room's planes (RoomPlan surfaces), raw frame: the outline, and Rescan's auto-align.
        var planes: [PlaneRegistration.Plane] = []
        /// Heights of the proxy's derived levels, raw frame (the outline skips the floors they replaced).
        var levelYs: [Float] = []
    }

    /// The ghost's line geometry, in chunks: the mesh (a proxy's lattice included) and the outline.
    struct Parts {
        var mesh: [MeshDescriptor] = []
        var outline: [MeshDescriptor] = []
    }

    /// Reads a room scan's ghost: the proxy (when `withProxy` and one exists) else the full mesh,
    /// with its planes and derived levels when `withProxy`. Background: file reads and an O(n)
    /// text pass. `context` names the caller in the logs.
    static func readArtifacts(scanDirectory: URL, proxyCandidates: [URL], meshFileURL: URL,
                              withProxy: Bool, context: String, scanId: UUID) -> Artifacts {
        // DECISION 2: rescans AND adjacent-connects load the light proxy (walls/floor/ceiling subtracted, RoomPlan
        // quads baked in) instead of the full 10⁵–10⁶-face mesh — killing the 2× mesh-
        // coexistence memory and most of the ghost render/parse cost. A proxy ghost also
        // retires the mesh-ICP path for the session (plane auto-align drives the green chip;
        // save-time registration is the correction authority) — the dense-ICP machinery only
        // engages for legacy scans with no proxy artifact.
        var artifacts = Artifacts()
        if withProxy {
            for url in proxyCandidates {
                if let data = try? Data(contentsOf: url) {
                    artifacts.data = data
                    artifacts.isProxy = true
                    print("[GhostProxy] \(context) ghost using proxy (\(data.count / 1024)KB)")
                    break
                }
            }
        }
        if !artifacts.isProxy {
            artifacts.data = try? Data(contentsOf: meshFileURL)
        }
        // DECISION 1 co-framing: if this scan's mesh was registered into the canonical frame
        // at ITS save, undo that here — the live session relocalizes into the scan's RAW
        // capture frame (the world map can't be re-based), and the ghost must share it
        // (visual overlay, manual nudge, and the ICP probe all assume ghost ≡ live frame).
        // One O(n) text pass, only for scans that actually carry an applied registration.
        let undo = SaveRegistration.inverseForGhost(scanDirectory: scanDirectory)
        if let data = artifacts.data, let undo {
            artifacts.data = SaveRegistration.transformOBJ(data, by: undo)
            print("[PlaneReg] ghost mesh de-registered back to its raw capture frame for relocalization overlay")
        }
        guard withProxy else { return artifacts }
        // The room's planes in the SAME raw frame as the (de-registered) mesh and world map: the
        // outline, and Rescan's ghost auto-align reference.
        artifacts.planes = SaveRegistration.rawFramePlanes(scanDirectory: scanDirectory)
        if !artifacts.planes.isEmpty {
            print("[PlaneReg] ghost auto-align reference loaded: \(artifacts.planes.count) planes")
        } else {
            // Loud, not silent: without reference planes there is NO auto-align, NO plane
            // detection, and no [PlaneReg] output at all — this line is the only breadcrumb.
            print("[PlaneReg] auto-align DISABLED: no reference planes — roomplan.json missing/undecodable for scan \(scanId) (was a room built at its save?)")
        }
        // Derived LEVEL heights, for the renderer's outline set: the proxy builder replaced the
        // RoomPlan floor quads these matched, so outlining those floors draws a rectangle around
        // geometry the ghost no longer contains. The sidecar is co-framed with mesh.obj — canonical
        // for a registered scan — so its heights go through the SAME raw-frame undo the reference
        // planes take above (skipping it puts them in the wrong frame on exactly those scans).
        if let derived = DerivedSurfacesData.load(scanDirectory: scanDirectory) {
            artifacts.levelYs = derived.surfaces
                .filter { $0.category == DerivedSurfacesData.levelCategory }
                .compactMap { surface in
                    guard let plane = PlaneRegistration.plane(category: "floor", width: surface.dimensions.width,
                                                              height: surface.dimensions.height,
                                                              transform: surface.transform) else { return nil }
                    return (undo.map { PlaneRegistration.applying($0, to: plane) } ?? plane).center.y
                }
            if !artifacts.levelYs.isEmpty {
                print("[GhostProxy] ghost derived levels for outline suppression: \(artifacts.levelYs.count)")
            }
        }
        return artifacts
    }

    /// The planes the room outline is drawn from: a proxy ghost's reference planes, minus the floors
    /// a derived level replaced (the builder swapped that quad for the level's own rectangle, so
    /// outlining the floor draws a border around geometry the proxy does not contain). None for a
    /// full-mesh ghost.
    static func outlinePlanes(isProxy: Bool, planes: [PlaneRegistration.Plane],
                              levelYs: [Float]) -> [PlaneRegistration.Plane] {
        guard isProxy else { return [] }
        return planes.filter { plane in
            !(plane.category == .floor && ARCoverageView.outlinedFloorIsReplaced(floorY: plane.center.y,
                                                                                 levelYs: levelYs))
        }
    }

    /// The ghost's lines (background). Empty when the OBJ has no faces.
    static func build(data: Data, isProxy: Bool, outlinePlanes: [PlaneRegistration.Plane]) -> Parts {
        // Build procedural wireframe: thin 3D quads for each unique edge. A proxy ghost's
        // RoomPlan quads are already baked INTO the OBJ at save (coordinate-locked with the
        // mesh remainder), so the LATTICE needs no dynamic assembly — but the TRAILING lattice
        // faces (count in the v4 header) render with thick lines: the sparse 1 m grid is
        // sub-pixel at the mesh's 1 mm default beyond ~1.5 m and visually vanishes. The room
        // OUTLINE below IS assembled here, and deliberately from the AUTO-ALIGN REFERENCE set
        // (the very planes handed to PlaneRegistration.register) minus the floors a derived
        // level replaced — not from the set the builder actually baked.
        var parts = Parts()
        if isProxy,
           let quadFaces = ARCoverageView.ghostProxyQuadFaceCount(from: data), quadFaces > 0,
           let parsed = MeshParser.parseOBJ(from: data), parsed.faces.count > quadFaces {
            let split = parsed.faces.count - quadFaces
            parts.mesh = MeshParser.buildWireframeDescriptors(
                vertices: parsed.vertices, faces: Array(parsed.faces[..<split]), thickness: 0.001)
            // Cross-section (not flat-ribbon) lines for the lattice: a flat ribbon with a
            // fixed perpendicular is edge-on/backface-invisible for axis-aligned grid lines
            // on walls of particular orientations (the "clips on some walls" finding).
            parts.mesh += MeshParser.buildCrossWireframeDescriptors(
                vertices: parsed.vertices, faces: Array(parsed.faces[split...]),
                thickness: ARCoverageView.ghostProxyQuadLineThickness)
        } else {
            parts.mesh = MeshParser.generateWireframeDescriptors(from: data)
        }
        guard !parts.mesh.isEmpty else { return Parts() }

        // Room OUTLINE: each plane rectangle's 4 border edges — the wall-wall vertical
        // corners, the wall-floor seams, and the ceiling line — drawn bolder and lighter than
        // the interior lattice so the room's structural box reads at a glance (architectural-
        // drawing emphasis). Adjacent rects contribute coincident borders (a wall's bottom ≈
        // the floor's edge) — harmless, same color. Rendered as children of the same container
        // so it rides auto-align / manual nudge / de-registration with everything else.
        if !outlinePlanes.isEmpty {
            var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
            for plane in outlinePlanes {
                let halfX = plane.xAxis * (plane.width / 2)
                let halfY = plane.yAxis * (plane.height / 2)
                let c00 = plane.center - halfX - halfY, c10 = plane.center + halfX - halfY
                let c11 = plane.center + halfX + halfY, c01 = plane.center - halfX + halfY
                edges.append(contentsOf: [(c00, c10), (c10, c11), (c11, c01), (c01, c00)])
            }
            parts.outline = MeshParser.buildCrossWireframeDescriptors(
                edges: edges, thickness: ARCoverageView.ghostProxyOutlineThickness)
        }
        return parts
    }

    /// The user's ghost colour (Settings), and the outline's: same hue, strongly lightened. That reads
    /// as the same ghost's frame while separating architecture from content, and can't collide with
    /// the live-scan color whatever the user picked for either.
    static func colors() -> (mesh: SIMD4<Float>, outline: SIMD4<Float>) {
        let name = UserDefaults.standard.string(forKey: AppConstants.Key.ghostMeshColor) ?? AppConstants.ghostMeshColor
        let color = name.toSIMD4Color
        let outline = simd_mix(color, SIMD4<Float>(1, 1, 1, color.w), SIMD4<Float>(repeating: 0.55))
        return (color, outline)
    }

    // MARK: SceneKit

    /// Node name of the ghost's geometry in a SceneKit scene; the focus overlay cuts it inside a
    /// shown splat's box, as it cuts the preview's mesh.
    static let sceneNodeName = "ghostMesh"

    /// The ghost as SceneKit nodes (background is fine: nothing here is in a scene yet): one per
    /// part, opaque and unlit, under one container. nil when there are no lines.
    static func sceneNode(_ parts: Parts) -> SCNNode? {
        let palette = colors()
        let container = SCNNode()
        // The mesh's lines are flat ribbons, visible from one side only unless double-sided; the
        // lattice and outline are cross-sections wound both ways already.
        for (descriptors, color, doubleSided) in [(parts.mesh, palette.mesh, true), (parts.outline, palette.outline, false)] {
            guard let geometry = sceneGeometry(descriptors, color: color, doubleSided: doubleSided) else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = sceneNodeName
            container.addChildNode(node)
        }
        return container.childNodes.isEmpty ? nil : container
    }

    /// RealityKit's chunks as one SceneKit geometry (32-bit indices, so no chunk limit).
    private static func sceneGeometry(_ descriptors: [MeshDescriptor], color: SIMD4<Float>,
                                      doubleSided: Bool) -> SCNGeometry? {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        for descriptor in descriptors {
            guard case .triangles(let chunk)? = descriptor.primitives else { continue }
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: descriptor.positions.elements.map { SCNVector3($0.x, $0.y, $0.z) })
            indices.append(contentsOf: chunk.map { $0 + base })
        }
        guard !indices.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                                   elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        material.isDoubleSided = doubleSided
        geometry.materials = [material]
        return geometry
    }
}
