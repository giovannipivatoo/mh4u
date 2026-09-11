cmake_minimum_required(VERSION 3.25)
project(mh4u_runtime LANGUAGES CXX OBJCXX)
if(NOT APPLE OR NOT CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
  message(FATAL_ERROR "This runtime targets native Apple Silicon macOS.")
endif()
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "13.4")

add_executable(metal-probe tools/metal_probe.mm)
target_compile_options(metal-probe PRIVATE -fobjc-arc -Wall -Wextra -Werror)
target_link_libraries(metal-probe PRIVATE "-framework Foundation" "-framework Metal" "-weak_framework MetalFX")

set(AZAHAR_SOURCE "${CMAKE_SOURCE_DIR}/.local/azahar-src" CACHE PATH "Local key-free Azahar source export")
set(LIBRETRO_INCLUDE "${AZAHAR_SOURCE}/externals/libretro-common/libretro-common/include")
if(NOT EXISTS "${LIBRETRO_INCLUDE}/libretro.h")
  message(FATAL_ERROR "Run python3 tools/build_vulkan_core.py to prepare the pinned core first.")
endif()
add_executable(mh4u-runtime src/main.mm src/vulkan_bridge.mm)
target_include_directories(mh4u-runtime PRIVATE "${LIBRETRO_INCLUDE}" "${AZAHAR_SOURCE}/externals/vulkan-headers/include")
target_compile_options(mh4u-runtime PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(mh4u-runtime PRIVATE "-framework Cocoa" "-framework Metal" "-weak_framework MetalFX" "-framework QuartzCore" "-framework AudioToolbox" "-framework GameController")
configure_file(src/Info.plist.in "${CMAKE_BINARY_DIR}/MH4U-Info.plist" @ONLY)
set(APP_CONTENTS "${CMAKE_BINARY_DIR}/MH4U Runtime.app/Contents")
add_custom_target(native-app ALL
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${APP_CONTENTS}/MacOS"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:mh4u-runtime>" "${APP_CONTENTS}/MacOS/mh4u-runtime"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_BINARY_DIR}/MH4U-Info.plist" "${APP_CONTENTS}/Info.plist"
  DEPENDS mh4u-runtime)

enable_testing()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_test(NAME local-input-boundaries COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s tests -v)
set_tests_properties(local-input-boundaries PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
add_test(NAME metal-device COMMAND metal-probe)
add_test(NAME native-input COMMAND mh4u-runtime --input-self-test)
add_test(NAME metal4-presentation COMMAND mh4u-runtime --self-test)
add_test(NAME metal-legacy-presentation COMMAND mh4u-runtime --self-test --no-metal4)
add_test(NAME metal-bilinear-presentation COMMAND mh4u-runtime --self-test --no-metalfx)
set_tests_properties(metal4-presentation metal-legacy-presentation metal-bilinear-presentation
  PROPERTIES TIMEOUT 30 RUN_SERIAL TRUE)
