#include "keys.h"

#include <algorithm>
#include <random>
#include <iostream>

#include "device_launch_parameters.h"
#include <thrust/execution_policy.h>
#include "thrust/sequence.h"
#include <thrust/gather.h>
#include <thrust/sort.h>

namespace Flavors
{
	Keys::Keys(const Configuration& config, int count) : 
		Store(config.Depth(), count),
		Config(config),
		Count(count)
	{
	}

	Keys::Keys(const Configuration& config, int count, unsigned* data) :
		Keys(config, count)
	{
		cuda::memory::copy(Store.Get(), data, Count * Depth() * sizeof(unsigned));
	}

	void Keys::FillRandom(int seed)
	{
		std::mt19937 mt(seed);

		std::vector<unsigned> randomValues(Count);
		unsigned mask = 0;

		for (int level = 0; level < Depth(); ++level)
		{
			mask = Config.Mask(level);
			std::generate(randomValues.begin(), randomValues.end(), [&mt, &mask] { return mt() & mask; });
			cuda::memory::copy(Store[level], randomValues.data(), Count * sizeof(unsigned));
		}
	}

	std::vector<std::vector<unsigned>> Keys::ToHost() const
	{
		return Store.ToHost();
	}

	std::ostream& operator<<(std::ostream& os, const Keys& obj)
	{
		auto h_store = obj.ToHost();

		for (int item = 0; item < obj.Count; ++item)
		{
			for (int level = 0; level < obj.Config.Depth(); ++level)
			{
				for (int bit = obj.Config[level] - 1; bit >= 0; --bit)
					std::cout << ((h_store[level][item] >> bit) & 1u);
					std::cout << "\t";
			}

			std::cout << std::endl;
		}

		return os;
	}

	bool operator==(const Keys& lhs, const Keys& rhs)
	{
		if (lhs.Count != rhs.Count || lhs.Config != rhs.Config)
			return false;

		auto h_lhs = lhs.ToHost();
		auto h_rhs = rhs.ToHost();

		for(int level = 0; level < lhs.Depth(); ++level)
		{
			auto cmpResult = std::mismatch(h_lhs[level].begin(), h_lhs[level].end(), h_rhs[level].begin());

			if (cmpResult.first != h_lhs[level].end())
				return false;
		}

		return lhs.Count == rhs.Count;
	}

	bool operator!=(const Keys& lhs, const Keys& rhs)
	{
		return !(lhs == rhs);
	}

	__global__ void reshape(int count, int keyLenght, int srcDepth, unsigned* srcLevels, unsigned** srcStore, int dstDepth, unsigned* dstLevels, unsigned** dstStore)
	{
		int key = blockIdx.x * blockDim.x + threadIdx.x;
		if (key >= count)
			return;

		int bit = 0;

		int srcBit = 0;
		int srcLevel = srcDepth - 1;

		int dstBit = 0;
		int dstLevel = dstDepth - 1;

		unsigned srcValue = srcStore[srcLevel][key];
		unsigned dstValue = 0;

		while(bit < keyLenght)
		{
			if((srcValue >> srcBit) & 1u)
				dstValue = dstValue | (1u << dstBit);

			++bit; ++srcBit; ++dstBit;

			if(dstBit == dstLevels[dstLevel])
			{
				dstStore[dstLevel][key] = dstValue;
				dstValue = 0;
				dstBit = 0;
				dstLevel--;
			}

			if(srcBit == srcLevels[srcLevel])
			{
				srcBit = 0;
				srcLevel--;

				if(srcLevel >= 0)
					srcValue = srcStore[srcLevel][key];
			}
		}
	}

	void Keys::launchReshape(Configuration& newConfig, Keys& newKeys)
	{
		auto kernelConfig = make_launch_config(Count);
		cuda::launch(
			reshape,
			kernelConfig,
			Count,
			Config.Length,
			Config.Depth(),
			Config.Levels.Get(),
			Store.GetLevels(),
			newConfig.Depth(),
			newConfig.Levels.Get(),
			newKeys.Store.GetLevels()
		);
	}

	void Keys::copyPermutation(Keys& newKeys)
	{
		if(Sorted())
		{
			newKeys.Permutation = CudaArray<unsigned>{ Count };
			cuda::memory::copy(newKeys.Permutation.Get(), Permutation.Get(), Count * sizeof(unsigned));
		}
	}

	Keys Keys::ReshapeKeys(Configuration& newConfig)
	{
		Keys newKeys{ newConfig, Count };
		launchReshape(newConfig, newKeys);
		copyPermutation(newKeys);

		return newKeys;
	}

	void Keys::Sort()
	{
		CudaArray<unsigned> tmp{ Count };
		initPermutation();

		for(int level = Depth() - 1; level >= 0; --level)
			updatePermutation(level, tmp);

		for (int level = 0; level < Depth(); ++level)
			applyPermutation(level, tmp);
	}

	__global__ void markBorders(int count, int level, unsigned** nodesBorders, unsigned** store)
	{
		int entry = blockIdx.x * blockDim.x + threadIdx.x + 1;
		if (entry < count)
		{
			if (store[level - 1][entry - 1] != store[level - 1][entry])
				nodesBorders[level][entry] = 1;
		}
	}

	Cuda2DArray Keys::Borders()
	{
		if (!Sorted())
			Sort();

		Cuda2DArray borders{ Depth(), Count };

		unsigned mark = 1u;
		cuda::memory::copy(borders[0], &mark, sizeof(unsigned));

		auto kernelConfig =  make_launch_config(Count);
		for (int level = 1; level < Depth(); ++level)
		{
			cuda::memory::copy(borders[level], borders[level - 1], Count * sizeof(unsigned));
			cuda::launch(
				markBorders,
				kernelConfig,
				Count,
				level,
				borders.GetLevels(),
				Store.GetLevels());		
		}


		return borders;
	}

	void Keys::initPermutation()
	{
		Permutation = CudaArray<unsigned>{ Count };
		thrust::sequence(thrust::device, Permutation.Get(), Permutation.Get() + Count);
	}

	void Keys::updatePermutation(int level, CudaArray<unsigned>& tmp)
	{
		thrust::gather(thrust::device, Permutation.Get(), Permutation.Get() + Count, Store[level], tmp.Get());
		thrust::stable_sort_by_key(thrust::device, tmp.Get(), tmp.Get() + Count, Permutation.Get());
	}

	void Keys::applyPermutation(int level, CudaArray<unsigned>& tmp)
	{
		thrust::gather(thrust::device, Permutation.Get(), Permutation.Get() + Count, Store[level], tmp.Get());
		cuda::memory::copy(Store[level], tmp.Get(), Count * sizeof(unsigned));
	}
}
