from pystencils.backend.transformations import (
    CanonicalizeSymbols, AxisExpansion, HoistIterationInvariantDeclarations)

cube = factory.cube_from_ispace(ispace, body)      # the whole space as an axes cube
canonicalize = CanonicalizeSymbols(ctx)
cube = canonicalize(cube)
