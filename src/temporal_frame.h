#pragma once

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#define RETRO_ENVIRONMENT_GET_MH4U_TEMPORAL_DEPTH_SINK (0x20000u | 0x4d48u)
#define MH4U_TEMPORAL_DEPTH_ABI_VERSION 2u

enum mh4u_temporal_depth_flags {
    MH4U_TEMPORAL_DEPTH_TOP_UPRIGHT = 1u << 0,
    MH4U_TEMPORAL_DEPTH_COLOR_BGRA8 = 1u << 1,
    MH4U_TEMPORAL_DEPTH_DEPTH_R32F = 1u << 2,
    MH4U_TEMPORAL_DEPTH_VALIDATED_SCALE = 1u << 3,
};

enum mh4u_pica_depth_mode {
    MH4U_PICA_W_BUFFERING = 0,
    MH4U_PICA_Z_BUFFERING = 1,
};

struct mh4u_temporal_depth_frame {
    uint32_t abi_version;
    uint32_t struct_size;
    uint64_t sequence;
    uint64_t display_sequence;
    uint32_t source_color_address;
    uint32_t presented_color_address;
    uint32_t width;
    uint32_t height;
    uint32_t scale;
    uint32_t color_row_bytes;
    uint32_t depth_row_bytes;
    uint32_t flags;
    uint32_t pica_depth_mode;
    uint32_t pica_viewport_depth_range_raw;
    uint32_t pica_viewport_depth_near_plane_raw;
    float pica_viewport_depth_scale;
    float pica_viewport_depth_offset;
    const uint8_t* color_bgra8;
    const float* depth_r32f;
};

typedef void (*mh4u_temporal_depth_callback)(
    void* user, const struct mh4u_temporal_depth_frame* frame);
typedef bool (*mh4u_temporal_depth_enabled)(void* user);

struct mh4u_temporal_depth_sink {
    uint32_t abi_version;
    uint32_t struct_size;
    mh4u_temporal_depth_enabled enabled;
    mh4u_temporal_depth_callback callback;
    void* user;
};

#ifdef __cplusplus
static_assert(sizeof(float) == 4, "MH4U temporal ABI requires 32-bit float");
#endif
