# rhi-zig

A backend-agnostic **Render Hardware Interface (RHI)** for GPU rendering, written in Zig.

`rhi-zig` provides one explicit, modern GPU API over multiple graphics backends (Vulkan and
Metal today), a higher-level render-program (`rpi`) layer, a Dear ImGui rendering layer, and a
handful of asset loaders. Its RHI design is ported from the Amnesia/HPL2 engine
(`RITypes.h` / `RIBarrier.h`).

> **Status:** early / work in progress (`0.0.0`). The API is unstable and the project tracks a
> nightly Zig toolchain. See [Status & caveats](#status--caveats).

## Features

- **Backend-agnostic GPU API** — a single command/resource API that targets Vulkan or Metal
  from the same source, selected per platform at compile time.
- **Explicit, modern surface** — devices, queues, swapchains, command pools/buffers,
  images and image views, buffers, samplers, pipelines and pipeline layouts, descriptors, and
  barrier-based synchronization (fences, semaphores, timelines).
- **`rpi` render-program layer** — bundles a pipeline layout, a hash-keyed pipeline cache, and
  descriptor sets resolved by name for one set of shader stages (a Zig port of the C++ engine's
  `RIProgram`).
- **Dear ImGui layer** (`rhi.imgui`) — renders ImGui draw data through the RHI itself; its
  shaders are authored in Slang, compiled to SPIR-V, and embedded into the library.
- **Slang shader toolchain** — compiles shaders to SPIR-V (Vulkan) and MSL (Metal) via `slangc`,
  fetched automatically per host or supplied with `-Dslangc=<path>`.
- **Asset loading** — a std-only glTF loader (`rhi.io.gltf`).
- **Utilities** — a GPU profiler, a resource loader, and several allocators (scratch, segment,
  offset, and an index pool).

## Backend support

| Backend | Platforms       | Status                                                              |
| ------- | --------------- | ------------------------------------------------------------------ |
| Vulkan  | Windows, Linux  | Primary backend; most complete.                                    |
| Metal   | macOS, iOS      | Supported. Examples `00`–`02` are ported; on Metal the `rpi` layer covers the render-pipeline cache + push constants only. |
| D3D12   | Windows         | Declared in the backend enum but **not yet implemented** (`src/d3d12.zig` is a stub). |

The active backends per platform are chosen in `src/root.zig` (`platform_api`): Windows
`{ vk, dx12 }`, Linux `{ vk }`, macOS/iOS `{ mtl }`.

## Requirements

- **Zig 0.16.0+.** The code tracks 0.16-dev (nightly), so a matching nightly build is
  recommended (`minimum_zig_version = "0.16.0"`).
- **Vulkan targets:** the Vulkan headers are fetched as a dependency, but running requires a
  Vulkan runtime/driver on the machine.
- **`slangc`:** fetched automatically as a prebuilt Slang release for your host (lazily, so only
  the matching archive downloads), or override with `-Dslangc=/path/to/slangc`.
- **Examples:** additionally use SDL3 (fetched lazily) and `zla` (linear algebra).

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

The examples are standalone SDL3-hosted apps under `examples/`, each registered as a named run
step:

```sh
cd examples
zig build 00_clear      # or 01_shader, 02_mesh, 03_imgui, 04_svt
```

| Step        | Source          | Demonstrates                                                             | Backends       |
| ----------- | --------------- | ----------------------------------------------------------------------- | -------------- |
| `00_clear`  | `00Clear.zig`   | Minimal swapchain clear with image barriers.                            | Vulkan, Metal  |
| `01_shader` | `01Shader.zig`  | Fullscreen shader (Mandelbrot); Slang → SPIR-V/MSL per backend.         | Vulkan, Metal  |
| `02_mesh`   | `02Mesh.zig`    | Mesh rendering with push constants (`bunny.obj`).                       | Vulkan, Metal  |
| `03_imgui`  | `03Imgui.zig`   | Dear ImGui UI drawn through `rhi.imgui`.                                | Vulkan         |
| `04_svt`    | `04SVT.zig`     | Software virtual texturing on the `rpi` layer (feedback pass → CPU tile streaming → composite). | Vulkan |

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
  d3d12.zig          D3D12 backend (stub)
  rpi/               Render-program layer (Program, bindings, pipeline descs)
  imgui.zig          Dear ImGui rendering layer
  io/gltf/           std-only glTF loader
  shaders/           Embedded ImGui Slang shader
examples/            Standalone SDL3 example apps + their own build
deps/                Vendored path dependencies: vma, metal, slang
```

The public API is re-exported from [`src/root.zig`](src/root.zig) — start there for the full list
of types (`Renderer`, `Device`, `Swapchain`, `Cmd`, `Pipeline`, `Buffer`, `Image`, the `rpi`
namespace, the allocators, etc.).

## Status & caveats

- Version `0.0.0` — early and evolving; expect breaking API changes.
- The D3D12 backend is stubbed and not usable yet.
- `03_imgui` and `04_svt` are Vulkan-only; the `rpi` layer is Vulkan-complete but only partially
  implemented on Metal.
- The project tracks nightly Zig (0.16-dev); older/stable Zig releases are not supported.

## License

- **GNU General Public License (GPL)** for open-source use.
