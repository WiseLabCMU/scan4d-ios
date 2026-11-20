import Foundation
@preconcurrency import Metal
import os
import SceneKit
import simd

// MARK: - Drawing a splat inside a SceneKit view (REQ-041)

/// Matches `SplatUniforms` in Splat.metal.
nonisolated struct SplatUniforms {
    var modelView: simd_float4x4
    var projection: simd_float4x4
    var viewport: SIMD2<Float>
    var focal: SIMD2<Float>
    var tanHalfFov: SIMD2<Float>
    var linearOutput: UInt32
    var opacity: Float
}

/// Matches `SplatSortParams` in Splat.metal.
nonisolated struct SplatSortParams {
    var axis: SIMD4<Float>
    var zMin: Float
    var zScale: Float
    var count: UInt32
    var pad: UInt32 = 0
}

/// Draws one `SplatCloud` inside SceneKit's own render pass, as the renderer delegate of a node with
/// no geometry (`makeNode`); the node's transform places the splat, so it sits in the scene like any
/// other node and is depth tested against the scene's geometry. SceneKit calls `renderNode` on its
/// render thread. The depth sort runs on the GPU, on its own queue, whenever the view direction has
/// turned, and each frame draws with the latest finished order, so a sort can trail a fast turn by a
/// frame. The view must render continuously (`SCNView.rendersContinuously`) for a finished sort to
/// reach the screen while the camera is still.
///
/// SceneKit does not retain a node's renderer delegate: whoever adds the node keeps this object.
nonisolated final class SplatRenderer: NSObject, SCNNodeRendererDelegate, @unchecked Sendable {
    let cloud: SplatCloud

    /// Re-sort once the view direction has turned by more than about 0.8 degrees.
    static let resortCosine: Float = 0.9999
    /// Frames a retired order buffer waits before a sort may write it again: SceneKit may still be
    /// drawing with it.
    static let framesInFlight = 3

    private let lock = NSLock()
    private var opacityValue: Float = 1
    private var published: MTLBuffer?
    private var sortedAxis: SIMD3<Float>?
    private var sorting = false
    private var spare: [(buffer: MTLBuffer, retired: Int)] = []
    private var allocated = 0
    private var frame = 0
    private let keys: MTLBuffer?
    private let histogram: MTLBuffer?

    init(cloud: SplatCloud) {
        self.cloud = cloud
        let device = cloud.buffer.device
        keys = device.makeBuffer(length: max(cloud.count, 1) * 2, options: .storageModePrivate)
        histogram = device.makeBuffer(length: 65_536 * 4, options: .storageModePrivate)
        super.init()
    }

    /// The whole splat's opacity, 0...1 (0 draws nothing). Any thread.
    var opacity: Float {
        get { lock.withLock { opacityValue } }
        set { lock.withLock { opacityValue = max(0, min(1, newValue)) } }
    }

    /// A node that draws this splat, with no geometry of its own and after the scene's other nodes.
    func makeNode() -> SCNNode {
        let node = SCNNode()
        node.name = "splat"
        node.renderingOrder = 1_000
        node.rendererDelegate = self
        return node
    }

    // MARK: SCNNodeRendererDelegate

    func renderNode(_ node: SCNNode, renderer: SCNRenderer, arguments: [String: Any]) {
        let passDescriptor: MTLRenderPassDescriptor? = renderer.currentRenderPassDescriptor
        guard let encoder = renderer.currentRenderCommandEncoder, let pass = passDescriptor,
              let target = pass.colorAttachments[0].texture,
              let modelViewValue = (arguments[SCNModelViewTransform] as? NSValue)?.scnMatrix4Value,
              let projectionValue = (arguments[SCNProjectionTransform] as? NSValue)?.scnMatrix4Value
        else { return }
        let modelView = simd_float4x4(modelViewValue)
        let projection = simd_float4x4(projectionValue)

        let axis = simd_normalize(SIMD3<Float>(modelView.columns.0.z, modelView.columns.1.z, modelView.columns.2.z))
        let (order, opacity, job) = lock.withLock { () -> (MTLBuffer?, Float, MTLBuffer?) in
            frame += 1
            var job: MTLBuffer?
            if !sorting, sortedAxis.map({ simd_dot($0, axis) < Self.resortCosine }) ?? true {
                job = takeSpareLocked()
                if job != nil { sorting = true }
            }
            return (published, opacityValue, job)
        }
        if let job { encodeSort(axis: axis, into: job) }
        guard let order, opacity > 0 else { return }

        var colors: [MTLPixelFormat] = []
        for slot in 0..<8 {
            guard let texture = pass.colorAttachments[slot].texture else { break }
            colors.append(texture.pixelFormat)
        }
        let formats = SplatPipelines.Formats(colors: colors,
                                              depth: pass.depthAttachment.texture?.pixelFormat ?? .invalid,
                                              stencil: pass.stencilAttachment.texture?.pixelFormat ?? .invalid,
                                              samples: target.sampleCount)
        let compare: MTLCompareFunction = formats.depth == .invalid ? .always
            : (Self.isReverseZ(projection) ? .greaterEqual : .lessEqual)
        guard let pipeline = SplatPipelines.shared.render(formats),
              let depthState = SplatPipelines.shared.depth(compare) else { return }

        let size = SIMD2<Float>(Float(target.width), Float(target.height))
        var uniforms = SplatUniforms(
            modelView: modelView,
            projection: projection,
            viewport: size,
            focal: SIMD2(projection.columns.0.x * size.x / 2, projection.columns.1.y * size.y / 2),
            tanHalfFov: SIMD2(1 / projection.columns.0.x, 1 / projection.columns.1.y),
            linearOutput: Self.storesLinear(target.pixelFormat) ? 1 : 0,
            opacity: opacity)

        encoder.pushDebugGroup("Splat")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(cloud.buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(order, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cloud.count)
        encoder.popDebugGroup()
    }

    // MARK: Sorting

    /// An order buffer no frame in flight can still be reading, else a new one (at most four).
    /// Called under `lock`.
    private func takeSpareLocked() -> MTLBuffer? {
        if let index = spare.firstIndex(where: { frame - $0.retired > Self.framesInFlight }) {
            return spare.remove(at: index).buffer
        }
        guard allocated < 4,
              let buffer = cloud.buffer.device.makeBuffer(length: max(cloud.count, 1) * 4, options: .storageModePrivate)
        else { return nil }
        allocated += 1
        return buffer
    }

    private func encodeSort(axis: SIMD3<Float>, into order: MTLBuffer) {
        let gpu = SplatPipelines.shared
        guard let queue = gpu.queue, let keysPipeline = gpu.sortKeys, let offsetsPipeline = gpu.sortOffsets,
              let scatterPipeline = gpu.sortScatter, let keys, let histogram,
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder()
        else {
            finishSort(order, axis: nil)
            return
        }
        // The depth range from the bounds' corners: every splat's key lands in 0...65535.
        let lower = cloud.boundsMin, upper = cloud.boundsMax
        var zMin = Float.greatestFiniteMagnitude, zMax = -Float.greatestFiniteMagnitude
        for corner in 0..<8 {
            let point = SIMD3<Float>(corner & 1 == 0 ? lower.x : upper.x, corner & 2 == 0 ? lower.y : upper.y,
                                     corner & 4 == 0 ? lower.z : upper.z)
            let depth = simd_dot(axis, point)
            zMin = min(zMin, depth)
            zMax = max(zMax, depth)
        }
        var params = SplatSortParams(axis: SIMD4(axis, 0), zMin: zMin, zScale: 65_535 / max(zMax - zMin, 1e-6),
                                     count: UInt32(cloud.count))

        blit.fill(buffer: histogram, range: 0..<histogram.length, value: 0)
        blit.endEncoding()
        guard let compute = commands.makeComputeCommandEncoder() else {
            finishSort(order, axis: nil)
            return
        }
        let width = min(256, keysPipeline.maxTotalThreadsPerThreadgroup, scatterPipeline.maxTotalThreadsPerThreadgroup)
        let threads = MTLSize(width: width, height: 1, depth: 1)
        let groups = MTLSize(width: (cloud.count + width - 1) / width, height: 1, depth: 1)
        compute.setComputePipelineState(keysPipeline)
        compute.setBuffer(cloud.buffer, offset: 0, index: 0)
        compute.setBuffer(keys, offset: 0, index: 1)
        compute.setBuffer(histogram, offset: 0, index: 2)
        compute.setBytes(&params, length: MemoryLayout<SplatSortParams>.stride, index: 3)
        compute.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        compute.setComputePipelineState(offsetsPipeline)
        compute.setBuffer(histogram, offset: 0, index: 0)
        compute.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        compute.setComputePipelineState(scatterPipeline)
        compute.setBuffer(keys, offset: 0, index: 0)
        compute.setBuffer(histogram, offset: 0, index: 1)
        compute.setBuffer(order, offset: 0, index: 2)
        compute.setBytes(&params, length: MemoryLayout<SplatSortParams>.stride, index: 3)
        compute.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        compute.endEncoding()
        commands.addCompletedHandler { [weak self] done in
            self?.finishSort(order, axis: done.status == .completed ? axis : nil)
        }
        commands.commit()
    }

    private func finishSort(_ order: MTLBuffer, axis: SIMD3<Float>?) {
        lock.withLock {
            sorting = false
            if let axis {
                if let old = published { spare.append((old, frame)) }
                published = order
                sortedAxis = axis
            } else {
                spare.append((order, frame))
            }
        }
    }

    // MARK: Helpers

    /// Whether `projection` maps near to a larger depth than far (SceneKit's reverse Z): the depth
    /// test must agree with the depth buffer SceneKit wrote with the same matrix.
    static func isReverseZ(_ projection: simd_float4x4) -> Bool {
        let near = projection * SIMD4<Float>(0, 0, -1, 1)
        let far = projection * SIMD4<Float>(0, 0, -10, 1)
        return near.z / near.w > far.z / far.w
    }

    /// Formats that store linear colour (the GPU encodes to sRGB on write, or keeps floats): the
    /// splat's display-sRGB colours are linearized first, as SceneKit's own colours are.
    static func storesLinear(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgra10_xr_srgb, .bgr10_xr_srgb, .rgba16Float, .rgba32Float:
            return true
        default:
            return false
        }
    }
}

/// The splat pipelines, made once per render pass layout, and the sort's queue.
nonisolated final class SplatPipelines: @unchecked Sendable {
    static let shared = SplatPipelines()
    static let log = Logger(subsystem: "org.arenaxr.scan4d", category: "splat")

    nonisolated struct Formats: Hashable {
        let colors: [MTLPixelFormat]
        let depth: MTLPixelFormat
        let stencil: MTLPixelFormat
        let samples: Int
    }

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let sortKeys: MTLComputePipelineState?
    let sortOffsets: MTLComputePipelineState?
    let sortScatter: MTLComputePipelineState?
    private let library: MTLLibrary?
    private let lock = NSLock()
    private var renders: [Formats: MTLRenderPipelineState] = [:]
    private var depths: [MTLCompareFunction: MTLDepthStencilState] = [:]

    private init() {
        let device = SplatMetal.device
        let library = device?.makeDefaultLibrary()
        func compute(_ name: String) -> MTLComputePipelineState? {
            guard let device, let function = library?.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = device?.makeCommandQueue()
        self.library = library
        self.sortKeys = compute("splatSortKeys")
        self.sortOffsets = compute("splatSortOffsets")
        self.sortScatter = compute("splatSortScatter")
    }

    func render(_ formats: Formats) -> MTLRenderPipelineState? {
        lock.withLock {
            if let made = renders[formats] { return made }
            guard let device, let library, let vertex = library.makeFunction(name: "splatVertex"),
                  let fragment = library.makeFunction(name: "splatFragment"), !formats.colors.isEmpty
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Splat"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.rasterSampleCount = formats.samples
            for (slot, format) in formats.colors.enumerated() {
                guard let attachment = descriptor.colorAttachments[slot] else { continue }
                attachment.pixelFormat = format
                if slot == 0 {
                    // Premultiplied "over".
                    attachment.isBlendingEnabled = true
                    attachment.rgbBlendOperation = .add
                    attachment.alphaBlendOperation = .add
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                } else {
                    attachment.writeMask = []
                }
            }
            descriptor.depthAttachmentPixelFormat = formats.depth
            descriptor.stencilAttachmentPixelFormat = formats.stencil
            do {
                let made = try device.makeRenderPipelineState(descriptor: descriptor)
                renders[formats] = made
                Self.log.info("splat pipeline for \(String(describing: formats), privacy: .public)")
                return made
            } catch {
                Self.log.error("no splat pipeline for \(String(describing: formats), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Tests against the scene's depth, never writes it: splats are all transparency.
    func depth(_ compare: MTLCompareFunction) -> MTLDepthStencilState? {
        lock.withLock {
            if let made = depths[compare] { return made }
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = false
            let made = device?.makeDepthStencilState(descriptor: descriptor)
            depths[compare] = made
            return made
        }
    }
}
