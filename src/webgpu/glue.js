// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only
//
// JS half of the rhi-zig WebGPU backend. `src/webgpu.zig` declares the imports;
// this file implements them against `navigator.gpu`.
//
// Contract with the Zig side:
//
//   * WebGPU objects never cross the boundary. They live in `handles` and are
//     addressed by a u32 index; 0 is null.
//   * Every argument is a scalar or a (ptr, len) pair into wasm linear memory.
//     No struct layout is shared, so there is nothing to drift out of sync.
//   * The enum tables below are positional. Their order must match the
//     corresponding `enum(u32)` in webgpu.zig exactly; adding a value means
//     adding it in both files, at the same index.
//   * Sizes and offsets are u32, so no BigInt is ever involved. u64 values that
//     must round-trip (timeline counters) are split into lo/hi halves.

// --- Enum tables (order must match src/webgpu.zig) -------------------------

// Installed side by side with this file (see build.zig), not as a sibling
// directory, so the import is flat.
import { makeWebglImports } from "./webgl_glue.js";

const TEXTURE_FORMAT = [
  "r8unorm", "r8snorm", "r8uint", "r8sint",
  "r16uint", "r16sint", "r16float",
  "rg8unorm", "rg8snorm", "rg8uint", "rg8sint",
  "r32uint", "r32sint", "r32float",
  "rg16uint", "rg16sint", "rg16float",
  "rgba8unorm", "rgba8unorm-srgb", "rgba8snorm", "rgba8uint", "rgba8sint",
  "bgra8unorm", "bgra8unorm-srgb",
  "rgb9e5ufloat", "rgb10a2uint", "rgb10a2unorm", "rg11b10ufloat",
  "rg32uint", "rg32sint", "rg32float",
  "rgba16uint", "rgba16sint", "rgba16float",
  "rgba32uint", "rgba32sint", "rgba32float",
  "depth16unorm", "depth24plus", "depth24plus-stencil8", "depth32float", "depth32float-stencil8",
  "bc1-rgba-unorm", "bc1-rgba-unorm-srgb", "bc2-rgba-unorm", "bc2-rgba-unorm-srgb",
  "bc3-rgba-unorm", "bc3-rgba-unorm-srgb", "bc4-r-unorm", "bc4-r-snorm",
  "bc5-rg-unorm", "bc5-rg-snorm", "bc6h-rgb-ufloat", "bc6h-rgb-float",
  "bc7-rgba-unorm", "bc7-rgba-unorm-srgb",
  "etc2-rgb8unorm", "etc2-rgb8unorm-srgb", "etc2-rgb8a1unorm", "etc2-rgb8a1unorm-srgb",
  "etc2-rgba8unorm", "etc2-rgba8unorm-srgb",
  "eac-r11unorm", "eac-r11snorm", "eac-rg11unorm", "eac-rg11snorm",
  // `undefined_format`: the Zig-side sentinel for "no such WebGPU format".
  // Reaching JS as an actual format is a bug; as a depth format it means the
  // render pass has no depth attachment.
  null,
];

const TEXTURE_DIMENSION = ["1d", "2d", "3d"];
const VIEW_DIMENSION = ["1d", "2d", "2d-array", "cube", "cube-array", "3d"];
const TEXTURE_ASPECT = ["all", "stencil-only", "depth-only"];
const LOAD_OP = ["load", "clear"];
const STORE_OP = ["store", "discard"];
const TOPOLOGY = ["point-list", "line-list", "line-strip", "triangle-list", "triangle-strip"];
const CULL_MODE = ["none", "front", "back"];
const FRONT_FACE = ["ccw", "cw"];
const COMPARE = ["never", "less", "equal", "less-equal", "greater", "not-equal", "greater-equal", "always"];
const INDEX_FORMAT = ["uint16", "uint32"];
const VERTEX_FORMAT = ["float32", "float32x2", "float32x3", "float32x4"];

// --- Handle table ----------------------------------------------------------

// Index 0 is reserved as the null handle, matching `Handle.none` in Zig.
const handles = [null];
const freeList = [];

function put(obj) {
  if (obj === null || obj === undefined) return 0;
  if (freeList.length > 0) {
    const id = freeList.pop();
    handles[id] = obj;
    return id;
  }
  handles.push(obj);
  return handles.length - 1;
}

function get(id) {
  return id === 0 ? null : handles[id];
}

function drop(id) {
  if (id === 0 || id >= handles.length || handles[id] === null) return;
  handles[id] = null;
  freeList.push(id);
}

// --- Boot ------------------------------------------------------------------

/**
 * Load and run an rhi-zig WebGPU module.
 *
 * The adapter and device are requested *before* the wasm module is
 * instantiated. That is what lets the Zig side keep `Renderer.init` ->
 * `enumerate_adapters` -> `Device.init` synchronous: by the time any Zig code
 * runs, both objects already exist in the handle table. The alternative would
 * be asyncify or an async split of the RHI's init path.
 *
 * The wasm module is expected to export:
 *   - `memory`
 *   - `rhi_web_init(canvasSelectorPtr, canvasSelectorLen) -> i32`  (0 = ok)
 *   - `rhi_web_frame(widthPx, heightPx, timeMs) -> i32`            (0 = continue)
 *   - `rhi_web_deinit()`                                           (optional)
 *   - `rhi_web_alloc(len) -> ptr`                                  (for passing the selector in)
 */
export async function boot(wasmUrl, options = {}) {
  const canvasSelector = options.canvas ?? "#canvas";
  const canvasEl = document.querySelector(canvasSelector);
  if (!canvasEl) throw new Error(`no element matches canvas selector ${canvasSelector}`);

  // Probe WebGPU, then fall back to WebGL2. A canvas can only ever hand out one
  // context type, so WebGL2 is only requested when WebGPU is genuinely
  // unusable — and `forceBackend: "webgl"` skips the probe entirely, which is
  // how the fallback gets tested on a machine where WebGPU works.
  let adapter = null;
  let device = null;
  let webgpuError = "not attempted";
  if (options.forceBackend !== "webgl") {
    if (!navigator.gpu) {
      webgpuError = "navigator.gpu is undefined (needs a secure context and a browser with WebGPU enabled)";
    } else {
      try {
        adapter = await navigator.gpu.requestAdapter(options.adapterOptions);
        if (!adapter) {
          webgpuError = "requestAdapter() returned null (on Linux, Chrome needs --enable-unsafe-webgpu)";
        } else {
          device = await adapter.requestDevice(options.deviceOptions);
        }
      } catch (e) {
        webgpuError = String(e && e.message ? e.message : e);
        adapter = null;
        device = null;
      }
    }
  }

  let gl = null;
  let webglError = "not attempted";
  if (!device) {
    gl = canvasEl.getContext("webgl2", { alpha: false, antialias: false, depth: false, stencil: false });
    if (!gl) webglError = "canvas.getContext('webgl2') returned null";
  }

  if (!device && !gl) {
    throw new Error(`no usable GPU backend.\n  WebGPU: ${webgpuError}\n  WebGL2: ${webglError}`);
  }
  console.info(`[rhi] backend: ${device ? "WebGPU" : "WebGL2"}`);

  if (device) {
    device.lost.then((info) => {
      console.error(`[rhi] WebGPU device lost (${info.reason}): ${info.message}`);
    });
    // Without this, validation failures are reported asynchronously and can be
    // easy to miss; surfacing them eagerly keeps the cause near the effect.
    device.addEventListener?.("uncapturederror", (e) => {
      console.error("[rhi] WebGPU error:", e.error?.message ?? e.error);
    });
  }

  const adapterHandle = put(adapter);
  const deviceHandle = put(device);

  // Filled in after instantiation; imports close over this object rather than
  // the instance so they can be built first.
  const wasm = { memory: null, exports: null };

  const u8 = () => new Uint8Array(wasm.memory.buffer);
  const u32 = () => new Uint32Array(wasm.memory.buffer);
  const bytes = (ptr, len) => u8().subarray(ptr, ptr + len);
  const str = (ptr, len) => new TextDecoder().decode(bytes(ptr, len));

  const f32 = () => new Float32Array(wasm.memory.buffer);

  // Both namespaces are always supplied: the wasm module declares imports for
  // both backends, and instantiation fails unless every one is satisfied. The
  // unselected backend's imports are simply never called.
  const imports = {
    wgpu: makeImports({ adapterHandle, deviceHandle, wasm, u8, u32, bytes, str }),
    webgl: makeWebglImports({ gl, wasm, u8, f32, bytes, str }),
  };

  const response = await fetch(wasmUrl);
  const { instance } = await WebAssembly.instantiateStreaming(response, imports);
  wasm.memory = instance.exports.memory;
  wasm.exports = instance.exports;

  const canvas = canvasEl;

  // Hand the selector to Zig through wasm memory so the swapchain can resolve
  // the same canvas when it creates its surface.
  const selectorBytes = new TextEncoder().encode(canvasSelector);
  const selectorPtr = instance.exports.rhi_web_alloc(selectorBytes.length);
  u8().set(selectorBytes, selectorPtr);

  const initRc = instance.exports.rhi_web_init(selectorPtr, selectorBytes.length);
  if (initRc !== 0) throw new Error(`rhi_web_init failed with ${initRc}`);

  let running = true;
  const frame = (timeMs) => {
    if (!running) return;
    // Track the canvas backing-store size to its CSS size; the Zig side polls
    // these each frame and reconfigures the surface when they change.
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.floor(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.floor(canvas.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    let rc;
    try {
      rc = instance.exports.rhi_web_frame(w, h, timeMs ?? 0);
    } catch (e) {
      running = false;
      console.error("[rhi] frame threw, stopping loop:", e);
      return;
    }
    if (rc !== 0) {
      running = false;
      instance.exports.rhi_web_deinit?.();
      return;
    }
    requestAnimationFrame(frame);
  };
  requestAnimationFrame(frame);

  return {
    instance,
    device,
    adapter,
    gl,
    backend: device ? "webgpu" : "webgl",
    canvas,
    stop() {
      running = false;
      instance.exports.rhi_web_deinit?.();
    },
  };
}

// --- Imports ---------------------------------------------------------------

function makeImports(ctx) {
  const { adapterHandle, deviceHandle, wasm, u8, u32, bytes, str } = ctx;

  // Per-surface state. A surface handle wraps the canvas context plus the
  // configuration it was last given, because `getCurrentTexture` needs both and
  // WebGPU has no object that bundles them.
  const surfaces = new Map();

  return {
    // -- Adapter / device --------------------------------------------------
    wgpu_adapter_get: () => adapterHandle,
    wgpu_device_get: () => deviceHandle,
    wgpu_device_get_queue: (dev) => put(get(dev).queue),

    wgpu_adapter_name: (adapter, bufPtr, bufLen) => {
      const a = get(adapter);
      // `info` is the modern spelling; older builds exposed only the (removed)
      // async requestAdapterInfo, so fall back to an empty description rather
      // than throwing.
      const name = a?.info?.description || a?.info?.vendor || "WebGPU";
      const enc = new TextEncoder().encode(name);
      const n = Math.min(enc.length, bufLen);
      u8().set(enc.subarray(0, n), bufPtr);
      return n;
    },
    // The browser deliberately withholds vendor/device ids from most origins;
    // 0 means "not reported" and the Zig side maps it to `.unknown`.
    wgpu_adapter_vendor_id: (adapter) => {
      const v = get(adapter)?.info?.vendor;
      // Chrome reports a vendor string ("nvidia"), not a PCI id. Map the ones
      // the RHI's Vendor enum knows about back to their PCI ids.
      if (typeof v === "string") {
        const s = v.toLowerCase();
        if (s.includes("nvidia")) return 0x10de;
        if (s.includes("amd") || s.includes("ati")) return 0x1002;
        if (s.includes("intel")) return 0x8086;
      }
      return 0;
    },
    wgpu_adapter_device_id: (adapter) => {
      const d = get(adapter)?.info?.device;
      return typeof d === "number" ? d : 0;
    },
    // 0 = discrete, 1 = integrated, 2 = cpu, 3 = unknown.
    wgpu_adapter_type: (adapter) => {
      const a = get(adapter);
      if (a?.info?.architecture === "cpu" || a?.isFallbackAdapter) return 2;
      const t = a?.info?.type;
      if (t === "discrete-gpu") return 0;
      if (t === "integrated-gpu") return 1;
      return 3;
    },
    wgpu_adapter_limit: (adapter, namePtr, nameLen) => {
      const v = get(adapter)?.limits?.[str(namePtr, nameLen)];
      return typeof v === "number" ? v : 0;
    },

    wgpu_release: (handle) => {
      const obj = get(handle);
      // GPUBuffer/GPUTexture/GPUQuerySet own real memory and expose destroy();
      // everything else is reclaimed by GC once the table entry is cleared.
      if (obj && typeof obj.destroy === "function") {
        try {
          obj.destroy();
        } catch {
          // A canvas texture is destroyed by the browser at end of frame;
          // destroying it again is harmless but throws in some builds.
        }
      }
      surfaces.delete(handle);
      drop(handle);
    },

    // -- Surface (canvas) --------------------------------------------------
    wgpu_surface_create: (selPtr, selLen) => {
      const selector = str(selPtr, selLen);
      const canvas = document.querySelector(selector);
      if (!canvas) {
        console.error(`[rhi] no element matches canvas selector ${selector}`);
        return 0;
      }
      const context = canvas.getContext("webgpu");
      if (!context) {
        console.error("[rhi] canvas.getContext('webgpu') returned null");
        return 0;
      }
      const id = put(context);
      surfaces.set(id, { canvas, context, format: null });
      return id;
    },
    wgpu_surface_preferred_format: () => {
      const name = navigator.gpu.getPreferredCanvasFormat();
      const idx = TEXTURE_FORMAT.indexOf(name);
      if (idx < 0) {
        console.error(`[rhi] preferred canvas format ${name} is not in the format table`);
        // bgra8unorm is what every current browser reports; falling back to it
        // is better than handing Zig an out-of-range enum value.
        return TEXTURE_FORMAT.indexOf("bgra8unorm");
      }
      return idx;
    },
    wgpu_surface_configure: (surface, dev, format, width, height) => {
      const s = surfaces.get(surface);
      if (!s) return;
      // The backing store must match what we configure, or getCurrentTexture
      // returns a texture of a different size than the pass expects.
      s.canvas.width = width;
      s.canvas.height = height;
      s.format = TEXTURE_FORMAT[format];
      s.context.configure({
        device: get(dev),
        format: s.format,
        alphaMode: "opaque",
        usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
      });
    },
    wgpu_surface_get_current_texture: (surface) => {
      const s = surfaces.get(surface);
      if (!s) return 0;
      try {
        return put(s.context.getCurrentTexture());
      } catch (e) {
        // Thrown when the context is unconfigured or was lost; the Zig side
        // reads a null handle as `.out_of_date` and reconfigures.
        console.warn("[rhi] getCurrentTexture failed:", e);
        return 0;
      }
    },

    // -- Textures ----------------------------------------------------------
    wgpu_device_create_texture: (dev, format, width, height, depthOrLayers, mipLevelCount, sampleCount, dimension, usage) =>
      put(get(dev).createTexture({
        size: { width, height, depthOrArrayLayers: depthOrLayers },
        mipLevelCount,
        sampleCount,
        dimension: TEXTURE_DIMENSION[dimension],
        format: TEXTURE_FORMAT[format],
        usage,
      })),

    wgpu_texture_create_view: (texture, format, dimension, aspect, baseMipLevel, mipLevelCount, baseArrayLayer, arrayLayerCount) =>
      put(get(texture).createView({
        format: TEXTURE_FORMAT[format],
        dimension: VIEW_DIMENSION[dimension],
        aspect: TEXTURE_ASPECT[aspect],
        baseMipLevel,
        mipLevelCount,
        baseArrayLayer,
        arrayLayerCount,
      })),

    // -- Buffers -----------------------------------------------------------
    wgpu_device_create_buffer: (dev, size, usage) =>
      put(get(dev).createBuffer({ size, usage })),

    wgpu_queue_write_buffer: (queue, buffer, bufferOffset, dataPtr, dataLen) => {
      // writeBuffer copies synchronously, so a view into (growable) wasm memory
      // is safe here as long as it is taken fresh.
      get(queue).writeBuffer(get(buffer), bufferOffset, bytes(dataPtr, dataLen));
    },

    // -- Shaders -----------------------------------------------------------
    wgpu_device_create_shader_module: (dev, wgslPtr, wgslLen) => {
      const code = str(wgslPtr, wgslLen);
      const module = get(dev).createShaderModule({ code });
      // Compilation is async but the messages are worth surfacing: a WGSL error
      // otherwise shows up only as a pipeline creation failure.
      module.getCompilationInfo?.().then((info) => {
        for (const m of info.messages) {
          if (m.type === "error") console.error(`[rhi] WGSL ${m.lineNum}:${m.linePos}: ${m.message}`);
          else if (m.type === "warning") console.warn(`[rhi] WGSL ${m.lineNum}:${m.linePos}: ${m.message}`);
        }
      });
      return put(module);
    },

    // -- Pipelines ---------------------------------------------------------
    wgpu_device_create_render_pipeline: (
      dev,
      vsModule, vsEntryPtr, vsEntryLen,
      fsModule, fsEntryPtr, fsEntryLen,
      colorFormat, depthFormat,
      topology, cullMode, frontFace,
      depthWrite, depthCompare,
      vertexStride, attrsPtr, attrsLen,
    ) => {
      // Attributes arrive as a flat (location, format, offset) triple array
      // rather than a struct, so there is no field layout to keep in sync.
      const flat = u32().subarray(attrsPtr >> 2, (attrsPtr >> 2) + attrsLen);
      const attributes = [];
      for (let i = 0; i < attrsLen; i += 3) {
        attributes.push({
          shaderLocation: flat[i],
          format: VERTEX_FORMAT[flat[i + 1]],
          offset: flat[i + 2],
        });
      }

      const desc = {
        // "auto" derives bind group layouts from the shader, which is why the
        // backend needs no explicit pipeline layout object.
        layout: "auto",
        vertex: {
          module: get(vsModule),
          entryPoint: str(vsEntryPtr, vsEntryLen),
          buffers: attributes.length > 0
            ? [{ arrayStride: vertexStride, stepMode: "vertex", attributes }]
            : [],
        },
        primitive: {
          topology: TOPOLOGY[topology],
          cullMode: CULL_MODE[cullMode],
          frontFace: FRONT_FACE[frontFace],
        },
      };
      if (fsModule !== 0) {
        desc.fragment = {
          module: get(fsModule),
          entryPoint: str(fsEntryPtr, fsEntryLen),
          targets: [{ format: TEXTURE_FORMAT[colorFormat] }],
        };
      }
      const depth = TEXTURE_FORMAT[depthFormat];
      if (depth !== null && depth !== undefined) {
        desc.depthStencil = {
          format: depth,
          depthWriteEnabled: depthWrite !== 0,
          depthCompare: COMPARE[depthCompare],
        };
      }
      try {
        return put(get(dev).createRenderPipeline(desc));
      } catch (e) {
        console.error("[rhi] createRenderPipeline failed:", e);
        return 0;
      }
    },

    wgpu_render_pipeline_get_bind_group_layout: (pipeline, index) => {
      try {
        return put(get(pipeline).getBindGroupLayout(index));
      } catch (e) {
        console.error(`[rhi] getBindGroupLayout(${index}) failed:`, e);
        return 0;
      }
    },

    wgpu_device_create_bind_group_uniform: (dev, layout, buffer, offset, size) => {
      try {
        return put(get(dev).createBindGroup({
          layout: get(layout),
          entries: [{ binding: 0, resource: { buffer: get(buffer), offset, size } }],
        }));
      } catch (e) {
        console.error("[rhi] createBindGroup failed:", e);
        return 0;
      }
    },

    // -- Command encoding --------------------------------------------------
    wgpu_device_create_command_encoder: (dev) => put(get(dev).createCommandEncoder()),

    wgpu_command_encoder_begin_render_pass: (
      encoder,
      colorView, colorLoadOp, colorStoreOp, r, g, b, a,
      depthView, depthLoadOp, depthStoreOp, clearDepth,
    ) => {
      const desc = {
        colorAttachments: [{
          view: get(colorView),
          loadOp: LOAD_OP[colorLoadOp],
          storeOp: STORE_OP[colorStoreOp],
          clearValue: { r, g, b, a },
        }],
      };
      if (depthView !== 0) {
        desc.depthStencilAttachment = {
          view: get(depthView),
          depthLoadOp: LOAD_OP[depthLoadOp],
          depthStoreOp: STORE_OP[depthStoreOp],
          depthClearValue: clearDepth,
        };
      }
      return put(get(encoder).beginRenderPass(desc));
    },

    wgpu_command_encoder_copy_buffer_to_buffer: (encoder, src, srcOffset, dst, dstOffset, size) =>
      get(encoder).copyBufferToBuffer(get(src), srcOffset, get(dst), dstOffset, size),

    wgpu_command_encoder_finish: (encoder) => put(get(encoder).finish()),

    // -- Render pass -------------------------------------------------------
    wgpu_render_pass_set_viewport: (pass, x, y, width, height, minDepth, maxDepth) =>
      get(pass).setViewport(x, y, width, height, minDepth, maxDepth),
    wgpu_render_pass_set_scissor_rect: (pass, x, y, width, height) =>
      get(pass).setScissorRect(x, y, width, height),
    wgpu_render_pass_set_pipeline: (pass, pipeline) => get(pass).setPipeline(get(pipeline)),
    wgpu_render_pass_set_bind_group: (pass, index, bindGroup) =>
      get(pass).setBindGroup(index, get(bindGroup)),
    wgpu_render_pass_set_vertex_buffer: (pass, slot, buffer, offset) =>
      get(pass).setVertexBuffer(slot, get(buffer), offset),
    wgpu_render_pass_set_index_buffer: (pass, buffer, format, offset) =>
      get(pass).setIndexBuffer(get(buffer), INDEX_FORMAT[format], offset),
    wgpu_render_pass_draw: (pass, vertexCount, instanceCount, firstVertex, firstInstance) =>
      get(pass).draw(vertexCount, instanceCount, firstVertex, firstInstance),
    wgpu_render_pass_draw_indexed: (pass, indexCount, instanceCount, firstIndex, baseVertex, firstInstance) =>
      get(pass).drawIndexed(indexCount, instanceCount, firstIndex, baseVertex, firstInstance),
    wgpu_render_pass_end: (pass) => get(pass).end(),

    // -- Queue -------------------------------------------------------------
    wgpu_queue_submit: (queue, bufsPtr, count) => {
      const ids = u32().subarray(bufsPtr >> 2, (bufsPtr >> 2) + count);
      const list = [];
      for (let i = 0; i < count; i++) list.push(get(ids[i]));
      get(queue).submit(list);
    },

    // Writes `value` back to `outPtr` as two little-endian u32s once the GPU
    // has finished the work submitted so far. Splitting the u64 keeps BigInt
    // out of the boundary entirely. `outPtr` points at a `[2]u32` inside a
    // Timeline, which outlives the callback.
    wgpu_queue_on_submitted_work_done: (queue, outPtr, valueLo, valueHi) => {
      get(queue).onSubmittedWorkDone().then(() => {
        const idx = outPtr >> 2;
        const view = u32();
        // Callbacks can retire out of order relative to each other; only ever
        // move the completed value forward.
        const prev = view[idx + 1] * 0x100000000 + view[idx];
        const next = valueHi * 0x100000000 + valueLo;
        if (next > prev) {
          view[idx] = valueLo;
          view[idx + 1] = valueHi;
        }
      });
    },

    // -- Diagnostics -------------------------------------------------------
    wgpu_log: (level, ptr, len) => {
      const msg = str(ptr, len);
      if (level >= 3) console.error(msg);
      else if (level === 2) console.warn(msg);
      else if (level === 1) console.info(msg);
      else console.debug(msg);
    },
  };
}
