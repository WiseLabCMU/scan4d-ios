import Accelerate
import Compression
import CoreGraphics
import Foundation
import ImageIO
import Metal
import os
import simd

// MARK: - A splat ready to draw (REQ-041)

/// One splat as the GPU reads it (`SplatGPU` in Splat.metal): its centre, the upper triangle of its
/// 3D covariance, and its colour, 40 bytes.
nonisolated struct SplatGPU {
    var px: Float, py: Float, pz: Float
    var xx: Float, xy: Float, xz: Float
    var yy: Float, yz: Float, zz: Float
    /// Display sRGB, alpha = opacity; bytes r, g, b, a.
    var rgba: UInt32
}

/// A decoded splat in its own coordinates: a Metal buffer of `SplatGPU`, with its bounds. Immutable
/// once made, so any thread may read it; `SplatRenderer` draws it.
nonisolated final class SplatCloud: @unchecked Sendable {
    let count: Int
    let buffer: MTLBuffer
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    /// How the WebP images decoded (premultiplied alpha loses colour where opacity is low), for the log.
    let decodeNote: String

    init(count: Int, buffer: MTLBuffer, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, decodeNote: String) {
        self.count = count
        self.buffer = buffer
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        self.decodeNote = decodeNote
    }

    var center: SIMD3<Float> { (boundsMin + boundsMax) / 2 }
}

nonisolated enum SplatMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}

// MARK: - SOG

/// Reads PlayCanvas SOG version 2, what LichtFeld (and so `scan4d-splat`) writes: one ZIP of
/// `meta.json` and lossless WebP images, one splat per pixel. Positions, rotations, scales, base
/// colour and opacity are read; the higher SH bands (`shN`) are not, so the phone draws SH degree 0.
/// The decoding matches LichtFeld's own SOG reader (`src/io/formats/sogs.cpp`).
nonisolated enum SOGReader {
    nonisolated enum Failure: LocalizedError {
        case notSOG(String)
        case unsupportedVersion(Int)
        case tooLarge(count: Int)
        case noGPU

        var errorDescription: String? {
            switch self {
            case .notSOG(let why): return "Not a splat this app can open: \(why)."
            case .unsupportedVersion(let v): return "This splat is SOG version \(v); the app reads version 2."
            case .tooLarge(let count):
                return "Too large for this device: \(count.formatted()) Gaussians need more memory than is free."
            case .noGPU: return "No Metal device."
            }
        }
    }

    nonisolated struct Meta: Decodable {
        nonisolated struct Means: Decodable {
            let mins: [Float]
            let maxs: [Float]
            let files: [String]
        }
        nonisolated struct Coded: Decodable {
            let codebook: [Float]
            let files: [String]
        }
        nonisolated struct Files: Decodable {
            let files: [String]
        }
        let version: Int?
        let count: Int
        let means: Means
        let scales: Coded
        let quats: Files
        let sh0: Coded
    }

    /// SH band 0's constant: base colour = 0.5 + C0 * coefficient.
    static let shC0: Float = 0.28209479177387814

    /// The splat count from `meta.json` alone, without decoding the images.
    static func count(of url: URL) throws -> Int {
        try meta(ZipReader(url: url)).count
    }

    /// Decodes the file into a GPU buffer. Splats with no opacity are dropped. Throws `tooLarge`
    /// when the decoded splat would not fit in the memory this app has left.
    static func read(_ url: URL, device: MTLDevice? = SplatMetal.device) throws -> SplatCloud {
        guard let device else { throw Failure.noGPU }
        let zip = try ZipReader(url: url)
        let meta = try meta(zip)
        guard meta.count > 0 else { throw Failure.notSOG("no splats") }
        guard meta.means.mins.count == 3, meta.means.maxs.count == 3,
              meta.means.files.count == 2, meta.scales.files.count == 1, meta.quats.files.count == 1,
              meta.sh0.files.count == 1, meta.scales.codebook.count == 256, meta.sh0.codebook.count == 256
        else { throw Failure.notSOG("an unexpected meta.json") }

        // The GPU buffer, plus about two decoded images at a time, plus room for the app.
        let bytes = meta.count * MemoryLayout<SplatGPU>.stride
        let available = Int(os_proc_available_memory())
        if available > 0, bytes + meta.count * 4 * 3 + (200 << 20) > available {
            throw Failure.tooLarge(count: meta.count)
        }
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw Failure.tooLarge(count: meta.count)
        }
        let out = buffer.contents().bindMemory(to: SplatGPU.self, capacity: meta.count)

        var notes: Set<String> = []
        func image(_ name: String) throws -> [UInt8] {
            let decoded = try WebPPixels.rgba(try zip.read(name))
            notes.insert(decoded.note)
            guard decoded.width * decoded.height >= meta.count else {
                throw Failure.notSOG("\(name) is smaller than the splat count")
            }
            return decoded.pixels
        }

        // Positions: 16 bits per axis over two images, log-encoded between mins and maxs.
        do {
            let low = try image(meta.means.files[0])
            let high = try image(meta.means.files[1])
            let mins = SIMD3<Float>(meta.means.mins[0], meta.means.mins[1], meta.means.mins[2])
            let span = SIMD3<Float>(meta.means.maxs[0], meta.means.maxs[1], meta.means.maxs[2]) - mins
            low.withUnsafeBufferPointer { lowBytes in
                high.withUnsafeBufferPointer { highBytes in
                    for index in 0..<meta.count {
                        let pixel = index * 4
                        func word(_ channel: Int) -> Float {
                            Float(UInt16(lowBytes[pixel + channel]) | UInt16(highBytes[pixel + channel]) << 8)
                        }
                        let logged = mins + span * (SIMD3<Float>(word(0), word(1), word(2)) / 65535)
                        out[index].px = unlog(logged.x)
                        out[index].py = unlog(logged.y)
                        out[index].pz = unlog(logged.z)
                    }
                }
            }
        }

        // Covariance from rotation and scale: R S S R^T.
        do {
            let quats = try image(meta.quats.files[0])
            let scales = try image(meta.scales.files[0])
            let scaleBook = meta.scales.codebook.map { exp($0) }
            quats.withUnsafeBufferPointer { quatBytes in
                scales.withUnsafeBufferPointer { scaleBytes in
                    scaleBook.withUnsafeBufferPointer { book in
                        for index in 0..<meta.count {
                            let pixel = index * 4
                            let rotation = quaternion(quatBytes[pixel], quatBytes[pixel + 1], quatBytes[pixel + 2],
                                                      quatBytes[pixel + 3])
                            let scale = SIMD3<Float>(book[Int(scaleBytes[pixel])], book[Int(scaleBytes[pixel + 1])],
                                                     book[Int(scaleBytes[pixel + 2])])
                            let basis = simd_float3x3(rotation) * simd_float3x3(diagonal: scale)
                            let cov = basis * basis.transpose
                            out[index].xx = cov[0][0]
                            out[index].xy = cov[1][0]
                            out[index].xz = cov[2][0]
                            out[index].yy = cov[1][1]
                            out[index].yz = cov[2][1]
                            out[index].zz = cov[2][2]
                        }
                    }
                }
            }
        }

        // Colour and opacity; drop the splats nobody can see, compacting in place.
        var kept = 0
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        do {
            let sh0 = try image(meta.sh0.files[0])
            let level: [UInt32] = meta.sh0.codebook.map { coefficient in
                UInt32(max(0, min(255, ((0.5 + shC0 * coefficient) * 255).rounded())))
            }
            sh0.withUnsafeBufferPointer { colorBytes in
                level.withUnsafeBufferPointer { levels in
                    for index in 0..<meta.count {
                        let pixel = index * 4
                        let alpha = colorBytes[pixel + 3]
                        // LichtFeld writes opacity 0 as 1, so WebP keeps the colour.
                        guard alpha > 1 else { continue }
                        var splat = out[index]
                        let position = SIMD3<Float>(splat.px, splat.py, splat.pz)
                        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
                              splat.xx.isFinite, splat.yy.isFinite, splat.zz.isFinite else { continue }
                        splat.rgba = levels[Int(colorBytes[pixel])] | levels[Int(colorBytes[pixel + 1])] << 8
                            | levels[Int(colorBytes[pixel + 2])] << 16 | UInt32(alpha) << 24
                        out[kept] = splat
                        kept += 1
                        lower = simd_min(lower, position)
                        upper = simd_max(upper, position)
                    }
                }
            }
        }
        guard kept > 0 else { throw Failure.notSOG("every splat is transparent") }
        return SplatCloud(count: kept, buffer: buffer, boundsMin: lower, boundsMax: upper,
                          decodeNote: notes.sorted().joined(separator: ", "))
    }

    static func meta(_ zip: ZipReader) throws -> Meta {
        let meta: Meta
        do {
            meta = try JSONDecoder().decode(Meta.self, from: try zip.read("meta.json"))
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.notSOG("meta.json: \(error.localizedDescription)")
        }
        if let version = meta.version, version != 2 { throw Failure.unsupportedVersion(version) }
        return meta
    }

    /// Inverse of the position encoding's log transform.
    @inline(__always)
    static func unlog(_ value: Float) -> Float {
        value >= 0 ? exp(value) - 1 : 1 - exp(-value)
    }

    /// SOG v2 "smallest three": the alpha byte (252 + i) names the largest component, which was
    /// dropped (i: 0 w, 1 x, 2 y, 3 z); the other three are stored in order, scaled by sqrt 2.
    static func quaternion(_ first: UInt8, _ second: UInt8, _ third: UInt8, _ mode: UInt8) -> simd_quatf {
        let v0 = (Float(first) / 255 - 0.5) * Float(2).squareRoot()
        let v1 = (Float(second) / 255 - 0.5) * Float(2).squareRoot()
        let v2 = (Float(third) / 255 - 0.5) * Float(2).squareRoot()
        let largest = max(0, 1 - (v0 * v0 + v1 * v1 + v2 * v2)).squareRoot()
        let wxyz: SIMD4<Float>
        switch Int(mode) - 252 {
        case 1: wxyz = SIMD4(v0, largest, v1, v2)
        case 2: wxyz = SIMD4(v0, v1, largest, v2)
        case 3: wxyz = SIMD4(v0, v1, v2, largest)
        default: wxyz = SIMD4(largest, v0, v1, v2)
        }
        let unit = simd_normalize(wxyz)
        return simd_quatf(ix: unit.y, iy: unit.z, iz: unit.w, r: unit.x)
    }
}

// MARK: - WebP

nonisolated enum WebPPixels {
    /// The image's RGBA bytes, unpremultiplied, rows packed. A SOG keeps data in the alpha channel
    /// (opacity, the rotation's mode), so the bytes must come out as stored: vImage converts whatever
    /// ImageIO decoded into straight RGBA in the image's own colour space (no colour matching).
    static func rgba(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int, note: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw SOGReader.Failure.notSOG("an image that doesn't decode") }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue))
        else { throw SOGReader.Failure.notSOG("an image in an unexpected format") }
        let buffer = try vImage_Buffer(cgImage: image, format: format)
        defer { buffer.free() }
        let width = Int(buffer.width), height = Int(buffer.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress, let src = buffer.data else { return }
            for row in 0..<height {
                memcpy(base + row * width * 4, src + row * buffer.rowBytes, width * 4)
            }
        }
        let note = "\(image.bitsPerPixel)bpp alpha \(image.alphaInfo.rawValue)"
        return (pixels, width, height, note)
    }
}

// MARK: - ZIP

/// The parts of ZIP a SOG uses: the central directory (ZIP64 included), stored and deflated entries.
/// Entries are found by their last path component, so a folder inside the zip doesn't matter.
nonisolated struct ZipReader {
    nonisolated struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    nonisolated struct Damaged: LocalizedError {
        let why: String
        var errorDescription: String? { "Not a readable zip: \(why)." }
    }

    let data: Data
    let entries: [String: Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        // Offsets below count from 0: a slice is copied so its indices do too.
        let whole = data.startIndex == 0 ? data : Data(data)
        self.data = whole
        self.entries = try Self.directory(whole)
    }

    func read(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw SOGReader.Failure.notSOG("\(name) is missing") }
        let header = entry.localHeaderOffset
        guard Self.u32(data, header) == 0x0403_4b50 else { throw Damaged(why: "a bad local header") }
        let start = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        guard start >= 0, start + entry.compressedSize <= data.count else { throw Damaged(why: "an entry past the end") }
        let body = data.subdata(in: start..<start + entry.compressedSize)
        switch entry.method {
        case 0:
            return body
        case 8:
            guard entry.size > 0 else { return Data() }
            guard !body.isEmpty else { throw Damaged(why: "\(name) is empty") }
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                body.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Damaged(why: "\(name) doesn't inflate") }
            return out
        default:
            throw Damaged(why: "compression method \(entry.method)")
        }
    }

    private static func directory(_ zip: Data) throws -> [String: Entry] {
        // The end-of-central-directory record, within the last 64 KiB plus its own 22 bytes.
        guard zip.count >= 22 else { throw Damaged(why: "too short") }
        var end = -1
        var scan = zip.count - 22
        let floor = max(0, zip.count - 22 - 65_535)
        while scan >= floor {
            if u32(zip, scan) == 0x0605_4b50 { end = scan; break }
            scan -= 1
        }
        guard end >= 0 else { throw Damaged(why: "no central directory") }
        var count = Int(u16(zip, end + 10))
        var offset = Int(u32(zip, end + 16))
        if count == 0xFFFF || offset == 0xFFFF_FFFF, end >= 20, u32(zip, end - 20) == 0x0706_4b50 {
            let record = Int(u64(zip, end - 20 + 8))
            guard record >= 0, record + 56 <= zip.count, u32(zip, record) == 0x0606_4b50 else {
                throw Damaged(why: "a bad ZIP64 record")
            }
            count = Int(u64(zip, record + 32))
            offset = Int(u64(zip, record + 48))
        }
        var entries: [String: Entry] = [:]
        var cursor = offset
        for _ in 0..<count {
            guard cursor >= 0, cursor + 46 <= zip.count, u32(zip, cursor) == 0x0201_4b50 else {
                throw Damaged(why: "a bad directory entry")
            }
            let method = u16(zip, cursor + 10)
            var compressed = Int(u32(zip, cursor + 20))
            var size = Int(u32(zip, cursor + 24))
            let nameLength = Int(u16(zip, cursor + 28))
            let extraLength = Int(u16(zip, cursor + 30))
            let commentLength = Int(u16(zip, cursor + 32))
            var local = Int(u32(zip, cursor + 42))
            guard cursor + 46 + nameLength + extraLength <= zip.count else {
                throw Damaged(why: "a directory entry past the end")
            }
            let name = String(decoding: zip.subdata(in: cursor + 46..<cursor + 46 + nameLength), as: UTF8.self)
            // ZIP64: the 64-bit values follow, in order, for each 32-bit field that is all ones.
            var extra = cursor + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = u16(zip, extra), length = Int(u16(zip, extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF { size = Int(u64(zip, field)); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = Int(u64(zip, field)); field += 8 }
                    if local == 0xFFFF_FFFF { local = Int(u64(zip, field)) }
                }
                extra += 4 + length
            }
            let key = name.split(separator: "/").last.map(String.init) ?? name
            if !name.hasSuffix("/") {
                entries[key] = Entry(method: method, compressedSize: compressed, size: size, localHeaderOffset: local)
            }
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func u16(_ bytes: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(bytes, offset)) | UInt32(u16(bytes, offset + 2)) << 16
    }

    private static func u64(_ bytes: Data, _ offset: Int) -> UInt64 {
        UInt64(u32(bytes, offset)) | UInt64(u32(bytes, offset + 4)) << 32
    }
}
