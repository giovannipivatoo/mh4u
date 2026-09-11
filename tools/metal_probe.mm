#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#if __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define HAS_METALFX 1
#else
#define HAS_METALFX 0
#endif
#include <cstdio>
#include <sys/utsname.h>

// This exercises the installed runtime; SDK declarations alone are not support.
int main() {
    @autoreleasepool {
        struct utsname host {};
        uname(&host);
        NSMutableDictionary *report = [@{
            @"schema_version": @1,
            @"architecture": @(host.machine),
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"clang": @(__clang_version__),
            @"sdk_max_allowed": @(__MAC_OS_X_VERSION_MAX_ALLOWED),
            @"metal_fx_sdk": @(HAS_METALFX),
            @"metal4_sdk": @(__MAC_OS_X_VERSION_MAX_ALLOWED >= 260000)
        } mutableCopy];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        report[@"metal_device_available"] = @(device != nil);
        bool computePassed = false;
        if (device) {
            report[@"device"] = device.name;
            report[@"unified_memory"] = @(device.hasUnifiedMemory);
            report[@"recommended_max_working_set_bytes"] = @(device.recommendedMaxWorkingSetSize);
            NSMutableArray *families = [NSMutableArray array];
            const struct { MTLGPUFamily value; NSString *name; } candidates[] = {
                {MTLGPUFamilyApple1, @"Apple1"}, {MTLGPUFamilyApple2, @"Apple2"},
                {MTLGPUFamilyApple3, @"Apple3"}, {MTLGPUFamilyApple4, @"Apple4"},
                {MTLGPUFamilyApple5, @"Apple5"}, {MTLGPUFamilyApple6, @"Apple6"},
                {MTLGPUFamilyApple7, @"Apple7"}, {MTLGPUFamilyApple8, @"Apple8"},
                {MTLGPUFamilyMac2, @"Mac2"}, {MTLGPUFamilyCommon1, @"Common1"},
                {MTLGPUFamilyCommon2, @"Common2"}, {MTLGPUFamilyCommon3, @"Common3"},
                {MTLGPUFamilyMetal3, @"Metal3"}
            };
            for (const auto &family : candidates)
                if ([device supportsFamily:family.value]) [families addObject:family.name];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 140000
            if ([device supportsFamily:MTLGPUFamilyApple9]) [families addObject:@"Apple9"];
#endif
            report[@"metal4_runtime"] = @NO;
            report[@"metal4_family"] = @NO;
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
            if (@available(macOS 26.0, *)) {
                report[@"metal4_runtime"] = @YES;
                if ([device supportsFamily:MTLGPUFamilyApple10]) [families addObject:@"Apple10"];
                BOOL metal4 = [device supportsFamily:MTLGPUFamilyMetal4];
                report[@"metal4_family"] = @(metal4);
                if (metal4) {
                    [families addObject:@"Metal4"];
                    report[@"metal4_command_queue_created"] = @([device newMTL4CommandQueue] != nil);
                    NSError *error = nil;
                    id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
                    report[@"metal4_compiler_created"] = @(compiler != nil);
                    if (error) report[@"metal4_compiler_error"] = error.localizedDescription;
                }
            }
#endif
            report[@"supported_gpu_families"] = families;
#if HAS_METALFX
            if (@available(macOS 13.0, *)) {
                NSMutableDictionary *fx = [@{
                    @"spatial": @([MTLFXSpatialScalerDescriptor supportsDevice:device]),
                    @"temporal": @([MTLFXTemporalScalerDescriptor supportsDevice:device])
                } mutableCopy];
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 260000
                if (@available(macOS 26.0, *)) {
                    fx[@"metal4_spatial"] = @([MTLFXSpatialScalerDescriptor supportsMetal4FX:device]);
                    fx[@"metal4_temporal"] = @([MTLFXTemporalScalerDescriptor supportsMetal4FX:device]);
                    fx[@"frame_interpolation"] = @([MTLFXFrameInterpolatorDescriptor supportsDevice:device]);
                    fx[@"temporal_denoising"] = @([MTLFXTemporalDenoisedScalerDescriptor supportsDevice:device]);
                }
#endif
                report[@"metal_fx_supports_device"] = fx;
            }
#endif
            // A real GPU dispatch checks runtime MSL compilation and readback.
            NSError *error = nil;
            id<MTLLibrary> library = [device newLibraryWithSource:
                @"#include <metal_stdlib>\nusing namespace metal;\n"
                 "kernel void probe(device uint *out [[buffer(0)]]) { out[0] = 42; }"
                options:nil error:&error];
            report[@"msl_library_compiled"] = @(library != nil);
            id<MTLComputePipelineState> pipeline = nil;
            if (library) pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"probe"] error:&error];
            if (error) report[@"compute_error"] = error.localizedDescription;
            id<MTLBuffer> result = [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
            id<MTLCommandQueue> queue = [device newCommandQueue];
            if (pipeline && result && queue) {
                *static_cast<uint32_t *>(result.contents) = 0;
                id<MTLCommandBuffer> command = [queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                [encoder setComputePipelineState:pipeline];
                [encoder setBuffer:result offset:0 atIndex:0];
                [encoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [encoder endEncoding];
                [command commit];
                [command waitUntilCompleted];
                computePassed = command.status == MTLCommandBufferStatusCompleted && *static_cast<uint32_t *>(result.contents) == 42;
                if (command.error) report[@"compute_error"] = command.error.localizedDescription;
            }
        }
        report[@"gpu_compute_smoke_passed"] = @(computePassed);
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!json) {
            fprintf(stderr, "JSON serialization failed: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return computePassed ? 0 : 1;
    }
}
