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

add_executable(temporal-probe tools/temporal_probe.mm)
target_compile_options(temporal-probe PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(temporal-probe PRIVATE "-framework Foundation" "-framework Metal" "-weak_framework MetalFX")

add_executable(temporal-runtime-probe tools/temporal_runtime_probe.mm src/temporal_processor.mm src/motion_estimator.mm)
target_include_directories(temporal-runtime-probe PRIVATE src)
target_compile_options(temporal-runtime-probe PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(temporal-runtime-probe PRIVATE "-framework Foundation" "-framework Metal" "-weak_framework MetalFX")

add_executable(motion-probe tools/motion_probe.mm src/motion_estimator.mm)
target_include_directories(motion-probe PRIVATE src)
target_compile_options(motion-probe PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(motion-probe PRIVATE "-framework Foundation" "-framework Metal")

add_executable(audio-buffer-probe tools/audio_buffer_probe.cpp)
target_include_directories(audio-buffer-probe PRIVATE src)
target_compile_options(audio-buffer-probe PRIVATE -Wall -Wextra -Werror)

set(AZAHAR_SOURCE "${CMAKE_SOURCE_DIR}/.local/azahar-src" CACHE PATH "Local key-free Azahar source export")
set(LIBRETRO_INCLUDE "${AZAHAR_SOURCE}/externals/libretro-common/libretro-common/include")
if(NOT EXISTS "${LIBRETRO_INCLUDE}/libretro.h")
  message(FATAL_ERROR "Run python3 tools/build_vulkan_core.py to prepare the pinned core first.")
endif()
set(CORE_ARCHIVES "${CMAKE_SOURCE_DIR}/.local/core-vulkan-build")
add_executable(savestate-path-probe tools/savestate_path_probe.cpp)
target_include_directories(savestate-path-probe PRIVATE "${AZAHAR_SOURCE}/src"
  "${AZAHAR_SOURCE}/externals/boost" "${AZAHAR_SOURCE}/externals/fmt/include")
target_link_libraries(savestate-path-probe PRIVATE
  "${CORE_ARCHIVES}/src/core/libcitra_core.a" "${CORE_ARCHIVES}/src/common/libcitra_common.a"
  "${CORE_ARCHIVES}/externals/libboost_serialization.a" "${CORE_ARCHIVES}/externals/libboost_iostreams.a"
  "${CORE_ARCHIVES}/externals/fmt/libfmt.a" "-framework Foundation" "-framework Security")
add_executable(mh4u-runtime src/main.mm src/vulkan_bridge.mm src/controller_config.mm src/texture_pack.cpp src/save_import.cpp src/motion_estimator.mm src/temporal_processor.mm)
target_include_directories(mh4u-runtime PRIVATE "${LIBRETRO_INCLUDE}" "${AZAHAR_SOURCE}/externals/vulkan-headers/include")
target_compile_options(mh4u-runtime PRIVATE -fobjc-arc -Wall -Wextra)
target_link_libraries(mh4u-runtime PRIVATE "-framework Cocoa" "-framework Metal" "-weak_framework MetalFX" "-framework QuartzCore" "-framework AudioToolbox" "-framework GameController" "-framework IOKit")
configure_file(src/Info.plist.in "${CMAKE_BINARY_DIR}/MH4U-Info.plist" @ONLY)
set(APP_CONTENTS "${CMAKE_BINARY_DIR}/MH4U Runtime.app/Contents")
add_custom_target(native-app ALL
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${APP_CONTENTS}/MacOS"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "$<TARGET_FILE:mh4u-runtime>" "${APP_CONTENTS}/MacOS/mh4u-runtime"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${CMAKE_BINARY_DIR}/MH4U-Info.plist" "${APP_CONTENTS}/Info.plist"
  COMMAND /usr/bin/codesign --force --sign - "${CMAKE_BINARY_DIR}/MH4U Runtime.app"
  DEPENDS mh4u-runtime)

enable_testing()
find_package(Python3 REQUIRED COMPONENTS Interpreter)
add_test(NAME relocated-savestate-paths COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/check_savestate_paths.py" "$<TARGET_FILE:savestate-path-probe>")
add_test(NAME local-input-boundaries COMMAND "${Python3_EXECUTABLE}" -m unittest discover -s tests -v)
set_tests_properties(local-input-boundaries PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
add_test(NAME metal-device COMMAND metal-probe)
add_test(NAME metal-temporal-interpolation COMMAND temporal-probe)
set_tests_properties(metal-temporal-interpolation PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 180 RUN_SERIAL TRUE)
add_test(NAME scaled-optical-motion COMMAND motion-probe)
set_tests_properties(scaled-optical-motion PROPERTIES TIMEOUT 30 RUN_SERIAL TRUE)
add_test(NAME audio-buffer-policy COMMAND audio-buffer-probe)
add_test(NAME temporal-runtime COMMAND temporal-runtime-probe)
set_tests_properties(temporal-runtime PROPERTIES SKIP_RETURN_CODE 77 TIMEOUT 30 RUN_SERIAL TRUE)
add_test(NAME native-input COMMAND mh4u-runtime --input-self-test)
add_test(NAME native-menu-tracking COMMAND mh4u-runtime --menu-tracking-self-test)
set_tests_properties(native-menu-tracking PROPERTIES TIMEOUT 30 RUN_SERIAL TRUE)
add_test(NAME native-video COMMAND mh4u-runtime --video-self-test)
add_test(NAME native-savestate COMMAND mh4u-runtime --savestate-self-test)
add_test(NAME native-save-import COMMAND mh4u-runtime --save-import-self-test)
set_tests_properties(native-save-import PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" TIMEOUT 30)
set_tests_properties(native-savestate PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}" TIMEOUT 30)
add_test(NAME native-texture-pack COMMAND mh4u-runtime --texture-pack-self-test)
set_tests_properties(native-texture-pack PROPERTIES WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
add_test(NAME native-audio-settings COMMAND mh4u-runtime --audio-self-test)
add_test(NAME metal4-presentation COMMAND mh4u-runtime --self-test)
add_test(NAME metal-legacy-presentation COMMAND mh4u-runtime --self-test --no-metal4)
add_test(NAME metal-bilinear-presentation COMMAND mh4u-runtime --self-test --no-metalfx)
add_test(NAME metal4-presentation-2x COMMAND mh4u-runtime --self-test --resolution 2)
add_test(NAME metal-bilinear-presentation-4x COMMAND mh4u-runtime --self-test --no-metalfx --resolution 4)
set_tests_properties(metal4-presentation metal-legacy-presentation metal-bilinear-presentation
  metal4-presentation-2x metal-bilinear-presentation-4x
  PROPERTIES TIMEOUT 30 RUN_SERIAL TRUE)
