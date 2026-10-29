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
    │   │   ├── name: N0 #12
    │   │   ├── kind: value
    │   │   └── struct[0]: v : @primitives$I32
    │   ├── decls[12] > type:
    │   │   ├── name: N1 #13
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N0
    │   ├── decls[13] > type:
    │   │   ├── name: N2 #14
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N1
    │   ├── decls[14] > type:
    │   │   ├── name: N3 #15
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N2
    │   ├── decls[15] > type:
    │   │   ├── name: N4 #16
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N3
    │   ├── decls[16] > type:
    │   │   ├── name: N5 #17
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N4
    │   ├── decls[17] > type:
    │   │   ├── name: N6 #18
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N5
    │   ├── decls[18] > type:
    │   │   ├── name: N7 #19
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N6
    │   ├── decls[19] > type:
    │   │   ├── name: N8 #20
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N7
    │   ├── decls[20] > type:
    │   │   ├── name: N9 #21
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N8
    │   ├── decls[21] > type:
    │   │   ├── name: N10 #22
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N9
    │   ├── decls[22] > type:
    │   │   ├── name: N11 #23
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N10
    │   ├── decls[23] > type:
    │   │   ├── name: N12 #24
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N11
    │   ├── decls[24] > type:
    │   │   ├── name: N13 #25
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N12
    │   ├── decls[25] > type:
    │   │   ├── name: N14 #26
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N13
    │   ├── decls[26] > type:
    │   │   ├── name: N15 #27
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N14
    │   ├── decls[27] > type:
    │   │   ├── name: N16 #28
    │   │   ├── kind: value
    │   │   └── struct[0]: inner : app$N15
    │   ├── decls[28] > type:
    │   │   ├── name: Cursor #29
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: cursor
    │   │       └── free: cursor_free
    │   ├── decls[29] > type:
    │   │   ├── name: Deflater #30
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: deflater_t
    │   │       ├── set: deflater_set
    │   │       └── free: deflater_free
    │   ├── decls[30] > verb:
    │   │   ├── signature: @primitives$I64 crc(@primitives$I64, @primitives$String) #31
    │   │   └── foreign: zane_crc32 (pure, int64_t (int64_t, struct zane_bytes))
    │   ├── decls[31] > verb:
    │   │   ├── signature: app$Vec3 add(app$Vec3, app$Vec3) #32
    │   │   └── foreign: vec_add (pure, vec3 (vec3, vec3))
    │   ├── decls[32] > verb:
    │   │   ├── signature: app$Pair mirror(app$Pair) #33
    │   │   └── foreign: pair_mirror (pure, pair (pair))
    │   ├── decls[33] > verb:
    │   │   ├── signature: @primitives$I32 narrow(@primitives$I32, @primitives$I32) #34
    │   │   └── foreign: narrow (pure, int16_t (uint8_t, short))
    │   ├── decls[34] > verb:
    │   │   ├── signature: @primitives$Bool odd(@primitives$I32) #35
    │   │   └── foreign: odd (pure, bool (int))
    │   ├── decls[35] > verb:
    │   │   ├── signature: @primitives$F64 sum(@primitives$Array<@primitives$F64, 4>, @primitives$List<@primitives$I64>) #36
    │   │   └── foreign: sum (pure, double (const double *, struct zane_span))
    │   ├── decls[36] > verb:
    │   │   ├── signature: @primitives$F64 fold(@primitives$F64[@primitives$F64, @primitives$I32], @primitives$F64) #37
    │   │   └── foreign: fold (pure, double (double (*)(double, int32_t), double))
    │   ├── decls[37] > verb:
    │   │   ├── signature: @primitives$String name(@primitives$I64) #38
    │   │   └── foreign: name (pure, struct zane_bytes (int64_t))
    │   ├── decls[38] > verb:
    │   │   ├── signature: @primitives$Unit reset() #39
    │   │   └── foreign: reset (pure, void (void))
    │   ├── decls[39] > verb:
    │   │   ├── signature: ^app$Deflater?@primitives$Unit deflater(@primitives$I32) #40
    │   │   └── foreign: deflater_new (pure, struct deflater_t * (int32_t))
    │   ├── decls[40] > verb:
    │   │   ├── signature: @primitives$String deflate(this app$Deflater, @primitives$String) mut #41
    │   │   └── foreign: deflate (pure, struct zane_bytes (struct deflater_t *, struct zane_bytes))
    │   ├── decls[41] > verb:
    │   │   ├── signature: @primitives$I64 totalIn(this app$Deflater) #42
    │   │   └── foreign: deflater_total_in (pure, int64_t (const struct deflater_t *))
    │   ├── decls[42] > verb:
    │   │   ├── signature: @primitives$I64 compare(this app$Deflater, app$Deflater) #43
    │   │   └── foreign: deflater_compare (pure, int64_t (const struct deflater_t *, const struct deflater_t *))
    │   ├── decls[43] > verb:
    │   │   ├── signature: app$Twin twinTypedef(app$Twin) #44
    │   │   └── foreign: twin_typedef (pure, twin (twin))
    │   ├── decls[44] > verb:
    │   │   ├── signature: app$TwinTag twinTagged(app$TwinTag) #45
    │   │   └── foreign: twin_tagged (pure, struct twin (struct twin))
    │   ├── decls[45] > verb:
    │   │   ├── signature: ^app$Cursor?@primitives$Unit cursor() #46
    │   │   └── foreign: cursor_new (pure, struct cursor * (void))
    │   ├── decls[46] > verb:
    │   │   ├── signature: app$N16 deep(app$N16) #47
    │   │   └── foreign: deep (pure, n16 (n16))
    │   ├── decls[47] > type:
    │   │   ├── name: Stream #48
    │   │   ├── kind: reference
    │   │   └── struct[0]: _deflater : app$Deflater
    │   ├── decls[48] > verb:
    │   │   ├── signature: @primitives$Unit replace(this app$Stream) mut #49
    │   │   ├── params[0]: this #1 : app$Stream
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: app$Deflater
    │   │   │   │   ├── target: this #1 : app$Stream
    │   │   │   │   └── field: _deflater (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Deflater
    │   │   │       ├── callee: deflater #40
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
    │   └── decls[49] > verb:
    │       ├── signature: @primitives$Unit main() #50
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
    │       │       ├── callee: open #60
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "app.log" : @concepts$String
    │       ├── body[2] > do > call:
    │       │   ├── type: @primitives$Unit
    │       │   ├── callee: write #61
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
    │       │       ├── callee: size #62
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1]: log #4 : fs$File
    │       ├── body[4] > let:
    │       │   ├── local: spare #6 : fs$Fs
    │       │   └── value > foreign_global:
    │       │       ├── type: fs$Fs
    │       │       ├── package: fs
    │       │       └── symbol: zane_spare
    │       ├── body[5] > let:
    │       │   ├── local: spared #7 : @primitives$I64
    │       │   └── value > call:
    │       │       ├── type: @primitives$I64
    │       │       ├── callee: size #62
    │       │       ├── args[0]: spare #6 : fs$Fs
    │       │       └── args[1]: log #4 : fs$File
    │       ├── body[6] > let:
    │       │   ├── local: other #8 : fs$Fs
    │       │   └── value > foreign_global:
    │       │       ├── type: fs$Fs
    │       │       ├── package: fs
    │       │       └── symbol: zane_other
    │       ├── body[7] > let:
    │       │   ├── local: otherSize #9 : @primitives$I64
    │       │   └── value > call:
    │       │       ├── type: @primitives$I64
    │       │       ├── callee: size #62
    │       │       ├── args[0]: other #8 : fs$Fs
    │       │       └── args[1]: log #4 : fs$File
    │       ├── body[8] > let:
    │       │   ├── local: d #11 : app$Deflater
    │       │   └── value > call:
    │       │       ├── type: app$Deflater
    │       │       ├── callee: deflater #40
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: @primitives$I32
    │       │       │   ├── ctor: @primitives$I32
    │       │       │   └── args[0]: 6 : @concepts$Int
    │       │       └── handler:
    │       │           ├── binder: e #10 : @primitives$Unit
    │       │           └── body[0] > return > construct:
    │       │               ├── type: @primitives$Unit
    │       │               ├── ctor: @primitives$Unit
    │       │               └── args:
    │       ├── body[9] > assign:
    │       │   ├── target: d #11 : app$Deflater
    │       │   └── value > call:
    │       │       ├── type: app$Deflater
    │       │       ├── callee: deflater #40
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: @primitives$I32
    │       │       │   ├── ctor: @primitives$I32
    │       │       │   └── args[0]: 9 : @concepts$Int
    │       │       └── handler:
    │       │           ├── binder: e #12 : @primitives$Unit
    │       │           └── body[0] > return > construct:
    │       │               ├── type: @primitives$Unit
    │       │               ├── ctor: @primitives$Unit
    │       │               └── args:
    │       ├── body[10] > let:
    │       │   ├── local: r #13 : ^fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #60
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "b.log" : @concepts$String
    │       ├── body[11] > assign:
    │       │   ├── target: r #13 : fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #60
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "c.log" : @concepts$String
    │       └── body[12] > return > construct:
    │           ├── type: @primitives$Unit
    │           ├── ctor: @primitives$Unit
    │           └── args:
    ├── packages[1] > package:
    │   ├── name: fs
    │   ├── decls[0] > alias:
    │   │   ├── name: Unit #51
    │   │   └── target: @primitives$Unit
    │   ├── decls[1] > alias:
    │   │   ├── name: Bool #52
    │   │   └── target: @primitives$Bool
    │   ├── decls[2] > alias:
    │   │   ├── name: I32 #53
    │   │   └── target: @primitives$I32
    │   ├── decls[3] > alias:
    │   │   ├── name: I64 #54
    │   │   └── target: @primitives$I64
    │   ├── decls[4] > alias:
    │   │   ├── name: F32 #55
    │   │   └── target: @primitives$F32
    │   ├── decls[5] > alias:
    │   │   ├── name: F64 #56
    │   │   └── target: @primitives$F64
    │   ├── decls[6] > alias:
    │   │   ├── name: String #57
    │   │   └── target: @primitives$String
    │   ├── decls[7] > type:
    │   │   ├── name: Fs #58
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: capability
    │   │       └── cType: zane_fs_t
    │   ├── decls[8] > type:
    │   │   ├── name: File #59
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: outside
    │   │       ├── cType: zane_file_t
    │   │       └── free: zane_fclose
    │   ├── decls[9] > verb:
    │   │   ├── signature: ^fs$File open(this fs$Fs, @primitives$String) mut #60
    │   │   └── foreign: zane_fopen (writes, struct zane_file_t * (struct zane_fs_t *, struct zane_bytes))
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit write(this fs$Fs, fs$File, @primitives$String) mut #61
    │   │   └── foreign: zane_fwrite (writes, void (struct zane_fs_t *, struct zane_file_t *, struct zane_bytes))
    │   └── decls[11] > verb:
    │       ├── signature: @primitives$I64 size(this fs$Fs, fs$File) #62
    │       └── foreign: zane_fsize (reads, int64_t (const struct zane_fs_t *, const struct zane_file_t *))
    └── instances:
