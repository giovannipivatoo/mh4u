#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <vector>

namespace mh4u::pica_metal {

struct Float2 {
    float x{}, y{};
};

struct Float4 {
    float x{}, y{}, z{}, w{};
};

// Post-PICA-vertex-shader values. PICA float24 values are expanded to float32;
// the Metal vertex stage applies Azahar's (x, y, -z, w) convention.
struct OutputVertex {
    Float4 clip_position{};
    Float4 primary_color{};
    Float2 texcoord0{};
};

enum class TevSource : uint32_t {
    PrimaryColor,
    Texture0,
    PreviousBuffer,
    Constant,
    Previous,
};

enum class ColorModifier : uint32_t {
    SourceColor,
    OneMinusSourceColor,
    SourceAlpha,
    OneMinusSourceAlpha,
    SourceRed,
    OneMinusSourceRed,
    SourceGreen,
    OneMinusSourceGreen,
    SourceBlue,
    OneMinusSourceBlue,
};

enum class AlphaModifier : uint32_t {
    SourceAlpha,
    OneMinusSourceAlpha,
    SourceRed,
    OneMinusSourceRed,
    SourceGreen,
    OneMinusSourceGreen,
    SourceBlue,
    OneMinusSourceBlue,
};

enum class TevOperation : uint32_t {
    Replace,
    Modulate,
    Add,
    AddSigned,
    Lerp,
    Subtract,
    Dot3Rgb,
    Dot3Rgba,
    MultiplyThenAdd,
    AddThenMultiply,
};

struct TevStage {
    std::array<TevSource, 3> color_source{TevSource::Previous, TevSource::Previous,
                                         TevSource::Previous};
    std::array<TevSource, 3> alpha_source{TevSource::Previous, TevSource::Previous,
                                         TevSource::Previous};
    std::array<ColorModifier, 3> color_modifier{};
    std::array<AlphaModifier, 3> alpha_modifier{};
    TevOperation color_operation{TevOperation::Replace};
    TevOperation alpha_operation{TevOperation::Replace};
    uint32_t color_multiplier{1};
    uint32_t alpha_multiplier{1};
    bool update_buffer_color{};
    bool update_buffer_alpha{};
    Float4 constant{};
};

enum class CompareFunc : uint32_t {
    Never,
    Always,
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
};

enum class CullMode : uint32_t {
    KeepAll,
    KeepClockwise,
    KeepCounterClockwise,
};

enum class TextureFilter : uint32_t { Nearest, Linear };
enum class WrapMode : uint32_t { ClampToEdge, Repeat, MirroredRepeat };
enum class DepthMode : uint32_t { ZBuffering, WBuffering };
enum class BlendEquation : uint32_t { Add, Subtract, ReverseSubtract, Min, Max };
enum class BlendFactor : uint32_t {
    Zero,
    One,
    SourceColor,
    OneMinusSourceColor,
    DestinationColor,
    OneMinusDestinationColor,
    SourceAlpha,
    OneMinusSourceAlpha,
    DestinationAlpha,
    OneMinusDestinationAlpha,
    ConstantColor,
    OneMinusConstantColor,
    ConstantAlpha,
    OneMinusConstantAlpha,
    SourceAlphaSaturate,
};
enum class StencilAction : uint32_t {
    Keep,
    Zero,
    Replace,
    IncrementClamp,
    DecrementClamp,
    Invert,
    IncrementWrap,
    DecrementWrap,
};

struct TextureRgba8 {
    uint32_t width{};
    uint32_t height{};
    uint32_t row_bytes{};
    std::span<const uint8_t> pixels{};
    TextureFilter filter{TextureFilter::Nearest};
    WrapMode wrap_s{WrapMode::ClampToEdge};
    WrapMode wrap_t{WrapMode::ClampToEdge};
};

struct DrawState {
    int32_t viewport_x{};
    int32_t viewport_y{};
    uint32_t viewport_width{};
    uint32_t viewport_height{};
    bool flip_viewport_y{};
    bool scissor_enable{};
    uint32_t scissor_x{};
    uint32_t scissor_y{};
    uint32_t scissor_width{};
    uint32_t scissor_height{};
    CullMode cull_mode{CullMode::KeepAll};
    bool blend_enable{};
    BlendEquation color_blend_equation{BlendEquation::Add};
    BlendEquation alpha_blend_equation{BlendEquation::Add};
    BlendFactor source_color_blend_factor{BlendFactor::One};
    BlendFactor destination_color_blend_factor{BlendFactor::Zero};
    BlendFactor source_alpha_blend_factor{BlendFactor::One};
    BlendFactor destination_alpha_blend_factor{BlendFactor::Zero};
    Float4 blend_constant{};
    float pica_depth_scale{-1.0f};
    float pica_depth_offset{};
    DepthMode depth_mode{DepthMode::ZBuffering};
    bool depth_test_enable{};
    bool depth_write_enable{};
    CompareFunc depth_compare{CompareFunc::Less};
    bool stencil_test_enable{};
    CompareFunc stencil_compare{CompareFunc::Always};
    StencilAction stencil_fail{StencilAction::Keep};
    StencilAction stencil_depth_fail{StencilAction::Keep};
    StencilAction stencil_depth_pass{StencilAction::Keep};
    uint8_t stencil_reference{};
    uint8_t stencil_read_mask{0xff};
    uint8_t stencil_write_mask{0xff};
    bool alpha_test_enable{};
    CompareFunc alpha_compare{CompareFunc::Always};
    uint8_t alpha_reference{};
    Float4 combiner_buffer_color{};
    std::array<TevStage, 6> tev{};
};

struct Draw {
    std::span<const OutputVertex> vertices{};
    DrawState state{};
    const TextureRgba8* texture0{};
};

struct Frame {
    uint32_t width{};
    uint32_t height{};
    Float4 clear_color{};
    float clear_depth{1.0f};
    uint32_t pica_depth_bits{24};
    std::span<const Draw> draws{};
    bool has_stencil{};
    uint8_t clear_stencil{};
};

enum class Error {
    None,
    InvalidDraw,
    UnsupportedState,
    MetalUnavailable,
    ShaderCompilation,
    Submission,
};

struct Image {
    uint32_t width{};
    uint32_t height{};
    uint32_t row_bytes{};
    std::vector<uint8_t> rgba8{};
};

struct RenderResult {
    Error error{Error::None};
    std::string message{};
    Image image{};
    explicit operator bool() const { return error == Error::None; }
};

struct ValidationResult {
    Error error{Error::None};
    std::string message{};
    explicit operator bool() const { return error == Error::None; }
};

struct TargetDescriptor {
    uint32_t width{};
    uint32_t height{};
    uint32_t pica_depth_bits{24};
    bool has_stencil{};
    Float4 clear_color{};
    float clear_depth{1.0f};
    uint8_t clear_stencil{};
    std::span<const uint8_t> initial_color_rgba8{};
    uint32_t initial_color_row_bytes{};
};

class Target {
public:
    ~Target();
    Target(Target&&) noexcept;
    Target& operator=(Target&&) noexcept;
    Target(const Target&) = delete;
    Target& operator=(const Target&) = delete;

private:
    struct Impl;
    explicit Target(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
    friend class Renderer;
};

struct TargetResult {
    Error error{Error::None};
    std::string message{};
    std::unique_ptr<Target> target{};
    explicit operator bool() const { return error == Error::None; }
};

// Returns an explanation on failure. No command is submitted until the complete
// PICA state is accepted, so unsupported states fail closed.
ValidationResult validate(const Frame& frame);

class Renderer {
public:
    Renderer();
    ~Renderer();
    Renderer(Renderer&&) noexcept;
    Renderer& operator=(Renderer&&) noexcept;
    Renderer(const Renderer&) = delete;
    Renderer& operator=(const Renderer&) = delete;

    TargetResult create_target(const TargetDescriptor& descriptor);
    ValidationResult draw(Target& target, std::span<const Draw> draws);
    RenderResult readback(Target& target);
    RenderResult render(const Frame& frame);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace mh4u::pica_metal
