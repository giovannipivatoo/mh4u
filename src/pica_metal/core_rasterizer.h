#pragma once

#include "azahar_adapter.h"

#include "video_core/rasterizer_interface.h"

#include <memory>
#include <string>

namespace Memory {
class MemorySystem;
}

namespace Pica {
class PicaCore;
}

namespace mh4u::pica_metal {

// Experimental Azahar integration seam. PICA vertex shaders remain in the
// pinned core; this consumes only RasterizerInterface::AddTriangle output.
class CoreRasterizer final : public VideoCore::RasterizerInterface {
public:
    CoreRasterizer(Memory::MemorySystem& memory, Pica::PicaCore& pica);
    ~CoreRasterizer() override;

    void AddTriangle(const Pica::OutputVertex& v0, const Pica::OutputVertex& v1,
                     const Pica::OutputVertex& v2) override;
    void DrawTriangles() override;
    void FlushAll() override;
    void FlushRegion(PAddr addr, u32 size) override;
    void InvalidateRegion(PAddr addr, u32 size) override;
    void FlushAndInvalidateRegion(PAddr addr, u32 size) override;
    void ClearAll(bool flush) override;

    // Used by RendererSoftware immediately before its existing RAM presenter.
    // Presentation reads color only; dirty depth/stencil remains owned by the target.
    bool FlushColorForPresentation();
    bool healthy() const;
    const std::string& error() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace mh4u::pica_metal
