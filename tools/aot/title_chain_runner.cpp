#include "fixture.h"

#include <iostream>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: aot-title-chain-runner FIXTURE CODE_BIN\n";
        return 2;
    }
    mh4u::aot::fixture::Fixture fixture;
    std::string error;
    if (!mh4u::aot::fixture::Load(argv[1], fixture, error)) {
        std::cerr << error << '\n';
        return 1;
    }
    mh4u::aot::fixture::Host host;
    host.memory = fixture.memory;
    host.ticks_remaining = fixture.ticks_remaining;
    if (!mh4u::aot::fixture::MapBinary(argv[2], fixture.base, host, error)) {
        std::cerr << error << '\n';
        return 1;
    }
    const auto initial_memory = host.memory;
    const auto callbacks = mh4u::aot::fixture::MakeCallbacks(host);
    const auto result = mh4u_aot_execute(&fixture.state, &callbacks);
    if (result.exit != mh4u::aot::BlockExit::SupervisorCall || host.svc_calls.size() != 1) {
        std::cerr << "title chain did not reach exactly one SVC; detail=0x" << std::hex
                  << result.detail << '\n';
        return 1;
    }
    std::cout << mh4u::aot::fixture::FormatSummary(fixture.state, host, initial_memory);
    return 0;
}
