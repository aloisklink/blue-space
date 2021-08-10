#include "explorer/explorer.h"
#include "explorer/storage.h"

#include "miner/common/miner.h"
#include "miner/cpu/miner.h"
#ifdef HAS_CUDA_MINER
#include "miner/cuda/miner.h"
#endif

#include <chrono>
#include <cstdint>
#include <iostream>
#include <memory>

const uint64_t RARITY = 16384;
const uint64_t KEY = 420;

int main(int argc, char **argv)
{
    miner::common::Coordinate origin(0, 0);
    auto storage = std::make_shared<explorer::FileStorage>("/tmp/explorer.db");
    auto explorer = std::make_shared<explorer::SpiralExplorer>(storage, origin);

    std::size_t batch_size = 256 * 256 * 4;
    std::vector<miner::common::WorkItem> batch;

    for (std::size_t i = 0; i < batch_size; ++i)
    {
        // just crash if there's no value
        auto next = explorer->next().value();
        batch.push_back(miner::common::WorkItem{.x = next.x, .y = next.y, .is_planet = false, .hash = ""});
    }

#ifdef HAS_CUDA_MINER
    miner::cuda::CudaMiner miner(0);
#else
    miner::cpu::CpuMiner miner;
#endif

    auto start = std::chrono::steady_clock::now();
    miner.mine_batch(batch, RARITY, KEY);
    for (auto &item : batch)
    {
        storage->store(item);
    }
    auto end = std::chrono::steady_clock::now();

    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start).count();
    auto rate = (batch_size * 1000.0) / duration;
    std::cout << "Mine " << batch_size << " hashes in " << duration << " ms (" << rate << " H/s)" << std::endl;

    for (std::size_t i = 0; i < batch.size(); ++i) {
        auto p = batch[i];
        if (p.is_planet)
        {
            std::cout << "H(" << p.x << ", " << p.y << ") = " << p.hash << std::endl;
        }
    }
    return 0;
}