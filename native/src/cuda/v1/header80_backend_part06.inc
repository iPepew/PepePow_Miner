    const bool active = index < count;
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
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) {
            result->hash_words[i] = final_hash[i];
        }
    }
}

#include "../warp_pair128_production.inc"

} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index) : device_index_(device_index) {}

Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr || device_matrix_ != nullptr ||
        device_scaled_nibble_ != nullptr || device_work_ != nullptr) {
        cudaSetDevice(device_index_);
    }
    if (device_result_ != nullptr) {
        cudaFree(device_result_);
        device_result_ = nullptr;
    }
    if (device_matrix_ != nullptr) {
        cudaFree(device_matrix_);
        device_matrix_ = nullptr;
    }
    if (device_scaled_nibble_ != nullptr) {
        cudaFree(device_scaled_nibble_);
        device_scaled_nibble_ = nullptr;
    }
    if (device_work_ != nullptr) {
        cudaFree(device_work_);
        device_work_ = nullptr;
        device_work_capacity_ = 0;
    }
}

#if PEPEPOW_CUDA_SPLIT_PIPELINE
std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-split-pipeline"; }
#else
std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-monolithic-pipeline"; }
#endif

std::vector<DeviceInfo> Header80CudaBackend::enumerate_devices() const {
    int count = 0;
    check_cuda_header80(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
    std::vector<DeviceInfo> devices;
    devices.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        cudaDeviceProp properties{};
        check_cuda_header80(cudaGetDeviceProperties(&properties, index), "cudaGetDeviceProperties");
        devices.push_back(DeviceInfo{index, properties.name, properties.major,
                                     properties.minor, properties.totalGlobalMem});
    }
    return devices;
}

std::optional<ShareCandidate> Header80CudaBackend::search(
    const MiningJob& job,
    SearchRange range,
    std::span<const std::uint8_t, 32> target) {
    if (range.count == 0 || range.begin > std::numeric_limits<std::uint32_t>::max()) {
        return std::nullopt;
    }

    const std::uint64_t max_count = 0x100000000ULL - range.begin;
    const std::size_t count = static_cast<std::size_t>(std::min(range.count, max_count));
    if (count == 0) return std::nullopt;

    MiningJob base_job = job;
    base_job.nonce = 0U;
    const Header80 header = build_header80(base_job);
    Header80 masked_header = header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const crypto::Hash256 matrix_seed = crypto::blake3_hash(masked_header);

    check_cuda_header80(cudaSetDevice(device_index_), "cudaSetDevice(header80)");

    static thread_local bool header_cached = false;
    static thread_local int cached_device = -1;
    static thread_local crypto::Hash256 cached_matrix_seed{};
    if (device_matrix_ == nullptr || !header_cached || cached_device != device_index_ || cached_matrix_seed != matrix_seed) {
        const crypto::HoohashMatrix matrix = crypto::generate_hoohash_matrix(matrix_seed);
        if (device_matrix_ == nullptr) {
            check_cuda_header80(cudaMalloc(&device_matrix_, kMatrixElements * sizeof(double)),
                                "cudaMalloc(header80 matrix)");
        }
        check_cuda_header80(
            cudaMemcpy(device_matrix_, matrix.data()->data(),
                       kMatrixElements * sizeof(double), cudaMemcpyHostToDevice),
            "cudaMemcpy(header80 matrix)");
#if PEPEPOW_CUDA_SCALED_MATRIX || PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        std::array<double, kMatrixElements> scaled_matrix{};
        const double* matrix_values = matrix.data()->data();
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            scaled_matrix[cell] = matrix_values[cell] * 0.0001;
        }
#endif
#if PEPEPOW_CUDA_SCALED_MATRIX
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80ScaledMatrix, scaled_matrix.data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 scaled matrix)");
#endif
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        if (device_scaled_nibble_ == nullptr) {
            check_cuda_header80(
                cudaMalloc(&device_scaled_nibble_, kScaledNibbleElements * sizeof(double)),
                "cudaMalloc(header80 scaled nibble table)");
        }
        std::vector<double> scaled_nibble(kScaledNibbleElements);
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            const double scaled = scaled_matrix[cell];
            for (std::uint32_t nibble = 0; nibble < 16U; ++nibble) {
                scaled_nibble[cell * 16U + nibble] =
                    scaled * static_cast<double>(nibble);
            }
        }
        check_cuda_header80(
            cudaMemcpy(device_scaled_nibble_, scaled_nibble.data(),
                       kScaledNibbleElements * sizeof(double), cudaMemcpyHostToDevice),
            "cudaMemcpy(header80 scaled nibble table)");
#endif
        const auto midstate = first_block_midstate(header);
        const std::array<std::uint32_t, 3> tail_words{
            host_load_le32(header.data() + 64),
            host_load_le32(header.data() + 68),
            host_load_le32(header.data() + 72)};
        check_cuda_header80(
