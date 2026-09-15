#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "pica_metal.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <utility>

namespace mh4u::pica_metal {
namespace {

struct alignas(16) GpuVertex {
    std::array<float, 4> position;
    std::array<float, 4> color;
    std::array<float, 2> uv;
    std::array<float, 2> uv2;
};
static_assert(sizeof(GpuVertex) == 48);

struct alignas(16) GpuProceduralTexture {
    std::array<Float2, 128> color_map{};
    std::array<Float4, 256> color{};
    std::array<Float4, 256> color_difference{};
};
static_assert(sizeof(GpuProceduralTexture) == 9216);

struct alignas(16) GpuTevStage {
    std::array<uint32_t, 4> color_source{};
    std::array<uint32_t, 4> alpha_source{};
    std::array<uint32_t, 4> color_modifier{};
    std::array<uint32_t, 4> alpha_modifier{};
    std::array<uint32_t, 4> operation_multiplier{};
    std::array<uint32_t, 4> update{};
    std::array<uint32_t, 4> constant{};
};
static_assert(sizeof(GpuTevStage) == 112);

struct alignas(16) GpuFragmentState {
    std::array<GpuTevStage, 6> tev{};
    std::array<uint32_t, 4> initial_buffer{};
    std::array<float, 4> depth{};
    std::array<uint32_t, 4> alpha{};
};

constexpr const char* shader_source = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertexIn { float4 position; float4 color; float2 uv; float2 uv2; };
struct VertexOut { float4 position [[position]]; float4 color; float2 uv; float2 uv2; };
struct TevStage {
    uint4 color_source;
    uint4 alpha_source;
    uint4 color_modifier;
    uint4 alpha_modifier;
    uint4 operation_multiplier;
    uint4 update;
    uint4 constant_color;
};
struct FragmentState {
    TevStage tev[6];
    uint4 initial_buffer;
    float4 depth;
    uint4 alpha;
};
struct ProceduralTextureState {
    float2 color_map[128];
    float4 color[256];
    float4 color_difference[256];
};
struct FragmentOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

vertex VertexOut pica_vertex(const device VertexIn* vertices [[buffer(0)]],
                             constant uint& flip_y [[buffer(1)]], uint id [[vertex_id]]) {
    const VertexIn v = vertices[id];
    VertexOut out;
    out.position = float4(v.position.x, flip_y ? -v.position.y : v.position.y,
                          -v.position.z, v.position.w);
    out.color = v.color;
    out.uv = v.uv;
    out.uv2 = v.uv2;
    return out;
}

float4 source_value(uint source, float4 primary, float4 texture0, float4 procedural_texture,
                    uint4 previous_buffer, uint4 constant_color, uint4 previous) {
    switch (source) {
    case 0: return primary;
    case 1: return texture0;
    case 2: return float4(previous_buffer) / 255.0;
    case 3: return float4(constant_color) / 255.0;
    case 4: return float4(previous) / 255.0;
    case 5: return procedural_texture;
    default: return 0.0;
    }
}

float procedural_lookup(constant ProceduralTextureState& state, float coord) {
    coord *= 128.0;
    const float index = clamp(floor(coord), 0.0, 127.0);
    const float fraction = coord - index;
    const float2 entry = state.color_map[uint(index)];
    return clamp(entry.x + entry.y * fraction, 0.0, 1.0);
}

float4 sample_procedural_texture(constant ProceduralTextureState& state, float2 coordinate) {
    const float u = min(abs(coordinate.x), 1.0);
    const float mapped = procedural_lookup(state, u);
    const float index = mapped * 127.0;
    const uint integer = uint(index);
    return state.color[integer] + (index - float(integer)) * state.color_difference[integer];
}

float3 modify_color(float4 value, uint modifier) {
    switch (modifier) {
    case 0: return value.rgb;
    case 1: return 1.0 - value.rgb;
    case 2: return value.aaa;
    case 3: return 1.0 - value.aaa;
    case 4: return value.rrr;
    case 5: return 1.0 - value.rrr;
    case 6: return value.ggg;
    case 7: return 1.0 - value.ggg;
    case 8: return value.bbb;
    case 9: return 1.0 - value.bbb;
    default: return 0.0;
    }
}

float modify_alpha(float4 value, uint modifier) {
    switch (modifier) {
    case 0: return value.a;
    case 1: return 1.0 - value.a;
    case 2: return value.r;
    case 3: return 1.0 - value.r;
    case 4: return value.g;
    case 5: return 1.0 - value.g;
    case 6: return value.b;
    case 7: return 1.0 - value.b;
    default: return 0.0;
    }
}

float3 combine_color(float3 a, float3 b, float3 c, uint op) {
    switch (op) {
    case 0: return a;
    case 1: return a * b;
    case 2: return a + b;
    case 3: return a + b - 0.5;
    case 4: return mix(b, a, c);
    case 5: return a - b;
    case 6: case 7: return dot(a - 0.5, b - 0.5) * 4.0;
    case 8: return fma(a, b, c);
    case 9: return min(a + b, 1.0) * c;
    default: return 0.0;
    }
}

float combine_alpha(float a, float b, float c, uint op) {
    switch (op) {
    case 0: return a;
    case 1: return a * b;
    case 2: return a + b;
    case 3: return a + b - 0.5;
    case 4: return mix(b, a, c);
    case 5: return a - b;
    case 8: return fma(a, b, c);
    case 9: return min(a + b, 1.0) * c;
    default: return 0.0;
    }
}

bool compare_u8(uint value, uint reference, uint func) {
    switch (func) {
    case 0: return false;
    case 1: return true;
    case 2: return value == reference;
    case 3: return value != reference;
    case 4: return value < reference;
    case 5: return value <= reference;
    case 6: return value > reference;
    case 7: return value >= reference;
    default: return false;
    }
}

fragment FragmentOut pica_fragment(VertexOut in [[stage_in]],
                                    constant FragmentState& state [[buffer(0)]],
                                    constant ProceduralTextureState& procedural [[buffer(1)]],
                                    texture2d<float> texture0 [[texture(0)]],
                                    sampler texture0_sampler [[sampler(0)]]) {
    const float4 primary =
        float4(uint4(clamp(in.color, 0.0, 1.0) * 255.0 + 0.5)) / 255.0;
    const float4 sampled = texture0.sample(texture0_sampler, in.uv);
    const float4 procedural_sample = sample_procedural_texture(procedural, in.uv2);
    uint4 previous_buffer = 0;
    uint4 next_buffer = state.initial_buffer;
    uint4 previous = 0;
    for (uint i = 0; i < 6; ++i) {
        const TevStage stage = state.tev[i];
        float3 color_arg[3];
        float alpha_arg[3];
        for (uint j = 0; j < 3; ++j) {
            const uint color_source =
                i == 0 && j < 2 && stage.color_source[j] == 4 ? stage.color_source[2]
                                                     : stage.color_source[j];
            const uint alpha_source =
                i == 0 && stage.alpha_source[j] == 4 ? stage.alpha_source[2]
                                                     : stage.alpha_source[j];
            color_arg[j] = modify_color(source_value(color_source, primary, sampled,
                                                      procedural_sample,
                                                      previous_buffer, stage.constant_color, previous),
                                        stage.color_modifier[j]);
            alpha_arg[j] = modify_alpha(source_value(alpha_source, primary, sampled,
                                                      procedural_sample,
                                                      previous_buffer, stage.constant_color, previous),
                                        stage.alpha_modifier[j]);
        }
        uint3 color = uint3(clamp(combine_color(color_arg[0], color_arg[1], color_arg[2],
                                                stage.operation_multiplier.x),
                                   0.0, 1.0) * 255.0 + 0.5);
        uint alpha = stage.operation_multiplier.x == 7
                          ? color.r
                          : uint(clamp(combine_alpha(alpha_arg[0], alpha_arg[1], alpha_arg[2],
                                                     stage.operation_multiplier.y),
                                       0.0, 1.0) * 255.0 + 0.5);
        previous = uint4(min(color * stage.operation_multiplier.z, uint3(255)),
                         min(alpha * stage.operation_multiplier.w, 255u));
        previous_buffer = next_buffer;
        if (stage.update.x != 0) next_buffer.rgb = previous.rgb;
        if (stage.update.y != 0) next_buffer.a = previous.a;
    }
    if (state.alpha.x != 0 &&
        !compare_u8(previous.a, state.alpha.z, state.alpha.y))
        discard_fragment();

    FragmentOut out;
    out.color = float4(previous) / 255.0;
    const float pica_z_over_w = -in.position.z;
    const float depth = clamp(fma(pica_z_over_w, state.depth.x, state.depth.y), 0.0, 1.0);
    out.depth = floor(depth * state.depth.z) / state.depth.z;
    return out;
}
)MSL";

MTLCompareFunction compare_function(CompareFunc func) {
    static constexpr std::array<MTLCompareFunction, 8> functions{
        MTLCompareFunctionNever,       MTLCompareFunctionAlways,
        MTLCompareFunctionEqual,       MTLCompareFunctionNotEqual,
        MTLCompareFunctionLess,        MTLCompareFunctionLessEqual,
        MTLCompareFunctionGreater,     MTLCompareFunctionGreaterEqual,
    };
    return functions[static_cast<size_t>(func)];
}

MTLStencilOperation stencil_operation(StencilAction action) {
    static constexpr std::array<MTLStencilOperation, 8> operations{
        MTLStencilOperationKeep,
        MTLStencilOperationZero,
        MTLStencilOperationReplace,
        MTLStencilOperationIncrementClamp,
        MTLStencilOperationDecrementClamp,
        MTLStencilOperationInvert,
        MTLStencilOperationIncrementWrap,
        MTLStencilOperationDecrementWrap,
    };
    return operations[static_cast<size_t>(action)];
}

MTLBlendOperation blend_operation(BlendEquation equation) {
    static constexpr std::array<MTLBlendOperation, 5> operations{
        MTLBlendOperationAdd,
        MTLBlendOperationSubtract,
        MTLBlendOperationReverseSubtract,
        MTLBlendOperationMin,
        MTLBlendOperationMax,
    };
    return operations[static_cast<size_t>(equation)];
}

MTLBlendFactor blend_factor(BlendFactor factor) {
    static constexpr std::array<MTLBlendFactor, 15> factors{
        MTLBlendFactorZero,
        MTLBlendFactorOne,
        MTLBlendFactorSourceColor,
        MTLBlendFactorOneMinusSourceColor,
        MTLBlendFactorDestinationColor,
        MTLBlendFactorOneMinusDestinationColor,
        MTLBlendFactorSourceAlpha,
        MTLBlendFactorOneMinusSourceAlpha,
        MTLBlendFactorDestinationAlpha,
        MTLBlendFactorOneMinusDestinationAlpha,
        MTLBlendFactorBlendColor,
        MTLBlendFactorOneMinusBlendColor,
        MTLBlendFactorBlendAlpha,
        MTLBlendFactorOneMinusBlendAlpha,
        MTLBlendFactorSourceAlphaSaturated,
    };
    return factors[static_cast<size_t>(factor)];
}

MTLSamplerAddressMode address_mode(WrapMode mode) {
    switch (mode) {
    case WrapMode::ClampToEdge: return MTLSamplerAddressModeClampToEdge;
    case WrapMode::Repeat: return MTLSamplerAddressModeRepeat;
    case WrapMode::MirroredRepeat: return MTLSamplerAddressModeMirrorRepeat;
    }
    return MTLSamplerAddressModeClampToEdge;
}

template <class T>
std::array<uint32_t, 4> four(const std::array<T, 3>& values) {
    return {static_cast<uint32_t>(values[0]), static_cast<uint32_t>(values[1]),
            static_cast<uint32_t>(values[2]), 0};
}

GpuFragmentState gpu_state(const DrawState& state, uint32_t depth_bits) {
    GpuFragmentState result{};
    const auto byte = [](float value) {
        return static_cast<uint32_t>(std::clamp(value, 0.0f, 1.0f) * 255.0f + 0.5f);
    };
    result.initial_buffer = {byte(state.combiner_buffer_color.x),
                             byte(state.combiner_buffer_color.y),
                             byte(state.combiner_buffer_color.z),
                             byte(state.combiner_buffer_color.w)};
    result.depth = {state.pica_depth_scale, state.pica_depth_offset,
                    static_cast<float>((1U << depth_bits) - 1U), 0.0f};
    result.alpha = {state.alpha_test_enable, static_cast<uint32_t>(state.alpha_compare),
                    state.alpha_reference, 0};
    for (size_t i = 0; i < state.tev.size(); ++i) {
        const auto& source = state.tev[i];
        auto& target = result.tev[i];
        target.color_source = four(source.color_source);
        target.alpha_source = four(source.alpha_source);
        target.color_modifier = four(source.color_modifier);
        target.alpha_modifier = four(source.alpha_modifier);
        target.operation_multiplier = {static_cast<uint32_t>(source.color_operation),
                                       static_cast<uint32_t>(source.alpha_operation),
                                       source.color_multiplier, source.alpha_multiplier};
        target.update = {source.update_buffer_color, source.update_buffer_alpha, 0, 0};
        target.constant = {byte(source.constant.x), byte(source.constant.y),
                           byte(source.constant.z), byte(source.constant.w)};
    }
    return result;
}

} // namespace

struct Target::Impl {
    id<MTLDevice> device{};
    id<MTLTexture> color{};
    id<MTLTexture> depth{};
    uint32_t width{};
    uint32_t height{};
    uint32_t depth_bits{};
    bool has_stencil{};
    bool poisoned{};
};

Target::Target(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}
Target::~Target() = default;
Target::Target(Target&&) noexcept = default;
Target& Target::operator=(Target&&) noexcept = default;

struct Renderer::Impl {
    id<MTLDevice> device{};
    id<MTLCommandQueue> queue{};
    id<MTLRenderPipelineState> depth_pipeline{};
    id<MTLRenderPipelineState> stencil_pipeline{};
    id<MTLFunction> vertex_function{};
    id<MTLFunction> fragment_function{};
    Error setup_error_code{Error::None};
    std::string setup_error;

    Impl() {
        device = MTLCreateSystemDefaultDevice();
        if (!device) {
            setup_error_code = Error::MetalUnavailable;
            setup_error = "no Metal device is available";
            return;
        }
        queue = [device newCommandQueue];
        NSError* error = nil;
        NSString* source = [NSString stringWithUTF8String:shader_source];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            setup_error_code = Error::ShaderCompilation;
            setup_error = error ? error.localizedDescription.UTF8String
                                : "Metal shader compilation failed";
            return;
        }
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        vertex_function = [library newFunctionWithName:@"pica_vertex"];
        fragment_function = [library newFunctionWithName:@"pica_fragment"];
        descriptor.vertexFunction = vertex_function;
        descriptor.fragmentFunction = fragment_function;
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        depth_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        stencil_pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!queue || !depth_pipeline || !stencil_pipeline) {
            setup_error_code = queue ? Error::ShaderCompilation : Error::MetalUnavailable;
            setup_error = error ? error.localizedDescription.UTF8String
                                : "Metal pipeline creation failed";
        }
    }

    id<MTLRenderPipelineState> pipeline(const DrawState& state, bool has_stencil,
                                        NSError** error) {
        if (!state.blend_enable)
            return has_stencil ? stencil_pipeline : depth_pipeline;
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex_function;
        descriptor.fragmentFunction = fragment_function;
        auto* color = descriptor.colorAttachments[0];
        color.pixelFormat = MTLPixelFormatRGBA8Unorm;
        color.blendingEnabled = YES;
        color.rgbBlendOperation = blend_operation(state.color_blend_equation);
        color.alphaBlendOperation = blend_operation(state.alpha_blend_equation);
        color.sourceRGBBlendFactor = blend_factor(state.source_color_blend_factor);
        color.destinationRGBBlendFactor = blend_factor(state.destination_color_blend_factor);
        color.sourceAlphaBlendFactor = blend_factor(state.source_alpha_blend_factor);
        color.destinationAlphaBlendFactor = blend_factor(state.destination_alpha_blend_factor);
        descriptor.depthAttachmentPixelFormat = has_stencil
                                                    ? MTLPixelFormatDepth32Float_Stencil8
                                                    : MTLPixelFormatDepth32Float;
        if (has_stencil)
            descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        return [device newRenderPipelineStateWithDescriptor:descriptor error:error];
    }
};

Renderer::Renderer() : impl_(std::make_unique<Impl>()) {}
Renderer::~Renderer() = default;
Renderer::Renderer(Renderer&&) noexcept = default;
Renderer& Renderer::operator=(Renderer&&) noexcept = default;

TargetResult Renderer::create_target(const TargetDescriptor& descriptor) {
    @autoreleasepool {
        if (!impl_ || !impl_->setup_error.empty())
            return {impl_ ? impl_->setup_error_code : Error::MetalUnavailable,
                    impl_ ? impl_->setup_error : "Metal renderer was moved from", {}};
        if (!descriptor.width || !descriptor.height || descriptor.width > 16384 ||
            descriptor.height > 16384 ||
            (descriptor.pica_depth_bits != 16 && descriptor.pica_depth_bits != 24) ||
            !std::isfinite(descriptor.clear_color.x) ||
            !std::isfinite(descriptor.clear_color.y) ||
            !std::isfinite(descriptor.clear_color.z) ||
            !std::isfinite(descriptor.clear_color.w) ||
            !std::isfinite(descriptor.clear_depth) || descriptor.clear_depth < 0.0f ||
            descriptor.clear_depth > 1.0f)
            return {Error::InvalidDraw, "persistent Metal target descriptor is invalid", {}};
        if (!descriptor.initial_color_rgba8.empty() &&
            (descriptor.initial_color_row_bytes < descriptor.width * 4ULL ||
             descriptor.initial_color_rgba8.size() <
                 static_cast<uint64_t>(descriptor.initial_color_row_bytes) * descriptor.height))
            return {Error::InvalidDraw, "persistent target RGBA8 import is truncated", {}};
        const uint64_t pixel_count = static_cast<uint64_t>(descriptor.width) * descriptor.height;
        const bool imports_depth = !descriptor.initial_depth.empty();
        if ((imports_depth && descriptor.initial_depth.size() < pixel_count) ||
            (!descriptor.initial_stencil.empty() && !descriptor.has_stencil) ||
            (!descriptor.initial_stencil.empty() && !imports_depth) ||
            (descriptor.has_stencil && imports_depth &&
             descriptor.initial_stencil.size() < pixel_count))
            return {Error::InvalidDraw, "persistent target depth/stencil import is incomplete", {}};
        if (imports_depth) {
            for (uint64_t index = 0; index < pixel_count; ++index) {
                const float value = descriptor.initial_depth[index];
                if (!std::isfinite(value) || value < 0.0f || value > 1.0f)
                    return {Error::InvalidDraw,
                            "persistent target depth import contains an invalid value", {}};
            }
        }

        auto target = std::make_unique<Target::Impl>();
        target->device = impl_->device;
        target->width = descriptor.width;
        target->height = descriptor.height;
        target->depth_bits = descriptor.pica_depth_bits;
        target->has_stencil = descriptor.has_stencil;
        MTLTextureDescriptor* color_descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:descriptor.width
                                           height:descriptor.height mipmapped:NO];
        color_descriptor.storageMode = MTLStorageModeShared;
        color_descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        target->color = [impl_->device newTextureWithDescriptor:color_descriptor];
        MTLTextureDescriptor* depth_descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:descriptor.has_stencil
                                                   ? MTLPixelFormatDepth32Float_Stencil8
                                                   : MTLPixelFormatDepth32Float
                                            width:descriptor.width height:descriptor.height
                                         mipmapped:NO];
        depth_descriptor.storageMode = MTLStorageModePrivate;
        depth_descriptor.usage = MTLTextureUsageRenderTarget;
        target->depth = [impl_->device newTextureWithDescriptor:depth_descriptor];
        if (!target->color || !target->depth)
            return {Error::MetalUnavailable, "persistent Metal target allocation failed", {}};
        if (!descriptor.initial_color_rgba8.empty()) {
            [target->color replaceRegion:MTLRegionMake2D(0, 0, descriptor.width, descriptor.height)
                              mipmapLevel:0
                                withBytes:descriptor.initial_color_rgba8.data()
                              bytesPerRow:descriptor.initial_color_row_bytes];
        }

        const uint32_t depth_row_bytes = (descriptor.width * 4U + 255U) & ~255U;
        const uint32_t stencil_row_bytes = (descriptor.width + 255U) & ~255U;
        id<MTLBuffer> depth_import{};
        id<MTLBuffer> stencil_import{};
        if (imports_depth) {
            depth_import = [impl_->device
                newBufferWithLength:static_cast<NSUInteger>(depth_row_bytes) * descriptor.height
                            options:MTLResourceStorageModeShared];
            if (!depth_import || !depth_import.contents)
                return {Error::MetalUnavailable, "persistent depth import allocation failed", {}};
            auto* destination = static_cast<uint8_t*>(depth_import.contents);
            for (uint32_t y = 0; y < descriptor.height; ++y)
                std::memcpy(destination + static_cast<size_t>(y) * depth_row_bytes,
                            descriptor.initial_depth.data() + static_cast<size_t>(y) * descriptor.width,
                            static_cast<size_t>(descriptor.width) * sizeof(float));
            if (descriptor.has_stencil) {
                stencil_import = [impl_->device
                    newBufferWithLength:static_cast<NSUInteger>(stencil_row_bytes) * descriptor.height
                                options:MTLResourceStorageModeShared];
                if (!stencil_import || !stencil_import.contents)
                    return {Error::MetalUnavailable, "persistent stencil import allocation failed", {}};
                destination = static_cast<uint8_t*>(stencil_import.contents);
                for (uint32_t y = 0; y < descriptor.height; ++y)
                    std::memcpy(destination + static_cast<size_t>(y) * stencil_row_bytes,
                                descriptor.initial_stencil.data() + static_cast<size_t>(y) * descriptor.width,
                                descriptor.width);
            }
        }

        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        if (!command)
            return {Error::MetalUnavailable, "persistent target command allocation failed", {}};
        if (imports_depth) {
            id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
            if (!blit)
                return {Error::MetalUnavailable, "persistent depth import encoder failed", {}};
            const MTLSize size = MTLSizeMake(descriptor.width, descriptor.height, 1);
            const MTLBlitOption depth_option = descriptor.has_stencil
                                                   ? MTLBlitOptionDepthFromDepthStencil
                                                   : MTLBlitOptionNone;
            [blit copyFromBuffer:depth_import sourceOffset:0 sourceBytesPerRow:depth_row_bytes
                 sourceBytesPerImage:0
                          sourceSize:size toTexture:target->depth destinationSlice:0
                    destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)
                            options:depth_option];
            if (descriptor.has_stencil) {
                [blit copyFromBuffer:stencil_import sourceOffset:0
                     sourceBytesPerRow:stencil_row_bytes
                   sourceBytesPerImage:0
                              sourceSize:size toTexture:target->depth destinationSlice:0
                        destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)
                                options:MTLBlitOptionStencilFromDepthStencil];
            }
            [blit endEncoding];
        }

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target->color;
        pass.colorAttachments[0].loadAction = descriptor.initial_color_rgba8.empty()
                                                  ? MTLLoadActionClear
                                                  : MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            descriptor.clear_color.x, descriptor.clear_color.y, descriptor.clear_color.z,
            descriptor.clear_color.w);
        pass.depthAttachment.texture = target->depth;
        pass.depthAttachment.loadAction = imports_depth ? MTLLoadActionLoad : MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        const uint32_t levels = (1U << descriptor.pica_depth_bits) - 1U;
        pass.depthAttachment.clearDepth = std::floor(descriptor.clear_depth * levels) / levels;
        if (descriptor.has_stencil) {
            pass.stencilAttachment.texture = target->depth;
            pass.stencilAttachment.loadAction = imports_depth ? MTLLoadActionLoad : MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.clearStencil = descriptor.clear_stencil;
        }
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder)
            return {Error::MetalUnavailable, "persistent target initialization encoder failed", {}};
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "persistent target initialization failed",
                    {}};
        return {Error::None, {}, std::unique_ptr<Target>(new Target(std::move(target)))};
    }
}

ValidationResult Renderer::draw(Target& target, std::span<const Draw> draws) {
    @autoreleasepool {
        if (!impl_ || !impl_->setup_error.empty() || !target.impl_ ||
            target.impl_->device != impl_->device || target.impl_->poisoned)
            return {Error::InvalidDraw, "persistent Metal target is moved from"};
        const Frame validation_frame{target.impl_->width, target.impl_->height, {}, 1.0f,
                                     target.impl_->depth_bits, draws,
                                     target.impl_->has_stencil, 0};
        const ValidationResult validation = validate(validation_frame);
        if (!validation) return validation;
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target.impl_->color;
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.texture = target.impl_->depth;
        pass.depthAttachment.loadAction = MTLLoadActionLoad;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        if (target.impl_->has_stencil) {
            pass.stencilAttachment.texture = target.impl_->depth;
            pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder =
            command ? [command renderCommandEncoderWithDescriptor:pass] : nil;
        if (!command || !encoder)
            return {Error::MetalUnavailable, "persistent Metal draw encoder failed"};
        const uint8_t white[]{255, 255, 255, 255};
        for (const Draw& draw : draws) {
            const DrawState& state = draw.state;
            NSError* pipeline_error = nil;
            id<MTLRenderPipelineState> pipeline =
                impl_->pipeline(state, target.impl_->has_stencil, &pipeline_error);
            std::vector<GpuVertex> vertices;
            vertices.reserve(draw.vertices.size());
            for (const auto& vertex : draw.vertices)
                vertices.push_back({{vertex.clip_position.x, vertex.clip_position.y,
                                     vertex.clip_position.z, vertex.clip_position.w},
                                    {vertex.primary_color.x, vertex.primary_color.y,
                                     vertex.primary_color.z, vertex.primary_color.w},
                                    {vertex.texcoord0.x, vertex.texcoord0.y},
                                    {vertex.texcoord2.x, vertex.texcoord2.y}});
            const GpuFragmentState fragment = gpu_state(state, target.impl_->depth_bits);
            GpuProceduralTexture procedural{};
            if (draw.procedural_texture) {
                procedural.color_map = draw.procedural_texture->color_map;
                procedural.color = draw.procedural_texture->color;
                procedural.color_difference = draw.procedural_texture->color_difference;
            }
            id<MTLBuffer> vertex_buffer = [impl_->device
                newBufferWithBytes:vertices.data() length:vertices.size() * sizeof(GpuVertex)
                            options:MTLResourceStorageModeShared];
            id<MTLBuffer> fragment_buffer = [impl_->device
                newBufferWithBytes:&fragment length:sizeof(fragment)
                            options:MTLResourceStorageModeShared];
            id<MTLBuffer> procedural_buffer = [impl_->device
                newBufferWithBytes:&procedural length:sizeof(procedural)
                            options:MTLResourceStorageModeShared];
            const TextureRgba8* source_texture = draw.texture0;
            MTLTextureDescriptor* texture_descriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                width:source_texture ? source_texture->width : 1
                                               height:source_texture ? source_texture->height : 1
                                            mipmapped:NO];
            texture_descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [impl_->device newTextureWithDescriptor:texture_descriptor];
            if (texture)
                [texture replaceRegion:MTLRegionMake2D(0, 0, texture.width, texture.height)
                           mipmapLevel:0
                             withBytes:source_texture ? source_texture->pixels.data() : white
                           bytesPerRow:source_texture ? source_texture->row_bytes : 4];
            MTLSamplerDescriptor* sampler_descriptor = [MTLSamplerDescriptor new];
            const bool linear = source_texture && source_texture->filter == TextureFilter::Linear;
            sampler_descriptor.minFilter =
                linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
            sampler_descriptor.magFilter = sampler_descriptor.minFilter;
            sampler_descriptor.sAddressMode = source_texture ? address_mode(source_texture->wrap_s)
                                                             : MTLSamplerAddressModeClampToEdge;
            sampler_descriptor.tAddressMode = source_texture ? address_mode(source_texture->wrap_t)
                                                             : MTLSamplerAddressModeClampToEdge;
            id<MTLSamplerState> sampler =
                [impl_->device newSamplerStateWithDescriptor:sampler_descriptor];
            MTLDepthStencilDescriptor* depth_descriptor = [MTLDepthStencilDescriptor new];
            depth_descriptor.depthCompareFunction = state.depth_test_enable
                                                        ? compare_function(state.depth_compare)
                                                        : MTLCompareFunctionAlways;
            depth_descriptor.depthWriteEnabled = state.depth_write_enable;
            if (state.stencil_test_enable) {
                MTLStencilDescriptor* stencil = [MTLStencilDescriptor new];
                stencil.stencilCompareFunction = compare_function(state.stencil_compare);
                stencil.stencilFailureOperation = stencil_operation(state.stencil_fail);
                stencil.depthFailureOperation = stencil_operation(state.stencil_depth_fail);
                stencil.depthStencilPassOperation = stencil_operation(state.stencil_depth_pass);
                stencil.readMask = state.stencil_read_mask;
                stencil.writeMask = state.stencil_write_mask;
                depth_descriptor.frontFaceStencil = stencil;
                depth_descriptor.backFaceStencil = stencil;
            }
            id<MTLDepthStencilState> depth_state =
                [impl_->device newDepthStencilStateWithDescriptor:depth_descriptor];
            if (!pipeline || !vertex_buffer || !fragment_buffer || !procedural_buffer || !texture || !sampler ||
                !depth_state) {
                [encoder endEncoding];
                return {pipeline ? Error::MetalUnavailable : Error::ShaderCompilation,
                        pipeline_error ? pipeline_error.localizedDescription.UTF8String
                                       : "persistent Metal draw resource allocation failed"};
            }
            [encoder setRenderPipelineState:pipeline];
            [encoder setDepthStencilState:depth_state];
            [encoder setStencilReferenceValue:state.stencil_reference];
            [encoder setBlendColorRed:state.blend_constant.x green:state.blend_constant.y
                                 blue:state.blend_constant.z alpha:state.blend_constant.w];
            [encoder setViewport:MTLViewport{static_cast<double>(state.viewport_x),
                                            static_cast<double>(state.viewport_y),
                                            static_cast<double>(state.viewport_width),
                                            static_cast<double>(state.viewport_height), 0.0, 1.0}];
            [encoder setScissorRect:state.scissor_enable
                                        ? MTLScissorRect{state.scissor_x, state.scissor_y,
                                                         state.scissor_width, state.scissor_height}
                                        : MTLScissorRect{0, 0, target.impl_->width,
                                                         target.impl_->height}];
            [encoder setFrontFacingWinding:state.cull_mode == CullMode::KeepCounterClockwise
                                               ? MTLWindingClockwise
                                               : MTLWindingCounterClockwise];
            [encoder setCullMode:state.cull_mode == CullMode::KeepAll
                                     ? MTLCullModeNone
                                     : (state.invert_ndc_y ? MTLCullModeFront
                                                              : MTLCullModeBack)];
            const uint32_t flip = state.invert_ndc_y;
            [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
            [encoder setVertexBytes:&flip length:sizeof(flip) atIndex:1];
            [encoder setFragmentBuffer:fragment_buffer offset:0 atIndex:0];
            [encoder setFragmentBuffer:procedural_buffer offset:0 atIndex:1];
            [encoder setFragmentTexture:texture atIndex:0];
            [encoder setFragmentSamplerState:sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                         vertexCount:vertices.size()];
        }
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            target.impl_->poisoned = true;
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "persistent Metal draw did not complete"};
        }
        return {};
    }
}

RenderResult Renderer::readback(Target& target) {
    @autoreleasepool {
        if (!impl_ || !impl_->setup_error.empty() || !target.impl_ ||
            target.impl_->device != impl_->device || target.impl_->poisoned)
            return {Error::InvalidDraw, "persistent Metal target is moved from", {}};
        const uint32_t aligned_row = (target.impl_->width * 4U + 255U) & ~255U;
        id<MTLBuffer> buffer = [impl_->device
            newBufferWithLength:static_cast<NSUInteger>(aligned_row) * target.impl_->height
                        options:MTLResourceStorageModeShared];
        if (!buffer || !buffer.contents)
            return {Error::MetalUnavailable, "persistent Metal readback allocation failed", {}};
        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        if (!command)
            return {Error::MetalUnavailable, "persistent Metal readback command failed", {}};
        id<MTLBlitCommandEncoder> blit = command ? [command blitCommandEncoder] : nil;
        if (!blit)
            return {Error::MetalUnavailable, "persistent Metal readback allocation failed", {}};
        [blit copyFromTexture:target.impl_->color sourceSlice:0 sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(target.impl_->width, target.impl_->height, 1)
                          toBuffer:buffer destinationOffset:0 destinationBytesPerRow:aligned_row
               destinationBytesPerImage:static_cast<NSUInteger>(aligned_row) * target.impl_->height];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            target.impl_->poisoned = true;
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "persistent Metal readback failed",
                    {}};
        }
        Image image{target.impl_->width, target.impl_->height, target.impl_->width * 4U,
                    std::vector<uint8_t>(static_cast<uint64_t>(target.impl_->width) *
                                         target.impl_->height * 4)};
        const auto* bytes = static_cast<const uint8_t*>(buffer.contents);
        for (uint32_t y = 0; y < image.height; ++y)
            std::memcpy(image.rgba8.data() + y * image.row_bytes, bytes + y * aligned_row,
                        image.row_bytes);
        return {Error::None, {}, std::move(image)};
    }
}

DepthStencilResult Renderer::readback_depth_stencil(Target& target) {
    @autoreleasepool {
        if (!impl_ || !impl_->setup_error.empty() || !target.impl_ ||
            target.impl_->device != impl_->device || target.impl_->poisoned)
            return {Error::InvalidDraw, "persistent Metal target is moved from", {}};
        const uint32_t depth_row_bytes = (target.impl_->width * 4U + 255U) & ~255U;
        const uint32_t stencil_row_bytes = (target.impl_->width + 255U) & ~255U;
        id<MTLBuffer> depth_buffer = [impl_->device
            newBufferWithLength:static_cast<NSUInteger>(depth_row_bytes) * target.impl_->height
                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> stencil_buffer{};
        if (target.impl_->has_stencil) {
            stencil_buffer = [impl_->device
                newBufferWithLength:static_cast<NSUInteger>(stencil_row_bytes) * target.impl_->height
                            options:MTLResourceStorageModeShared];
        }
        if (!depth_buffer || !depth_buffer.contents ||
            (target.impl_->has_stencil && (!stencil_buffer || !stencil_buffer.contents)))
            return {Error::MetalUnavailable,
                    "persistent Metal depth/stencil readback allocation failed", {}};
        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        if (!command)
            return {Error::MetalUnavailable,
                    "persistent Metal depth/stencil readback command failed", {}};
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!blit)
            return {Error::MetalUnavailable,
                    "persistent Metal depth/stencil readback encoder failed", {}};
        const MTLSize size = MTLSizeMake(target.impl_->width, target.impl_->height, 1);
        const MTLBlitOption depth_option = target.impl_->has_stencil
                                               ? MTLBlitOptionDepthFromDepthStencil
                                               : MTLBlitOptionNone;
        [blit copyFromTexture:target.impl_->depth sourceSlice:0 sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:size
                         toBuffer:depth_buffer destinationOffset:0
           destinationBytesPerRow:depth_row_bytes
         destinationBytesPerImage:0
                           options:depth_option];
        if (target.impl_->has_stencil) {
            [blit copyFromTexture:target.impl_->depth sourceSlice:0 sourceLevel:0
                          sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:size
                             toBuffer:stencil_buffer destinationOffset:0
               destinationBytesPerRow:stencil_row_bytes
             destinationBytesPerImage:0
                               options:MTLBlitOptionStencilFromDepthStencil];
        }
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) {
            target.impl_->poisoned = true;
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "persistent Metal depth/stencil readback failed",
                    {}};
        }
        DepthStencilImage image{};
        image.width = target.impl_->width;
        image.height = target.impl_->height;
        const size_t pixel_count = static_cast<size_t>(image.width) * image.height;
        image.depth.resize(pixel_count);
        if (target.impl_->has_stencil) image.stencil.resize(pixel_count);
        const auto* depth_bytes = static_cast<const uint8_t*>(depth_buffer.contents);
        const auto* stencil_bytes = target.impl_->has_stencil
                                        ? static_cast<const uint8_t*>(stencil_buffer.contents)
                                        : nullptr;
        for (uint32_t y = 0; y < image.height; ++y) {
            std::memcpy(image.depth.data() + static_cast<size_t>(y) * image.width,
                        depth_bytes + static_cast<size_t>(y) * depth_row_bytes,
                        static_cast<size_t>(image.width) * sizeof(float));
            if (stencil_bytes)
                std::memcpy(image.stencil.data() + static_cast<size_t>(y) * image.width,
                            stencil_bytes + static_cast<size_t>(y) * stencil_row_bytes,
                            image.width);
        }
        return {Error::None, {}, std::move(image)};
    }
}

RenderResult Renderer::render(const Frame& frame) {
    const ValidationResult validation = validate(frame);
    if (!validation) return {validation.error, validation.message, {}};
    TargetResult target = create_target(
        TargetDescriptor{frame.width, frame.height, frame.pica_depth_bits, frame.has_stencil,
                         frame.clear_color, frame.clear_depth, frame.clear_stencil});
    if (!target) return {target.error, target.message, {}};
    const ValidationResult drawn = draw(*target.target, frame.draws);
    if (!drawn) return {drawn.error, drawn.message, {}};
    return readback(*target.target);
}

} // namespace mh4u::pica_metal
