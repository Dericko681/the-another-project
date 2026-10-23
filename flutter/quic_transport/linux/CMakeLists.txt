# Flutter tooling requires CMake 3.10+; do not raise this or some customers
# will fail to compile.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "quic_transport")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../rust quic_transport "")

set(quic_transport_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
