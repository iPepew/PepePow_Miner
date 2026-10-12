#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <coroutine>
#include <cstdint>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <vector>
#ifdef PEPEW_HOST_HEADER80_FIXTURES
#include <blake3.h>
#include "pepepow/core/header_builder.hpp"
static std::array<std::uint8_t,32> hash_header(const pepepow::Header80& bytes) {
    std::array<std::uint8_t,32> out{}; blake3_hasher h;
    blake3_hasher_init(&h);blake3_hasher_update(&h,bytes.data(),bytes.size());blake3_hasher_finalize(&h,out.data(),out.size());return out;
}
#endif

struct Event {
    std::uint64_t sum_bits, sw_bits;
    bool cold;
    bool operator==(const Event&) const = default;
};
static std::array<std::vector<Event>,32> expected_trace, actual_trace;
static int current_lane=0;
static unsigned active_mask=0;
static bool collective_vote=false;
static std::uint64_t observed_votes=0, observed_barriers=0, finished_lane_votes=0;
static std::array<std::uint64_t,33> frontier_hist{}, full_warp_hist{};
static std::uint64_t nonlinear_calls=0;
static void record_reference(std::size_t i,std::size_t j,double sum,double sw) {
    if (expected_trace[current_lane].size()!=i*64+j) throw std::runtime_error("reference cell order");
    expected_trace[current_lane].push_back({std::bit_cast<std::uint64_t>(sum),std::bit_cast<std::uint64_t>(sw),sw<=0.02});
}

// @REFERENCE@

struct Task {
    struct promise_type {
        int event=-1;
        unsigned mask=0;
        bool vote=false;
        bool pending=false;
        std::exception_ptr error;
        Task get_return_object() { return Task{std::coroutine_handle<promise_type>::from_promise(*this)}; }
        std::suspend_always initial_suspend() { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { error=std::current_exception(); }
    };
    std::coroutine_handle<promise_type> h;
};
struct SyncAwaiter {
    unsigned mask; int slot; bool pending=false;
    bool await_ready() const noexcept { return false; }
    void await_suspend(std::coroutine_handle<Task::promise_type> h) const noexcept {
        h.promise().event=slot;h.promise().mask=mask;h.promise().pending=pending;
    }
    void await_resume() const noexcept {}
};
struct VoteAwaiter {
    unsigned mask; bool unfinished;
    bool await_ready() const noexcept { return false; }
    void await_suspend(std::coroutine_handle<Task::promise_type> h) const noexcept {
        h.promise().event=2;h.promise().mask=mask;h.promise().vote=unfinished;
    }
    bool await_resume() const noexcept { return collective_vote; }
};
#define __device__
#define __forceinline__ inline
static unsigned long long __double2ull_rd(double x) {
    if(!std::isfinite(x) || x<0.0 || x>=0x1.0p64) throw std::runtime_error("SW intrinsic host domain");
    return static_cast<unsigned long long>(x);
}
static void trace_gpu_sw(double sum,bool cold) {
    const double sw=sum/1024.0-std::floor(sum/1024.0);
    actual_trace[current_lane].push_back({std::bit_cast<std::uint64_t>(sum),std::bit_cast<std::uint64_t>(sw),cold});
}
// @SW_HELPERS@
static std::uint32_t byte_swap32(std::uint32_t x) { return __builtin_bswap32(x); }
static double u32_to_double_exact(std::uint32_t x) { return static_cast<double>(x); }
static double nibble_to_double(std::uint32_t x) { return static_cast<double>(x&15U); }
static std::uint64_t positive_double_to_u64_rz(double x) { return static_cast<std::uint64_t>(x); }
static double safe_nonlinear(double x) { ++nonlinear_calls; return pepepow::crypto::for_complex(x); }
template<class T> static T __ldg(const T* p) { return *p; }
#define __device__
#define __forceinline__ inline
#define PEPEPOW_CUDA_SCALED_NIBBLE_TABLE 1
#define PEPEPOW_CUDA_SCALED_MATRIX 0
// @HELPERS@
// @CANDIDATE@

static void dispatch(std::array<Task,32>& tasks,unsigned mask,int order) {
    std::vector<int> lanes;
    for(int i=0;i<32;++i) if(mask&(1U<<i)) lanes.push_back(i);
    for(int phase=0;phase<15000;++phase) {
        auto execution=lanes;
        if(order==1) std::reverse(execution.begin(),execution.end());
        if(order==2) std::rotate(execution.begin(),execution.begin()+(phase%execution.size()),execution.end());
        int completed=0;
        for(int lane:execution) {
            current_lane=lane;
            auto h=tasks[lane].h;
            h.resume();
            if(h.promise().error) std::rethrow_exception(h.promise().error);
            completed+=h.done();
        }
        if(completed) {
            if(completed!=static_cast<int>(lanes.size())) throw std::runtime_error("early lane completion before cohort");
            return;
        }
        int kind=tasks[lanes[0]].h.promise().event;
        if(kind!=phase%3) throw std::runtime_error("collective slot order");
        if(kind==0) {
            unsigned pending=0;
            for(int lane:lanes) pending+=tasks[lane].h.promise().pending;
            ++frontier_hist[pending];
            if(mask==0xffffffffU) ++full_warp_hist[pending];
        }
        collective_vote=false;
        for(int lane:lanes) {
            auto& p=tasks[lane].h.promise();
            if(p.mask!=mask || p.event!=kind) throw std::runtime_error("inconsistent member mask or collective slot");
            if(kind==2) {
                collective_vote|=p.vote;
                ++observed_votes;
                if(!p.vote) ++finished_lane_votes;
            } else ++observed_barriers;
        }
    }
    throw std::runtime_error("collective completion bound exceeded");
}
int main() {
    try {
        using namespace pepepow::crypto;
#ifdef PEPEW_HOST_HEADER80_FIXTURES
        std::array<std::uint8_t,32> empty{};blake3_hasher kat;
        blake3_hasher_init(&kat);blake3_hasher_finalize(&kat,empty.data(),empty.size());
        const std::array<std::uint8_t,32> expected_empty{0xaf,0x13,0x49,0xb9,0xf5,0xf9,0xa1,0xa6,0xa0,0x40,0x4d,0xea,0x36,0xdc,0xc9,0x49,0x9b,0xcb,0x25,0xc9,0xad,0xc1,0x12,0xb7,0xcc,0x9a,0x93,0xca,0xe4,0x1f,0x32,0x62};
        if(empty!=expected_empty) throw std::runtime_error("BLAKE3 official empty KAT");
#endif
        const std::array<unsigned,8> masks{1U,3U,0x1ffffU,0x7fffffffU,0xffffffffU,0x80000001U,0xaaaaaaaaU,0x01010101U};
        std::uint64_t hashes=0, batches=0, cells=0;
        std::array<std::uint64_t,33> order0_hist{};
        for(unsigned header=0;header<8;++header) {
            Hash256 seed{};
            for(unsigned i=0;i<32;++i) seed[i]=static_cast<std::uint8_t>(header*71U+i*17U);
#ifdef PEPEW_HOST_HEADER80_FIXTURES
            pepepow::MiningJob job{};
            job.version=0x20004000U+header;job.ntime=0x6a673f01U+header;job.bits=0x1d0124fbU;
            for(unsigned i=0;i<32;++i) {job.previous_hash[i]=static_cast<std::uint8_t>(i*17U+11U+header);job.merkle_root[i]=static_cast<std::uint8_t>(i*31U+5U+header*7U);}
            job.nonce=0;seed=hash_header(pepepow::build_header80(job));
#endif
            const auto matrix=generate_hoohash_matrix(seed);
            std::array<double,4096> flat{};
            std::array<double,4096*16> scaled{};
            for(unsigned cell=0;cell<4096;++cell) {
                flat[cell]=matrix[cell/64][cell%64];
                for(unsigned nib=0;nib<16;++nib) scaled[cell*16+nib]=flat[cell]*0.0001*static_cast<double>(nib);
            }
            for(unsigned mask:masks) for(int order=0;order<3;++order) {
                active_mask=mask;
                const auto hist_before=frontier_hist;
                std::array<std::array<std::uint32_t,8>,32> inputs{},outputs{};
                std::array<Hash256,32> references{};
                std::array<std::uint32_t,32> nonces{};
                std::array<Task,32> tasks{};
                auto rng=make_xoshiro(seed);
                for(int lane=0;lane<32;++lane) if(mask&(1U<<lane)) {
                    expected_trace[lane].clear();actual_trace[lane].clear();
                    Hash256 first{};
                    for(unsigned i=0;i<32;++i) first[i]=static_cast<std::uint8_t>(rng.next());
#ifdef PEPEW_HOST_HEADER80_FIXTURES
                    job.nonce=header==6?0x7ffffff0U+static_cast<unsigned>(lane):(header==7?0xffffffe0U+static_cast<unsigned>(lane):65536U+header*1024U+static_cast<unsigned>(lane));
                    const auto wire=pepepow::build_header80(job);
                    first=hash_header(wire);
                    nonces[lane]=std::uint32_t(wire[76])|(std::uint32_t(wire[77])<<8)|(std::uint32_t(wire[78])<<16)|(std::uint32_t(wire[79])<<24);
                    if(nonces[lane]!=__builtin_bswap32(job.nonce)) throw std::runtime_error("Header80 nonce wire/mix contract");
#else
                    if(lane%8==0) first.fill(0);
                    if(lane%8==1) first.fill(255);
                    if(lane%8==2) for(unsigned i=0;i<32;++i) first[i]=(i&1)?0x0f:0xf0;
                    if(lane%8==3) for(unsigned i=0;i<32;++i) first[i]=static_cast<std::uint8_t>(1U<<(i%8));
                    nonces[lane]=(header&1)?0xffffffffU-static_cast<unsigned>(lane):0x7ffffff0U+static_cast<unsigned>(lane);
#endif
                    for(unsigned i=0;i<32;++i) inputs[lane][i/4]|=std::uint32_t(first[i])<<((i%4)*8);
                    current_lane=lane;
                    references[lane]=hoohash_matrix_mix(matrix,first,nonces[lane]);
                    tasks[lane]=hoohash_mix_words_hotrun8_reconverged(flat.data(),scaled.data(),nonces[lane],inputs[lane].data(),outputs[lane].data());
                }
                dispatch(tasks,mask,order);
                std::array<std::uint64_t,33> delta{};
                for(unsigned i=0;i<=32;++i) delta[i]=frontier_hist[i]-hist_before[i];
                if(order==0) order0_hist=delta;
                else if(delta!=order0_hist) throw std::runtime_error("frontier order invariance");
                for(int lane=0;lane<32;++lane) if(mask&(1U<<lane)) {
                    tasks[lane].h.destroy();
                    if(actual_trace[lane].size()!=4096 || actual_trace[lane]!=expected_trace[lane]) throw std::runtime_error("per-cell FP64/SW trace mismatch");
                    for(unsigned i=0;i<32;++i)
                        if(static_cast<std::uint8_t>(outputs[lane][i/4]>>((i%4)*8))!=references[lane][i]) throw std::runtime_error("mixed output mismatch");
                    ++hashes;cells+=4096;
                }
                ++batches;
            }
        }
        if(batches!=192 || hashes!=2520 || cells!=10321920 || !finished_lane_votes) throw std::runtime_error("coverage contract");
        std::uint64_t observed_pending=0;
        for(unsigned i=0;i<=32;++i) observed_pending+=i*frontier_hist[i];
        if(observed_pending!=nonlinear_calls) throw std::runtime_error("frontier pending-call conservation");
        std::cout<<"HOST_RECONVERGENCE_RESULT {\"status\":\"PASS\",\"batches\":"<<batches<<",\"hashes\":"<<hashes<<",\"cell_trace_comparisons\":"<<cells<<",\"barrier_arrivals\":"<<observed_barriers<<",\"vote_arrivals\":"<<observed_votes<<",\"finished_lane_vote_arrivals\":"<<finished_lane_votes<<",\"mismatches\":0,\"gpu_executed\":false,\"host_libm_only\":true,\"nonlinear_calls\":"<<nonlinear_calls<<",\"frontier_order_invariance\":true,\"frontier_pending_conservation\":true,\"frontier_histogram\":[";
        for(unsigned i=0;i<=32;++i) std::cout<<(i?",":"")<<frontier_hist[i];
        std::cout<<"],\"full_warp_frontier_histogram\":[";
        for(unsigned i=0;i<=32;++i) std::cout<<(i?",":"")<<full_warp_hist[i];
        std::cout<<"]}\n";
    } catch(const std::exception& e) { std::cerr<<"HOST_RECONVERGENCE_FAIL "<<e.what()<<"\n";return 1; }
}
