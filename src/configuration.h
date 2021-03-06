#pragma once
#include <vector>
#include <ostream>
#include "api_wrappers.h"
#include "utils.h"

namespace Flavors
{
	class Configuration
	{
	public:
		static Configuration DefaultConfig32;

		int Length;
		CudaArray<unsigned> Levels;

		Configuration();
		explicit Configuration(const std::vector<unsigned>& levels);

		unsigned operator[](int level) const;

		int Depth() const { return h_levels.size(); };
		int Mask(int level) const;

		void PopLastLevel();

		friend std::ostream& operator<<(std::ostream& os, const Configuration& obj);

		friend bool operator==(const Configuration& lhs, const Configuration& rhs);
		friend bool operator!=(const Configuration& lhs, const Configuration& rhs);

		Configuration(const Configuration& other) = default;
		Configuration(Configuration&& other) noexcept = default;
		Configuration& operator=(const Configuration& other) = default;
		Configuration& operator=(Configuration&& other) noexcept = default;
	private:
		std::vector<unsigned> h_levels;
	};
}
