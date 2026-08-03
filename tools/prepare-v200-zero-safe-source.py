from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: prepare-v200-zero-safe-source.py SOURCE")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    if (sw_state_is_cold(sw)) {
'''
new = r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    const bool cold = sw_state_is_cold(sw);
    // A zero nibble contributes exactly zero in the cold state. The sum is
    // unchanged, therefore sw remains cold and recomputing the fraction is
    // consensus-equivalent. This is a fresh, minimal implementation of the
    // earlier zero-elision idea without touching indexing or memory state.
    if (cold && nibble == 0U) return;
    if (cold) {
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"ERROR: accumulate signature count={count}")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
