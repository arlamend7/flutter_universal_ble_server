cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "universal_ble_server_plugin")
add_library(${PROJECT_NAME} SHARED
  "universal_ble_server_plugin.cpp"
  "universal_ble_server_plugin.h"
)
set_target_properties(${PROJECT_NAME} PROPERTIES
  WIN32_EXECUTABLE FALSE
  OUTPUT_NAME "universal_ble_server_plugin"
)
target_compile_definitions(${PROJECT_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PROJECT_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(${PROJECT_NAME} PRIVATE flutter flutter_wrapper_plugin)
