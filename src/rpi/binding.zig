//! Program binding model: shader stages, the name->binding reflection map, and
//! the explicit descriptor-layout declaration a Program is initialized from.
//!
//! The C++ `RIProgram` derives this map from SPIR-V reflection. This port takes
//! the *explicit-layout* approach instead: the caller declares the bindings
//! (name, set, register, type, count, stages) and the name->binding map is built
//! from that declaration. Real shader reflection can replace `Layout` later
//! without changing `bindDescriptors` / `findReflection`.

const rhi = @import("../root.zig");
const std = @import("std");

/// Descriptor categories, shared with the core pipeline-layout vocabulary.
pub const DescriptorType = rhi.pipeline_layout.DescriptorType;

/// Program stages, ordered to mirror `RIProgram::ProgramStages` so the same
/// index can address the per-stage shader-binary array.
pub const ProgramStage = enum(u8) {
    vertex = 0,
    fragment = 1,
    compute = 2,
    raygen = 3,
    miss = 4,
    closest_hit = 5,
    any_hit = 6,
    intersection = 7,
    callable = 8,

    pub const count = @typeInfo(ProgramStage).@"enum".field_names.len;
};

/// Which shader stages a binding / push-constant range is visible to. Mirrors
/// `VkShaderStageFlags` for the bindings we support.
pub const ShaderStageFlags = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    raygen: bool = false,
    miss: bool = false,
    closest_hit: bool = false,
    any_hit: bool = false,
    intersection: bool = false,
    callable: bool = false,

    pub fn merge(self: ShaderStageFlags, other: ShaderStageFlags) ShaderStageFlags {
        return .{
            .vertex = self.vertex or other.vertex,
            .fragment = self.fragment or other.fragment,
            .compute = self.compute or other.compute,
            .raygen = self.raygen or other.raygen,
            .miss = self.miss or other.miss,
            .closest_hit = self.closest_hit or other.closest_hit,
            .any_hit = self.any_hit or other.any_hit,
            .intersection = self.intersection or other.intersection,
            .callable = self.callable or other.callable,
        };
    }

    pub fn any(self: ShaderStageFlags) bool {
        return self.vertex or self.fragment or self.compute or self.raygen or
            self.miss or self.closest_hit or self.any_hit or self.intersection or
            self.callable;
    }

    pub fn to_vk(self: ShaderStageFlags) rhi.vulkan.vk.ShaderStageFlags {
        return .{
            .vertex_bit = self.vertex,
            .fragment_bit = self.fragment,
            .compute_bit = self.compute,
            .raygen_bit_khr = self.raygen,
            .miss_bit_khr = self.miss,
            .closest_hit_bit_khr = self.closest_hit,
            .any_hit_bit_khr = self.any_hit,
            .intersection_bit_khr = self.intersection,
            .callable_bit_khr = self.callable,
        };
    }
};

/// Stable identity for a named descriptor binding. The hash is what
/// `bindDescriptors` looks up; the name is kept for diagnostics. Mirrors
/// `DescriptorBindingID`.
pub const DescriptorBindingID = struct {
    name: []const u8,
    hash: u64,

    pub fn create(name: []const u8) DescriptorBindingID {
        return .{ .name = name, .hash = std.hash.Wyhash.hash(0, name) };
    }
};

/// One resolved binding: where in (set, register) a named descriptor lands.
/// Mirrors `RIProgram::BindingReflection`.
pub const BindingReflection = struct {
    hash: u64,
    is_array: bool,
    dim_count: u16,
    set: u16,
    base_register_index: u16,
    descriptor_type: DescriptorType,
};

/// A live binding handed to `bindDescriptors`: a name handle + the descriptor to
/// write at it, optionally offset within an array. Mirrors
/// `RIProgram::DescriptorBinding`.
pub const DescriptorBinding = struct {
    handle: DescriptorBindingID,
    register_offset: u32 = 0,
    descriptor: rhi.Descriptor,

    pub fn init(name: []const u8, descriptor: rhi.Descriptor, register_offset: u32) DescriptorBinding {
        return .{
            .handle = DescriptorBindingID.create(name),
            .register_offset = register_offset,
            .descriptor = descriptor,
        };
    }
};

// ---- Explicit layout declaration -----------------------------------------

/// A shader binary for one program stage, fed to `Program.initialize`. Mirrors
/// `RIProgram::ModuleStage`.
pub const ModuleStage = struct {
    stage: ProgramStage,
    /// SPIR-V (Vulkan) or MSL text (Metal) for this stage. Borrowed; the Program
    /// copies it.
    data: []const u8,
    /// Entry-point function name. Defaults to "main" (GLSL / single-entry HLSL);
    /// Slang `-fvk-use-entrypoint-name` keeps the source name (e.g. "csMain").
    entry_point: []const u8 = "main",
};

/// One descriptor binding in the program layout. Replaces what SPIR-V
/// reflection would otherwise produce.
pub const LayoutBinding = struct {
    /// Name used by `bindDescriptors` to resolve this binding.
    name: []const u8,
    /// Descriptor set index (register space). Must be < `Program.DESCRIPTOR_SET_MAX`.
    set: u32,
    /// Base register/binding within the set.
    binding: u32,
    descriptor_type: DescriptorType,
    /// Array length; > 1 marks the binding as an array (partially-bound on vk).
    count: u32 = 1,
    stages: ShaderStageFlags,
};

pub const PushConstantRange = struct {
    stages: ShaderStageFlags,
    size: u32,
};

/// A `VkDescriptorSetLayout` on Vulkan, `void` elsewhere. Gated so `Layout`
/// (a type used by Metal paths too) parses on backends without Vulkan, where
/// `rhi.vulkan` is `void` and `rhi.vulkan.vk` would not resolve.
pub const ExternalLayout = if (rhi.platform_has_api(.vk)) rhi.vulkan.vk.DescriptorSetLayout else void;

/// The full explicit layout a Program is built from.
pub const Layout = struct {
    bindings: []const LayoutBinding = &.{},
    push_constant: ?PushConstantRange = null,
    /// Per-set externally-owned (bindless) layouts, vk-only. A non-null entry at
    /// index `i` makes set `i` external: the Program uses that layout in its
    /// pipeline layout and skips all alloc/write/bind for it (caller binds it via
    /// `bindBindlessDescriptorSet`). Slots past the slice are treated as null.
    external_sets: []const ?ExternalLayout = &.{},
};
