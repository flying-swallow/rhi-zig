// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only
//
// JS half of the rhi-zig WebGL2 backend. `src/webgl.zig` declares the imports;
// this file implements them against a `webgl2` canvas context.
//
// This backend is the *fallback* under WebGPU: WebGL2 needs no browser flags,
// where WebGPU is still gated on Linux Chrome and missing from older browsers.
// `src/webgpu/glue.js` owns the probe and calls `makeWebglImports` from here.
//
// Contract with the Zig side is the same as the WebGPU glue: objects live in a
// handle table addressed by u32 (0 = null), and every argument is a scalar or a
// (ptr, len) pair. GL enum values cross as their real numeric values rather than
// as table indices, so there is no ordering to keep in sync — only the constants
// themselves, which `src/webgl/enums.zig` pins with a test.

const GL = {
  ARRAY_BUFFER: 0x8892,
  ELEMENT_ARRAY_BUFFER: 0x8893,
  CULL_FACE: 0x0B44,
  DEPTH_TEST: 0x0B71,
  BLEND: 0x0BE2,
  SCISSOR_TEST: 0x0C11,
  FRONT: 0x0404,
  BACK: 0x0405,
  CW: 0x0900,
  CCW: 0x0901,
  LESS: 0x0201,
  TRIANGLES: 0x0004,
  UNSIGNED_SHORT: 0x1403,
  UNSIGNED_INT: 0x1405,
  FLOAT: 0x1406,
  RGBA8: 0x8058,
  DEPTH_COMPONENT32F: 0x8CAC,
  COLOR_ATTACHMENT0: 0x8CE0,
  DEPTH_ATTACHMENT: 0x8D00,
  FRAMEBUFFER_COMPLETE: 0x8CD5,
};

// Uniform types, for dispatching gl_uniform_raw.
const FLOAT = 0x1406;
const FLOAT_VEC2 = 0x8B50;
const FLOAT_VEC3 = 0x8B51;
const FLOAT_VEC4 = 0x8B52;
const INT = 0x1404;
const FLOAT_MAT4 = 0x8B5C;

export function makeWebglImports(ctx) {
  const { gl, wasm, u8, f32, bytes, str } = ctx;

  // Index 0 is the null handle, matching `Handle.none` in Zig.
  const handles = [null];
  const freeList = [];
  const put = (o) => {
    if (o === null || o === undefined) return 0;
    if (freeList.length) { const i = freeList.pop(); handles[i] = o; return i; }
    handles.push(o); return handles.length - 1;
  };
  const get = (i) => (i === 0 ? null : handles[i]);
  const drop = (i) => { if (i > 0 && handles[i] != null) { handles[i] = null; freeList.push(i); } };

  // Vertex attribute state is recorded into whichever VAO is bound, so the
  // helpers below bind explicitly rather than relying on a current VAO.
  return {
    gl_available: () => (gl ? 1 : 0),
    gl_renderer_name: (ptr, len) => {
      const info = gl.getExtension("WEBGL_debug_renderer_info");
      const name = (info && gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) || gl.getParameter(gl.RENDERER) || "WebGL2";
      const enc = new TextEncoder().encode(String(name));
      const n = Math.min(enc.length, len);
      u8().set(enc.subarray(0, n), ptr);
      return n;
    },
    gl_get_parameter_int: (pname) => {
      const v = gl.getParameter(pname);
      return typeof v === "number" ? v : 0;
    },

    // -- Buffers -----------------------------------------------------------
    gl_create_buffer: (size, usage) => {
      const b = gl.createBuffer();
      // COPY_WRITE_BUFFER, not ARRAY_BUFFER: WebGL2 locks a buffer to the first
      // target it is bound to, and binding it to a second one afterwards is an
      // INVALID_OPERATION. Allocating through ARRAY_BUFFER would therefore make
      // every index buffer fail at its first ELEMENT_ARRAY_BUFFER bind. The
      // COPY_* targets are exempt from that rule precisely for this case.
      //
      // Size is reserved up front so later sub-data writes never reallocate,
      // which would invalidate any VAO already referencing this buffer.
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, b);
      gl.bufferData(gl.COPY_WRITE_BUFFER, size, usage || gl.STATIC_DRAW);
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, null);
      return put(b);
    },
    gl_delete_buffer: (h) => { const b = get(h); if (b) gl.deleteBuffer(b); drop(h); },
    gl_buffer_sub_data: (h, offset, ptr, len) => {
      // COPY_WRITE_BUFFER for the same reason as gl_create_buffer: uploading
      // must not decide what kind of buffer this is.
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, get(h));
      gl.bufferSubData(gl.COPY_WRITE_BUFFER, offset, bytes(ptr, len));
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, null);
    },
    gl_copy_buffer_sub_data: (src, srcOff, dst, dstOff, size) => {
      gl.bindBuffer(gl.COPY_READ_BUFFER, get(src));
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, get(dst));
      gl.copyBufferSubData(gl.COPY_READ_BUFFER, gl.COPY_WRITE_BUFFER, srcOff, dstOff, size);
      gl.bindBuffer(gl.COPY_READ_BUFFER, null);
      gl.bindBuffer(gl.COPY_WRITE_BUFFER, null);
    },

    // -- Textures and framebuffers ----------------------------------------
    gl_create_texture_2d: (internalFormat, width, height, levels) => {
      const t = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texStorage2D(gl.TEXTURE_2D, Math.max(1, levels), internalFormat, width, height);
      // WebGL2 samples nothing without complete filter state, and the RHI has
      // no separate sampler object on this backend.
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.bindTexture(gl.TEXTURE_2D, null);
      return put(t);
    },
    gl_delete_texture: (h) => { const t = get(h); if (t) gl.deleteTexture(t); drop(h); },
    gl_create_framebuffer: () => put(gl.createFramebuffer()),
    gl_delete_framebuffer: (h) => { const f = get(h); if (f) gl.deleteFramebuffer(f); drop(h); },
    gl_framebuffer_texture_2d: (fbo, attachment, texture) => {
      gl.bindFramebuffer(gl.FRAMEBUFFER, get(fbo));
      gl.framebufferTexture2D(gl.FRAMEBUFFER, attachment, gl.TEXTURE_2D, get(texture), 0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    },
    gl_check_framebuffer_status: (fbo) => {
      gl.bindFramebuffer(gl.FRAMEBUFFER, get(fbo));
      const s = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      return s;
    },
    gl_bind_framebuffer: (fbo) => gl.bindFramebuffer(gl.FRAMEBUFFER, get(fbo)),
    gl_blit_to_canvas: (srcFbo, width, height) => {
      // WebGL2 cannot attach the canvas's colour buffer to a custom FBO, so
      // everything renders offscreen and is resolved here. Source and
      // destination share an origin, so this is a straight 1:1 blit.
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, get(srcFbo));
      gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
      gl.blitFramebuffer(0, 0, width, height, 0, 0, width, height, gl.COLOR_BUFFER_BIT, gl.NEAREST);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, null);
      gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, null);
    },

    // -- Programs ----------------------------------------------------------
    gl_create_program: (vsPtr, vsLen, fsPtr, fsLen, errPtr, errLen) => {
      const writeErr = (msg) => {
        const enc = new TextEncoder().encode(msg);
        u8().set(enc.subarray(0, Math.min(enc.length, errLen)), errPtr);
      };
      const compile = (type, src, what) => {
        const s = gl.createShader(type);
        gl.shaderSource(s, src);
        gl.compileShader(s);
        if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
          writeErr(`${what}: ${gl.getShaderInfoLog(s)}`);
          gl.deleteShader(s);
          return null;
        }
        return s;
      };
      const vs = compile(gl.VERTEX_SHADER, str(vsPtr, vsLen), "vertex");
      if (!vs) return 0;
      const fs = compile(gl.FRAGMENT_SHADER, str(fsPtr, fsLen), "fragment");
      if (!fs) { gl.deleteShader(vs); return 0; }
      const p = gl.createProgram();
      gl.attachShader(p, vs);
      gl.attachShader(p, fs);
      gl.linkProgram(p);
      // The shaders are reference-counted by the program; detaching lets them
      // be freed once linking has consumed them.
      gl.detachShader(p, vs); gl.detachShader(p, fs);
      gl.deleteShader(vs); gl.deleteShader(fs);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) {
        writeErr(`link: ${gl.getProgramInfoLog(p)}`);
        gl.deleteProgram(p);
        return 0;
      }
      return put(p);
    },
    gl_delete_program: (h) => { const p = get(h); if (p) gl.deleteProgram(p); drop(h); },
    gl_use_program: (h) => gl.useProgram(get(h)),
    gl_active_uniform_count: (h) => gl.getProgramParameter(get(h), gl.ACTIVE_UNIFORMS) || 0,
    gl_active_uniform_info: (h, index, namePtr, nameLen, outType) => {
      const info = gl.getActiveUniform(get(h), index);
      if (!info) return 0;
      const enc = new TextEncoder().encode(info.name);
      const n = Math.min(enc.length, nameLen);
      u8().set(enc.subarray(0, n), namePtr);
      new Uint32Array(wasm.memory.buffer)[outType >> 2] = info.type;
      return n;
    },
    gl_uniform_location: (h, namePtr, nameLen) => {
      const loc = gl.getUniformLocation(get(h), str(namePtr, nameLen));
      if (loc === null) return -1;
      // WebGLUniformLocation is an object, not an int, so it goes in the handle
      // table like everything else. -1 stays the "not found" sentinel.
      return put(loc);
    },
    gl_uniform_raw: (location, type, ptr, len) => {
      if (location < 0) return;
      const loc = get(location);
      if (!loc) return;
      const f = f32().subarray(ptr >> 2, (ptr >> 2) + (len >> 2));
      switch (type) {
        case FLOAT: gl.uniform1fv(loc, f); break;
        case FLOAT_VEC2: gl.uniform2fv(loc, f); break;
        case FLOAT_VEC3: gl.uniform3fv(loc, f); break;
        case FLOAT_VEC4: gl.uniform4fv(loc, f); break;
        case FLOAT_MAT4: gl.uniformMatrix4fv(loc, false, f); break;
        case INT: gl.uniform1iv(loc, new Int32Array(wasm.memory.buffer, ptr, len >> 2)); break;
        default: console.warn(`[rhi] unhandled uniform type 0x${type.toString(16)}`);
      }
    },

    // -- Vertex arrays -----------------------------------------------------
    gl_create_vertex_array: () => put(gl.createVertexArray()),
    gl_delete_vertex_array: (h) => { const v = get(h); if (v) gl.deleteVertexArray(v); drop(h); },
    gl_bind_vertex_array: (h) => gl.bindVertexArray(get(h)),
    gl_vertex_attrib_pointer: (vao, buffer, location, components, stride, offset) => {
      gl.bindVertexArray(get(vao));
      gl.bindBuffer(gl.ARRAY_BUFFER, get(buffer));
      gl.enableVertexAttribArray(location);
      gl.vertexAttribPointer(location, components, gl.FLOAT, false, stride, offset);
      gl.bindVertexArray(null);
    },
    gl_vao_set_element_buffer: (vao, buffer) => {
      gl.bindVertexArray(get(vao));
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, get(buffer));
      gl.bindVertexArray(null);
    },

    // -- Fixed-function state ---------------------------------------------
    gl_viewport: (x, y, w, h, minDepth, maxDepth) => {
      gl.viewport(x, y, w, h);
      gl.depthRange(minDepth, maxDepth);
    },
    gl_scissor: (x, y, w, h) => gl.scissor(x, y, w, h),
    gl_set_enabled: (cap, on) => (on ? gl.enable(cap) : gl.disable(cap)),
    gl_depth_func: (f) => gl.depthFunc(f),
    gl_depth_mask: (on) => gl.depthMask(!!on),
    gl_cull_face: (m) => gl.cullFace(m),
    gl_front_face: (m) => gl.frontFace(m),
    gl_color_mask: (r, g, b, a) => gl.colorMask(!!r, !!g, !!b, !!a),

    // -- Clears and draws --------------------------------------------------
    gl_clear_color: (r, g, b, a) => {
      gl.clearColor(r, g, b, a);
      gl.clear(gl.COLOR_BUFFER_BIT);
    },
    gl_clear_depth: (d) => {
      gl.clearDepth(d);
      gl.clear(gl.DEPTH_BUFFER_BIT);
    },
    gl_draw_arrays: (mode, first, count, instances) => {
      if (instances > 1) gl.drawArraysInstanced(mode, first, count, instances);
      else gl.drawArrays(mode, first, count);
    },
    gl_draw_elements: (mode, count, type, offset, instances) => {
      if (instances > 1) gl.drawElementsInstanced(mode, count, type, offset, instances);
      else gl.drawElements(mode, count, type, offset);
    },
    gl_finish: () => gl.finish(),

    // -- Sync --------------------------------------------------------------
    gl_fence_sync: () => put(gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)),
    gl_client_wait_sync: (h) => {
      const s = get(h);
      if (!s) return 1;
      // Timeout must be 0: MAX_CLIENT_WAIT_TIMEOUT_WEBGL is 0, so a page cannot
      // block on the GPU here.
      const r = gl.clientWaitSync(s, 0, 0);
      return r === gl.ALREADY_SIGNALED || r === gl.CONDITION_SATISFIED ? 1 : 0;
    },
    gl_delete_sync: (h) => { const s = get(h); if (s) gl.deleteSync(s); drop(h); },

    // -- Diagnostics -------------------------------------------------------
    gl_log: (level, ptr, len) => {
      const msg = str(ptr, len);
      if (level >= 3) console.error(msg);
      else if (level === 2) console.warn(msg);
      else if (level === 1) console.info(msg);
      else console.debug(msg);
    },
  };
}

export { GL };
