#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

// Contract: search may return ANY qualifying nonce, selected by atomicCAS.
// No performance claims: CPU enumeration is intentionally inside this test.

static int direct_differential() {
    pepepow::Header80CudaBackend backend(0);
    pepepow::Hash256 target; target.fill(255);
    std::uint64_t tested=0, mismatches=0;
    for (unsigned header_id=0; header_id<100; ++header_id) {
        pepepow::MiningJob job;
        job.job_id="direct-100k";
        job.version=0x20004000U+header_id;
        job.ntime=0x6a673f01U+header_id;
        job.bits=0x1d0124fbU;
        for (std::size_t k=0;k<32;++k) {
            job.previous_hash[k]=static_cast<std::uint8_t>(k*17+11+header_id);
            job.merkle_root[k]=static_cast<std::uint8_t>(k*31+5+header_id*7);
        }
        for (std::uint32_t i=0;i<1000;++i) {
            const std::uint32_t nonce=i<8 ?
                std::array<std::uint32_t,8>{0,1,31,32,127,128,0xfffffffeU,0xffffffffU}[i] :
                static_cast<std::uint32_t>((header_id*1000U+i)*2654435761U);
            job.nonce=nonce;
            const auto expected=pepepow::crypto::calculate_header80_pow(pepepow::build_header80(job));
            job.nonce=0;
            const auto actual=backend.search(job,pepepow::SearchRange{nonce,1},target);
            ++tested;
            if (!actual || actual->nonce!=nonce || actual->hash!=expected) {
                ++mismatches;
                if (mismatches<=10)
                    std::cerr<<"DIRECT_MISMATCH header="<<header_id<<" nonce="<<nonce<<"\n";
            }
        }
    }
    std::cout<<"direct_headers=100\ndirect_cases="<<tested
             <<"\ndirect_mismatches="<<mismatches<<"\n";
    if (tested!=100000 || mismatches) return 3;
    std::cout<<"DIRECT_CORRECTNESS_PASS\n";
    return 0;
}

int main(int argc, char** argv) {
    try {
        if (argc==2 && std::string(argv[1])=="--direct-100000") return direct_differential();
        if (argc!=1) throw std::runtime_error("unsupported test arguments");
        pepepow::Header80CudaBackend backend(0);
        std::uint64_t cases=0, mismatches=0, cpu_hashes=0;
        const std::array<std::uint64_t,11> base_sizes{2,31,32,33,127,128,129,257,4095,4096,4097};
        const std::array<std::uint64_t,3> production_sizes{65535,65536,65537};
        const std::uint64_t working_span=16777216, tile_size=65536;
        const unsigned working_tiles=16;
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
            std::vector<std::uint64_t> sizes(base_sizes.begin(),base_sizes.end());
            if (header_id==0)
                sizes.insert(sizes.end(),production_sizes.begin(),production_sizes.end());
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
            if (header_id==0) {
                for (unsigned tile=0; tile<working_tiles; ++tile) {
                    const std::uint64_t begin=127+
                        (working_span-tile_size)*tile/(working_tiles-1);
                    const std::uint64_t count=tile_size;
                    std::vector<pepepow::Hash256> hashes;
                    hashes.reserve(count);
                    for (std::uint64_t i=0;i<count;++i) {
                        job.nonce=static_cast<std::uint32_t>(begin+i);
                        hashes.push_back(pepepow::crypto::calculate_header80_pow(pepepow::build_header80(job)));
                        ++cpu_hashes;
                    }
                    const auto minimum=*std::min_element(hashes.begin(),hashes.end());
                    if (std::count(hashes.begin(),hashes.end(),minimum)!=1)
                        throw std::runtime_error("tile oracle minimum is not unique");
                    auto below=minimum;
                    bool decremented=false;
                    for (std::size_t i=32;i-->0;) {
                        if (below[i]!=0) { --below[i]; decremented=true; break; }
                        below[i]=255;
                    }
                    if (!decremented) throw std::runtime_error("tile zero minimum cannot be decremented");
                    pepepow::Hash256 maximum; maximum.fill(255);
                    for (const auto& target:std::array<pepepow::Hash256,4>{maximum,minimum,below,maximum}) {
                        ++cases;
                        const bool expected=std::any_of(hashes.begin(),hashes.end(),
                            [&](const auto& h){return h<=target;});
                        job.nonce=0;
                        const auto result=backend.search(job,pepepow::SearchRange{begin,count},target);
                        bool ok=result.has_value()==expected;
                        if (result) {
                            const auto nonce=static_cast<std::uint64_t>(result->nonce);
                            ok=ok && nonce>=begin && nonce-begin<count;
                            if (ok) ok=result->hash==hashes[nonce-begin] && result->hash<=target;
                        }
                        if (!ok) {
                            ++mismatches;
                            std::cerr<<"WORKING_TILE_MISMATCH tile="<<tile<<" begin="<<begin
                                     <<" count="<<count<<" case="<<cases<<"\n";
                        }
                    }
                }
            }
        }
        std::cout<<"working_span="<<working_span<<"\n"
                 <<"working_tiles="<<working_tiles<<"\n"
                 <<"working_tile_size="<<tile_size<<"\n"
                 <<"batch_search_calls="<<cases<<"\n"
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
