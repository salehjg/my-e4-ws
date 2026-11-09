#define PY_SSIZE_T_CLEAN
#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
#include <Python.h>
#include <numpy/ndarrayobject.h>
#include <array>
#include <vector>
#include <string>
#include <sstream>
#include <utility>
#include <initializer_list>
#include "pystencils_runtime/generic_cpu.hpp"
#include <cmath>
#include <limits>
#define RESTRICT __restrict__
namespace internal {
