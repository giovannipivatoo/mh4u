#include "fixture.h"

#include <iostream>
#include <string_view>

int main(int argc, char** argv) {
    if (argc != 2 && argc != 3) {
        std::cerr << "usage: aot-runner FIXTURE [--linked|--dispatch|--limit]\n";
        return 2;
    }
    mh4u::aot::fixture::Fixture fixture;
    std::string error;
    if (!mh4u::aot::fixture::Load(argv[1], fixture, error)) {
        std::cerr << "aot-runner: " << error << '\n';
        return 1;
    }
    mh4u::aot::fixture::Host host;
    host.memory = fixture.memory;
    host.ticks_remaining = fixture.ticks_remaining;
    const auto callbacks = mh4u::aot::fixture::MakeCallbacks(host);
    const auto result = mh4u_aot_execute(&fixture.state, &callbacks);
    auto expected = mh4u::aot::BlockExit::SupervisorCall;
    if (argc == 3) {
        const std::string_view option = argv[2];
        if (option == "--linked") expected = mh4u::aot::BlockExit::Linked;
        else if (option == "--dispatch") expected = mh4u::aot::BlockExit::Dispatch;
        else if (option == "--limit") expected = mh4u::aot::BlockExit::DispatcherLimit;
        else {
            std::cerr << "aot-runner: unknown expected exit " << option << '\n';
            return 2;
        }
    }
    if (result.exit != expected) {
        std::cerr << "aot-runner: block exited " << static_cast<unsigned>(result.exit)
                  << " at 0x" << std::hex << result.next_pc << " detail 0x" << result.detail << '\n';
        return 1;
    }
    std::cout << mh4u::aot::fixture::Format(fixture.state, host);
    return 0;
}
