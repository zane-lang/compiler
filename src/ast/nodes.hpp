#pragma once
#include "fwd.hpp"
namespace ast {
	#define X(Name, Members) struct Name Members;
	#include "node_list.def"
	#undef X
}
