cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "pm25_camera.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

target_link_libraries(${BINARY_NAME} PRIVATE mfplat mf mfreadwrite mfuuid ole32 bcrypt)


# Optional ONNX Runtime CPU SDK. The default PoC still builds without a model
# or this external SDK and cannot pass the validated-device gate.
set(PM25_ORT_ROOT "$ENV{PM25_ORT_ROOT}" CACHE PATH "ONNX Runtime Windows CPU SDK root")
if(PM25_ORT_ROOT)
  find_path(PM25_ORT_INCLUDE onnxruntime_cxx_api.h PATHS "${PM25_ORT_ROOT}/include" NO_DEFAULT_PATH)
  find_library(PM25_ORT_LIB onnxruntime PATHS "${PM25_ORT_ROOT}/lib" NO_DEFAULT_PATH)
  find_file(PM25_ORT_DLL onnxruntime.dll PATHS "${PM25_ORT_ROOT}/lib" NO_DEFAULT_PATH)
  if(NOT PM25_ORT_INCLUDE OR NOT PM25_ORT_LIB OR NOT PM25_ORT_DLL)
    message(FATAL_ERROR "PM25_ORT_ROOT must contain include/onnxruntime_cxx_api.h and lib/onnxruntime.lib/.dll")
  endif()
  target_sources(${BINARY_NAME} PRIVATE "pm25_rec_model.cpp")
  target_include_directories(${BINARY_NAME} SYSTEM PRIVATE "${PM25_ORT_INCLUDE}")
  target_compile_definitions(${BINARY_NAME} PRIVATE PM25_WITH_ORT=1)
  target_link_libraries(${BINARY_NAME} PRIVATE "${PM25_ORT_LIB}")
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${PM25_ORT_DLL}" "$<TARGET_FILE_DIR:${BINARY_NAME}>")
  install(FILES "${PM25_ORT_DLL}" DESTINATION "." COMPONENT Runtime)
  set(PM25_WINDOWS_ASSETS "$ENV{PM25_WINDOWS_ASSETS}" CACHE PATH "Verified offline REC and UVC profile assets")
  if(PM25_WINDOWS_ASSETS)
    foreach(asset rec.onnx rec.conf rec.dict uvc.conf)
      if(NOT EXISTS "${PM25_WINDOWS_ASSETS}/${asset}")
        message(FATAL_ERROR "Missing offline asset: ${asset}")
      endif()
      install(FILES "${PM25_WINDOWS_ASSETS}/${asset}" DESTINATION "." COMPONENT Runtime)
    endforeach()
  endif()
endif()
