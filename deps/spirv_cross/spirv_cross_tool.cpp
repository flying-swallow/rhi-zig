// Copyright 2026 Michael Pollind
// SPDX-License-Identifier: GPL-2.0-only
//
// Minimal SPIR-V -> GLSL ES translator for the WebGL2 backend.
//
// This is a stand-in for the upstream `spirv-cross` CLI, which pulls in the
// MSL, HLSL, C++ and reflection backends. Only CompilerGLSL is needed here, so
// linking just its five translation units keeps the build small — the same
// reason `deps/vma/vma_impl.cpp` exists rather than building all of VMA's
// samples.
//
//   spirv_cross_tool <in.spv> <out.glsl> <version> <es|core>
//
// Slang cannot emit GLSL ES (it offers glsl_110..glsl_460, no ES profiles), so
// the example shaders go Slang -> SPIR-V -> here -> GLSL ES 3.00.

#include "spirv_glsl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace
{
// SPIRV-Cross refuses to translate SPIR-V that reads BaseVertex/BaseInstance
// into an ES profile, because GLSL ES 3.00 has no gl_BaseVertex. Slang emits
// those unconditionally: HLSL's SV_VertexID is the per-draw index, so Slang
// lowers it as `VertexIndex - BaseVertex`, which puts BaseVertex into every
// shader that reads SV_VertexID (e.g. the fullscreen triangle in
// examples/example_assets/01_mandelbrot.slang).
//
// WebGL2 has no base vertex or base instance at all — `drawArrays`/
// `drawElements` take no such parameter — so both are always zero, and the
// backend rejects a non-zero `first_instance`/`vertex_offset` rather than
// silently dropping it. Folding them to the literal 0 here is therefore exact,
// not an approximation, and the GLSL compiler folds the subtraction away.
class CompilerGLSLES : public SPIRV_CROSS_NAMESPACE::CompilerGLSL
{
public:
	explicit CompilerGLSLES(std::vector<uint32_t> spirv_)
	    : SPIRV_CROSS_NAMESPACE::CompilerGLSL(std::move(spirv_))
	{
	}

protected:
	std::string builtin_to_glsl(spv::BuiltIn builtin, spv::StorageClass storage) override
	{
		switch (builtin)
		{
		case spv::BuiltInBaseVertex:
		case spv::BuiltInBaseInstance:
			return "0";
		default:
			return SPIRV_CROSS_NAMESPACE::CompilerGLSL::builtin_to_glsl(builtin, storage);
		}
	}
};
} // namespace

static bool read_spirv(const char *path, std::vector<uint32_t> &out)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return false;
	if (fseek(f, 0, SEEK_END) != 0)
	{
		fclose(f);
		return false;
	}
	long len = ftell(f);
	rewind(f);
	// SPIR-V is a stream of 32-bit words; a size that is not a multiple of 4
	// means the file is not SPIR-V at all.
	if (len < 0 || (len % 4) != 0)
	{
		fclose(f);
		return false;
	}
	out.resize(static_cast<size_t>(len) / 4);
	size_t got = fread(out.data(), 1, static_cast<size_t>(len), f);
	fclose(f);
	return got == static_cast<size_t>(len);
}

int main(int argc, char **argv)
{
	if (argc != 5)
	{
		fprintf(stderr, "usage: %s <in.spv> <out.glsl> <version> <es|core>\n", argv[0]);
		return 2;
	}
	const char *in_path = argv[1];
	const char *out_path = argv[2];
	const uint32_t version = static_cast<uint32_t>(atoi(argv[3]));
	const bool es = strcmp(argv[4], "es") == 0;

	std::vector<uint32_t> spirv;
	if (!read_spirv(in_path, spirv))
	{
		fprintf(stderr, "spirv_cross_tool: cannot read SPIR-V from %s\n", in_path);
		return 1;
	}

	std::string source;
	try
	{
		CompilerGLSLES compiler(std::move(spirv));
		auto opts = compiler.get_common_options();
		opts.version = version;
		opts.es = es;
		// WebGL2 has no separate sampler objects; combined image samplers are
		// the only form GLSL ES 3.00 accepts.
		opts.vulkan_semantics = false;
		// The SPIR-V is compiled with Vulkan semantics, so it carries Vulkan's
		// NDC: Y down and depth in [0, 1]. GL wants Y up and [-1, 1], and
		// WebGL2 has no glClipControl to change that. These two fixups rewrite
		// gl_Position accordingly, which is why no `.slang` source needs a
		// GL-specific variant (the Metal/Vulkan `y_sign` constant keeps its
		// Vulkan value on this path).
		opts.vertex.flip_vert_y = true;
		opts.vertex.fixup_clipspace = true;
		// GLSL ES 3.00 has gl_VertexID/gl_InstanceID but no gl_BaseVertex or
		// gl_BaseInstance, so SPIR-V's VertexIndex must lower to a plain
		// gl_VertexID. Without this, any shader reading SV_VertexID fails to
		// translate with "BaseVertex not supported in ES profile". The backend
		// separately rejects a non-zero first_instance/vertex_offset, so
		// dropping the base offsets here loses nothing.
		opts.vertex.support_nonzero_base_instance = false;
		compiler.set_common_options(opts);

		// GLSL links the stages by matching varying *names*, and GLSL ES 3.00
		// does not allow a `layout(location = ...)` qualifier on a varying (that
		// arrives in ES 3.1). Each stage is translated on its own here, and
		// SPIRV-Cross derives names from each side's SPIR-V independently — so
		// a vertex output comes out as `entryPointParam_vertexMain_uv` while the
		// matching fragment input comes out as `input_uv`, and linking fails
		// with "FRAGMENT varying ... does not match any VERTEX varying".
		//
		// The SPIR-V locations do agree, so renaming both sides after the
		// location makes them match by construction. Only the interface between
		// stages is touched: vertex *inputs* and fragment *outputs* keep their
		// explicit locations, which ES 3.00 does allow.
		{
			const auto model = compiler.get_execution_model();
			auto resources = compiler.get_shader_resources();
			const auto rename = [&](const SPIRV_CROSS_NAMESPACE::SmallVector<SPIRV_CROSS_NAMESPACE::Resource> &vars) {
				for (const auto &v : vars)
				{
					if (!compiler.has_decoration(v.id, spv::DecorationLocation))
						continue;
					const uint32_t location = compiler.get_decoration(v.id, spv::DecorationLocation);
					compiler.set_name(v.id, std::string("rhi_varying_") + std::to_string(location));
				}
			};
			if (model == spv::ExecutionModelVertex)
				rename(resources.stage_outputs);
			else if (model == spv::ExecutionModelFragment)
				rename(resources.stage_inputs);
		}

		source = compiler.compile();
	}
	catch (const std::exception &e)
	{
		fprintf(stderr, "spirv_cross_tool: %s: %s\n", in_path, e.what());
		return 1;
	}

	FILE *out = fopen(out_path, "wb");
	if (!out)
	{
		fprintf(stderr, "spirv_cross_tool: cannot open %s for writing\n", out_path);
		return 1;
	}
	fwrite(source.data(), 1, source.size(), out);
	fclose(out);
	return 0;
}
