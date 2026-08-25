from pathlib import Path

path = Path("native/src/cuda/v1/header80_backend_part06.inc")
text = path.read_text(encoding="utf-8")

old = """    const bool active = index < count;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(active ? index : 0U);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    if (active) blake3_header80_words(nonce, first_pass);

    hoohash_mix_words_service(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, active, scratch);

    if (!active) return;
"""

new = """    if (index >= count) return;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    blake3_header80_words(nonce, first_pass);

    // Architecture experiment: direct per-thread HooHash. This removes the
    // shared task queue, atomicAdd and the two block-wide barriers from each
    // matrix-cell service operation while preserving the same HooHash math.
    hoohash_mix_words(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);

"""

if old not in text:
    raise SystemExit("expected share-producing service snippet not found")

patched = text.replace(old, new, 1)
path.write_text(patched, encoding="utf-8")

if "hoohash_mix_words_service(" not in text:
    raise SystemExit("baseline service path unexpectedly absent")
if "hoohash_mix_words(" not in patched:
    raise SystemExit("direct HooHash call missing after patch")

print("Applied no-barrier direct HooHash patch")
