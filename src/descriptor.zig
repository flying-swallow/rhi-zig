const rhi = @import("root.zig");
const vulkan = @import("vulkan.zig");

//pub const Descriptor = @This();
//backend: union(rhi.Backend) {
//    vk: rhi.wrapper_platform_type(.vk, struct {
//        type: volk.c.VkDescriptorType,
//        view: union {
//            image: volk.c.VkDescriptorImageInfo,
//            buffer: volk.c.VkDescriptorBufferInfo,
//        } 
//    }),
//    dx12: rhi.wrapper_platform_type(.dx12, struct {}), 
//    mtl: rhi.wrapper_platform_type(.mtl, struct {}), 
//},
//
//pub const Ownership = enum(u8) {
//    Owned,
//    Borrowed
//};

//pub fn TextureDescriptor (texture: Ownership, sampler: Ownership) type {
//    return struct {
//        pub const Self = @This();
//        texture: *rhi.Texture = undefined,
//        sampler: *rhi.Sampler = undefined,
//        backend: union(rhi.Backend) {
//            vk: rhi.wrapper_platform_type(.vk, struct {
//                image_view: volk.c.VkImageView = null,
//                sampler: volk.c.VkSampler = null,
//            }),
//            dx12: rhi.wrapper_platform_type(.dx12, struct {}), 
//            mtl: rhi.wrapper_platform_type(.mtl, struct {}), 
//        },
//
//        pub fn descriptor(self: *Self) Descriptor {
//            switch(self.backend) {
//                .vk => |vk| {
//                    return .{
//                        .backend = .{
//                            .vk = .{
//                                .type = volk.c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
//                                .view = .{
//                                    .image = volk.c.VkDescriptorImageInfo{
//                                        .sampler = self.sampler.backend.vk.sampler,
//                                        .imageView = self.backend.vk.image_view,
//                                        .imageLayout = volk.c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
//                                    }
//                                }
//                            }
//                        }
//                    };
//                },
//                .dx12 => {},
//                .mtl => {},
//            }
//            return error.UnsupportedBackend;
//        }
//
//        pub fn init(renderer: *rhi.Renderer, tex: *rhi.Texture, sam: *rhi.Sampler) !Self {
//            if (rhi.is_target_selected(.vk, renderer)) {
//                var image_view_usage = volk.c.VkImageViewUsageCreateInfo {
//                    .sType = volk.c.VK_STRUCTURE_TYPE_IMAGE_VIEW_USAGE_CREATE_INFO 
//                };
//                var image_view_create_info = volk.c.VkImageViewCreateInfo {
//                    .sType = volk.c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
//                };
//                vulkan.add_next(&image_view_create_info, &image_view_usage);
//
//                return .{
//                    .texture = tex,
//                    .sampler = sam
//                };
//            }
//            return error.UnsupportedBackend;
//        }
//
//        //pub fn deinit(self: *Self) void {
//        //}
//    };
//}


