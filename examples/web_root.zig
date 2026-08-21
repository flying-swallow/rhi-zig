// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Root module for the web builds of the examples.
//!
//! An example cannot be its own root on `wasm32-freestanding`, because
//! `std.start` gates on `@hasDecl(root, "main")`: declaring `main` at all makes
//! it emit `wasm_freestanding_start`, which constructs a `std.Io.Threaded` and
//! drags in posix. There is no way to omit a top-level declaration
//! conditionally, so the web build swaps the root instead. The example is
//! imported here as `example` and keeps its native `main` untouched.

const std = @import("std");
const example = @import("example");

/// Reached through the example rather than imported directly: a source file may
/// belong to only one module, and the example already owns platform.zig.
const platform = example.platform;

// Emits `rhi_web_init` / `rhi_web_frame` / `rhi_web_deinit` for the JS glue.
// `export` inside a generic type only reaches the binary if the namespace is
// referenced.
comptime {
    _ = example.App.web_exports;
}

/// `std.log` and panics have nowhere to go on freestanding wasm; both are
/// routed to the browser console.
pub const std_options: std.Options = .{ .logFn = platform.logFn };
pub const panic = platform.impl.panic;
