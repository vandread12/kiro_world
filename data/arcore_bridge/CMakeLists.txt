cmake_minimum_required(VERSION 3.18)
project(arcore_bridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ARCore Native SDK
set(ARCORE_SDK_PATH "" CACHE PATH "Path to ARCore Native SDK")

find_library(ARCORE_LIB NAMES arcore PATHS ${ARCORE_SDK_PATH}/libs)

# Shared memory support
find_library(ASHMEM_LIB NAMES android PATHS /system/lib /system/lib64)

add_library(arcore_bridge SHARED
    arcore_bridge.cpp
    arcore_bridge.h
)

target_include_directories(arcore_bridge PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${ARCORE_SDK_PATH}/include
)

target_link_libraries(arcore_bridge
    ${ARCORE_LIB}
    ${ASHMEM_LIB}
    log
    android
)