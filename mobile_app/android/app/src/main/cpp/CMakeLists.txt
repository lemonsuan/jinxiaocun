cmake_minimum_required(VERSION 3.22.1)
project(inventory_ocr)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if (NOT ANDROID_ABI STREQUAL "arm64-v8a")
    add_library(${PROJECT_NAME} SHARED unsupported_abi_stub.cpp)
    return()
endif ()

include(FetchContent)
set(ABSL_PROPAGATE_CXX_STD ON)
set(ABSL_BUILD_TESTING OFF)
set(ABSL_ENABLE_INSTALL OFF)

FetchContent_Declare(
    abseil-cpp
    GIT_REPOSITORY https://github.com/abseil/abseil-cpp.git
    GIT_TAG 20250814.1
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(abseil-cpp)

if (CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_definitions(NDEBUG)
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -ffast-math -ftree-vectorize")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -march=armv8-a+simd+crypto")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -mtune=cortex-a76")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -flto=thin")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -funroll-loops")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -fomit-frame-pointer")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -ffunction-sections -fdata-sections")
    set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -fvisibility=hidden -fvisibility-inlines-hidden")
    set(CMAKE_SHARED_LINKER_FLAGS_RELEASE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE} -flto=thin -Wl,--gc-sections -Wl,--strip-all")
endif ()

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -O1")
endif ()

add_compile_definitions(
    LITERT_DISABLE_OPENCL_SUPPORT
    LITERT_DISABLE_VULKAN_SUPPORT
    LITERT_DISABLE_WEBGPU_SUPPORT
)

add_subdirectory("litert_cc_sdk" "litert_cc_sdk/build")

set(LITERT_CC_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_compiled_model.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_macros.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_model.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_tensor_buffer.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_opaque_options.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/litert_custom_op_kernel.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_options_lite.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_tensor_buffer_types_lite.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/options/litert_compiler_options.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/options/litert_cpu_options.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/options/litert_gpu_options.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/options/litert_runtime_options.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/internal/scoped_file.cc
    ${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include/litert/cc/internal/scoped_file_posix.cc
)

set(OCR_SOURCES
    ppocrv5_jni.cpp
    ocr_engine.cpp
    text_detector.cpp
    text_recognizer.cpp
    image_utils.cpp
    postprocess.cpp
    ${LITERT_CC_SOURCES}
)

add_library(${PROJECT_NAME} SHARED ${OCR_SOURCES})
target_include_directories(${PROJECT_NAME}
    SYSTEM PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/litert_cc_sdk/include"
)

set_source_files_properties(${LITERT_CC_SOURCES}
    PROPERTIES COMPILE_OPTIONS "-w"
)

set(INVENTORY_OCR_LIBS
    litert_cc_api
    android
    log
    jnigraphics
    absl::span
    absl::flat_hash_map
    absl::strings
    absl::status
    absl::statusor
    absl::cleanup
    absl::log
    absl::log_internal_check_op
    absl::log_internal_message
    absl::algorithm_container
    absl::any_invocable
    absl::string_view
)

if (TARGET litert_opencl)
    list(APPEND INVENTORY_OCR_LIBS litert_opencl)
endif ()

target_link_libraries(${PROJECT_NAME} ${INVENTORY_OCR_LIBS})
