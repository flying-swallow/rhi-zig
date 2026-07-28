// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only

//! Thin compatibility layer over the `webgpu.h`/`wgpu.h` C ABI shipped by the
//! pinned wgpu-native release. Native-only event pumping is kept here so the
//! RHI backend can later share its object model with Emscripten WebGPU.

pub const c = @import("wgpu");

pub fn stringView(bytes: []const u8) c.WGPUStringView {
    return .{
        .data = bytes.ptr,
        .length = bytes.len,
    };
}

pub fn stringViewZ(bytes: [*:0]const u8) c.WGPUStringView {
    return stringView(std.mem.span(bytes));
}

pub fn slice(view: c.WGPUStringView) []const u8 {
    if (view.data == null) return &.{};
    return view.data[0..view.length];
}

const std = @import("std");

fn pumpUntil(instance: c.WGPUInstance, completed: *const bool) !void {
    var attempts: usize = 0;
    while (!completed.* and attempts < 1_000_000) : (attempts += 1) {
        c.wgpuInstanceProcessEvents(instance);
        std.atomic.spinLoopHint();
    }
    if (!completed.*) return error.WebGPUWaitFailed;
}

const AdapterResponse = struct {
    status: c.WGPURequestAdapterStatus = c.WGPURequestAdapterStatus_Error,
    adapter: c.WGPUAdapter = null,
    completed: bool = false,
};

fn adapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const response: *AdapterResponse = @ptrCast(@alignCast(userdata1.?));
    response.status = status;
    response.adapter = adapter;
    response.completed = true;
    if (status != c.WGPURequestAdapterStatus_Success)
        std.log.err("WebGPU adapter request: {s}", .{slice(message)});
}

pub fn requestAdapterSync(instance: c.WGPUInstance) !c.WGPUAdapter {
    var response: AdapterResponse = .{};
    var options: c.WGPURequestAdapterOptions = .{
        .featureLevel = c.WGPUFeatureLevel_Core,
        .powerPreference = c.WGPUPowerPreference_HighPerformance,
    };
    const future = c.wgpuInstanceRequestAdapter(instance, &options, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterCallback,
        .userdata1 = &response,
    });
    _ = future;
    try pumpUntil(instance, &response.completed);
    if (response.status != c.WGPURequestAdapterStatus_Success or response.adapter == null)
        return error.WebGPUAdapterUnavailable;
    return response.adapter;
}

const DeviceResponse = struct {
    status: c.WGPURequestDeviceStatus = c.WGPURequestDeviceStatus_Error,
    device: c.WGPUDevice = null,
    completed: bool = false,
};

fn deviceCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const response: *DeviceResponse = @ptrCast(@alignCast(userdata1.?));
    response.status = status;
    response.device = device;
    response.completed = true;
    if (status != c.WGPURequestDeviceStatus_Success)
        std.log.err("WebGPU device request: {s}", .{slice(message)});
}

fn uncapturedError(
    device: [*c]const c.WGPUDevice,
    error_type: c.WGPUErrorType,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = device;
    _ = userdata1;
    _ = userdata2;
    std.log.err("WebGPU error ({d}): {s}", .{ error_type, slice(message) });
}

pub fn requestDeviceSync(instance: c.WGPUInstance, adapter: c.WGPUAdapter) !c.WGPUDevice {
    var response: DeviceResponse = .{};
    var descriptor: c.WGPUDeviceDescriptor = .{
        .uncapturedErrorCallbackInfo = .{ .callback = uncapturedError },
    };
    const future = c.wgpuAdapterRequestDevice(adapter, &descriptor, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceCallback,
        .userdata1 = &response,
    });
    _ = future;
    try pumpUntil(instance, &response.completed);
    if (response.status != c.WGPURequestDeviceStatus_Success or response.device == null)
        return error.WebGPUDeviceUnavailable;
    return response.device;
}

pub const Completion = std.atomic.Value(bool);

fn workDoneCallback(
    status: c.WGPUQueueWorkDoneStatus,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const completion: *Completion = @ptrCast(@alignCast(userdata1.?));
    if (status != c.WGPUQueueWorkDoneStatus_Success)
        std.log.err("WebGPU submitted work: {s}", .{slice(message)});
    completion.store(true, .release);
}

pub fn trackSubmitted(queue: c.WGPUQueue, completion: *Completion) void {
    completion.store(false, .release);
    _ = c.wgpuQueueOnSubmittedWorkDone(queue, .{
        .mode = c.WGPUCallbackMode_AllowProcessEvents,
        .callback = workDoneCallback,
        .userdata1 = completion,
    });
}
