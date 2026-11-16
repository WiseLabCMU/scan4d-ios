import Compression
import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd
import XCTest
@testable import scan4d_ios

/// The phone's splat reader and renderer helpers (REQ-041): the ZIP reader, SOG v2 decoding (the
/// same encoding LichtFeld writes), the GPU struct layouts, and how a splat is placed in its box.
final class SplatSOGTests: XCTestCase {

    // MARK: Fixtures

    /// A ZIP of `files`, each stored or deflated, under an optional folder.
    private func zip(_ files: [(name: String, data: Data, deflate: Bool)]) -> Data {
        var out = Data()
        var directory = Data()
        func u16(_ value: Int, _ data: inout Data) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
        func u32(_ value: Int, _ data: inout Data) { u16(value & 0xFFFF, &data); u16((value >> 16) & 0xFFFF, &data) }
        for file in files {
            var body = file.data
            if file.deflate {
                let capacity = file.data.count + 1024
                var packed = [UInt8](repeating: 0, count: capacity)
                let packedCount = file.data.withUnsafeBytes { src in
                    compression_encode_buffer(&packed, capacity, src.bindMemory(to: UInt8.self).baseAddress!,
                                              file.data.count, nil, COMPRESSION_ZLIB)
                }
                body = Data(packed[0..<packedCount])
            }
            let name = Data(file.name.utf8)
            let offset = out.count
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(file.deflate ? 8 : 0, &out)
            u16(0, &out); u16(0, &out); u32(0, &out)
            u32(body.count, &out); u32(file.data.count, &out); u16(name.count, &out); u16(0, &out)
            out.append(name)
            out.append(body)
            u32(0x0201_4b50, &directory); u16(20, &directory); u16(20, &directory); u16(0, &directory)
            u16(file.deflate ? 8 : 0, &directory); u16(0, &directory); u16(0, &directory); u32(0, &directory)
            u32(body.count, &directory); u32(file.data.count, &directory); u16(name.count, &directory)
            u16(0, &directory); u16(0, &directory); u16(0, &directory); u16(0, &directory); u32(0, &directory)
            u32(offset, &directory)
            directory.append(name)
        }
        let directoryOffset = out.count
        out.append(directory)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(files.count, &out); u16(files.count, &out)
        u32(directory.count, &out); u32(directoryOffset, &out); u16(0, &out)
        return out
    }

    /// A lossless image of straight RGBA bytes. PNG, not WebP: ImageIO sniffs the bytes, not the
    /// name, so it stands in for the WebP a SOG holds.
    private func image(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: width * 4, space: space,
                                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                       provider: provider, decode: nil, shouldInterpolate: false,
                                       intent: .defaultIntent))
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private struct Splat {
        var position: SIMD3<Float>
        /// w, x, y, z
        var rotation: SIMD4<Float>
        var scaleIndices: SIMD3<UInt8>
        var color: SIMD3<UInt8>
        var alpha: UInt8
    }

    private func logEncode(_ value: Float) -> Float { value >= 0 ? log(value + 1) : -log(-value + 1) }

    /// A SOG v2 file the way LichtFeld's writer packs it (sogs.cpp), with codebooks chosen so a
    /// scale index i means 0.01 (i + 1) m and a colour index i means the byte i.
    private func sog(_ splats: [Splat], version: Int = 2) throws -> URL {
        let width = 4, height = 4
        var means = (low: [UInt8](repeating: 0, count: width * height * 4), high: [UInt8](repeating: 0, count: width * height * 4))
        var quats = [UInt8](repeating: 0, count: width * height * 4)
        var scales = [UInt8](repeating: 0, count: width * height * 4)
        var sh0 = [UInt8](repeating: 0, count: width * height * 4)
        for (index, splat) in splats.enumerated() {
            let pixel = index * 4
            for axis in 0..<3 {
                let quantized = UInt16(((logEncode(splat.position[axis]) + 1) / 2 * 65535).rounded())
                means.low[pixel + axis] = UInt8(quantized & 0xFF)
                means.high[pixel + axis] = UInt8(quantized >> 8)
            }
            means.low[pixel + 3] = 255
            means.high[pixel + 3] = 255
            var unit = simd_normalize(splat.rotation)
            var largest = 0
            for component in 1..<4 where abs(unit[component]) > abs(unit[largest]) { largest = component }
            if unit[largest] < 0 { unit = -unit }
            let others = [[1, 2, 3], [0, 2, 3], [0, 1, 3], [0, 1, 2]][largest]
            for (slot, component) in others.enumerated() {
                quats[pixel + slot] = UInt8(255 * (unit[component] * Float(2).squareRoot() * 0.5 + 0.5))
            }
            quats[pixel + 3] = UInt8(252 + largest)
            scales[pixel] = splat.scaleIndices.x
            scales[pixel + 1] = splat.scaleIndices.y
            scales[pixel + 2] = splat.scaleIndices.z
            scales[pixel + 3] = 255
            sh0[pixel] = splat.color.x
            sh0[pixel + 1] = splat.color.y
            sh0[pixel + 2] = splat.color.z
            sh0[pixel + 3] = splat.alpha
        }
        let scaleBook = (0..<256).map { log(0.01 * Float($0 + 1)) }
        let colorBook = (0..<256).map { (Float($0) / 255 - 0.5) / SOGReader.shC0 }
        let meta: [String: Any] = [
            "version": version, "count": splats.count,
            "means": ["mins": [-1, -1, -1], "maxs": [1, 1, 1], "files": ["means_l.webp", "means_u.webp"]],
            "scales": ["codebook": scaleBook, "files": ["scales.webp"]],
            "quats": ["files": ["quats.webp"]],
            "sh0": ["codebook": colorBook, "files": ["sh0.webp"]],
            "asset": ["generator": "test"]
        ]
        let data = zip([
            ("splat/meta.json", try JSONSerialization.data(withJSONObject: meta), true),
            ("splat/means_l.webp", try image(width: width, height: height, rgba: means.low), false),
            ("splat/means_u.webp", try image(width: width, height: height, rgba: means.high), true),
            ("splat/quats.webp", try image(width: width, height: height, rgba: quats), false),
            ("splat/scales.webp", try image(width: width, height: height, rgba: scales), false),
            ("splat/sh0.webp", try image(width: width, height: height, rgba: sh0), true)
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("splat-\(UUID().uuidString).sog")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Tests

    func testTheZipReaderFindsStoredAndDeflatedEntriesByName() throws {
        let text = Data(String(repeating: "splat ", count: 500).utf8)
        let reader = try ZipReader(data: zip([("a/meta.json", text, true), ("a/b.bin", Data([1, 2, 3]), false)]))
        XCTAssertEqual(try reader.read("meta.json"), text)
        XCTAssertEqual(try reader.read("b.bin"), Data([1, 2, 3]))
        XCTAssertThrowsError(try reader.read("missing.webp"))
        XCTAssertThrowsError(try ZipReader(data: Data("not a zip at all, not even close".utf8)))
    }

    func testTheGPUStructsMatchTheShaders() {
        XCTAssertEqual(MemoryLayout<SplatGPU>.stride, 40)
        XCTAssertEqual(MemoryLayout<SplatUniforms>.stride, 160)
        XCTAssertEqual(MemoryLayout<SplatSortParams>.stride, 32)
    }

    func testEachSmallestThreeModeDecodes() {
        // w largest, stored x y z; then x, y, z largest, stored w and the other two.
        let identity = SOGReader.quaternion(127, 127, 127, 252)
        XCTAssertEqual(identity.real, 1, accuracy: 0.01)
        let aboutX = SOGReader.quaternion(127, 127, 127, 253)
        XCTAssertEqual(aboutX.imag.x, 1, accuracy: 0.01)
        let aboutY = SOGReader.quaternion(127, 127, 127, 254)
        XCTAssertEqual(aboutY.imag.y, 1, accuracy: 0.01)
        let aboutZ = SOGReader.quaternion(127, 127, 127, 255)
        XCTAssertEqual(aboutZ.imag.z, 1, accuracy: 0.01)
        // A stored component: w and y both 0.707 (w wins the tie, as in the writer).
        let half = SOGReader.quaternion(127, 255, 127, 252)
        XCTAssertEqual(half.real, 0.7071, accuracy: 0.01)
        XCTAssertEqual(half.imag.y, 0.7071, accuracy: 0.01)
        XCTAssertEqual(SOGReader.unlog(Float(log(1.5))), 0.5, accuracy: 1e-5)
        XCTAssertEqual(SOGReader.unlog(-Float(log(3.0))), -2, accuracy: 1e-5)
    }

    func testASOGDecodesIntoTheGPULayout() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let half = Float(0.5).squareRoot()
        let url = try sog([
            Splat(position: SIMD3(0.5, -0.25, 1.0), rotation: SIMD4(1, 0, 0, 0), scaleIndices: SIMD3(9, 19, 29),
                  color: SIMD3(200, 100, 50), alpha: 255),
            // 90 degrees about +Y: x goes to -z, so the variances along x and z swap.
            Splat(position: SIMD3(-0.75, 0, 0.1), rotation: SIMD4(half, 0, half, 0), scaleIndices: SIMD3(9, 19, 29),
                  color: SIMD3(10, 20, 30), alpha: 200),
            // Transparent: dropped.
            Splat(position: .zero, rotation: SIMD4(0, 0, 0, 1), scaleIndices: SIMD3(0, 0, 0),
                  color: SIMD3(1, 2, 3), alpha: 0)
        ])
        XCTAssertEqual(try SOGReader.count(of: url), 3)
        let cloud = try SOGReader.read(url)
        XCTAssertEqual(cloud.count, 2)
        let splats = cloud.buffer.contents().bindMemory(to: SplatGPU.self, capacity: cloud.count)

        let first = splats[0]
        XCTAssertEqual(first.px, 0.5, accuracy: 1e-3)
        XCTAssertEqual(first.py, -0.25, accuracy: 1e-3)
        XCTAssertEqual(first.pz, 1.0, accuracy: 1e-3)
        XCTAssertEqual(first.xx, 0.01, accuracy: 5e-4)
        XCTAssertEqual(first.yy, 0.04, accuracy: 5e-4)
        XCTAssertEqual(first.zz, 0.09, accuracy: 5e-4)
        XCTAssertEqual(first.xy, 0, accuracy: 5e-4)
        XCTAssertEqual(first.rgba & 0xFF, 200)
        XCTAssertEqual((first.rgba >> 8) & 0xFF, 100)
        XCTAssertEqual((first.rgba >> 16) & 0xFF, 50)
        XCTAssertEqual(first.rgba >> 24, 255)

        let second = splats[1]
        XCTAssertEqual(second.px, -0.75, accuracy: 1e-3)
        XCTAssertEqual(second.xx, 0.09, accuracy: 2e-3)
        XCTAssertEqual(second.yy, 0.04, accuracy: 2e-3)
        XCTAssertEqual(second.zz, 0.01, accuracy: 2e-3)
        // Opacity is stored as is; colour within one level (in case ImageIO premultiplied it).
        XCTAssertEqual(second.rgba >> 24, 200)
        XCTAssertEqual(Double(second.rgba & 0xFF), 10, accuracy: 1)
        XCTAssertEqual(Double((second.rgba >> 16) & 0xFF), 30, accuracy: 1)

        XCTAssertEqual(cloud.boundsMin.x, -0.75, accuracy: 1e-3)
        XCTAssertEqual(cloud.boundsMax.z, 1.0, accuracy: 1e-3)
    }

    func testAnotherSOGVersionIsRefusedBeforeDecoding() throws {
        let url = try sog([Splat(position: .zero, rotation: SIMD4(1, 0, 0, 0), scaleIndices: SIMD3(0, 0, 0),
                                 color: SIMD3(0, 0, 0), alpha: 255)], version: 3)
        XCTAssertThrowsError(try SOGReader.count(of: url)) { error in
            guard case SOGReader.Failure.unsupportedVersion(3) = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testTheDepthTestFollowsTheProjection() {
        let near: Float = 0.1, far: Float = 100
        func projection(reversed: Bool) -> simd_float4x4 {
            let zz = reversed ? near / (far - near) : far / (near - far)
            let zw = reversed ? near * far / (far - near) : near * far / (near - far)
            return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, zz, -1), SIMD4(0, 0, zw, 0)))
        }
        XCTAssertFalse(SplatRenderer.isReverseZ(projection(reversed: false)))
        XCTAssertTrue(SplatRenderer.isReverseZ(projection(reversed: true)))
        XCTAssertTrue(SplatRenderer.storesLinear(.bgra8Unorm_srgb))
        XCTAssertFalse(SplatRenderer.storesLinear(.bgra8Unorm))
    }

    /// The box placement comes from the sync while it describes the same version (it follows box
    /// edits), else from the copy downloaded with the file.
    func testTheSplatIsPlacedInItsBox() throws {
        let flip: [Float] = [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 1]
        let moved: [Float] = [1, 0, 0, 0, 0, -1, 0, 0, 0, 0, -1, 0, 0.5, 0, 0, 1]
        func layer(_ version: String, toBox: [Float]?) -> ScanLayer {
            ScanLayer(kind: "splat", subject: .init(mapId: nil, scanId: nil), version: version, state: "current",
                      files: [], placement: .init(toCapture: flip, toBox: toBox, toCanonical: nil), meta: nil)
        }
        XCTAssertNil(SplatScene.matrix([1, 2, 3]))
        XCTAssertEqual(SplatScene.matrix(moved)?.columns.3.x, 0.5)

        guard let device = MTLCreateSystemDefaultDevice(),
              let buffer = device.makeBuffer(length: 40, options: .storageModeShared) else {
            throw XCTSkip("No Metal device")
        }
        let cloud = SplatCloud(count: 1, buffer: buffer, boundsMin: SIMD3(1, 1, 1), boundsMax: SIMD3(3, 3, 3), decodeNote: "")
        let local = layer("v1", toBox: flip)
        XCTAssertEqual(SplatScene.placementInBox(local: local, remote: layer("v1", toBox: moved), cloud: cloud).columns.3.x, 0.5)
        XCTAssertEqual(SplatScene.placementInBox(local: local, remote: layer("v2", toBox: moved), cloud: cloud).columns.3.x, 0)
        // No box: stood upright and centred on its bounds (centre (2, 2, 2) flips to (2, -2, -2)).
        let centred = SplatScene.placementInBox(local: layer("v1", toBox: nil), remote: nil, cloud: cloud)
        let origin = centred * SIMD4<Float>(2, 2, 2, 1)
        XCTAssertEqual(simd_length(SIMD3(origin.x, origin.y, origin.z)), 0, accuracy: 1e-5)
    }
}
