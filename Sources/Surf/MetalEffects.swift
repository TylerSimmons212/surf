import AppKit
import MetalKit
import SwiftUI

/// The two effects SwiftUI can't draw on its own: the page refracting under a
/// ripple, and a sticker curling off its backing as a real sheet.
///
/// Both are ports of Canvas UI's WebGL components (canvasui.dev — Ripple and
/// Peel). Those can't run in Surf as they are: they capture live HTML into a
/// texture with Chrome's experimental HTML-in-Canvas API, which WebKit doesn't
/// have, and the things they would bend here — the window's own chrome — aren't
/// HTML anyway. The shader maths carries over almost line for line; what
/// changes is where the texture comes from: a snapshot of the web view, or the
/// sticker's own views rendered once.
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
        let ripple: MTLRenderPipelineState
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
                // Premultiplied alpha throughout: snapshots and rendered views
                // both arrive that way.
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
                ripple: try pipeline("fullscreen_vertex", "ripple_fragment", depth: false),
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

/// An `MTKView` that never takes a click, draws over whatever is under it, and
/// matches the snapshot's colour space so an undistorted pixel is the page's
/// own pixel.
private class EffectView: MTKView {
    init(device: MTLDevice) {
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        wantsLayer = true
        makeTransparent()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Said again once the view is in a window, because the metal layer can
    /// be made or replaced after `init`. An opaque one composites its clear
    /// colour as black instead of letting the page show through.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makeTransparent()
    }

    private func makeTransparent() {
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Ripple

/// Uniforms for `ripple_fragment`. Field order and types mirror the MSL struct.
private struct RippleUniforms {
    var resolution: SIMD2<Float>
    var origin: SIMD2<Float>
    var time: Float
    var speed: Float
    var wavelength: Float
    var width: Float
    var decay: Float
    var refraction: Float
    var dispersion: Float
    var shine: Float
    var opacity: Float
}

/// The page, as it was when the load finished, rippling from `origin`.
///
/// Runs its own clock, because the ripple is one fixed event rather than
/// something driven by SwiftUI state, and calls `onFinished` once the water
/// has gone still.
struct RippleMetalView: NSViewRepresentable {
    let snapshot: CGImage
    /// Where the ripple starts, in this view's points from its top-leading
    /// corner. May lie outside the view — a split pane's ripple comes in from
    /// its edge.
    let origin: CGPoint
    let onFinished: () -> Void

    /// From impact to still water, in seconds. Long enough to be seen
    /// settling, short enough to be over before you've started reading.
    static let duration: Double = 0.8

    func makeNSView(context: Context) -> NSView {
        guard let pipelines = MetalEffects.shared,
              let texture = MetalEffects.texture(from: snapshot, device: pipelines.device) else {
            DispatchQueue.main.async(execute: onFinished)
            return NSView()
        }
        return RippleView(pipelines: pipelines, texture: texture, origin: origin, onFinished: onFinished)
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class RippleView: EffectView, MTKViewDelegate {
    private let pipelines: MetalEffects.Pipelines
    private let page: MTLTexture
    private let origin: CGPoint
    private let onFinished: () -> Void
    private let start = CACurrentMediaTime()
    private var isDone = false

    init(pipelines: MetalEffects.Pipelines, texture: MTLTexture, origin: CGPoint, onFinished: @escaping () -> Void) {
        self.pipelines = pipelines
        self.page = texture
        self.origin = origin
        self.onFinished = onFinished
        super.init(device: pipelines.device)
        delegate = self
        preferredFramesPerSecond = 120
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let elapsed = CACurrentMediaTime() - start
        guard elapsed < RippleMetalView.duration else {
            finish()
            return
        }
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = pipelines.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        // The tail fades the snapshot out over the live page rather than
        // letting it vanish: anything that painted since the snapshot was
        // taken arrives as a dissolve, not a pop.
        let fadeStart = RippleMetalView.duration - 0.2
        let opacity = elapsed < fadeStart ? 1 : 1 - (elapsed - fadeStart) / 0.2

        // Tuned against Canvas UI's defaults, then calmed: this plays after
        // every page load, not on a click, so it has to be a settling rather
        // than a splash.
        var uniforms = RippleUniforms(
            resolution: SIMD2(Float(bounds.width), Float(bounds.height)),
            origin: SIMD2(Float(origin.x), Float(origin.y)),
            time: Float(elapsed),
            // Fast and quick to lose energy: the rings cross the page and the
            // water is still again inside the duration.
            speed: 760,
            wavelength: 72,
            width: 110,
            decay: 3.2,
            refraction: 18,
            dispersion: 0.18,
            shine: 0.5,
            opacity: Float(opacity)
        )
        encoder.setRenderPipelineState(pipelines.ripple)
        encoder.setFragmentTexture(page, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private func finish() {
        guard !isDone else { return }
        isDone = true
        isPaused = true
        DispatchQueue.main.async { [onFinished] in onFinished() }
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

// MARK: Ripple — after Canvas UI's Ripple fragment shader.

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle that covers the screen; uv runs top-left (0,0) to bottom-right (1,1).
vertex QuadOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QuadOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

struct RippleUniforms {
    float2 resolution;
    float2 origin;
    float time;
    float speed;
    float wavelength;
    float width;
    float decay;
    float refraction;
    float dispersion;
    float shine;
    float opacity;
};

fragment float4 ripple_fragment(QuadOut in [[stage_in]],
                                texture2d<float> page [[texture(0)]],
                                constant RippleUniforms &u [[buffer(0)]]) {
    constexpr sampler linear(address::clamp_to_edge, filter::linear);
    float2 frag = in.uv * u.resolution;

    // One wave train leaving the origin: a crest band of Gaussian width around
    // the travelling front, losing energy with time and with distance spread.
    float k = 6.28318530718 / u.wavelength;
    float w2 = u.width * u.width;
    float2 dv = frag - u.origin;
    float r = length(dv);
    float front = u.speed * u.time;
    float s = r - front;
    float env = exp(-s * s / w2) * exp(-u.decay * u.time);
    env *= smoothstep(0.0, 0.08, u.time);
    env *= rsqrt(1.0 + front / max(u.wavelength, 1.0) * 0.2);

    // The surface's slope, which is what bends the light through it.
    float dh = (k * cos(s * k) - 2.0 * s / w2 * sin(s * k)) * env;
    float2 grad = dv / max(r, 1.0) * dh * u.wavelength * 0.16;

    // Lit from the top left: slopes facing it glint, slopes facing away shade.
    float g = dot(grad, float2(-0.55, -0.8));
    float glint = pow(saturate(g * 2.2), 2.0) * u.shine;
    float shade = pow(saturate(-g * 1.6), 2.0) * u.shine * 0.3;

    // Refraction, with the colours splitting slightly along the slopes.
    float2 offs = grad * u.refraction / u.resolution;
    float d = u.dispersion * 0.35;
    float4 centre = page.sample(linear, in.uv + offs);
    float3 col = float3(
        page.sample(linear, in.uv + offs * (1.0 + d)).r,
        centre.g,
        page.sample(linear, in.uv + offs * (1.0 - d)).b
    );
    // Glints in foam, the border's own spray colour, rather than plain white.
    col += glint * float3(0.78, 0.97, 0.98);
    col *= 1.0 - shade;
    return float4(col * u.opacity, u.opacity);
}

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

// MARK: - The page's ripple

extension Notification.Name {
    /// Posted by the loading border when a load's lap closes, with the tab's
    /// id as the object: the moment the page should ripple.
    static let surfLoadDidWash = Notification.Name("surfLoadDidWash")
}

/// The page refracting under the ripple that starts where the border's crests
/// meet.
///
/// Laid over the web view: when the border washes out, the page is snapshotted
/// and the snapshot drawn in its place for a moment, bent by the ripple, then
/// faded back to the live page. A snapshot because nothing outside WebKit can
/// draw a live page through a shader — which is the whole of what Canvas UI's
/// HTML-in-Canvas buys it, and what WebKit doesn't have.
struct PageRipple: View {
    let tab: Tab

    /// The window's coordinate space, named at the top of `ContentView`.
    static let windowSpace = "surf.window"

    @State private var run: Run?

    private struct Run {
        let id = UUID()
        let snapshot: CGImage
    }

    /// Whether this tab's page can ripple now.
    ///
    /// Not while the page is moving: the snapshot would freeze a playing video
    /// for the length of the ripple. Not while Focus or viewport emulation is
    /// showing something other than the page as laid out. Not under Reduce
    /// Motion — the caller checks that — and not without Metal.
    static func canRipple(_ tab: Tab) -> Bool {
        MetalEffects.isAvailable
            && tab.mode == .browsing
            && tab.media?.isPlaying != true
            && tab.focusPhase == .inactive
            && tab.emulatedViewport == nil
            && !PopOutController.shared.isPoppedOut(tab)
    }

    var body: some View {
        GeometryReader { proxy in
            if let run {
                // Where the crests met: the window's bottom centre, just inside
                // the border's inset, in this pane's own points.
                let window = proxy.bounds(of: .named(Self.windowSpace))
                    ?? CGRect(origin: .zero, size: proxy.size)
                RippleMetalView(
                    snapshot: run.snapshot,
                    origin: CGPoint(x: window.midX, y: window.maxY - 2.5)
                ) {
                    if self.run?.id == run.id { self.run = nil }
                }
                .id(run.id)
            }
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: .surfLoadDidWash)) { note in
            guard (note.object as? UUID) == tab.id, Self.canRipple(tab) else { return }
            Task { @MainActor in
                guard let image = await tab.captureVisibleArea(),
                      let snapshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }
                debugLog("ripple: page snapshot \(snapshot.width)×\(snapshot.height)")
                run = Run(snapshot: snapshot)
            }
        }
    }
}
