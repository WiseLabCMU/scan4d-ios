import CryptoKit
import Foundation
import XCTest
@testable import scan4d_ios

/// Layers from the Scan4D server (REQ-041): the sync reply's `layers`, what a card line says, which
/// scans a reply speaks for, the file request, and the copy on the phone.
@MainActor
final class ScanLayersTests: XCTestCase {

    private func layer(scan: UUID, version: String = "20261115T224358Z", state: String = "current",
                       sha256: String = String(repeating: "0", count: 64)) -> ScanLayer {
        ScanLayer(kind: "splat", subject: .init(mapId: nil, scanId: scan.uuidString.lowercased()), version: version,
                  state: state,
                  files: [.init(name: "splat.sog", role: "full", bytes: 15_687_117, sha256: sha256,
                                url: "/v1/scans/\(scan.uuidString.lowercased())/layers/splat/splat.sog")],
                  placement: nil, meta: nil)
    }

    /// A sync reply with a layer, as scan4d-server sends it (LayerOut, snake_case).
    func testSyncReplyCarriesLayers() throws {
        let scan = UUID(), map = UUID()
        let flip = "[1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1]"
        let body = """
        {"server_time": "2026-11-15T22:43:58Z", "device_id": "\(UUID().uuidString.lowercased())",
         "maps": 1, "scans": 2, "links": 0, "marked_gone": 0,
         "layers": [{"kind": "splat",
                     "subject": {"map_id": "\(map.uuidString.lowercased())", "scan_id": "\(scan.uuidString.lowercased())"},
                     "version": "20261115T224358Z", "state": "current",
                     "files": [{"name": "splat.sog", "role": "full", "bytes": 15687117,
                                "sha256": "c2781d643b28061ff940cc89ee31c1cb31a6184e5e6736e3b70d9dc9f205fc02",
                                "url": "/v1/scans/\(scan.uuidString.lowercased())/layers/splat/splat.sog"}],
                     "placement": {"to_capture": \(flip), "to_box": \(flip), "to_canonical": \(flip)},
                     "made_from": {"flow": "scan4d-splat", "bundle_fingerprint": null},
                     "meta": {"count": 1052472, "sog_version": 2, "sh_degree": 3},
                     "published_at": "2026-11-15T22:43:58.617958Z"}]}
        """
        let reply = try ControlPlaneClient.decode(ControlPlaneClient.SyncReply.self, from: Data(body.utf8))
        let layer = try XCTUnwrap(reply.layers?.first)
        XCTAssertEqual(layer.scanId, scan)
        XCTAssertEqual(layer.kind, ScanLayer.splat)
        XCTAssertEqual(layer.version, "20261115T224358Z")
        XCTAssertEqual(layer.placement?.toBox?.count, 16)
        XCTAssertEqual(layer.placement?.toCanonical?[5], -1)
        XCTAssertEqual(layer.meta?.count, 1_052_472)
        XCTAssertEqual(layer.meta?.sogVersion, 2)
        XCTAssertEqual(layer.phoneFile?.bytes, 15_687_117)
        // A server from before layers sends none: nothing is known, nothing is changed.
        let older = try ControlPlaneClient.decode(ControlPlaneClient.SyncReply.self, from: Data("""
        {"maps": 1, "scans": 2, "links": 0, "marked_gone": 0}
        """.utf8))
        XCTAssertNil(older.layers)
    }

    /// The phone variant when the server made one, else the full splat.
    func testThePhoneDownloadsThePhoneVariantWhenThereIsOne() {
        let scan = UUID()
        let full = layer(scan: scan)
        XCTAssertEqual(full.phoneFile?.role, "full")
        let both = ScanLayer(kind: "splat", subject: full.subject, version: full.version, state: full.state,
                             files: full.files + [.init(name: "phone.sog", role: "phone", bytes: 4_000_000,
                                                        sha256: "", url: "/x")],
                             placement: nil, meta: nil)
        XCTAssertEqual(both.phoneFile?.name, "phone.sog")
    }

    func testTheCardLineFollowsTheServerAndThePhone() {
        let scan = UUID()
        let current = layer(scan: scan)
        XCTAssertNil(ScanLayers.line(remote: nil, local: nil, downloading: nil, failure: nil))
        XCTAssertEqual(ScanLayers.line(remote: current, local: nil, downloading: nil, failure: nil),
                       .available(bytes: 15_687_117, stale: false))
        XCTAssertEqual(ScanLayers.line(remote: current, local: nil, downloading: 0.4, failure: nil), .downloading(0.4))
        XCTAssertEqual(ScanLayers.line(remote: current, local: current.version, downloading: nil, failure: nil),
                       .ready(stale: false))
        XCTAssertEqual(ScanLayers.line(remote: current, local: "20261101T000000Z", downloading: nil, failure: nil),
                       .update(bytes: 15_687_117))
        XCTAssertEqual(ScanLayers.line(remote: nil, local: current.version, downloading: nil, failure: nil), .localOnly)
        XCTAssertEqual(ScanLayers.line(remote: current, local: nil, downloading: nil, failure: "Can't reach"),
                       .failed("Can't reach"))
        // A failed update leaves the copy on the phone; a ready one ignores an old failure.
        XCTAssertEqual(ScanLayers.line(remote: current, local: current.version, downloading: nil, failure: "x"),
                       .ready(stale: false))
        XCTAssertEqual(ScanLayers.line(remote: layer(scan: scan, state: "stale"), local: nil, downloading: nil, failure: nil),
                       .available(bytes: 15_687_117, stale: true))
    }

    /// A reply speaks for the scans the sync reported: theirs are replaced (none = removed on the
    /// server); other scans keep what was known.
    func testAReplyReplacesOnlyTheReportedScansLayers() {
        let kept = UUID(), removed = UUID(), unreported = UUID()
        let known: [UUID: [ScanLayer]] = [kept: [layer(scan: kept, version: "v1")], removed: [layer(scan: removed)]]
        let merged = ScanLayers.merged(known, with: [layer(scan: kept, version: "v2"), layer(scan: unreported)],
                                       reported: [kept, removed])
        XCTAssertEqual(merged[kept]?.map(\.version), ["v2"])
        XCTAssertNil(merged[removed])                 // reported, no layer now: gone from the server
        XCTAssertNil(merged[unreported])              // not reported: the reply doesn't speak for it
        XCTAssertEqual(ScanLayers.merged(known, with: [], reported: []), known)
    }

    func testTheFileRequestKeepsTheServersPathPrefix() throws {
        let base = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "https://example.com/scan4d"))
        let scan = UUID()
        let request = ControlPlaneClient(baseURL: base).layerFileRequest(try XCTUnwrap(layer(scan: scan).phoneFile))
        XCTAssertEqual(request.url?.absoluteString,
                       "https://example.com/scan4d/v1/scans/\(scan.uuidString.lowercased())/layers/splat/splat.sog")
        XCTAssertEqual(request.httpMethod ?? "GET", "GET")
    }

    /// The download is checked against the server's sha256, then swapped in whole with its
    /// layer.json; a file that doesn't match leaves the copy that was there.
    func testTheCopyOnThePhoneIsCheckedAndSwappedIn() throws {
        let fm = FileManager.default
        let scanDirectory = fm.temporaryDirectory.appendingPathComponent("layers-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scanDirectory) }
        try fm.createDirectory(at: scanDirectory, withIntermediateDirectories: true)
        let scan = UUID()

        func download(_ contents: String) throws -> URL {
            let url = fm.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
            try Data(contents.utf8).write(to: url)
            return url
        }
        func sha(_ contents: String) -> String {
            SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        let first = layer(scan: scan, version: "v1", sha256: sha("first"))
        let firstFile = try download("first")
        try LayerCache.install(firstFile, file: try XCTUnwrap(first.phoneFile), layer: first, scanDirectory: scanDirectory)
        XCTAssertFalse(fm.fileExists(atPath: firstFile.path))
        XCTAssertEqual(LayerCache.local(scanDirectory: scanDirectory, kind: "splat")?.version, "v1")
        let stored = try XCTUnwrap(LayerCache.fileURL(scanDirectory: scanDirectory, layer: first))
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "first")
        XCTAssertEqual(stored.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "layers")

        // Changed on the server mid-download: refused, the copy stays.
        let second = layer(scan: scan, version: "v2", sha256: sha("second"))
        let wrong = try download("not the second")
        XCTAssertThrowsError(try LayerCache.install(wrong, file: try XCTUnwrap(second.phoneFile), layer: second,
                                                    scanDirectory: scanDirectory))
        XCTAssertFalse(fm.fileExists(atPath: wrong.path))
        XCTAssertEqual(LayerCache.local(scanDirectory: scanDirectory, kind: "splat")?.version, "v1")

        try LayerCache.install(try download("second"), file: try XCTUnwrap(second.phoneFile), layer: second,
                               scanDirectory: scanDirectory)
        XCTAssertEqual(LayerCache.local(scanDirectory: scanDirectory, kind: "splat")?.version, "v2")
        XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "second")
        // Nothing left behind: no staging, no old copy.
        let root = scanDirectory.appendingPathComponent(LayerCache.folder)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["splat"])

        LayerCache.remove(scanDirectory: scanDirectory, kind: "splat")
        XCTAssertNil(LayerCache.local(scanDirectory: scanDirectory, kind: "splat"))
    }
}
