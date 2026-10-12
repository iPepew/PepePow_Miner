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
    unsigned mask; int slot;
    bool await_ready() const noexcept { return false; }
    void await_suspend(std::coroutine_handle<Task::promise_type> h) const noexcept {
        h.promise().event=slot;h.promise().mask=mask;
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
static double safe_nonlinear(double x) { return pepepow::crypto::for_complex(x); }
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
        const std::array<unsigned,8> masks{1U,3U,0x1ffffU,0x7fffffffU,0xffffffffU,0x80000001U,0xaaaaaaaaU,0x01010101U};
        std::uint64_t hashes=0, batches=0, cells=0;
        for(unsigned header=0;header<8;++header) {
            Hash256 seed{};
            for(unsigned i=0;i<32;++i) seed[i]=static_cast<std::uint8_t>(header*71U+i*17U);
            const auto matrix=generate_hoohash_matrix(seed);
            std::array<double,4096> flat{};
            std::array<double,4096*16> scaled{};
            for(unsigned cell=0;cell<4096;++cell) {
                flat[cell]=matrix[cell/64][cell%64];
                for(unsigned nib=0;nib<16;++nib) scaled[cell*16+nib]=flat[cell]*0.0001*static_cast<double>(nib);
            }
            for(unsigned mask:masks) for(int order=0;order<3;++order) {
                active_mask=mask;
                std::array<std::array<std::uint32_t,8>,32> inputs{},outputs{};
                std::array<Hash256,32> references{};
                std::array<std::uint32_t,32> nonces{};
                std::array<Task,32> tasks{};
                auto rng=make_xoshiro(seed);
                for(int lane=0;lane<32;++lane) if(mask&(1U<<lane)) {
                    expected_trace[lane].clear();actual_trace[lane].clear();
                    Hash256 first{};
                    for(unsigned i=0;i<32;++i) first[i]=static_cast<std::uint8_t>(rng.next());
                    if(lane%8==0) first.fill(0);
                    if(lane%8==1) first.fill(255);
                    if(lane%8==2) for(unsigned i=0;i<32;++i) first[i]=(i&1)?0x0f:0xf0;
                    if(lane%8==3) for(unsigned i=0;i<32;++i) first[i]=static_cast<std::uint8_t>(1U<<(i%8));
                    for(unsigned i=0;i<32;++i) inputs[lane][i/4]|=std::uint32_t(first[i])<<((i%4)*8);
                    nonces[lane]=(header&1)?0xffffffffU-static_cast<unsigned>(lane):0x7ffffff0U+static_cast<unsigned>(lane);
                    current_lane=lane;
                    references[lane]=hoohash_matrix_mix(matrix,first,nonces[lane]);
                    tasks[lane]=hoohash_mix_words_hotrun8_reconverged(flat.data(),scaled.data(),nonces[lane],inputs[lane].data(),outputs[lane].data());
                }
                dispatch(tasks,mask,order);
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
        std::cout<<"HOST_RECONVERGENCE_RESULT {\"status\":\"PASS\",\"batches\":"<<batches<<",\"hashes\":"<<hashes<<",\"cell_trace_comparisons\":"<<cells<<",\"barrier_arrivals\":"<<observed_barriers<<",\"vote_arrivals\":"<<observed_votes<<",\"finished_lane_vote_arrivals\":"<<finished_lane_votes<<",\"mismatches\":0,\"gpu_executed\":false,\"host_libm_only\":true}\n";
    } catch(const std::exception& e) { std::cerr<<"HOST_RECONVERGENCE_FAIL "<<e.what()<<"\n";return 1; }
}
