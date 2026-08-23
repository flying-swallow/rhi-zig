# rhi-zig examples

Standalone apps demonstrating the [`rhi`](../README.md) API. They run natively on Vulkan and
Metal, and examples `00`–`02` also run in a browser on WebGPU or WebGL2.

> **This directory is a separate build root.** It has its own `build.zig` / `build.zig.zon` and
> consumes the library as a path dependency (`.rhi = .{ .path = ".." }`). Run every command below
> from `examples/`, not from the repository root — `zig build 00_clear` at the top level will fail
> with `no such step`.

## The examples

| Step        | Source         | Demonstrates                                                                                    | Backends                       |
| ----------- | -------------- | ----------------------------------------------------------------------------------------------- | ------------------------------ |
| `00_clear`  | `00Clear.zig`  | Swapchain clear with image barriers, plus four sub-rect quadrant clears. No shaders.             | Vulkan, Metal, WebGPU, WebGL2  |
| `01_shader` | `01Shader.zig` | Fullscreen Mandelbrot. A vertex-id triangle, so no vertex buffer.                                | Vulkan, Metal, WebGPU, WebGL2  |
| `02_mesh`   | `02Mesh.zig`   | Rotating cube: vertex + index buffers, a depth attachment, and push constants.                   | Vulkan, Metal, WebGPU, WebGL2  |
| `03_imgui`  | `03Imgui.zig`  | Dear ImGui drawn through `rhi.imgui`.                                                            | Vulkan                         |
| `04_svt`    | `04SVT.zig`    | Software virtual texturing on the `rpi` layer: feedback pass → CPU tile streaming → composite.   | Vulkan                         |

`03_imgui` and `04_svt` are Vulkan-only — the `rpi` descriptor path and the ImGui texture upload
are not implemented on the other backends. They are skipped automatically on Apple and web targets.

## Running natively

Each example is a run step, so building and running are one command:

```sh
zig build 00_clear      # or 01_shader, 02_mesh, 03_imgui, 04_svt
```

`zig build` with no step builds every example (for the current target) without running any of them.
Binaries land in `zig-out/bin/`.

Useful flags:

| | |
| --- | --- |
| `-Doptimize=ReleaseFast` | The default is a debug build, which is noticeably slow. |
| `-- --video-driver x11` | Force SDL's video backend. Everything after `--` is forwarded to the example. Needed to capture under RenderDoc, which does not support Wayland. |
| `-Dslangc=/path/to/slangc` | Use an existing `slangc` instead of downloading the prebuilt Slang — e.g. the one in the Vulkan SDK. |

Natively the examples are hosted by SDL3, which is fetched lazily on first build.

## Running in a browser

Examples `00`–`02` build for `wasm32-freestanding`, where the RHI targets WebGPU with a WebGL2
fallback. A `.wasm` cannot be launched by the build system, so the build installs a page and you
serve it:

```sh
zig build -Dtarget=wasm32-freestanding
cd zig-out/bin && python3 -m http.server 8000
```

Then open <http://localhost:8000/00_clear.html> — or `01_shader.html`, `02_mesh.html`.

**It has to be served over http(s).** `navigator.gpu` and WebGL2 both require a secure context, and
a `file://` URL is not one, so opening the page directly fails. `localhost` counts as secure.

The build emits into `zig-out/bin/`:

| File | |
| --- | --- |
| `<name>.wasm` | The example, with both web backends compiled in |
| `<name>.html` | A page that loads it: canvas, module loader, error panel |
| `glue.js` | The WebGPU half of the backend, and the probe that picks between them |
| `webgl_glue.js` | The WebGL2 half, imported by `glue.js` as a flat sibling |

There is no SDL on the web. `web_app.zig` replaces it, and the browser owns the frame loop: the
module exports `rhi_web_frame`, which `glue.js` calls once per `requestAnimationFrame`.

### Which backend am I getting?

The console says so on startup:

```
[rhi] backend: WebGPU        (or: WebGL2)
```

The page prefers WebGPU and falls back to WebGL2 when there is no usable adapter. To pin one,
edit the generated `<name>.html` — `boot()` takes a `forceBackend` option:

```js
boot("./00_clear.wasm", { canvas: "#canvas", forceBackend: "webgl" });
```

That is also how you exercise the fallback on a machine where WebGPU works.

### Troubleshooting

**Getting WebGL2 when you wanted WebGPU.** The browser has `navigator.gpu` but returned no adapter.
On Linux, Chrome gates WebGPU behind a flag:

```sh
google-chrome --enable-unsafe-webgpu http://localhost:8000/00_clear.html
```

or enable it permanently at `chrome://flags/#enable-unsafe-webgpu`. Firefox uses
`dom.webgpu.enabled` in `about:config`. This is not a failure — the page renders either way; it
only matters if you were specifically testing the WebGPU path.

**A blank page with an error panel.** Neither backend came up. The message names both failures:

```
no usable GPU backend.
  WebGPU: requestAdapter() returned null (on Linux, Chrome needs --enable-unsafe-webgpu)
  WebGL2: canvas.getContext('webgl2') returned null
```

**A blank page and nothing in the console.** Check that the `.wasm` is served as
`application/wasm`; `WebAssembly.instantiateStreaming` rejects anything else. Python's
`http.server` gets this right.

**A blank page after rebuilding, with WebGL warnings about invalid enums or unbound buffers.**
That was a stale browser cache pairing an old `glue.js` with a new `.wasm`, and it should no longer
be possible — see [Caching](#caching). If you do hit it, reload with cache disabled
(Ctrl+Shift+R).

### Caching

`glue.js`, `webgl_glue.js` and the `.wasm` are three files the browser caches independently — and an
ES module import is cached far more stubbornly than a `fetch`. Pairing an old glue with a new module
is silently catastrophic: JS ignores extra arguments and fills missing ones with `undefined`, so a
changed import signature shifts every argument along and the page renders nothing, with no error.

Two things prevent that:

- **The generated page appends a fresh token to every asset URL it loads**, and is itself marked
  `no-store`. Nothing is reused across a reload, so a rebuild is always picked up. These are
  development pages, so never caching them is the right trade; a real deployment should use content
  hashes instead.
- **The module and the glue agree on an ABI version** (`rhi.glue_abi_version` in `src/root.zig`,
  `GLUE_ABI_VERSION` in `src/webgpu/glue.js`). `boot()` refuses to start on a mismatch and says so
  rather than running with shifted arguments, and `zig build test` checks the two constants agree.
  Bump both whenever an `extern` signature in `webgpu.zig` or `webgl.zig` changes.

## Shaders

Shader sources are Slang, in `example_assets/`. Every backend compiles from the same source — the
build runs `slangc` per target and, for WebGL2, pipes the result through the vendored SPIRV-Cross
tool in [`deps/spirv_cross`](../deps/spirv_cross):

| Backend | Pipeline | Where it lands |
| --- | --- | --- |
| Vulkan | `slangc -target spirv` | `example_assets/<name>.spv` (gitignored, rebuilt each time) |
| Metal  | `slangc -target metal` | `example_assets/<name>.metal`, compiled at runtime |
| WebGPU | `slangc -target wgsl` | Embedded in the `.wasm` — freestanding wasm has no filesystem |
| WebGL2 | `slangc -target spirv` → `spirv_cross_tool` → GLSL ES 3.00 | Embedded in the `.wasm` |

Two places where the target leaks into the shader source, both worth knowing if you write a new one:

- **`02_mesh.slang` has an `#ifdef RHI_WGSL`.** WebGPU has no push constants, and slangc emits
  `[[vk::push_constant]]` as a WGSL `var<uniform>` with no `@group`/`@binding` attribute, which the
  browser rejects. The web build passes `-DRHI_WGSL=1` to select an explicitly bound
  `ConstantBuffer` instead.
- **Nothing is needed for WebGL2.** GL's flipped Y and `[-1, 1]` depth range are handled by
  SPIRV-Cross rather than in the shader, so the same source works unchanged.

`example_assets/` also contains some unused leftovers — `bunny.obj` and a few extensionless GLSL
440 files that predate the Slang toolchain. Nothing references them.

## How an example is put together

The three portable examples share a small platform layer so their bodies do not branch on the
target:

| File | |
| --- | --- |
| `platform.zig` | Selects the harness and exposes the common surface (`AppResult`, `Window`, `AppContext`, `window_handle`, `perf_counter`, `Application`, …) |
| `sdl_app.zig` | Desktop harness. Owns the SDL window and the frame loop |
| `web_app.zig` | Web harness. The browser owns the loop; this exports `rhi_web_init` / `rhi_web_frame` / `rhi_web_deinit` |
| `web_root.zig` | Root module for web builds only — see below |

`sdl_app.zig` also still exports the older `SdlApplicaton`, which `03_imgui` and `04_svt` use.

An example cannot be its own root on `wasm32-freestanding`: `std.start` keys off
`@hasDecl(root, "main")`, and emitting its wasm entry point pulls in `std.Io.Threaded` and posix,
which do not exist there. `web_root.zig` has no `main` and imports the example instead, so the
example keeps its native `main` untouched.

### Adding an example

1. Drop `NNName.zig` in this directory, modelled on `00Clear.zig`.
2. Add a row to the `examples` table in `build.zig`, with `apple` / `web` set to whichever targets
   it supports and a `shaders` list if it has any.
3. If it has shaders, put the `.slang` in `example_assets/` and name the entry points in that same
   table row.

The build takes care of the rest: run steps, shader compilation for every backend, and — for web
targets — the HTML page and the glue files.
