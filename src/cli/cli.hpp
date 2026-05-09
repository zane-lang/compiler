#pragma once

#include "cli/commands.hpp"
#include "utils/console.hpp"

#include <string>

class CLI {
public:
	CLI() {}

	int run(int argc, char* argv[]) {
		if (argc < 2) {
			PRINT("Usage: " << argv[0] << " <cmd>");
			return 1;
		}

		const char* cmd = argv[1];
		commands::dispatch(cmd, argc - 2, argv + 2);

		return 0;
	}
};
