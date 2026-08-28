// Compile the production Header80 translation unit directly so the static
// resource gate measures the exact shared-boundary implementation used by the
// candidate and cannot drift through a duplicate synthetic definition.
#include "../src/cuda/header80_backend.cu"
