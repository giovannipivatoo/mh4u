add_library(mh4u-pica-metal STATIC
  "${CMAKE_SOURCE_DIR}/src/pica_metal/pica_metal.cpp"
  "${CMAKE_SOURCE_DIR}/src/pica_metal/pica_metal.mm")
target_include_directories(mh4u-pica-metal PUBLIC "${CMAKE_SOURCE_DIR}/src/pica_metal")
target_compile_options(mh4u-pica-metal PRIVATE -Wall -Wextra -Werror
  $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
target_link_libraries(mh4u-pica-metal PUBLIC "-framework Foundation" "-framework Metal")

add_library(mh4u-pica-metal-azahar-adapter STATIC
  "${CMAKE_SOURCE_DIR}/src/pica_metal/azahar_adapter.cpp")
target_include_directories(mh4u-pica-metal-azahar-adapter PRIVATE
  "${AZAHAR_SOURCE}/src" "${AZAHAR_SOURCE}/externals/fmt/include"
  "${AZAHAR_SOURCE}/externals/boost")
target_link_libraries(mh4u-pica-metal-azahar-adapter PUBLIC mh4u-pica-metal)
target_compile_options(mh4u-pica-metal-azahar-adapter PRIVATE
  -Wall -Wextra -Wno-unused-parameter)

add_executable(pica-metal-probe "${CMAKE_SOURCE_DIR}/tools/pica_metal/probe.cpp")
target_link_libraries(pica-metal-probe PRIVATE mh4u-pica-metal)
target_compile_options(pica-metal-probe PRIVATE -Wall -Wextra -Werror)

add_test(NAME pica-metal-golden COMMAND pica-metal-probe)
set_tests_properties(pica-metal-golden PROPERTIES
  SKIP_RETURN_CODE 77 TIMEOUT 30 RUN_SERIAL TRUE)

add_executable(pica-metal-adapter-test
  "${CMAKE_SOURCE_DIR}/tests/pica_metal/adapter.cpp")
target_include_directories(pica-metal-adapter-test PRIVATE
  "${AZAHAR_SOURCE}/src" "${AZAHAR_SOURCE}/externals/fmt/include"
  "${AZAHAR_SOURCE}/externals/boost")
target_link_libraries(pica-metal-adapter-test PRIVATE mh4u-pica-metal-azahar-adapter)
target_compile_options(pica-metal-adapter-test PRIVATE
  -Wall -Wextra -Wno-unused-parameter)
add_test(NAME pica-metal-azahar-adapter COMMAND pica-metal-adapter-test)
set_tests_properties(pica-metal-azahar-adapter PROPERTIES
  SKIP_RETURN_CODE 77 TIMEOUT 30 RUN_SERIAL TRUE)

add_executable(pica-metal-trace-replay
  "${CMAKE_SOURCE_DIR}/tools/pica_metal/replay.cpp")
target_include_directories(pica-metal-trace-replay PRIVATE
  "${AZAHAR_SOURCE}/src" "${AZAHAR_SOURCE}/externals/fmt/include"
  "${AZAHAR_SOURCE}/externals/boost")
target_link_libraries(pica-metal-trace-replay PRIVATE mh4u-pica-metal-azahar-adapter)
target_compile_options(pica-metal-trace-replay PRIVATE
  -Wall -Wextra -Werror -Wno-unused-parameter)
