└── program:
    ├── packages[0] > package:
    │   ├── name: app
    │   ├── decls[0] > alias:
    │   │   ├── name: Unit #1
    │   │   └── target: @primitives$Unit
    │   ├── decls[1] > alias:
    │   │   ├── name: Bool #2
    │   │   └── target: @primitives$Bool
    │   ├── decls[2] > alias:
    │   │   ├── name: I32 #3
    │   │   └── target: @primitives$I32
    │   ├── decls[3] > alias:
    │   │   ├── name: I64 #4
    │   │   └── target: @primitives$I64
    │   ├── decls[4] > alias:
    │   │   ├── name: F32 #5
    │   │   └── target: @primitives$F32
    │   ├── decls[5] > alias:
    │   │   ├── name: F64 #6
    │   │   └── target: @primitives$F64
    │   ├── decls[6] > alias:
    │   │   ├── name: String #7
    │   │   └── target: @primitives$String
    │   ├── decls[7] > type:
    │   │   ├── name: Vec3 #8
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$F64
    │   │   ├── struct[1]: y : @primitives$F64
    │   │   └── struct[2]: z : @primitives$F64
    │   ├── decls[8] > type:
    │   │   ├── name: Pair #9
    │   │   ├── kind: value
    │   │   ├── struct[0]: id : @primitives$I32
    │   │   ├── struct[1]: weights : @primitives$Array<@primitives$F32, 3>
    │   │   └── struct[2]: at : app$Vec3
    │   ├── decls[9] > type:
    │   │   ├── name: Twin #10
    │   │   ├── kind: value
    │   │   └── struct[0]: a : @primitives$I32
    │   ├── decls[10] > type:
    │   │   ├── name: TwinTag #11
    │   │   ├── kind: value
    │   │   └── struct[0]: b : @primitives$F64
    │   ├── decls[11] > type:
    │   │   ├── name: Cursor #12
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: cursor
    │   │       └── free: cursor_free
    │   ├── decls[12] > type:
    │   │   ├── name: Deflater #13
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: deflater_t
    │   │       ├── set: deflater_set
    │   │       └── free: deflater_free
    │   ├── decls[13] > verb:
    │   │   ├── signature: @primitives$I64 crc(@primitives$I64, @primitives$String) #14
    │   │   └── foreign: zane_crc32 (pure, int64_t (int64_t, struct zane_bytes))
    │   ├── decls[14] > verb:
    │   │   ├── signature: app$Vec3 add(app$Vec3, app$Vec3) #15
    │   │   └── foreign: vec_add (pure, vec3 (vec3, vec3))
    │   ├── decls[15] > verb:
    │   │   ├── signature: app$Pair mirror(app$Pair) #16
    │   │   └── foreign: pair_mirror (pure, pair (pair))
    │   ├── decls[16] > verb:
    │   │   ├── signature: @primitives$I32 narrow(@primitives$I32, @primitives$I32) #17
    │   │   └── foreign: narrow (pure, int16_t (uint8_t, short))
    │   ├── decls[17] > verb:
    │   │   ├── signature: @primitives$Bool odd(@primitives$I32) #18
    │   │   └── foreign: odd (pure, bool (int))
    │   ├── decls[18] > verb:
    │   │   ├── signature: @primitives$F64 sum(@primitives$Array<@primitives$F64, 4>, @primitives$List<@primitives$I64>) #19
    │   │   └── foreign: sum (pure, double (const double *, struct zane_span))
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$F64 fold(@primitives$F64[@primitives$F64, @primitives$I32], @primitives$F64) #20
    │   │   └── foreign: fold (pure, double (double (*)(double, int32_t), double))
    │   ├── decls[20] > verb:
    │   │   ├── signature: @primitives$String name(@primitives$I64) #21
    │   │   └── foreign: name (pure, struct zane_bytes (int64_t))
    │   ├── decls[21] > verb:
    │   │   ├── signature: @primitives$Unit reset() #22
    │   │   └── foreign: reset (pure, void (void))
    │   ├── decls[22] > verb:
    │   │   ├── signature: ^app$Deflater?@primitives$Unit deflater(@primitives$I32) #23
    │   │   └── foreign: deflater_new (pure, struct deflater_t * (int32_t))
    │   ├── decls[23] > verb:
    │   │   ├── signature: @primitives$String deflate(this app$Deflater, @primitives$String) mut #24
    │   │   └── foreign: deflate (pure, struct zane_bytes (struct deflater_t *, struct zane_bytes))
    │   ├── decls[24] > verb:
    │   │   ├── signature: @primitives$I64 totalIn(this app$Deflater) #25
    │   │   └── foreign: deflater_total_in (pure, int64_t (const struct deflater_t *))
    │   ├── decls[25] > verb:
    │   │   ├── signature: @primitives$I64 compare(this app$Deflater, app$Deflater) #26
    │   │   └── foreign: deflater_compare (pure, int64_t (const struct deflater_t *, const struct deflater_t *))
    │   ├── decls[26] > verb:
    │   │   ├── signature: app$Twin twinTypedef(app$Twin) #27
    │   │   └── foreign: twin_typedef (pure, twin (twin))
    │   ├── decls[27] > verb:
    │   │   ├── signature: app$TwinTag twinTagged(app$TwinTag) #28
    │   │   └── foreign: twin_tagged (pure, struct twin (struct twin))
    │   ├── decls[28] > verb:
    │   │   ├── signature: ^app$Cursor?@primitives$Unit cursor() #29
    │   │   └── foreign: cursor_new (pure, struct cursor * (void))
    │   ├── decls[29] > type:
    │   │   ├── name: Stream #30
    │   │   ├── kind: reference
    │   │   └── struct[0]: _deflater : app$Deflater
    │   ├── decls[30] > verb:
    │   │   ├── signature: @primitives$Unit replace(this app$Stream) mut #31
    │   │   ├── params[0]: this #1 : app$Stream
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: app$Deflater
    │   │   │   │   ├── target: this #1 : app$Stream
    │   │   │   │   └── field: _deflater (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Deflater
    │   │   │       ├── callee: deflater #23
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$I32
    │   │   │       │   ├── ctor: @primitives$I32
    │   │   │       │   └── args[0]: 9 : @concepts$Int
    │   │   │       └── handler:
    │   │   │           ├── binder: e #2 : @primitives$Unit
    │   │   │           └── body[0] > return > construct:
    │   │   │               ├── type: @primitives$Unit
    │   │   │               ├── ctor: @primitives$Unit
    │   │   │               └── args:
    │   │   └── body[1] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   └── decls[31] > verb:
    │       ├── signature: @primitives$Unit main() #32
    │       ├── params:
    │       ├── body[0] > let:
    │       │   ├── local: files #3 : fs$Fs
    │       │   └── value > foreign_global:
    │       │       ├── type: fs$Fs
    │       │       ├── package: fs
    │       │       └── symbol: zane_fs
    │       ├── body[1] > let:
    │       │   ├── local: log #4 : fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #42
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "app.log" : @concepts$String
    │       ├── body[2] > do > call:
    │       │   ├── type: @primitives$Unit
    │       │   ├── callee: write #43
    │       │   ├── args[0]: files #3 : fs$Fs
    │       │   ├── args[1]: log #4 : fs$File
    │       │   └── args[2] > construct:
    │       │       ├── type: @primitives$String
    │       │       ├── ctor: @primitives$String
    │       │       └── args[0]: "started\\n" : @concepts$String
    │       ├── body[3] > let:
    │       │   ├── local: size #5 : @primitives$I64
    │       │   └── value > call:
    │       │       ├── type: @primitives$I64
    │       │       ├── callee: size #44
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1]: log #4 : fs$File
    │       ├── body[4] > let:
    │       │   ├── local: d #7 : app$Deflater
    │       │   └── value > call:
    │       │       ├── type: app$Deflater
    │       │       ├── callee: deflater #23
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: @primitives$I32
    │       │       │   ├── ctor: @primitives$I32
    │       │       │   └── args[0]: 6 : @concepts$Int
    │       │       └── handler:
    │       │           ├── binder: e #6 : @primitives$Unit
    │       │           └── body[0] > return > construct:
    │       │               ├── type: @primitives$Unit
    │       │               ├── ctor: @primitives$Unit
    │       │               └── args:
    │       ├── body[5] > assign:
    │       │   ├── target: d #7 : app$Deflater
    │       │   └── value > call:
    │       │       ├── type: app$Deflater
    │       │       ├── callee: deflater #23
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: @primitives$I32
    │       │       │   ├── ctor: @primitives$I32
    │       │       │   └── args[0]: 9 : @concepts$Int
    │       │       └── handler:
    │       │           ├── binder: e #8 : @primitives$Unit
    │       │           └── body[0] > return > construct:
    │       │               ├── type: @primitives$Unit
    │       │               ├── ctor: @primitives$Unit
    │       │               └── args:
    │       ├── body[6] > let:
    │       │   ├── local: r #9 : ^fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #42
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "b.log" : @concepts$String
    │       ├── body[7] > assign:
    │       │   ├── target: r #9 : fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #42
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "c.log" : @concepts$String
    │       └── body[8] > return > construct:
    │           ├── type: @primitives$Unit
    │           ├── ctor: @primitives$Unit
    │           └── args:
    ├── packages[1] > package:
    │   ├── name: fs
    │   ├── decls[0] > alias:
    │   │   ├── name: Unit #33
    │   │   └── target: @primitives$Unit
    │   ├── decls[1] > alias:
    │   │   ├── name: Bool #34
    │   │   └── target: @primitives$Bool
    │   ├── decls[2] > alias:
    │   │   ├── name: I32 #35
    │   │   └── target: @primitives$I32
    │   ├── decls[3] > alias:
    │   │   ├── name: I64 #36
    │   │   └── target: @primitives$I64
    │   ├── decls[4] > alias:
    │   │   ├── name: F32 #37
    │   │   └── target: @primitives$F32
    │   ├── decls[5] > alias:
    │   │   ├── name: F64 #38
    │   │   └── target: @primitives$F64
    │   ├── decls[6] > alias:
    │   │   ├── name: String #39
    │   │   └── target: @primitives$String
    │   ├── decls[7] > type:
    │   │   ├── name: Fs #40
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: capability
    │   │       └── cType: zane_fs_t
    │   ├── decls[8] > type:
    │   │   ├── name: File #41
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: outside
    │   │       ├── cType: zane_file_t
    │   │       └── free: zane_fclose
    │   ├── decls[9] > verb:
    │   │   ├── signature: ^fs$File open(this fs$Fs, @primitives$String) mut #42
    │   │   └── foreign: zane_fopen (writes, struct zane_file_t * (struct zane_fs_t *, struct zane_bytes))
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit write(this fs$Fs, fs$File, @primitives$String) mut #43
    │   │   └── foreign: zane_fwrite (writes, void (struct zane_fs_t *, struct zane_file_t *, struct zane_bytes))
    │   └── decls[11] > verb:
    │       ├── signature: @primitives$I64 size(this fs$Fs, fs$File) #44
    │       └── foreign: zane_fsize (reads, int64_t (const struct zane_fs_t *, const struct zane_file_t *))
    └── instances:
