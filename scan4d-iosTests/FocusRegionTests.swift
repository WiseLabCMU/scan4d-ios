import XCTest
import simd
@testable import scan4d_ios

/// The focus-scan region: its JSON (also the import format a downstream processor writes) and the
/// box math the capture gate and the viewer rely on.
@MainActor
final class FocusRegionTests: XCTestCase {

    func testJSONRoundTripUsesExplicitKeys() throws {
        let region = FocusRegion(center: SIMD3(1, 0.8, -2), yaw: 0.5, size: SIMD3(1.2, 0.6, 0.8),
                                 label: "work table", source: .roomplan, detail: .detail,
                                 locationId: UUID(), frameScanId: UUID(), frameIsCanonical: true,
                                 createdAtMs: 1_761_200_000_000, regionId: UUID())
        let data = try XCTUnwrap(region.encoded())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["center_m", "yaw_rad", "size_m", "detail_level", "frame_is_canonical", "created_at_ms", "region_id"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing \(key) in \(json)")
        }
        XCTAssertTrue(json.contains("\"roomplan\""))
        XCTAssertEqual(FocusRegion.decode(data), region)
    }

    func testLenientDecodeNeedsOnlyTheBox() throws {
        let minimal = #"{"center_m":[0.5,0.9,-1],"size_m":[0.6,0.4,0.6],"label":"bench"}"#
        let region = try XCTUnwrap(FocusRegion.decode(Data(minimal.utf8)))
        XCTAssertEqual(region.center, SIMD3(0.5, 0.9, -1))
        XCTAssertEqual(region.yaw, 0)
        XCTAssertEqual(region.detail, .check)
        XCTAssertEqual(region.source, .imported)
        XCTAssertTrue(region.frameIsCanonical)
        XCTAssertNil(region.regionId, "a first scan of a region carries no region id")
        XCTAssertEqual(region.label, "bench")
        XCTAssertNil(FocusRegion.decode(Data(#"{"center_m":[0,0,0]}"#.utf8)), "a box needs a size")
    }

    func testContainsAndCornersFollowYaw() {
        // 2 m along local x, 0.2 m along local z, turned 90 degrees: it now runs along world z.
        let region = FocusRegion(center: SIMD3(0, 1, 0), yaw: .pi / 2, size: SIMD3(2, 0.5, 0.2))
        XCTAssertTrue(region.contains(SIMD3(0, 1, 0.9)))
        XCTAssertFalse(region.contains(SIMD3(0.9, 1, 0)))
        XCTAssertFalse(region.contains(SIMD3(0, 1.3, 0)), "above the top face")
        let corners = region.corners
        XCTAssertEqual(corners.count, 8)
        let maxZ = corners.map(\.z).max() ?? 0
        XCTAssertEqual(maxZ, 1, accuracy: 1e-5)
        let maxX = corners.map(\.x).max() ?? 0
        XCTAssertEqual(maxX, 0.1, accuracy: 1e-5)
    }

    func testValidity() {
        XCTAssertTrue(FocusRegion(center: .zero, size: SIMD3(1, 1, 1)).isValid)
        XCTAssertFalse(FocusRegion(center: .zero, size: SIMD3(0, 1, 1)).isValid)
        XCTAssertFalse(FocusRegion(center: .zero, size: SIMD3(1, 1, 50)).isValid, "room-sized is not a focus region")
        XCTAssertFalse(FocusRegion(center: SIMD3(.nan, 0, 0), size: SIMD3(1, 1, 1)).isValid)
    }

    func testDeepLinkCarriesARegion() throws {
        let json = #"{"center_m":[1,0.8,-2],"size_m":[1.2,0.6,0.8],"label":"work table","detail_level":"detail","source":"user"}"#
        let base64url = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = try XCTUnwrap(URL(string: "scan4d://focus-region?data=\(base64url)"))
        let region = try FocusRegionInbox.region(from: url).get()
        XCTAssertEqual(region.label, "work table")
        XCTAssertEqual(region.detail, .detail)
        XCTAssertEqual(region.source, .imported, "an import is recorded as one whatever it says")

        var components = URLComponents()
        components.scheme = "scan4d"
        components.host = "focus-region"
        components.queryItems = [URLQueryItem(name: "json", value: json)]
        XCTAssertEqual(try FocusRegionInbox.region(from: try XCTUnwrap(components.url)).get().size, SIMD3(1.2, 0.6, 0.8))
    }

    func testDeepLinkRefusals() throws {
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "wisescandat://callback"))), .failure(.notARegionLink))
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "scan4d://focus-region"))), .failure(.noPayload))
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "scan4d://focus-region?data=@@@"))), .failure(.undecodable))
        let huge = #"{"center_m":[0,0,0],"size_m":[1,1,40]}"#
        XCTAssertEqual(FocusRegionInbox.region(fromJSON: Data(huge.utf8)), .failure(.invalidBox))
    }

    func testDetailLevelsTightenSpacingAndRaiseTargets() {
        let levels = FocusDetailLevel.allCases
        XCTAssertEqual(levels, [.check, .detail, .splat])
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(a.spacingDeg, b.spacingDeg)
            XCTAssertLessThan(a.targetStills, b.targetStills)
        }
        XCTAssertTrue(FocusDetailLevel.check.finishesAtTarget)
        XCTAssertFalse(FocusDetailLevel.splat.finishesAtTarget)
        XCTAssertTrue(FocusDetailLevel.check.waitsForSpacing)
        XCTAssertTrue(FocusDetailLevel.detail.waitsForSpacing)
        XCTAssertFalse(FocusDetailLevel.splat.waitsForSpacing, "Splat also takes repeats between new angles")
    }

    func testRescanKeepsTheBoxAndKeysTheRegion() {
        let firstScan = UUID(), mapScan = UUID()
        let drawn = FocusRegion(center: SIMD3(1, 0.8, -2), yaw: 0.4, size: SIMD3(1.2, 0.6, 0.8), label: "work table",
                                source: .roomplan, detail: .check, locationId: UUID(), frameScanId: mapScan,
                                frameIsCanonical: true, createdAtMs: 1_761_200_000_000, taskId: UUID())
        let rescan = drawn.forRescan(ofScan: firstScan, detail: .splat)
        // The same box in the same frame: the new scan lines up with the first.
        XCTAssertEqual(rescan.center, drawn.center)
        XCTAssertEqual(rescan.yaw, drawn.yaw)
        XCTAssertEqual(rescan.size, drawn.size)
        XCTAssertEqual(rescan.frameScanId, drawn.frameScanId)
        XCTAssertEqual(rescan.frameIsCanonical, drawn.frameIsCanonical)
        XCTAssertEqual(rescan.locationId, drawn.locationId)
        XCTAssertEqual(rescan.label, drawn.label)
        XCTAssertEqual(rescan.placement(inRawFrameOf: mapScan, appliedRegistration: nil),
                       drawn.placement(inRawFrameOf: mapScan, appliedRegistration: nil))
        // At the level asked for now, keyed by the first scan, and not answering the old task again.
        XCTAssertEqual(rescan.detail, .splat)
        XCTAssertEqual(rescan.regionId, firstScan)
        XCTAssertNil(rescan.taskId)
        // A rescan of the rescan keeps the first scan's key.
        XCTAssertEqual(rescan.forRescan(ofScan: UUID(), detail: .detail).regionId, firstScan)
    }
}
