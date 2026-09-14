set(MH4U_DYNARMIC_ROOT "${AZAHAR_SOURCE}/externals/dynarmic")
set(MH4U_DYNARMIC_LIBRARY "${CORE_ARCHIVES}/externals/dynarmic/src/dynarmic/libdynarmic.a")
set(MH4U_MCL_LIBRARY "${CORE_ARCHIVES}/externals/dynarmic/externals/mcl/src/libmcl.a")
set(MH4U_FMT_LIBRARY "${CORE_ARCHIVES}/externals/fmt/libfmt.a")
foreach(archive IN ITEMS "${MH4U_DYNARMIC_LIBRARY}" "${MH4U_MCL_LIBRARY}" "${MH4U_FMT_LIBRARY}")
  if(NOT EXISTS "${archive}")
    message(FATAL_ERROR "AOT needs the pinned local core build: missing ${archive}")
  endif()
endforeach()

set(MH4U_AOT_DYNARMIC_INCLUDES
  "${MH4U_DYNARMIC_ROOT}/src"
  "${MH4U_DYNARMIC_ROOT}/externals/mcl/include"
  "${MH4U_DYNARMIC_ROOT}/externals/robin-map/include"
  "${MH4U_DYNARMIC_ROOT}/externals/oaknut/include"
  "${AZAHAR_SOURCE}/externals/fmt/include"
  "${AZAHAR_SOURCE}/externals/boost"
  "${AZAHAR_SOURCE}/src")

add_library(mh4u-aot-runtime STATIC "${CMAKE_SOURCE_DIR}/src/aot/runtime.cpp")
target_include_directories(mh4u-aot-runtime PUBLIC "${CMAKE_SOURCE_DIR}/src")
target_compile_options(mh4u-aot-runtime PRIVATE -Wall -Wextra -Werror)

add_library(mh4u-aot-fixture STATIC "${CMAKE_SOURCE_DIR}/tools/aot/fixture.cpp")
target_include_directories(mh4u-aot-fixture PUBLIC
  "${CMAKE_SOURCE_DIR}/src" "${CMAKE_SOURCE_DIR}/tools/aot")
target_link_libraries(mh4u-aot-fixture PUBLIC mh4u-aot-runtime)
target_compile_options(mh4u-aot-fixture PRIVATE -Wall -Wextra -Werror)

set(MH4U_AOT_TICK_SOURCE "${AZAHAR_SOURCE}/src/core/arm/dynarmic/arm_tick_counts.cpp")
add_executable(mh4u-aot-generator
  "${CMAKE_SOURCE_DIR}/tools/aot/generator.cpp" "${MH4U_AOT_TICK_SOURCE}")
target_include_directories(mh4u-aot-generator PRIVATE
  "${CMAKE_SOURCE_DIR}/src" "${CMAKE_SOURCE_DIR}/tools/aot" ${MH4U_AOT_DYNARMIC_INCLUDES})
target_link_libraries(mh4u-aot-generator PRIVATE mh4u-aot-fixture
  "${MH4U_DYNARMIC_LIBRARY}" "${MH4U_MCL_LIBRARY}" "${MH4U_FMT_LIBRARY}")
target_compile_options(mh4u-aot-generator PRIVATE -Wall -Wextra)

add_executable(mh4u-aot-jit-reference
  "${CMAKE_SOURCE_DIR}/tools/aot/jit_reference.cpp" "${MH4U_AOT_TICK_SOURCE}"
  "${AZAHAR_SOURCE}/src/core/arm/dynarmic/arm_dynarmic_cp15.cpp")
target_include_directories(mh4u-aot-jit-reference PRIVATE ${MH4U_AOT_DYNARMIC_INCLUDES})
target_link_libraries(mh4u-aot-jit-reference PRIVATE mh4u-aot-fixture
  "${MH4U_DYNARMIC_LIBRARY}" "${MH4U_MCL_LIBRARY}" "${MH4U_FMT_LIBRARY}")
target_compile_options(mh4u-aot-jit-reference PRIVATE -Wall -Wextra)

string(SHA256 MH4U_AOT_BUILD_ID "${CMAKE_BINARY_DIR}")
string(SUBSTRING "${MH4U_AOT_BUILD_ID}" 0 12 MH4U_AOT_BUILD_ID)
set(MH4U_AOT_ARTIFACT_ROOT "${CMAKE_SOURCE_DIR}/.local/aot-generated/${MH4U_AOT_BUILD_ID}")

foreach(mode IN ITEMS arm thumb)
  set(fixture "${CMAKE_SOURCE_DIR}/tests/aot/${mode}.fixture")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${fixture}")
  file(SHA256 "${fixture}" fixture_sha)
  set(generated "${MH4U_AOT_ARTIFACT_ROOT}/${mode}.cpp")
  set(manifest "${MH4U_AOT_ARTIFACT_ROOT}/${mode}.json")
  add_custom_command(OUTPUT "${generated}" "${manifest}"
    COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${fixture}"
      --input-sha256 "${fixture_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
      --output "${generated}" --manifest "${manifest}"
    DEPENDS mh4u-aot-generator "${fixture}"
    VERBATIM)
  add_executable("mh4u-aot-runner-${mode}"
    "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${generated}")
  target_link_libraries("mh4u-aot-runner-${mode}" PRIVATE mh4u-aot-fixture)
  target_compile_options("mh4u-aot-runner-${mode}" PRIVATE -Wall -Wextra -Werror)
  add_test(NAME "aot-${mode}-differential" COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
    --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
    --runner "$<TARGET_FILE:mh4u-aot-runner-${mode}>" --fixture "${fixture}")
endforeach()

set(dynamic_fixture "${CMAKE_SOURCE_DIR}/tests/aot/dynamic.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${dynamic_fixture}")
file(SHA256 "${dynamic_fixture}" dynamic_sha)
set(dynamic_generated "${MH4U_AOT_ARTIFACT_ROOT}/dynamic.cpp")
set(dynamic_manifest "${MH4U_AOT_ARTIFACT_ROOT}/dynamic.json")
add_custom_command(OUTPUT "${dynamic_generated}" "${dynamic_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${dynamic_fixture}"
    --input-sha256 "${dynamic_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${dynamic_generated}" --manifest "${dynamic_manifest}"
  DEPENDS mh4u-aot-generator "${dynamic_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-dynamic
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${dynamic_generated}")
target_link_libraries(mh4u-aot-runner-dynamic PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-dynamic PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-dynamic-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-dynamic>"
  --fixture "${dynamic_fixture}" --matrix)

set(shift_fixture "${CMAKE_SOURCE_DIR}/tests/aot/shift.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${shift_fixture}")
file(SHA256 "${shift_fixture}" shift_sha)
set(shift_generated "${MH4U_AOT_ARTIFACT_ROOT}/shift.cpp")
set(shift_manifest "${MH4U_AOT_ARTIFACT_ROOT}/shift.json")
add_custom_command(OUTPUT "${shift_generated}" "${shift_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${shift_fixture}"
    --input-sha256 "${shift_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${shift_generated}" --manifest "${shift_manifest}"
  DEPENDS mh4u-aot-generator "${shift_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-shift
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${shift_generated}")
target_link_libraries(mh4u-aot-runner-shift PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-shift PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-shift-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-shift>"
  --fixture "${shift_fixture}" --shift-matrix)

set(loop_fixture "${CMAKE_SOURCE_DIR}/tests/aot/loop.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${loop_fixture}")
file(SHA256 "${loop_fixture}" loop_sha)
set(loop_generated "${MH4U_AOT_ARTIFACT_ROOT}/loop.cpp")
set(loop_manifest "${MH4U_AOT_ARTIFACT_ROOT}/loop.json")
add_custom_command(OUTPUT "${loop_generated}" "${loop_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${loop_fixture}"
    --max-blocks 2 --max-dispatch-steps 2
    --input-sha256 "${loop_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${loop_generated}" --manifest "${loop_manifest}"
  DEPENDS mh4u-aot-generator "${loop_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-loop
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${loop_generated}")
target_link_libraries(mh4u-aot-runner-loop PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-loop PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-dispatcher-controls COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --runner "$<TARGET_FILE:mh4u-aot-runner-loop>"
  --fixture "${loop_fixture}" --dispatcher-controls)

set(unsupported_fixture "${CMAKE_SOURCE_DIR}/tests/aot/unsupported.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${unsupported_fixture}")
file(SHA256 "${unsupported_fixture}" unsupported_sha)
add_test(NAME aot-unsupported-fails-closed COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --generator "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${unsupported_fixture}"
  --input-sha256 "${unsupported_sha}" --artifact-root "${MH4U_AOT_ARTIFACT_ROOT}")

set(MH4U_TITLE_CODE "${CMAKE_SOURCE_DIR}/.local/game/exefs/code.bin")
set(MH4U_TITLE_CODE_SHA256 "63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc")
if(EXISTS "${MH4U_TITLE_CODE}")
  file(SHA256 "${MH4U_TITLE_CODE}" actual_title_sha)
  if(NOT actual_title_sha STREQUAL MH4U_TITLE_CODE_SHA256)
    message(FATAL_ERROR "Local title code hash does not match the verified supplied image")
  endif()
  set(title_generated "${MH4U_AOT_ARTIFACT_ROOT}/title-entry.cpp")
  set(title_manifest "${MH4U_AOT_ARTIFACT_ROOT}/title-entry.json")
  add_custom_command(OUTPUT "${title_generated}" "${title_manifest}"
    COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --binary "${MH4U_TITLE_CODE}"
      --base 0x100000 --pc 0x100000 --cpsr 0x10
      --input-sha256 "${actual_title_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
      --output "${title_generated}" --manifest "${title_manifest}"
    DEPENDS mh4u-aot-generator "${MH4U_TITLE_CODE}"
    VERBATIM)
  add_executable(mh4u-aot-title-entry-runner
    "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${title_generated}")
  target_link_libraries(mh4u-aot-title-entry-runner PRIVATE mh4u-aot-fixture)
  target_compile_options(mh4u-aot-title-entry-runner PRIVATE -Wall -Wextra -Werror)
  add_test(NAME aot-title-entry-executes COMMAND mh4u-aot-title-entry-runner
    "${CMAKE_SOURCE_DIR}/tests/aot/title_entry.fixture" --linked)
  add_test(NAME aot-title-entry-provenance COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/aot/compare.py" --manifest "${title_manifest}"
    --runner "$<TARGET_FILE:mh4u-aot-title-entry-runner>"
    --fixture "${CMAKE_SOURCE_DIR}/tests/aot/title_entry.fixture")

  set(title_chain_fixture "${CMAKE_SOURCE_DIR}/tests/aot/title_chain.fixture")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${CMAKE_SOURCE_DIR}/tests/aot/title_entry.fixture" "${title_chain_fixture}")
  set(title_chain_generated "${MH4U_AOT_ARTIFACT_ROOT}/title-chain.cpp")
  set(title_chain_manifest "${MH4U_AOT_ARTIFACT_ROOT}/title-chain.json")
  add_custom_command(OUTPUT "${title_chain_generated}" "${title_chain_manifest}"
    COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --binary "${MH4U_TITLE_CODE}"
      --base 0x100000 --pc 0x100000 --cpsr 0x10 --max-blocks 64
      --max-instructions 4096 --max-dispatch-steps 1000000
      --input-sha256 "${actual_title_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
      --output "${title_chain_generated}" --manifest "${title_chain_manifest}"
    DEPENDS mh4u-aot-generator "${MH4U_TITLE_CODE}"
    VERBATIM)
  add_executable(mh4u-aot-title-chain-runner
    "${CMAKE_SOURCE_DIR}/tools/aot/title_chain_runner.cpp" "${title_chain_generated}")
  target_link_libraries(mh4u-aot-title-chain-runner PRIVATE mh4u-aot-fixture)
  target_compile_options(mh4u-aot-title-chain-runner PRIVATE -Wall -Wextra -Werror)
  add_test(NAME aot-title-chain-differential COMMAND "${Python3_EXECUTABLE}"
    "${CMAKE_SOURCE_DIR}/tests/aot/compare.py" --manifest "${title_chain_manifest}"
    --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
    --runner "$<TARGET_FILE:mh4u-aot-title-chain-runner>"
    --fixture "${title_chain_fixture}" --code-bin "${MH4U_TITLE_CODE}")
else()
  message(STATUS "AOT title entry skipped: verified local code.bin is absent")
endif()
