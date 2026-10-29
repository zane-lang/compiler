/* Every offset, size and count that emitted code relies on, written once.
   `zane_internal.h` includes this and asserts each against the structs it
   describes, and lib/codegen/dune reads it into the compiler's `Abi`
   module, so the runtime and the code the compiler emits share one copy.
   That rule reads the lines as they are, without a C compiler, so each
   number is a `#define` of a name to a plain decimal number. */

#ifndef ZANE_ABI_H
#define ZANE_ABI_H

/* A region's heap (`zane_heap`): a stack of returned blocks for each size
   class of 1 to ZANE_CLASSES words, then its frontier, the frontier's end,
   and its count of blocks out. */
#define ZANE_CLASSES 16
#define ZANE_HEAP_BUMP 128
#define ZANE_HEAP_END 136
#define ZANE_HEAP_LIVE 144

/* A scope's record (`zane_mark`), at the start of its frame: its region's
   heap first, then what emitted code reads and writes when it places and
   drains a frame. */
#define ZANE_MARK_HEAP 0
#define ZANE_MARK_CONTEXT 152
#define ZANE_MARK_DEPTH 160
#define ZANE_MARK_OUTER 168
#define ZANE_MARK_SKIP 176
#define ZANE_MARK_TASKS 184
#define ZANE_MARK_MAPPINGS 192
#define ZANE_MARK_STACKS 208
#define ZANE_MARK_SIZE 224

/* A context (`zane_context`): where its next frame starts, its innermost
   scope's record, and its range's end. */
#define ZANE_CONTEXT_FRONTIER 0
#define ZANE_CONTEXT_TOP 8
#define ZANE_CONTEXT_LIMIT 16

/* The header before a spawned call's frame (`zane_task`). */
#define ZANE_TASK_SIZE 96

/* A string's or a list's handle (`zane_text`, `zane_list`): its bytes or
   elements, its length or count, and its room. */
#define ZANE_HANDLE_LENGTH 8
#define ZANE_HANDLE_ROOM 16
#define ZANE_HANDLE_SIZE 24

/* The alignment of an oversized block's start past its mapping's header
   (arena.c). */
#define ZANE_LINE 64

/* A list's block is aligned to a word, as every element is. Its first
   holds four elements, but no fewer than ZANE_LIST_LEAST bytes and no more
   than ZANE_LIST_FIRST unless one push asks for more, so that a list of
   few small elements takes a size class's block (list.c). */
#define ZANE_LIST_ALIGN 8
#define ZANE_LIST_LEAST 32
#define ZANE_LIST_FIRST 128

/* A frame stretches for its scope's blocks by at least ZANE_STRETCH bytes,
   so a scope's first small blocks stretch it once, and to at most
   ZANE_STRETCHED bytes, its record and slots included, past which its
   blocks go into chunks (arena.c); a list growing in place stretches it
   further (list.c). Emitted code makes a list's first block in a stretch
   of its own (lib/codegen/emit.ml). */
#define ZANE_STRETCH 4096
#define ZANE_STRETCHED 65536

/* The guard after a context's range, one chunk: a frame no larger, placed
   below the range's end, ends inside the guard at worst, so emitted code
   checks only a larger one. */
#define ZANE_GUARD 1048576

#endif
