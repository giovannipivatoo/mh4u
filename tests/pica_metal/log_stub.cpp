#include "common/logging/log.h"

namespace Common::Log {

void FmtLogMessageImpl(Class, Level, const char*, unsigned int, const char*, fmt::string_view,
                       const fmt::format_args&) {}

} // namespace Common::Log
