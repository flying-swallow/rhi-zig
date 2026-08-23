# rhi-zig

A backend-agnostic **Render Hardware Interface (RHI)** for GPU rendering, written in Zig.

`rhi-zig` provides one explicit, modern GPU API over multiple graphics backends (Vulkan, Metal,
and WebGPU today), a higher-level render-program (`rpi`) layer, a Dear ImGui rendering layer, and
a handful of asset loaders. Its RHI design is ported from the Amnesia/HPL2 engine
(`RITypes.h` / `RIBarrier.h`).

> **Status:** early / work in progress (`0.0.0`). The API is unstable and the project tracks a
> nightly Zig toolchain. See [Status & caveats](#status--caveats).

## Features

- **Backend-agnostic GPU API** — a single command/resource API that targets Vulkan, Metal, or
  WebGPU from the same source, selected per platform at compile time.
- **Explicit, modern surface** — devices, queues, swapchains, command pools/buffers,
  images and image views, buffers, samplers, pipelines and pipeline layouts, descriptors, and
  barrier-based synchronization (fences, semaphores, timelines).
- **`rpi` render-program layer** — bundles a pipeline layout, a hash-keyed pipeline cache, and
  descriptor sets resolved by name for one set of shader stages (a Zig port of the C++ engine's
  `RIProgram`).
- **Dear ImGui layer** (`rhi.imgui`) — renders ImGui draw data through the RHI itself; its
  shaders are authored in Slang, compiled to SPIR-V, and embedded into the library.
- **Slang shader toolchain** — compiles shaders to SPIR-V (Vulkan), MSL (Metal), and WGSL
  (WebGPU) via `slangc`, fetched automatically per host or supplied with `-Dslangc=<path>`.
- **Asset loading** — a std-only glTF loader (`rhi.io.gltf`).
- **Utilities** — a GPU profiler, a resource loader, and several allocators (scratch, segment,
  offset, and an index pool).

## Backend support

| Backend | Platforms       | Status                                                              |
| ------- | --------------- | ------------------------------------------------------------------ |
| Vulkan  | Windows, Linux  | Primary backend; most complete.                                    |
| Metal   | macOS, iOS      | Supported. Examples `00`–`02` are ported; on Metal the `rpi` layer covers the render-pipeline cache + push constants only. |
| WebGPU  | Browsers (wasm) | **Web-only** — see [Web builds](#web-builds). Examples `00`–`02` are ported. |
| WebGL2  | Browsers (wasm) | **Web-only** fallback under WebGPU, for browsers without it. Examples `00`–`02` are ported. |
| D3D12   | Windows         | Declared in the backend enum but **not yet implemented** (`src/d3d12.zig` is a stub). |

The active backends per platform are chosen in `src/root.zig` (`platform_api`): any WebAssembly
target `{ wgpu, webgl }`, Windows `{ vk, dx12 }`, Linux `{ vk }`, macOS/iOS `{ mtl }`.

## Web builds

Two backends exist **only on WebAssembly targets** and are compiled into the same `.wasm`:
WebGPU, and WebGL2 as a fallback. Neither links a native library, so nothing changes for a desktop
build. Targeting `wasm32-freestanding` selects them automatically.

`src/webgpu/glue.js` owns the probe: it requests a WebGPU adapter first and falls back to a
`webgl2` canvas context when WebGPU is missing or `requestAdapter()` returns null — which is what
happens on Linux Chrome without `--enable-unsafe-webgpu`. Pass `forceBackend: "webgl"` to `boot()`
to exercise the fallback on a machine where WebGPU works.

```sh
# Build the library for the web
zig build -Dtarget=wasm32-freestanding
```

To build and run the examples in a browser, see
[Running the examples](#running-the-examples).

The glue requests the `GPUAdapter` and `GPUDevice` *before* instantiating the wasm module, which
is what keeps the synchronous `Renderer.init` -> `enumerate_adapters` -> `Device.init` chain
working unchanged — there is no asyncify and no async variant of the RHI API. The browser owns the
frame loop: `examples/web_app.zig` exports `rhi_web_frame`, called once per
`requestAnimationFrame`.

What the backend does *not* do, and why:

| RHI feature | On WebGPU |
| --- | --- |
| Barriers (`image_barrier`, `resource_barrier`, ...) | No-ops. WebGPU tracks resource state itself, so there is nothing to emit. |
| `Fence`, `Semaphore`, `CommandRingElement.wait` | No-ops. A browser frame cannot block on the GPU, and the browser keeps submitted resources alive. |
| `Timeline` | Fully implemented — a counter plus `queue.onSubmittedWorkDone()`. Only the blocking `Timeline.wait` errors. |
| Push constants | Emulated as a `@group(0) @binding(0)` uniform buffer owned by the pipeline. Shaders must declare the block with `[[vk::binding(0,0)]] ConstantBuffer<T>`; `slangc` emits `[[vk::push_constant]]` as a `var<uniform>` with no group/binding, which WebGPU rejects. See the `RHI_WGSL` switch in `examples/example_assets/02_mesh.slang`. |
| `persistant_map` buffers | Backed by a wasm-memory shadow flushed with `queueWriteBuffer` on first use, after which `mapped_region` becomes `null`. WebGPU has no persistent host mapping. |
| `clear_attachment_regions` | Unsupported — WebGPU has no mid-pass partial clear. Use the attachment `load_op`. |
| Ray tracing, `rpi`, descriptors, samplers, `ResourceLoader`, `imgui` | `error.UnsupportedBackend`; out of scope. |

WebGL2 differs from WebGPU in a few places that are worth knowing:

| | On WebGL2 |
| --- | --- |
| Command buffers | WebGL2 has none, so `Cmd` records into `src/webgl/command_list.zig` and `Queue.submit` replays it. Recording stays separate from execution, as the RHI's contract requires. |
| `clear_attachment_regions` | **Supported**, via a scissored clear per region — the one thing WebGL2 does that WebGPU cannot. |
| Swapchain | Renders to an offscreen colour texture blitted onto the canvas at submit. WebGL2 cannot attach the canvas's colour buffer to a custom FBO, and `02_mesh` pairs the swapchain image with its own depth attachment. |
| Swapchain format | `RGBA8`; WebGL2 has no renderable BGRA. |
| `Timeline` | A real `WebGLSync` polled with a zero timeout, and `wait_queue_idle` is a real `finish()`. |
| Vertex layout | A VAO fuses format with buffer, so VAOs are cached per (pipeline, vertex buffer, index buffer). |
| Shaders | GLSL ES 3.00, produced by `slangc -target spirv` piped through the vendored SPIRV-Cross tool in `deps/spirv_cross`. No `.slang` source change is needed: the tool also applies GL's Y-flip and `[0,1]` -> `[-1,1]` depth fixups. |
| Compute, storage buffers/images, indirect draws, base vertex/instance | `error.UnsupportedBackend`. Non-zero `first_instance`/`vertex_offset` is rejected rather than dropped. |

The Zig enums in `src/webgpu/enums.zig` and the string tables in `src/webgpu/glue.js` are
positional — a value's integer *is* its index in the JS array. `zig build test` checks that
contract, so a drift fails the build rather than showing up as the wrong texture format at runtime.

## Requirements

- **Zig 0.16.0+.** The code tracks 0.16-dev (nightly), so a matching nightly build is
  recommended (`minimum_zig_version = "0.16.0"`).
- **Vulkan targets:** the Vulkan headers are fetched as a dependency, but running requires a
  Vulkan runtime/driver on the machine.
- **`slangc`:** fetched automatically as a prebuilt Slang release for your host (lazily, so only
  the matching archive downloads), or override with `-Dslangc=/path/to/slangc`.
- **Examples:** additionally use SDL3 (fetched lazily) and `zla` (linear algebra). Neither is used
  by the web build, which has no window and drives its own frame loop.
- **Web targets:** the page must be served over http(s) — neither `navigator.gpu` nor a secure
  context exists on `file://`. WebGPU additionally needs a browser with it enabled (on Linux,
  Chrome needs `--enable-unsafe-webgpu`); the WebGL2 fallback needs no flags.

## Building

From the repository root:

```sh
# Build the `rhi` static library / module
zig build

# Run the tests (Metal init/swapchain and the Vulkan rpi type-check,
# gated by the platform's available backends)
zig build test
```

Useful build options:

- `-Dslangc=/path/to/slangc` — use an existing `slangc` (e.g. from the Vulkan SDK) instead of
  downloading the prebuilt Slang.
- `-Dzd3d12_gbv` — enable D3D12 GPU-Based Validation (Windows).

## Running the examples

The examples live under [`examples/`](examples/), which is a **separate build root** — run these
from that directory, not the repository root.

| Step        | Source         | Demonstrates                                                             | Backends                       |
| ----------- | -------------- | ------------------------------------------------------------------------ | ------------------------------ |
| `00_clear`  | `00Clear.zig`  | Swapchain clear with image barriers, plus sub-rect quadrant clears.      | Vulkan, Metal, WebGPU, WebGL2  |
| `01_shader` | `01Shader.zig` | Fullscreen shader (Mandelbrot).                                          | Vulkan, Metal, WebGPU, WebGL2  |
| `02_mesh`   | `02Mesh.zig`   | Rotating cube: vertex + index buffers, depth, push constants.            | Vulkan, Metal, WebGPU, WebGL2  |
| `03_imgui`  | `03Imgui.zig`  | Dear ImGui UI drawn through `rhi.imgui`.                                 | Vulkan                         |
| `04_svt`    | `04SVT.zig`    | Software virtual texturing on the `rpi` layer.                           | Vulkan                         |

```sh
cd examples

# Natively: build and run in one step
zig build 00_clear      # or 01_shader, 02_mesh, 03_imgui, 04_svt

# In a browser (examples 00-02): build, then serve — a secure context is
# required, so file:// will not work and localhost counts as secure
zig build -Dtarget=wasm32-freestanding
cd zig-out/bin && python3 -m http.server 8000   # open http://localhost:8000/00_clear.html
```

See [`examples/README.md`](examples/README.md) for build flags, how shaders are compiled per
backend, picking a specific web backend, and what to do when a page comes up blank.

## Quick start

The core flow is: **renderer → adapter → device → swapchain**, then per frame
**acquire → begin → barrier → render → submit**. Distilled from `examples/00Clear.zig`:

```zig
const rhi = @import("rhi");

// 1. Renderer -> physical adapter -> device
try rhi.Renderer.init(gpa, .{ .vk = .{ .app_name = "app", .enable_validation_layer = true } });
defer rhi.Renderer.deinit();

var adapters = try rhi.PhysicalAdapter.enumerate_adapters(gpa);
defer adapters.deinit(gpa);
const idx = rhi.PhysicalAdapter.default_select_adapter(adapters.items);

var device = try rhi.Device.init(gpa, &adapters.items[idx]);
defer device.deinit();

// 2. Swapchain + a command ring buffer (see the example for setup)
var swapchain = try rhi.Swapchain.init(gpa, &device, width, height, window_handle, .{});
defer swapchain.deinit(&device);

// 3. Per frame:
const index = try swapchain.acquire_next_image(&device);
var img = swapchain.image(index);
try cmd.begin(&device);
cmd.image_barrier(&device, .{ .image = &img, .before = .{}, .after = .{ .render_target = true } });
cmd.begin_rendering(&device, .{
    .color_attachments = &.{.{ .view = swapchain.image_view(index), .load_op = .clear, .store_op = .store, .clear_color = .{ 0.1, 0.2, 0.4, 1.0 } }},
    .render_area = .{ .width = swapchain.width, .height = swapchain.height },
});
// ... draw ...
cmd.end_rendering(&device);
cmd.image_barrier(&device, .{ .image = &img, .before = .{ .render_target = true }, .after = .{ .present = true } });
try swapchain.frame_submit(&device, &device.graphics_queue, .{ .image_index = index, .ring_element = &ring_element, .cmd = cmd });
```

See [`examples/00Clear.zig`](examples/00Clear.zig) for the complete, runnable version (window
creation, resize handling, and the command ring buffer). On Apple targets, pass `.{ .mtl = .{} }`
to `Renderer.init` instead of the Vulkan config.

## Using rhi-zig as a dependency

Fetch the module and add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/flying-swallow/rhi-zig.git
```

Then wire the `rhi` module into your build (mirroring `examples/build.zig`):

```zig
const rhi_dep = b.dependency("rhi", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("rhi", rhi_dep.module("rhi"));
```

The library selects its backend from the resolved target (Vulkan off Apple, Metal on Apple), so
forward `target`/`optimize` through.

## Project layout

```
src/                 RHI library — public API in src/root.zig
  vulkan.zig         Vulkan backend (vulkan-zig + VMA)
  metal.zig          Metal backend (Objective-C binding fabric)
  webgpu.zig         WebGPU backend (web-only): handle type + wasm imports
  webgpu/enums.zig   WebGPU enum tables, rhi.Format mapping, glue contract test
  webgpu/glue.js     JS half of the WebGPU backend (navigator.gpu + rAF loop, owns the backend probe)
  webgl.zig          WebGL2 backend (web-only fallback): handle type + GL imports
  webgl/enums.zig    GL constants, rhi.Format mapping, glue contract test
  webgl/command_list.zig  Deferred command recording + replay
  webgl/glue.js      JS half of the WebGL2 backend
  d3d12.zig          D3D12 backend (stub)
  rpi/               Render-program layer (Program, bindings, pipeline descs)
  imgui.zig          Dear ImGui rendering layer
  io/gltf/           std-only glTF loader
  shaders/           Embedded ImGui Slang shader
examples/            Standalone example apps + their own build
  sdl_app.zig        Desktop harness (SDL3)
  web_app.zig        Web harness (requestAnimationFrame, no SDL)
  platform.zig       Picks the harness for the target
deps/                Vendored path dependencies: vma, metal, slang, spirv_cross
```

The public API is re-exported from [`src/root.zig`](src/root.zig) — start there for the full list
of types (`Renderer`, `Device`, `Swapchain`, `Cmd`, `Pipeline`, `Buffer`, `Image`, the `rpi`
namespace, the allocators, etc.).

## Status & caveats

- Version `0.0.0` — early and evolving; expect breaking API changes.
- The D3D12 backend is stubbed and not usable yet.
- The WebGPU and WebGL2 backends are web-only and cover what examples `00`–`02` exercise; see the
  tables in [Web builds](#web-builds) for what they deliberately do not support.
- `03_imgui` and `04_svt` are Vulkan-only; the `rpi` layer is Vulkan-complete but only partially
  implemented on Metal.
- The project tracks nightly Zig (0.16-dev); older/stable Zig releases are not supported.

## License

- **GNU General Public License (GPL)** for open-source use.
