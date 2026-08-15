cmake_minimum_required(VERSION 3.22.1)
project(mabusignboard)

# One tiny .so whose only job is to open /dev/ttyS1 from C.
# See serial.c for why this cannot be done from Kotlin.
add_library(mabusignboard SHARED serial.c)

find_library(log-lib log)
target_link_libraries(mabusignboard ${log-lib})
