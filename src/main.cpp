#include "macros.hpp"
#include "cli/cli.hpp"
#include "utils/console.hpp"

int main(int argc, char* argv[]) {
	CLI cli;
	return cli.run(argc, argv);
}
