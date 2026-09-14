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
    std::array<float, 2> padding{};
};
static_assert(sizeof(GpuVertex) == 48);

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

struct VertexIn { float4 position; float4 color; float2 uv; float2 padding; };
struct VertexOut { float4 position [[position]]; float4 color; float2 uv; };
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
struct FragmentOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

vertex VertexOut pica_vertex(const device VertexIn* vertices [[buffer(0)]],
                             constant uint& flip_y [[buffer(1)]], uint id [[vertex_id]]) {
    const VertexIn v = vertices[id];
    VertexOut out;
    out.position = float4(v.position.x, flip_y ? -v.position.y : v.position.y,
                          -v.position.z, v.position.w);
    out.color = v.color;
    out.uv = v.uv;
    return out;
}

uint4 source_value(uint source, uint4 primary, uint4 texture0, uint4 previous_buffer,
                   uint4 constant_color, uint4 previous) {
    switch (source) {
    case 0: return primary;
    case 1: return texture0;
    case 2: return previous_buffer;
    case 3: return constant_color;
    case 4: return previous;
    default: return 0.0;
    }
}

float3 modify_color(uint4 bytes, uint modifier) {
    const float4 value = float4(bytes) / 255.0;
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

float modify_alpha(uint4 bytes, uint modifier) {
    const float4 value = float4(bytes) / 255.0;
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
                                    texture2d<float> texture0 [[texture(0)]],
                                    sampler texture0_sampler [[sampler(0)]]) {
    const uint4 primary = uint4(clamp(in.color, 0.0, 1.0) * 255.0 + 0.5);
    const uint4 sampled = uint4(texture0.sample(texture0_sampler, in.uv) * 255.0 + 0.5);
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
                                                      previous_buffer, stage.constant_color, previous),
                                        stage.color_modifier[j]);
            alpha_arg[j] = modify_alpha(source_value(alpha_source, primary, sampled,
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
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionStore;
        const uint32_t levels = (1U << descriptor.pica_depth_bits) - 1U;
        pass.depthAttachment.clearDepth = std::floor(descriptor.clear_depth * levels) / levels;
        if (descriptor.has_stencil) {
            pass.stencilAttachment.texture = target->depth;
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionStore;
            pass.stencilAttachment.clearStencil = descriptor.clear_stencil;
        }
        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder =
            command ? [command renderCommandEncoderWithDescriptor:pass] : nil;
        if (!command || !encoder)
            return {Error::MetalUnavailable, "persistent target clear encoder failed", {}};
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "persistent target clear failed",
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
                                    {vertex.texcoord0.x, vertex.texcoord0.y}});
            const GpuFragmentState fragment = gpu_state(state, target.impl_->depth_bits);
            id<MTLBuffer> vertex_buffer = [impl_->device
                newBufferWithBytes:vertices.data() length:vertices.size() * sizeof(GpuVertex)
                            options:MTLResourceStorageModeShared];
            id<MTLBuffer> fragment_buffer = [impl_->device
                newBufferWithBytes:&fragment length:sizeof(fragment)
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
            if (!pipeline || !vertex_buffer || !fragment_buffer || !texture || !sampler ||
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
                                     : (state.flip_viewport_y ? MTLCullModeFront
                                                              : MTLCullModeBack)];
            const uint32_t flip = state.flip_viewport_y;
            [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
            [encoder setVertexBytes:&flip length:sizeof(flip) atIndex:1];
            [encoder setFragmentBuffer:fragment_buffer offset:0 atIndex:0];
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

RenderResult Renderer::render(const Frame& frame) {
    @autoreleasepool {
        const ValidationResult validation = validate(frame);
        if (!validation) return {validation.error, validation.message, {}};
        if (!impl_ || !impl_->setup_error.empty())
            return {impl_ ? impl_->setup_error_code : Error::MetalUnavailable,
                    impl_ ? impl_->setup_error : "Metal renderer was moved from", {}};

        auto make_target = [&](MTLPixelFormat format, MTLTextureUsage usage) {
            MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:format width:frame.width height:frame.height
                                        mipmapped:NO];
            descriptor.storageMode = MTLStorageModePrivate;
            descriptor.usage = usage;
            return [impl_->device newTextureWithDescriptor:descriptor];
        };
        id<MTLTexture> color = make_target(MTLPixelFormatRGBA8Unorm,
                                           MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        const MTLPixelFormat depth_format = frame.has_stencil
                                                ? MTLPixelFormatDepth32Float_Stencil8
                                                : MTLPixelFormatDepth32Float;
        id<MTLTexture> depth = make_target(depth_format,
                                           MTLTextureUsageRenderTarget);
        if (!color || !depth)
            return {Error::MetalUnavailable, "Metal target allocation failed", {}};

        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = color;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            frame.clear_color.x, frame.clear_color.y, frame.clear_color.z, frame.clear_color.w);
        pass.depthAttachment.texture = depth;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        const uint32_t depth_levels = (1U << frame.pica_depth_bits) - 1U;
        pass.depthAttachment.clearDepth =
            std::floor(frame.clear_depth * depth_levels) / depth_levels;
        if (frame.has_stencil) {
            pass.stencilAttachment.texture = depth;
            pass.stencilAttachment.loadAction = MTLLoadActionClear;
            pass.stencilAttachment.storeAction = MTLStoreActionDontCare;
            pass.stencilAttachment.clearStencil = frame.clear_stencil;
        }

        id<MTLCommandBuffer> command = [impl_->queue commandBuffer];
        if (!command)
            return {Error::MetalUnavailable, "Metal command buffer allocation failed", {}};
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder)
            return {Error::MetalUnavailable, "Metal render encoder allocation failed", {}};
        const uint8_t white[]{255, 255, 255, 255};

        for (const Draw& draw : frame.draws) {
            const DrawState& state = draw.state;
            NSError* pipeline_error = nil;
            id<MTLRenderPipelineState> pipeline =
                impl_->pipeline(state, frame.has_stencil, &pipeline_error);
            if (!pipeline) {
                [encoder endEncoding];
                return {Error::ShaderCompilation,
                        pipeline_error ? pipeline_error.localizedDescription.UTF8String
                                       : "Metal blend pipeline creation failed",
                        {}};
            }
            std::vector<GpuVertex> vertices;
            vertices.reserve(draw.vertices.size());
            for (const auto& vertex : draw.vertices) {
                vertices.push_back({
                    {vertex.clip_position.x, vertex.clip_position.y, vertex.clip_position.z,
                     vertex.clip_position.w},
                    {vertex.primary_color.x, vertex.primary_color.y, vertex.primary_color.z,
                     vertex.primary_color.w},
                    {vertex.texcoord0.x, vertex.texcoord0.y},
                });
            }
            const GpuFragmentState fragment = gpu_state(state, frame.pica_depth_bits);
            id<MTLBuffer> vertex_buffer = [impl_->device
                newBufferWithBytes:vertices.data() length:vertices.size() * sizeof(GpuVertex)
                            options:MTLResourceStorageModeShared];
            id<MTLBuffer> fragment_buffer = [impl_->device
                newBufferWithBytes:&fragment length:sizeof(fragment)
                            options:MTLResourceStorageModeShared];

            const TextureRgba8* source_texture = draw.texture0;
            MTLTextureDescriptor* texture_descriptor = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                width:source_texture ? source_texture->width : 1
                                               height:source_texture ? source_texture->height : 1
                                            mipmapped:NO];
            texture_descriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> texture = [impl_->device newTextureWithDescriptor:texture_descriptor];
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
            if (!vertex_buffer || !fragment_buffer || !texture || !sampler || !depth_state) {
                [encoder endEncoding];
                return {Error::MetalUnavailable, "Metal draw resource allocation failed", {}};
            }

            [encoder setDepthStencilState:depth_state];
            [encoder setRenderPipelineState:pipeline];
            [encoder setBlendColorRed:state.blend_constant.x green:state.blend_constant.y
                                 blue:state.blend_constant.z alpha:state.blend_constant.w];
            [encoder setStencilReferenceValue:state.stencil_reference];
            [encoder setViewport:MTLViewport{static_cast<double>(state.viewport_x),
                                            static_cast<double>(state.viewport_y),
                                            static_cast<double>(state.viewport_width),
                                            static_cast<double>(state.viewport_height), 0.0, 1.0}];
            [encoder setScissorRect:state.scissor_enable
                                        ? MTLScissorRect{state.scissor_x, state.scissor_y,
                                                         state.scissor_width, state.scissor_height}
                                        : MTLScissorRect{0, 0, frame.width, frame.height}];
            [encoder setFrontFacingWinding:state.cull_mode == CullMode::KeepCounterClockwise
                                               ? MTLWindingClockwise
                                               : MTLWindingCounterClockwise];
            [encoder setCullMode:state.cull_mode == CullMode::KeepAll
                                     ? MTLCullModeNone
                                     : (state.flip_viewport_y ? MTLCullModeFront
                                                              : MTLCullModeBack)];
            const uint32_t flip = state.flip_viewport_y;
            [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
            [encoder setVertexBytes:&flip length:sizeof(flip) atIndex:1];
            [encoder setFragmentBuffer:fragment_buffer offset:0 atIndex:0];
            [encoder setFragmentTexture:texture atIndex:0];
            [encoder setFragmentSamplerState:sampler atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
                         vertexCount:vertices.size()];
        }
        [encoder endEncoding];

        const uint32_t aligned_row = (frame.width * 4U + 255U) & ~255U;
        id<MTLBuffer> readback = [impl_->device
            newBufferWithLength:static_cast<NSUInteger>(aligned_row) * frame.height
                        options:MTLResourceStorageModeShared];
        if (!readback || !readback.contents)
            return {Error::MetalUnavailable, "Metal readback allocation failed", {}};
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!blit)
            return {Error::MetalUnavailable, "Metal blit encoder allocation failed", {}};
        [blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(frame.width, frame.height, 1)
                        toBuffer:readback destinationOffset:0 destinationBytesPerRow:aligned_row
             destinationBytesPerImage:static_cast<NSUInteger>(aligned_row) * frame.height];
        [blit endEncoding];
        [command commit];
        [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted)
            return {Error::Submission,
                    command.error ? command.error.localizedDescription.UTF8String
                                  : "Metal draw did not complete",
                    {}};

        Image image{frame.width, frame.height, frame.width * 4U,
                    std::vector<uint8_t>(frame.width * frame.height * 4ULL)};
        const auto* bytes = static_cast<const uint8_t*>(readback.contents);
        for (uint32_t y = 0; y < frame.height; ++y)
            std::memcpy(image.rgba8.data() + y * image.row_bytes, bytes + y * aligned_row,
                        image.row_bytes);
        return {Error::None, {}, std::move(image)};
    }
}

} // namespace mh4u::pica_metal
