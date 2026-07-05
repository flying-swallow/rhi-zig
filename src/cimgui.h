// Aggregator header translated by `addTranslateC` into the `cimgui` module.
//
// We consume only the Dear ImGui *core* C bindings (dear_bindings' `dcimgui.h`):
// the RHI renders ImGui's draw data through its own pipeline/buffer/texture API
// (see `src/imgui.zig`), so cimgui's own imgui_impl_vulkan/metal renderers and
// the imgui_impl_sdl3 platform backend are intentionally not built or included.
// Keeping the core lib free of those backends also avoids linking a second SDL3
// alongside the one the examples already provide.
#include "dcimgui.h"
