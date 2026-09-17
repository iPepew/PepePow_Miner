#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

// Contract: search may return ANY qualifying nonce, selected by atomicCAS.
// No performance claims: CPU enumeration is intentionally inside this test.
int main() {
    try {
        pepepow::Header80CudaBackend backend(0);
        std::uint64_t cases=0, mismatches=0, cpu_hashes=0;
        const std::array<std::uint64_t,8> sizes{2,31,32,33,127,128,129,257};
        for (unsigned header_id=0; header_id<3; ++header_id) {
            pepepow::MiningJob job;
            job.job_id="batch-correctness";
            job.version=0x20004000U+header_id;
            job.ntime=0x6a673f01U+header_id;
            job.bits=0x1d0124fbU;
            for (std::size_t i=0;i<32;++i) {
                job.previous_hash[i]=static_cast<std::uint8_t>(i*17+11+header_id);
                job.merkle_root[i]=static_cast<std::uint8_t>(i*31+5+header_id*7);
            }
            for (auto count:sizes) {
                const std::uint64_t begin=header_id==2 ? 0x100000000ULL-count : 127+header_id*1024;
                std::vector<pepepow::Hash256> hashes;
                for (std::uint64_t i=0;i<count;++i) {
                    job.nonce=static_cast<std::uint32_t>(begin+i);
                    hashes.push_back(pepepow::crypto::calculate_header80_pow(pepepow::build_header80(job)));
                    ++cpu_hashes;
                }
                const auto minimum=*std::min_element(hashes.begin(),hashes.end());
                if (std::count(hashes.begin(),hashes.end(),minimum)!=1)
                    throw std::runtime_error("oracle minimum is not unique");
                auto below=minimum;
                bool decremented=false;
                for (std::size_t i=32;i-->0;) {
                    if (below[i]!=0) { --below[i]; decremented=true; break; }
                    below[i]=255;
                }
                if (!decremented) throw std::runtime_error("zero minimum cannot be decremented");
                pepepow::Hash256 maximum; maximum.fill(255);
                // Repeat maximum after empty-result search to detect stale result state.
                for (const auto& target:std::array<pepepow::Hash256,4>{maximum,minimum,below,maximum}) {
                    ++cases;
                    const bool expected=std::any_of(hashes.begin(),hashes.end(),
                        [&](const auto& h){return h<=target;});
                    job.nonce=0; // SearchRange, not this field, specifies the range.
                    const auto result=backend.search(job,pepepow::SearchRange{begin,count},target);
                    bool ok=result.has_value()==expected;
                    if (result) {
                        const auto nonce=static_cast<std::uint64_t>(result->nonce);
                        ok=ok && nonce>=begin && nonce-begin<count;
                        if (ok) ok=result->hash==hashes[nonce-begin] && result->hash<=target;
                    }
                    if (!ok) {
                        ++mismatches;
                        std::cerr<<"BATCH_MISMATCH header="<<header_id<<" begin="<<begin
                                 <<" count="<<count<<" case="<<cases<<"\n";
                    }
                }
            }
        }
        std::cout<<"batch_search_calls="<<cases<<"\n"
                 <<"batch_cpu_hashes="<<cpu_hashes<<"\n"
                 <<"batch_mismatches="<<mismatches<<"\n";
        if (mismatches) return 3;
        std::cout<<"BATCH_CORRECTNESS_PASS\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr<<"BATCH_CORRECTNESS_FAIL "<<e.what()<<"\n";
        return 1;
    }
}
