#include "miner/cuda/miner.h"

#include "miner/common/constants.h"

#include <boost/assert.hpp>
#include <boost/log/trivial.hpp>
#include <cgbn/cgbn.h>
#include <gmpxx.h>

// NEEDS TO BE INCLUDED AFTER CGBN AND GMP
#include "cu_helpers.h"

#include <cassert>
#include <iostream>
#include <vector>

using namespace miner::common;
using namespace miner::cuda;

CudaMiner::CudaMiner(int device, const CudaMinerOptions &options)
    : device_(device), options_(options), initialized_(false)
{
}

CudaMiner::~CudaMiner()
{
}

namespace kernel
{

static const uint32_t BIT_SIZE = 512;
static const uint32_t C_SIZE = 219;

typedef cgbn_mem_t<BIT_SIZE> bn_mem_t;

__constant__ bn_mem_t global_mimc_p;
__constant__ bn_mem_t global_mimc_c[C_SIZE];

struct MimcParams
{
    bn_mem_t P;
    bn_mem_t *C;
    std::size_t C_size;
};

struct CudaWorkItem
{
    int64_t x;
    int64_t y;
    bool is_planet;
    bn_mem_t hash;
};

template <uint32_t tpi> struct BnParams
{
    static const uint32_t TPI = tpi; // GCBN threads per intstance.
};

void to_mpz(mpz_t r, const bn_mem_t &x)
{
    mpz_import(r, BIT_SIZE / 32, -1, sizeof(uint32_t), 0, 0, x._limbs);
}

void from_mpz(mpz_srcptr s, bn_mem_t &n)
{
    uint32_t count = BIT_SIZE / 32;
    uint32_t *x = n._limbs;
    size_t words;

    if (mpz_sizeinbase(s, 2) > count * 32)
    {
        fprintf(stderr, "from_mpz failed -- result does not fit\n");
        exit(1);
    }

    mpz_export(x, &words, -1, sizeof(uint32_t), 0, 0, s);
    while (words < count)
    {
        x[words++] = 0;
    }
}

template <class env_t, class bn_t = typename env_t::cgbn_t>
__device__ __forceinline__ void wrap_coordinate(env_t &env, bn_t &c_bn, int64_t c, const bn_t &p)
{
    typename env_t::cgbn_t n, m;
    if (c >= 0)
    {
        env.set_ui32(n, c);
        env.set(c_bn, n);
        return;
    }
    env.set_ui32(m, -c);
    env.sub(n, p, m);
    env.set(c_bn, n);
}

template <class env_t, class bn_t = typename env_t::cgbn_t>
__device__ __forceinline__ void field_add(env_t &env, bn_t &r, const bn_t &a, const bn_t &b, bn_t &t, const bn_t &p)
{
    env.add(r, a, b);
    while (env.compare(r, p) > 0) {
        env.sub(r, r, p);
    }
}

template <class env_t, class bn_t = typename env_t::cgbn_t>
__device__ __forceinline__ void field_mul(env_t &env, bn_t &r, const bn_t &a, const bn_t &b, bn_t &t, const bn_t &p)
{
    env.mul(r, a, b);
    env.rem(r, r, p);
}

template <class env_t, class bn_t = typename env_t::cgbn_t>
__device__ __forceinline__ void fifth_power(env_t &env, bn_t &r, const bn_t &n, bn_t &s, bn_t &f, bn_t &t,
                                            const bn_t &p)
{
    field_mul(env, s, n, n, t, p);
    field_mul(env, f, s, s, t, p);
    field_mul(env, r, f, n, t, p);
}

template <class env_t, class bn_t = typename env_t::cgbn_t> class Sponge
{
  public:
    __device__ void reset(env_t &env)
    {
        env.set_ui32(l_, 0);
        env.set_ui32(r_, 0);
    }

    __device__ void inject(env_t &env, const bn_t &x, const bn_t &P)
    {
        field_add(env, l_, l_, x, t0_, P);
    }

    __device__ void mix(env_t &env, const bn_t &key, const bn_t *C, std::size_t C_size, const bn_t &P)
    {
        for (uint32_t j = 0; j < C_size; ++j)
        {
            field_add(env, t0_, key, l_, t1_, P);
            field_add(env, t1_, t0_, C[j], t2_, P);
            fifth_power(env, t0_, t1_, t2_, t3_, t4_, P);
            field_add(env, t1_, t0_, r_, t2_, P);
            env.set(r_, l_);
            env.set(l_, t1_);
        }
        field_add(env, t0_, key, l_, t2_, P);
        fifth_power(env, t1_, t0_, t2_, t3_, t4_, P);
        field_add(env, t0_, t1_, r_, t2_, P);
        env.set(r_, t0_);
    }

    __device__ void save(env_t &env)
    {
        env.set(snap_l_, l_);
        env.set(snap_r_, r_);
    }

    __device__ void restore(env_t &env)
    {
        env.set(l_, snap_l_);
        env.set(r_, snap_r_);
    }

    __device__ void result(env_t &env, bn_t &out)
    {
        env.set(out, l_);
    }

  private:
    bn_t l_;
    bn_t r_;

    bn_t snap_l_;
    bn_t snap_r_;

    bn_t t0_;
    bn_t t1_;
    bn_t t2_;
    bn_t t3_;
    bn_t t4_;
};

template <class bn_params>
__global__ void mine_batch_kernel(cgbn_error_report_t *report, const ChunkFootprint chunk, CudaWorkItem *result,
                                  uint32_t items_per_thread, bn_mem_t planet_threshold_mem, bn_mem_t key_mem)
{
    using context_t = cgbn_context_t<bn_params::TPI>;
    using env_t = cgbn_env_t<context_t, BIT_SIZE>;
    using bn_t = typename env_t::cgbn_t;

    // coord x is fixed for each thread
    // we know that blockDim = 1
    if (blockIdx.x >= chunk.side_length)
    {
        return;
    }

    int64_t coord_x = chunk.bottom_left.x + blockIdx.x;

    context_t ctx(cgbn_report_monitor, report);
    env_t env(ctx);

    // Copy mimc constants to memory
    bn_t C[C_SIZE];
    for (uint32_t i = 0; i < C_SIZE; ++i)
    {
        env.load(C[i], &(global_mimc_c[i]));
    }

    Sponge<env_t> sponge;
    bn_t P, key, planet_threshold;
    bn_t yi, xi, hash;
    env.load(P, &global_mimc_p);
    env.load(key, &key_mem);
    env.load(planet_threshold, &planet_threshold_mem);

    __syncthreads();

    wrap_coordinate(env, xi, coord_x, P);
    sponge.reset(env);
    sponge.inject(env, xi, P);
    sponge.mix(env, key, C, C_SIZE, P);
    sponge.save(env);

    uint32_t start_size_y = blockIdx.y * blockDim.y + items_per_thread * threadIdx.y;
    for (uint32_t i = 0; i < items_per_thread; ++i)
    {
        if (start_size_y + i >= chunk.side_length)
        {
            break;
        }

        int64_t coord_y = chunk.bottom_left.y + start_size_y + i;
        sponge.restore(env);
        wrap_coordinate(env, yi, coord_y, P);
        sponge.inject(env, yi, P);
        sponge.mix(env, key, C, C_SIZE, P);
        sponge.result(env, hash);

        uint32_t result_idx = blockIdx.x * chunk.side_length + start_size_y + i;
        env.store(&(result[result_idx].hash), hash);
        result[result_idx].is_planet = env.compare(hash, planet_threshold) < 0;
        result[result_idx].x = coord_x;
        result[result_idx].y = coord_y;
    }
}

template <class bn_params>
void run_mine_batch(int device, const CudaMinerOptions &options, const ChunkFootprint &chunk,
                    const bn_mem_t &planet_threshold, const bn_mem_t &key, std::vector<PlanetLocation> &result)
{
    cgbn_error_report_t *bn_report;

    CUDA_CHECK(cudaSetDevice(device));
    CUDA_CHECK(cgbn_error_report_alloc(&bn_report));

    // TODO: this one can be reused as long as size doesn't change.
    CudaWorkItem *d_batch, *cpu_batch;
    std::size_t batch_size = chunk.side_length * chunk.side_length;
    cpu_batch = static_cast<CudaWorkItem *>(malloc(sizeof(CudaWorkItem) * batch_size));
    CUDA_CHECK(cudaMalloc(&d_batch, sizeof(CudaWorkItem) * batch_size));

    uint32_t items_per_block = options.thread_work_size * options.block_size;
    // grid_size_y = ceil(side_length / items_per_block)
    uint32_t grid_size_y = (chunk.side_length + items_per_block - 1) / items_per_block;
    dim3 block_size(bn_params::TPI, options.block_size);
    dim3 grid_size(chunk.side_length, grid_size_y);

    BOOST_LOG_TRIVIAL(info) << "Starting miner kernel";
    BOOST_LOG_TRIVIAL(info) << "  CUDA configuration:";
    BOOST_LOG_TRIVIAL(info) << "  -      bottom left: "
                            << "(" << chunk.bottom_left.x << ", " << chunk.bottom_left.y << ")";
    BOOST_LOG_TRIVIAL(info) << "  -      side length: " << chunk.side_length;
    BOOST_LOG_TRIVIAL(info) << "  - thread_work_size: " << options.thread_work_size;
    BOOST_LOG_TRIVIAL(info) << "  -           BN TPI: " << bn_params::TPI;
    BOOST_LOG_TRIVIAL(info) << "  -       block size: "
                            << "(" << block_size.x << ", " << block_size.y << ")";
    BOOST_LOG_TRIVIAL(info) << "  -        grid size: "
                            << "(" << grid_size.x << ", " << grid_size.y << ")";

    mine_batch_kernel<bn_params>
        <<<grid_size, block_size>>>(bn_report, chunk, d_batch, options.thread_work_size, planet_threshold, key);

    CUDA_CHECK(cudaDeviceSynchronize());
    CUDA_CHECK(cudaGetLastError());
    CGBN_CHECK(bn_report);

    CUDA_CHECK(cudaMemcpy(cpu_batch, d_batch, sizeof(CudaWorkItem) * batch_size, cudaMemcpyDeviceToHost));

    mpz_class planet_hash;
    for (std::size_t i = 0; i < batch_size; ++i)
    {
        if (cpu_batch[i].is_planet)
        {
            to_mpz(planet_hash.get_mpz_t(), cpu_batch[i].hash);
            Coordinate coord(cpu_batch[i].x, cpu_batch[i].y);
            std::string hash = planet_hash.get_str();
            PlanetLocation location(std::move(coord), std::move(hash));
            result.push_back(location);
        }
    }

    // free up memory
    free(cpu_batch);
    CUDA_CHECK(cudaFree(d_batch));
}

} // namespace kernel

void CudaMiner::initialize()
{
    if (initialized_)
    {
        return;
    }

    initialized_ = true;

    // load P and C on device
    kernel::bn_mem_t P_bn;
    kernel::bn_mem_t C_bn[kernel::C_SIZE];

    BOOST_ASSERT(C.size() == kernel::C_SIZE);
    kernel::from_mpz(P.get_mpz_t(), P_bn);
    for (std::size_t i = 0; i < C.size(); i++)
    {
        kernel::from_mpz(C[i].get_mpz_t(), C_bn[i]);
    }

    CUDA_CHECK(cudaSetDevice(device_));

    CUDA_CHECK(cudaMemcpyToSymbol(kernel::global_mimc_p, &P_bn, sizeof(kernel::bn_mem_t)));
    CUDA_CHECK(cudaMemcpyToSymbol(kernel::global_mimc_c, C_bn, sizeof(kernel::bn_mem_t) * C.size()));
}

void CudaMiner::mine(const ChunkFootprint &chunk, uint32_t rarity, uint32_t key, std::vector<PlanetLocation> &result)
{
    kernel::bn_mem_t planet_threshold_bn, key_bn;

    initialize();

    mpz_class rarity_mpz(rarity);
    mpz_class planet_threshold = P / rarity_mpz;
    kernel::from_mpz(planet_threshold.get_mpz_t(), planet_threshold_bn);

    mpz_class key_mpz(key);
    kernel::from_mpz(key_mpz.get_mpz_t(), key_bn);

    switch (options_.threads_per_item) {
        case ThreadsPerItem::TPI_4:
            return kernel::run_mine_batch<kernel::BnParams<4>>(device_, options_, chunk, planet_threshold_bn, key_bn, result);
        case ThreadsPerItem::TPI_8:
            return kernel::run_mine_batch<kernel::BnParams<8>>(device_, options_, chunk, planet_threshold_bn, key_bn, result);
        case ThreadsPerItem::TPI_16:
            return kernel::run_mine_batch<kernel::BnParams<16>>(device_, options_, chunk, planet_threshold_bn, key_bn, result);
        default:
            return kernel::run_mine_batch<kernel::BnParams<32>>(device_, options_, chunk, planet_threshold_bn, key_bn, result);
    }
}