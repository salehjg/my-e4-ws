from pystencils.types import create_type, PsVectorType, constify, deconstify
from pystencils.types.quick import Fp, SInt, UInt, Ptr

t_double = create_type("double")           # -> PsIeeeFloatType(64)
t_ptr = create_type("float * restrict")    # -> PsPointerType(float, restrict=True)
t_vec = PsVectorType(Fp(64), 4)            # SIMD type: 4 x float64
assert create_type("float64") is Fp(64)    # types are interned (cached instances)
assert constify(Fp(64)) == create_type("const double")
