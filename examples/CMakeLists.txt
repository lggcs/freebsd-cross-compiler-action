cmake_minimum_required(VERSION 3.20)
project(freebsd-cross-compile-test LANGUAGES C CXX)

add_executable(hello-cmake hello.c)
add_executable(hello-cmake-cpp hello.cpp)