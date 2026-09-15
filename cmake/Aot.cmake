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

set(exclusive_fixture "${CMAKE_SOURCE_DIR}/tests/aot/exclusive.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${exclusive_fixture}")
file(SHA256 "${exclusive_fixture}" exclusive_sha)
set(exclusive_generated "${MH4U_AOT_ARTIFACT_ROOT}/exclusive.cpp")
set(exclusive_manifest "${MH4U_AOT_ARTIFACT_ROOT}/exclusive.json")
add_custom_command(OUTPUT "${exclusive_generated}" "${exclusive_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${exclusive_fixture}"
    --input-sha256 "${exclusive_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${exclusive_generated}" --manifest "${exclusive_manifest}"
  DEPENDS mh4u-aot-generator "${exclusive_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-exclusive
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${exclusive_generated}")
target_link_libraries(mh4u-aot-runner-exclusive PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-exclusive PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-exclusive-differential COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-exclusive>"
  --fixture "${exclusive_fixture}" --exclusive)

set(fpscr_fixture "${CMAKE_SOURCE_DIR}/tests/aot/fpscr.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${fpscr_fixture}")
file(SHA256 "${fpscr_fixture}" fpscr_sha)
set(fpscr_generated "${MH4U_AOT_ARTIFACT_ROOT}/fpscr.cpp")
set(fpscr_manifest "${MH4U_AOT_ARTIFACT_ROOT}/fpscr.json")
add_custom_command(OUTPUT "${fpscr_generated}" "${fpscr_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${fpscr_fixture}"
    --max-blocks 2
    --input-sha256 "${fpscr_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${fpscr_generated}" --manifest "${fpscr_manifest}"
  DEPENDS mh4u-aot-generator "${fpscr_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-fpscr
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${fpscr_generated}")
target_link_libraries(mh4u-aot-runner-fpscr PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-fpscr PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-fpscr-mode-missing-diagnosed COMMAND mh4u-aot-runner-fpscr
  "${fpscr_fixture}" --missing)

set(fpscr_mode_generated "${MH4U_AOT_ARTIFACT_ROOT}/fpscr-mode.cpp")
set(fpscr_mode_manifest "${MH4U_AOT_ARTIFACT_ROOT}/fpscr-mode.json")
add_custom_command(OUTPUT "${fpscr_mode_generated}" "${fpscr_mode_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${fpscr_fixture}"
    --entry-descriptor 0x1008,0x10,0x03000000 --max-blocks 2
    --input-sha256 "${fpscr_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${fpscr_mode_generated}" --manifest "${fpscr_mode_manifest}"
  DEPENDS mh4u-aot-generator "${fpscr_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-fpscr-mode
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${fpscr_mode_generated}")
target_link_libraries(mh4u-aot-runner-fpscr-mode PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-fpscr-mode PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-fpscr-differential COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-fpscr-mode>" --fixture "${fpscr_fixture}")

set(signextend_fixture "${CMAKE_SOURCE_DIR}/tests/aot/signextend.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${signextend_fixture}")
file(SHA256 "${signextend_fixture}" signextend_sha)
set(signextend_generated "${MH4U_AOT_ARTIFACT_ROOT}/signextend.cpp")
set(signextend_manifest "${MH4U_AOT_ARTIFACT_ROOT}/signextend.json")
add_custom_command(OUTPUT "${signextend_generated}" "${signextend_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${signextend_fixture}"
    --input-sha256 "${signextend_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${signextend_generated}" --manifest "${signextend_manifest}"
  DEPENDS mh4u-aot-generator "${signextend_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-signextend
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${signextend_generated}")
target_link_libraries(mh4u-aot-runner-signextend PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-signextend PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-signextend-differential COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-signextend>"
  --fixture "${signextend_fixture}" --signextend)

set(andnot_fixture "${CMAKE_SOURCE_DIR}/tests/aot/andnot.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${andnot_fixture}")
file(SHA256 "${andnot_fixture}" andnot_sha)
set(andnot_generated "${MH4U_AOT_ARTIFACT_ROOT}/andnot.cpp")
set(andnot_manifest "${MH4U_AOT_ARTIFACT_ROOT}/andnot.json")
add_custom_command(OUTPUT "${andnot_generated}" "${andnot_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${andnot_fixture}"
    --input-sha256 "${andnot_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${andnot_generated}" --manifest "${andnot_manifest}"
  DEPENDS mh4u-aot-generator "${andnot_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-andnot
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${andnot_generated}")
target_link_libraries(mh4u-aot-runner-andnot PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-andnot PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-andnot-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-andnot>"
  --fixture "${andnot_fixture}" --matrix)

set(memory64_fixture "${CMAKE_SOURCE_DIR}/tests/aot/memory64.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${memory64_fixture}")
file(SHA256 "${memory64_fixture}" memory64_sha)
set(memory64_generated "${MH4U_AOT_ARTIFACT_ROOT}/memory64.cpp")
set(memory64_manifest "${MH4U_AOT_ARTIFACT_ROOT}/memory64.json")
add_custom_command(OUTPUT "${memory64_generated}" "${memory64_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${memory64_fixture}"
    --input-sha256 "${memory64_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${memory64_generated}" --manifest "${memory64_manifest}"
  DEPENDS mh4u-aot-generator "${memory64_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-memory64
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${memory64_generated}")
target_link_libraries(mh4u-aot-runner-memory64 PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-memory64 PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-memory64-differential COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-memory64>"
  --fixture "${memory64_fixture}")

set(rrx_fixture "${CMAKE_SOURCE_DIR}/tests/aot/rrx.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${rrx_fixture}")
file(SHA256 "${rrx_fixture}" rrx_sha)
set(rrx_generated "${MH4U_AOT_ARTIFACT_ROOT}/rrx.cpp")
set(rrx_manifest "${MH4U_AOT_ARTIFACT_ROOT}/rrx.json")
add_custom_command(OUTPUT "${rrx_generated}" "${rrx_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${rrx_fixture}"
    --input-sha256 "${rrx_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${rrx_generated}" --manifest "${rrx_manifest}"
  DEPENDS mh4u-aot-generator "${rrx_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-rrx
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${rrx_generated}")
target_link_libraries(mh4u-aot-runner-rrx PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-rrx PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-rrx-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-rrx>"
  --fixture "${rrx_fixture}" --matrix)

set(packed_uqsub8_fixture "${CMAKE_SOURCE_DIR}/tests/aot/packed_uqsub8.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${packed_uqsub8_fixture}")
file(SHA256 "${packed_uqsub8_fixture}" packed_uqsub8_sha)
set(packed_uqsub8_generated "${MH4U_AOT_ARTIFACT_ROOT}/packed-uqsub8.cpp")
set(packed_uqsub8_manifest "${MH4U_AOT_ARTIFACT_ROOT}/packed-uqsub8.json")
add_custom_command(OUTPUT "${packed_uqsub8_generated}" "${packed_uqsub8_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${packed_uqsub8_fixture}"
    --input-sha256 "${packed_uqsub8_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${packed_uqsub8_generated}" --manifest "${packed_uqsub8_manifest}"
  DEPENDS mh4u-aot-generator "${packed_uqsub8_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-packed-uqsub8
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${packed_uqsub8_generated}")
target_link_libraries(mh4u-aot-runner-packed-uqsub8 PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-packed-uqsub8 PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-packed-uqsub8-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-packed-uqsub8>"
  --fixture "${packed_uqsub8_fixture}" --matrix)

set(mul_fixture "${CMAKE_SOURCE_DIR}/tests/aot/mul.fixture")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${mul_fixture}")
file(SHA256 "${mul_fixture}" mul_sha)
set(mul_generated "${MH4U_AOT_ARTIFACT_ROOT}/mul.cpp")
set(mul_manifest "${MH4U_AOT_ARTIFACT_ROOT}/mul.json")
add_custom_command(OUTPUT "${mul_generated}" "${mul_manifest}"
  COMMAND "$<TARGET_FILE:mh4u-aot-generator>" --fixture "${mul_fixture}"
    --input-sha256 "${mul_sha}" --artifact-root "${CMAKE_SOURCE_DIR}/.local"
    --output "${mul_generated}" --manifest "${mul_manifest}"
  DEPENDS mh4u-aot-generator "${mul_fixture}"
  VERBATIM)
add_executable(mh4u-aot-runner-mul
  "${CMAKE_SOURCE_DIR}/tools/aot/runner.cpp" "${mul_generated}")
target_link_libraries(mh4u-aot-runner-mul PRIVATE mh4u-aot-fixture)
target_compile_options(mh4u-aot-runner-mul PRIVATE -Wall -Wextra -Werror)
add_test(NAME aot-mul-register-matrix COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_SOURCE_DIR}/tests/aot/compare.py"
  --jit "$<TARGET_FILE:mh4u-aot-jit-reference>"
  --runner "$<TARGET_FILE:mh4u-aot-runner-mul>"
  --fixture "${mul_fixture}" --matrix)

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
