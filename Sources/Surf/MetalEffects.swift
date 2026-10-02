import AppKit
import Metal
import SwiftUI

/// What SwiftUI can't draw on its own: a sticker curling off its backing as a
/// real sheet.
///
/// A port of Canvas UI's WebGL Peel (canvasui.dev). It can't run in Surf as it
/// is: it captures live HTML into a texture with Chrome's experimental
/// HTML-in-Canvas API, which WebKit doesn't have, and what it would bend here —
/// the window's own chrome — isn't HTML anyway. The shader maths carries over
/// almost line for line; what changes is where the texture comes from: the
/// sticker's own views, rendered once.
///
/// The shaders are compiled from source the first time one is needed, by the
/// Metal framework itself. `swift build` doesn't compile `.metal` files, and
/// the offline compiler is an optional Xcode download; the runtime compiler is
/// part of every Mac. If compiling fails anyway, `isAvailable` is false and
/// callers fall back to what SwiftUI's `Canvas` can draw.
@MainActor
enum MetalEffects {
    static var isAvailable: Bool { shared != nil }

    struct Pipelines {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let sheet: MTLRenderPipelineState
        let sheetShadow: MTLRenderPipelineState
        let sheetDepth: MTLDepthStencilState
        let shadowDepth: MTLDepthStencilState
    }

    static let shared: Pipelines? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            debugLog("metal: no device")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            func pipeline(
                _ vertex: String, _ fragment: String, depth: Bool
            ) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let colour = descriptor.colorAttachments[0]!
                colour.pixelFormat = .bgra8Unorm
                // Premultiplied alpha throughout: rendered views arrive that
                // way.
                colour.isBlendingEnabled = true
                colour.sourceRGBBlendFactor = .one
                colour.sourceAlphaBlendFactor = .one
                colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
                colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                if depth { descriptor.depthAttachmentPixelFormat = .depth32Float }
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            let sheetDepth = MTLDepthStencilDescriptor()
            sheetDepth.depthCompareFunction = .lessEqual
            sheetDepth.isDepthWriteEnabled = true
            let shadowDepth = MTLDepthStencilDescriptor()
            shadowDepth.depthCompareFunction = .always
            shadowDepth.isDepthWriteEnabled = false
            return Pipelines(
                device: device,
                queue: queue,
                sheet: try pipeline("sheet_vertex", "sheet_fragment", depth: true),
                sheetShadow: try pipeline("sheet_shadow_vertex", "sheet_shadow_fragment", depth: true),
                sheetDepth: device.makeDepthStencilState(descriptor: sheetDepth)!,
                shadowDepth: device.makeDepthStencilState(descriptor: shadowDepth)!
            )
        } catch {
            debugLog("metal: shaders failed to compile — \(error)")
            return nil
        }
    }()

    /// A CGImage as a texture: 8-bit BGRA, premultiplied, sRGB-encoded, so
    /// drawing it unchanged gives back the same pixels.
    ///
    /// Redrawn into that one format first, rather than handed to
    /// `MTKTextureLoader` as it comes. The loader turned down what
    /// `ImageRenderer` produces for a sticker — every frame of every peel —
    /// and the peel fell back to a flat sticker that only ever faded. Drawing
    /// into a context of known layout accepts whatever a source hands over.
    static func texture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // Row 0 is the image's top in both: a bitmap context's memory runs top
        // to bottom, whatever its drawing coordinates say.
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        return texture
    }
}

// MARK: - Peel

/// Uniforms for the sheet shaders. Field order and types mirror the MSL struct.
private struct PeelUniforms {
    var canvas: SIMD2<Float>
    var tileOrigin: SIMD2<Float>
    var tileSize: SIMD2<Float>
    var peel: Float
    var reveal: Float
    var curl: Float
    var focal: Float
    var shade: Float
    var padding: Float = 0
}

/// A sticker peeling off as a sheet: a grid bent round a cylinder that sweeps
/// in from the bottom-trailing corner, drawn in perspective so the lifted part
/// comes toward you, with the adhesive back showing where it has rolled over.
///
/// Drawn into a canvas three tiles across, the sticker in the middle, so the
/// part that has rolled past the crease can hang off the tile's edge.
///
/// Rendered offscreen into an image, a frame per change in `progress`, rather
/// than into a live Metal view in the sidebar. A live view first went on
/// screen as a black square — composited opaque, or shown before it had drawn
/// — and an image has neither problem: SwiftUI composites it like any other.
/// At 228 pixels square, reading a frame back is nothing.
struct PeelMetalView: View {
    let face: AnyView
    let size: CGFloat
    let progress: CGFloat

    @Environment(\.displayScale) private var displayScale
    /// The sticker's face as a texture, and the sheet's geometry — made once,
    /// on the first frame, and kept for the rest of the peel. A reference so
    /// that filling it from `body` isn't a state change.
    @State private var renderer = PeelRenderer()

    var body: some View {
        if let frame = renderer.frame(
            face: face, size: size, progress: progress, scale: displayScale
        ) {
            Image(decorative: frame, scale: displayScale)
                .frame(width: size * 3, height: size * 3)
        } else {
            // Couldn't render: the sticker as it lies, rather than nothing.
            face.frame(width: size, height: size)
                .frame(width: size * 3, height: size * 3)
        }
    }
}

@MainActor
private final class PeelRenderer {
    private var face: MTLTexture?
    private var grid: MTLBuffer?
    private var indices: MTLBuffer?
    private var indexCount = 0
    /// Set once preparing has been tried, whether or not it worked: a face that
    /// can't be made into a texture shouldn't be re-rendered on every frame.
    private var isPrepared = false

    /// Grid resolution. A 38-point sticker needs far fewer than the 96 Canvas
    /// UI uses for a full page; this is enough that the curl stays round.
    private static let segments = 40

    func frame(face view: AnyView, size: CGFloat, progress: CGFloat, scale: CGFloat) -> CGImage? {
        guard let pipelines = MetalEffects.shared else { return nil }
        if !isPrepared {
            isPrepared = true
            prepare(view, size: size, scale: scale, pipelines: pipelines)
        }
        guard let face, let grid, let indices else { return nil }

        let pixels = Int((size * 3 * scale).rounded())
        let device = pipelines.device
        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false
        )
        colourDescriptor.usage = [.renderTarget]
        colourDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: pixels, height: pixels, mipmapped: false
        )
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: colourDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor),
              let commands = pipelines.queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        // The whole diagonal has to be past the crease by the end, or a corner
        // of the sticker would still be stuck down when it's flicked away.
        let tile = Float(size)
        let diagonal = tile * 2 / Float(2).squareRoot()
        var uniforms = PeelUniforms(
            canvas: SIMD2(tile * 3, tile * 3),
            tileOrigin: SIMD2(tile, tile),
            tileSize: SIMD2(tile, tile),
            peel: Float(progress),
            reveal: diagonal * 1.05,
            curl: tile * 0.32,
            focal: 220,
            shade: 0.55
        )
        // Counter-clockwise as laid out, so the sheet's face is the front and
        // whatever has rolled over shows its back.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(grid, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PeelUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PeelUniforms>.stride, index: 1)
        encoder.setFragmentTexture(face, index: 0)

        // The lifted part's shadow first, flat on the backing; then the sheet.
        encoder.setRenderPipelineState(pipelines.sheetShadow)
        encoder.setDepthStencilState(pipelines.shadowDepth)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint16,
            indexBuffer: indices, indexBufferOffset: 0
        )
        encoder.setRenderPipelineState(pipelines.sheet)
        encoder.setDepthStencilState(pipelines.sheetDepth)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint16,
            indexBuffer: indices, indexBufferOffset: 0
        )
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        target.getBytes(
            &bytes, bytesPerRow: pixels * 4,
            from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0
        )
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: pixels, height: pixels,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func prepare(_ view: AnyView, size: CGFloat, scale: CGFloat, pipelines: MetalEffects.Pipelines) {
        let renderer = ImageRenderer(content: view.frame(width: size, height: size))
        renderer.scale = scale
        guard let image = renderer.cgImage else {
            debugLog("peel: couldn't render the sticker's face")
            return
        }
        face = MetalEffects.texture(from: image, device: pipelines.device)
        if face == nil { debugLog("peel: couldn't make a texture of the sticker's face") }

        let n = Self.segments
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity((n + 1) * (n + 1))
        for y in 0...n {
            for x in 0...n {
                vertices.append(SIMD2(Float(x) / Float(n), Float(y) / Float(n)))
            }
        }
        var triangles: [UInt16] = []
        triangles.reserveCapacity(n * n * 6)
        for y in 0..<n {
            for x in 0..<n {
                let a = UInt16(y * (n + 1) + x), b = a + 1
                let c = a + UInt16(n + 1), d = c + 1
                triangles += [a, c, b, b, c, d]
            }
        }
        grid = pipelines.device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride
        )
        indices = pipelines.device.makeBuffer(
            bytes: triangles, length: triangles.count * MemoryLayout<UInt16>.stride
        )
        indexCount = triangles.count
    }
}

// MARK: - Shaders

private let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// MARK: Peel — after Canvas UI's Peel sheet shaders, turned to peel from a corner.

struct PeelUniforms {
    float2 canvas;
    float2 tileOrigin;
    float2 tileSize;
    float peel;
    float reveal;
    float curl;
    float focal;
    float shade;
    float padding;
};

struct SheetOut {
    float4 position [[position]];
    float2 uv;
    float theta;
    float lift;
};

struct Bent {
    float2 position;  // tile-local points, after bending
    float lift;       // toward the viewer, in points
    float theta;      // how far round the curl, 0 where flat
};

// The sheet bent round the curl. Everything nearer the bottom-trailing corner
// than the crease is lifted and rolled back round a cylinder of radius R; past
// half a turn it lies flat again, upside down, over the part still stuck.
static Bent bend(float2 p, constant PeelUniforms &u) {
    const float s = 0.70710678;
    // Distance in from the corner, along the diagonal the crease sweeps up.
    float along = (u.tileSize.x - p.x + u.tileSize.y - p.y) * s;

    float A = clamp(u.peel, 0.0, 1.0);
    float R = max(u.curl * A, 0.001);
    float c = A * u.reveal + R;

    float x = along;
    Bent out;
    out.lift = 0.0;
    out.theta = 0.0;
    if (A > 0.001 && along < c) {
        out.theta = (c - along) / R;
        if (out.theta <= M_PI_F) {
            x = c - R * sin(out.theta);
            out.lift = R * (1.0 - cos(out.theta));
        } else {
            x = c + (out.theta - M_PI_F) * R;
            out.lift = 2.0 * R;
        }
    }
    out.position = p + (along - x) * float2(s, s);
    return out;
}

static float2 toNDC(float2 tilePoint, constant PeelUniforms &u) {
    float2 ndc = (tilePoint + u.tileOrigin) / u.canvas * 2.0 - 1.0;
    ndc.y = -ndc.y;
    return ndc;
}

vertex SheetOut sheet_vertex(uint vid [[vertex_id]],
                             const device float2 *grid [[buffer(0)]],
                             constant PeelUniforms &u [[buffer(1)]]) {
    float2 g = grid[vid];
    Bent b = bend(g * u.tileSize, u);
    // Perspective about the canvas centre, which is the tile's: the lifted part
    // grows as it comes toward you.
    float w = (u.focal - b.lift) / u.focal;
    SheetOut out;
    out.position = float4(toNDC(b.position, u), (0.5 - 0.5 * b.lift / u.focal) * w, w);
    out.uv = g;
    out.theta = b.theta;
    out.lift = b.lift;
    return out;
}

// The same sheet laid flat where its shadow would fall: under each lifted
// point, pushed away from a light up and to the left by how high it is.
vertex SheetOut sheet_shadow_vertex(uint vid [[vertex_id]],
                                    const device float2 *grid [[buffer(0)]],
                                    constant PeelUniforms &u [[buffer(1)]]) {
    float2 g = grid[vid];
    Bent b = bend(g * u.tileSize, u);
    SheetOut out;
    out.position = float4(toNDC(b.position + float2(0.3, 0.45) * b.lift, u), 0.99, 1.0);
    out.uv = g;
    out.theta = b.theta;
    out.lift = b.lift;
    return out;
}

fragment float4 sheet_fragment(SheetOut in [[stage_in]],
                               bool isFront [[front_facing]],
                               texture2d<float> face [[texture(0)]],
                               constant PeelUniforms &u [[buffer(1)]]) {
    constexpr sampler linear(address::clamp_to_edge, filter::linear);
    float4 tex = face.sample(linear, in.uv);
    if (tex.a < 0.004) discard_fragment();

    // Darker where the sheet turns away from the light around the curl.
    float bend = sin(clamp(in.theta, 0.0, M_PI_F));
    float shaded = 1.0 - u.shade * 0.7 * pow(bend, 1.3);
    // A sheen along the top of the curl, where it catches the light.
    float sheen = in.theta > 0.001 ? exp(-pow(in.theta - 1.15, 2.0) / 0.12) * 0.5 : 0.0;

    float3 rgb;
    if (isFront) {
        rgb = tex.rgb * shaded;
    } else {
        // The adhesive back: plain white vinyl, cut to the sticker's shape,
        // greyer the further it has rolled under.
        float3 vinyl = mix(float3(0.82), float3(1.0), saturate(in.theta / M_PI_F));
        rgb = vinyl * tex.a * shaded;
    }
    rgb += sheen * tex.a;
    return float4(rgb, tex.a);
}

// The lifted sheet's shadow on the backing: the same grid, flattened, nudged
// away from a light up and to the left, and darker the higher it is lifted.
fragment float4 sheet_shadow_fragment(SheetOut in [[stage_in]],
                                      texture2d<float> face [[texture(0)]],
                                      constant PeelUniforms &u [[buffer(1)]]) {
    constexpr sampler linear(address::clamp_to_edge, filter::linear);
    float a = face.sample(linear, in.uv).a;
    float height = saturate(in.lift / max(u.curl * u.peel, 1.0));
    float alpha = 0.18 * height * a;
    return float4(0.0, 0.0, 0.0, alpha);
}
"""#
