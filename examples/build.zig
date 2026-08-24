// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

const std = @import("std");

/// One compiled shader stage: a Slang source + entry point + stage, emitted as
/// `<out>.spv` (Vulkan) and, on Apple targets, `<out>.metal` (Metal). The
/// examples load the artifact whose extension matches the active backend.
pub const ShaderStage = struct {
    src: []const u8,
    entry: []const u8,
    stage: []const u8, // "vertex" | "fragment" | "compute"
    out: []const u8,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The core RHI library. Forwarding target/optimize lets it select the
    // matching backend (Vulkan off Apple, Metal on Apple).
    const rhi_dep = b.dependency("rhi", .{
        .target = target,
        .optimize = optimize,
    });
    const rhi_module = rhi_dep.module("rhi");

    // Linear-algebra helpers for 04SVT's view/projection math. The pinned zla
    // revision gates its benchmark behind `b.isRoot()`, so consuming it as a
    // dependency here no longer pulls the `zbench` dev-dependency. Available to
    // every example module; only the ones that `@import("zla")` pull it in.
    const zla_module = b.dependency("zla", .{
        .target = target,
        .optimize = optimize,
    }).module("zla");

    const is_apple = target.result.os.tag == .macos or target.result.os.tag == .ios;

    // A WebAssembly target means the WebGPU backend (see src/root.zig), which
    // runs in the browser against navigator.gpu. There is no SDL and no window:
    // `examples/web_app.zig` is driven by requestAnimationFrame through
    // `src/webgpu/glue.js`, and each example ships as .wasm + glue.js +
    // index.html rather than an executable.
    const is_web = target.result.cpu.arch.isWasm();


    // SDL is a lazy dependency so the workspace can build without compiling
    // SDL's transitive build graph. The web build has no use for it.
    const sdl_dep = if (is_web) null else b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;

    const shaders_01 = [_]ShaderStage{
        .{ .src = "01_mandelbrot.slang", .entry = "vertexMain", .stage = "vertex", .out = "fullscreen.vert" },
        .{ .src = "01_mandelbrot.slang", .entry = "fragmentMain", .stage = "fragment", .out = "mandelbrot.frag" },
    };

    // `sdl_app.zig` is not imported at all on the web (platform.zig picks
    // `web_app.zig`), so the C bindings are only built off it.
    const sdl_c_module: ?*std.Build.Module = if (sdl_dep) |dep| blk: {
        const sdl_translate_c = b.addTranslateC(.{
            .root_source_file = b.path("sdl_includes.h"),
            .target = target,
            .optimize = optimize,
        });
        sdl_translate_c.addIncludePath(dep.path("include"));
        break :blk sdl_translate_c.createModule();
    } else null;

    const shaders_02 = [_]ShaderStage{
        .{ .src = "02_mesh.slang", .entry = "vertexMain", .stage = "vertex", .out = "02_mesh.vert" },
        .{ .src = "02_mesh.slang", .entry = "fragmentMain", .stage = "fragment", .out = "02_mesh.frag" },
    };

    const shaders_04 = [_]ShaderStage{
        // Shared vertex stage + the final composite fragment stage.
        .{ .src = "04_svt.slang", .entry = "vertexMain", .stage = "vertex", .out = "04_svt.vert" },
        .{ .src = "04_svt.slang", .entry = "compositeMain", .stage = "fragment", .out = "04_svt_composite.frag" },
        // Feedback fragment stage (writes requested page ids into an SSBO).
        .{ .src = "04_svt_feedback.slang", .entry = "feedbackMain", .stage = "fragment", .out = "04_svt_feedback.frag" },
    };

    // `apple` marks examples that have been ported to the backend-agnostic API
    // and therefore build on macOS/iOS (Metal). The others are still Vulkan-only.
    const shaders_05 = [_]ShaderStage{
        .{ .src = "05_texture.slang", .entry = "vertexMain", .stage = "vertex", .out = "05_texture.vert" },
        .{ .src = "05_texture.slang", .entry = "fragmentMain", .stage = "fragment", .out = "05_texture.frag" },
    };

    const examples = [_]struct {
        file: []const u8,
        name: []const u8,
        shaders: []const ShaderStage = &.{},
        apple: bool = false,
        /// Ported to the WebGPU backend. The rest use features WebGPU cannot
        /// express (imgui's texture/sampler path, rpi's descriptor sets).
        web: bool = false,
        /// Builds for a desktop (Vulkan) target. False for examples that
        /// demonstrate a web-only path.
        desktop: bool = true,
    }{
        .{ .file = "00Clear.zig", .name = "00_clear", .apple = true, .web = true },
        .{ .file = "01Shader.zig", .name = "01_shader", .shaders = shaders_01[0..], .apple = true, .web = true },
        .{ .file = "02Mesh.zig", .name = "02_mesh", .shaders = shaders_02[0..], .apple = true, .web = true },
        // ImGui shaders are embedded in the core rhi library; no shader step
        // here. Vulkan-only until the Metal texture/sampler path lands.
        .{ .file = "03Imgui.zig", .name = "03_imgui", .apple = false },
        // Software virtual texturing through the rpi layer. Vulkan-only: rpi's
        // name-resolved descriptor binding is not yet implemented on Metal.
        .{ .file = "04SVT.zig", .name = "04_svt", .shaders = shaders_04[0..], .apple = false },
        // Textured + alpha-blended quad: the acceptance test for the web
        // backends' texture upload, sampler and binding paths. Web-only, because
        // `Cmd.web_bind_descriptors` targets `Pipeline.init_graphics`'s world
        // -- on Vulkan and Metal the same descriptors go through `rpi`'s
        // descriptor sets instead (see 04_svt).
        .{ .file = "05Texture.zig", .name = "05_texture", .shaders = shaders_05[0..], .apple = false, .web = true, .desktop = false },
    };
    // Resolve the Slang compiler used to build example shaders: obtained from
    // the rhi dependency, which manages the prebuilt Slang download.
    const rhi_pkg = b.lazyImport(@This(), "rhi") orelse return;
    const slangc = rhi_pkg.getSlangc(b, rhi_dep) orelse return;
    // Only the web build needs GLSL ES, and building SPIRV-Cross costs a C++
    // compile, so it is resolved lazily and only there.
    const spirv_cross = if (is_web) (rhi_pkg.getSpirvCrossTool(b, rhi_dep) orelse return) else null;

    for (examples) |example| {
        if (is_apple and !example.apple) continue;
        if (is_web and !example.web) continue;
        if (!is_web and !is_apple and !example.desktop) continue;

        // Anonymous shader imports must land on whichever module actually
        // contains the `@embedFile` — the example, which is the root off the web
        // and a plain import on it.
        var shader_module_target: *std.Build.Module = undefined;
        const module = b.createModule(.{
            // On the web the example is not the root: `std.start` gates on
            // `@hasDecl(root, "main")` and emitting its wasm entry point pulls
            // in `std.Io.Threaded` (and posix, which freestanding lacks).
            // `web_root.zig` has no `main` and imports the example instead.
            .root_source_file = b.path(if (is_web) "web_root.zig" else example.file),
            .target = target,
            .optimize = optimize,
        });
        if (is_web) {
            const example_module = b.createModule(.{
                .root_source_file = b.path(example.file),
                .target = target,
                .optimize = optimize,
            });
            example_module.addImport("rhi", rhi_module);
            module.addImport("example", example_module);
            // The shader blobs are @embedFile'd by the example, not the root.
            shader_module_target = example_module;
        }
        module.addImport("rhi", rhi_module);
        if (!is_web) shader_module_target = module;
        if (sdl_c_module) |m| module.addImport("sdl", m);
        // zla sets `link_libc`, and that propagates to any module importing it —
        // which is fatal on wasm32-freestanding, where there is no libc to
        // provide. Only 04SVT uses zla and it is not a web example.
        if (!is_web) module.addImport("zla", zla_module);

        const exe = b.addExecutable(.{ .name = example.name, .root_module = module });
        if (sdl_dep) |dep| exe.root_module.linkLibrary(dep.artifact("SDL3"));

        if (is_web) {
            // No libc and no `main`: the browser calls the exported
            // `rhi_web_init` / `rhi_web_frame` that `web_app.zig` emits.
            exe.entry = .disabled;
            exe.rdynamic = true;
        }

        const install_exe = b.addInstallArtifact(exe, .{});
        b.getInstallStep().dependOn(&install_exe.step);
        const run_step = b.step(example.name, example.file);
        if (is_web) {
            // A .wasm cannot be run by the build system. The step installs the
            // page instead: serve zig-out over HTTP (WebGPU needs a secure
            // context, which localhost satisfies) and open <name>.html.
            run_step.dependOn(&install_exe.step);
            const glue = b.addInstallFile(rhi_dep.path("src/webgpu/glue.js"), "bin/glue.js");
            b.getInstallStep().dependOn(&glue.step);
            run_step.dependOn(&glue.step);
            // glue.js imports this as a flat sibling; it holds the WebGL2
            // fallback used when the browser has no usable WebGPU adapter.
            const gl_glue = b.addInstallFile(rhi_dep.path("src/webgl/glue.js"), "bin/webgl_glue.js");
            b.getInstallStep().dependOn(&gl_glue.step);
            run_step.dependOn(&gl_glue.step);
            const page = b.addInstallFile(webPage(b, example.name), b.fmt("bin/{s}.html", .{example.name}));
            b.getInstallStep().dependOn(&page.step);
            run_step.dependOn(&page.step);
        } else {
            const example_cmd = b.addRunArtifact(exe);
            if (@hasField(std.Build, "args") and b.args != null) { // TODO: Remove after 0.17
                example_cmd.addArgs(b.args.?);
            }
            run_step.dependOn(&example_cmd.step);
            example_cmd.step.dependOn(&install_exe.step);
        }

        for (example.shaders) |sh| {
            // WebGPU: Slang -> WGSL, embedded into the binary (freestanding wasm
            // has no filesystem to read a shader from at runtime).
            //
            // `-DRHI_WGSL=1` switches the shader's push-constant block from
            // `[[vk::push_constant]]` to `[[vk::binding(0,0)]] ConstantBuffer`:
            // slangc emits the former as a `var<uniform>` with no
            // `@group`/`@binding` attribute, which WebGPU rejects.
            if (is_web) {
                const wgsl = rhi_pkg.compileSlangWgsl(
                    b,
                    slangc,
                    b.fmt("example_assets/{s}", .{sh.src}),
                    sh.entry,
                    sh.stage,
                    b.fmt("{s}.wgsl", .{sh.out}),
                    &.{"RHI_WGSL=1"},
                );
                // The examples @embedFile these two names; each example is its
                // own binary, so the names need not be unique across examples.
                const is_vertex = std.mem.eql(u8, sh.stage, "vertex");
                shader_module_target.addAnonymousImport(
                    if (is_vertex) "shader_vs" else "shader_fs",
                    .{ .root_source_file = wgsl },
                );

                // The same stage again as GLSL ES 3.00, for the WebGL2
                // fallback. Both are embedded because the backend is chosen at
                // run time, in the browser, not at build time.
                const glsl = rhi_pkg.compileSlangGlslEs(
                    b,
                    slangc,
                    spirv_cross.?,
                    b.fmt("example_assets/{s}", .{sh.src}),
                    sh.entry,
                    sh.stage,
                    b.fmt("{s}.glsl", .{sh.out}),
                );
                shader_module_target.addAnonymousImport(
                    if (is_vertex) "shader_vs_glsl" else "shader_fs_glsl",
                    .{ .root_source_file = glsl },
                );
                continue;
            }
            // Vulkan: Slang -> SPIR-V (always built; the rhi lib targets vk off Apple).
            const spv = std.Build.Step.Run.create(b, b.fmt("{s} slangc spirv", .{sh.out}));
            spv.addFileArg(slangc); // argv[0]: the resolved slangc binary
            spv.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
            spv.addArgs(&.{ "-target", "spirv", "-entry", sh.entry, "-stage", sh.stage, "-o" });
            spv.addArg(try b.root.joinString(b.allocator, b.fmt("example_assets/{s}.spv", .{sh.out})));
            exe.step.dependOn(&spv.step);

            // Metal: Slang -> MSL (Apple only). Compiled at runtime via newLibraryWithSource.
            if (is_apple) {
                const msl = std.Build.Step.Run.create(b, b.fmt("{s} slangc metal", .{sh.out}));
                msl.addFileArg(slangc);
                msl.addFileArg(b.path(b.fmt("example_assets/{s}", .{sh.src})));
                msl.addArgs(&.{ "-target", "metal", "-entry", sh.entry, "-stage", sh.stage, "-o" });
                msl.addArg(try b.root.joinString(b.allocator, b.fmt("example_assets/{s}.metal", .{sh.out})));
                exe.step.dependOn(&msl.step);
            }
        }
    }
}

/// Writes the page that loads one example's .wasm through the WebGPU glue.
///
/// The page appends a fresh token to every asset URL it loads, so a rebuild is
/// never served from a stale browser cache. `glue.js`, `webgl_glue.js` and the
/// `.wasm` are cached independently — and an ES module import far more
/// stubbornly than a `fetch` — so an old glue can otherwise be paired with a
/// new module, which shifts every import argument and renders nothing.
///
/// The token is generated per page load rather than per build. A build-time
/// hash would be tidier, but Zig caches the configure phase, so a token
/// computed there stays frozen until `build.zig` itself changes — exactly when
/// it is least likely to help. These are development pages, so never caching
/// them is the right trade; a real deployment should use content hashes.
fn webPage(b: *std.Build, name: []const u8) std.Build.LazyPath {
    const html = b.fmt(
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta http-equiv="cache-control" content="no-store">
        \\<title>rhi-zig — {s}</title>
        \\<style>
        \\  html, body {{ margin: 0; height: 100%; background: #111; color: #ddd;
        \\               font: 13px system-ui, sans-serif; }}
        \\  canvas {{ display: block; width: 100vw; height: 100vh; }}
        \\  #err {{ position: fixed; inset: 0; display: none; place-content: center;
        \\          padding: 2rem; text-align: center; white-space: pre-wrap; }}
        \\</style>
        \\</head>
        \\<body>
        \\<canvas id="canvas"></canvas>
        \\<div id="err"></div>
        \\<script type="module">
        \\const v = Date.now();
        \\const {{ boot }} = await import(`./glue.js?v=${{v}}`);
        \\// WebGPU needs a secure context, so this must be served over http(s)
        \\// rather than opened as a file:// URL. localhost counts as secure.
        \\boot(`./{s}.wasm?v=${{v}}`, {{ canvas: "#canvas", assetVersion: String(v) }}).catch((e) => {{
        \\  const el = document.getElementById("err");
        \\  el.style.display = "grid";
        \\  el.textContent = String(e && e.message ? e.message : e);
        \\  console.error(e);
        \\}});
        \\</script>
        \\</body>
        \\</html>
        \\
    , .{ name, name });
    return b.addWriteFiles().add(b.fmt("{s}.html", .{name}), html);
}
