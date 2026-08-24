# PepeW Miner v1.0.6

PepeW Miner v1.0.6 adds native NVIDIA Tesla V100 / Volta (`sm_70`) support to the HooHash V110 miner line based on the verified v1.0.4 pool/consensus behavior.

## What's new

- Native CUDA `sm_70` build for NVIDIA Tesla V100 / Volta.
- Tested on Tesla V100-SXM2-16GB.
- Preserves the proven HooHash V110 pool/consensus behavior from v1.0.4.
- Uses the verified V100 `service736` geometry.
- HiveOS package included.
- HiveOS telemetry reports `ar=[accepted,rejected]` and version `1.0.6`.
- Professional PepeW console UI retained, including `PepeW — твоя монета. Твои правила.`

## Verified Tesla V100 result

Hardware: NVIDIA Tesla V100-SXM2-16GB (`sm_70`)

Verified real-pool result:

- Average hashrate: **4.072 MH/s**
- Minimum: **4.051 MH/s**
- Maximum: **4.114 MH/s**
- Accepted shares: **75**
- Rejected shares: **0**
- Status: **PASS**

The V100 build is considered verified because real Accepted shares were observed on the pool. Hashrate alone is not used as a correctness criterion.

## HooHash / Stratum contract

- HooHash V110
- `matrix_seed=BLAKE3_MASKED_HEADER`
- `header_nonce=BE32`
- `mix_nonce=LE32`
- `submit_nonce=LE_HEX`
- `share_target=NBITS_DIV_DIFFICULTY`
- `cuda-header80-monolithic-pipeline`

## HiveOS

Install URL:

`https://github.com/iPepew/PepePow_Miner/releases/download/v1.0.6/PepeW-Miner-HiveOS.tar.gz`

Algorithm: `hoohash`

Coin: `PEPEW`

## Notes

This release adds a dedicated Tesla V100 / Volta build. The existing v1.0.4 release remains the reference for previously supported GPU families. Further V100 performance work continues toward higher hashrate while preserving real Accepted shares and consensus correctness.
