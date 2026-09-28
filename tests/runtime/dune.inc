; Written by tests/gen/gen_rules.ml. Promote a change with `dune promote`.

(rule
 (deps anchors.c ../../runtime/zane.h ../../runtime/zane_internal.h ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)
 (targets anchors.exe)
 (action
  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o anchors.exe anchors.c
   ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)))

(rule
 (action
  (with-stdout-to
   anchors.out.actual
   (run ./anchors.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/anchors.out anchors.out.actual)))

(rule
 (deps arenas.c ../../runtime/zane.h ../../runtime/zane_internal.h ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)
 (targets arenas.exe)
 (action
  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o arenas.exe arenas.c
   ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)))

(rule
 (action
  (with-stdout-to
   arenas.out.actual
   (run ./arenas.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/arenas.out arenas.out.actual)))

(rule
 (deps blocks.c ../../runtime/zane.h ../../runtime/zane_internal.h ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)
 (targets blocks.exe)
 (action
  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o blocks.exe blocks.c
   ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)))

(rule
 (action
  (with-stdout-to
   blocks.out.actual
   (run ./blocks.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/blocks.out blocks.out.actual)))

(rule
 (deps spawns.c ../../runtime/zane.h ../../runtime/zane_internal.h ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)
 (targets spawns.exe)
 (action
  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o spawns.exe spawns.c
   ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)))

(rule
 (action
  (with-stdout-to
   spawns.out.actual
   (run ./spawns.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/spawns.out spawns.out.actual)))

(rule
 (deps texts.c ../../runtime/zane.h ../../runtime/zane_internal.h ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)
 (targets texts.exe)
 (action
  (run clang -std=c11 -Wall -Wextra -Werror -O2 -pthread -I ../../runtime -o texts.exe texts.c
   ../../runtime/main.c ../../runtime/arena.c ../../runtime/anchor.c ../../runtime/block.c ../../runtime/value.c ../../runtime/list.c ../../runtime/slot.c ../../runtime/spawn.c ../../runtime/snapshot.c)))

(rule
 (action
  (with-stdout-to
   texts.out.actual
   (run ./texts.exe))))

(rule
 (alias runtest)
 (action
  (diff golden/texts.out texts.out.actual)))

