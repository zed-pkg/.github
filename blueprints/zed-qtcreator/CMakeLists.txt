cmake_minimum_required(VERSION 3.20)
project(ZedQtCreatorCore VERSION 0.1.0 LANGUAGES CXX)

option(BUILD_TESTING "Build core conformance tests" ON)

add_library(zed_qtcreator_core src/zed_inspector.cpp)
target_include_directories(zed_qtcreator_core PUBLIC include)
target_compile_features(zed_qtcreator_core PUBLIC cxx_std_20)

if(BUILD_TESTING)
  include(CTest)
  add_executable(zed_qtcreator_core_tests tests/test_zed_inspector.cpp)
  target_link_libraries(zed_qtcreator_core_tests PRIVATE zed_qtcreator_core)
  add_test(NAME zed_qtcreator_core_tests COMMAND zed_qtcreator_core_tests)
endif()
