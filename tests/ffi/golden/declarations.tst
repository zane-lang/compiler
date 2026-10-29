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
    │   │   ├── name: B0 #29
    │   │   ├── kind: value
    │   │   └── struct[0]: v : @primitives$I32
    │   ├── decls[29] > type:
    │   │   ├── name: B1 #30
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B0
    │   │   └── struct[1]: right : app$B0
    │   ├── decls[30] > type:
    │   │   ├── name: B2 #31
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B1
    │   │   └── struct[1]: right : app$B1
    │   ├── decls[31] > type:
    │   │   ├── name: B3 #32
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B2
    │   │   └── struct[1]: right : app$B2
    │   ├── decls[32] > type:
    │   │   ├── name: B4 #33
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B3
    │   │   └── struct[1]: right : app$B3
    │   ├── decls[33] > type:
    │   │   ├── name: B5 #34
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B4
    │   │   └── struct[1]: right : app$B4
    │   ├── decls[34] > type:
    │   │   ├── name: B6 #35
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B5
    │   │   └── struct[1]: right : app$B5
    │   ├── decls[35] > type:
    │   │   ├── name: B7 #36
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B6
    │   │   └── struct[1]: right : app$B6
    │   ├── decls[36] > type:
    │   │   ├── name: B8 #37
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B7
    │   │   └── struct[1]: right : app$B7
    │   ├── decls[37] > type:
    │   │   ├── name: B9 #38
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B8
    │   │   └── struct[1]: right : app$B8
    │   ├── decls[38] > type:
    │   │   ├── name: B10 #39
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B9
    │   │   └── struct[1]: right : app$B9
    │   ├── decls[39] > type:
    │   │   ├── name: B11 #40
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B10
    │   │   └── struct[1]: right : app$B10
    │   ├── decls[40] > type:
    │   │   ├── name: B12 #41
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B11
    │   │   └── struct[1]: right : app$B11
    │   ├── decls[41] > type:
    │   │   ├── name: B13 #42
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B12
    │   │   └── struct[1]: right : app$B12
    │   ├── decls[42] > type:
    │   │   ├── name: B14 #43
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B13
    │   │   └── struct[1]: right : app$B13
    │   ├── decls[43] > type:
    │   │   ├── name: B15 #44
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B14
    │   │   └── struct[1]: right : app$B14
    │   ├── decls[44] > type:
    │   │   ├── name: B16 #45
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : app$B15
    │   │   └── struct[1]: right : app$B15
    │   ├── decls[45] > type:
    │   │   ├── name: Cursor #46
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: cursor
    │   │       └── free: cursor_free
    │   ├── decls[46] > type:
    │   │   ├── name: Deflater #47
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: data
    │   │       ├── cType: deflater_t
    │   │       ├── set: deflater_set
    │   │       └── free: deflater_free
    │   ├── decls[47] > verb:
    │   │   ├── signature: @primitives$I64 crc(@primitives$I64, @primitives$String) #48
    │   │   └── foreign: zane_crc32 (pure, int64_t (int64_t, struct zane_bytes))
    │   ├── decls[48] > verb:
    │   │   ├── signature: app$Vec3 add(app$Vec3, app$Vec3) #49
    │   │   └── foreign: vec_add (pure, vec3 (vec3, vec3))
    │   ├── decls[49] > verb:
    │   │   ├── signature: app$Pair mirror(app$Pair) #50
    │   │   └── foreign: pair_mirror (pure, pair (pair))
    │   ├── decls[50] > verb:
    │   │   ├── signature: @primitives$I32 narrow(@primitives$I32, @primitives$I32) #51
    │   │   └── foreign: narrow (pure, int16_t (uint8_t, short))
    │   ├── decls[51] > verb:
    │   │   ├── signature: @primitives$Bool odd(@primitives$I32) #52
    │   │   └── foreign: odd (pure, bool (int))
    │   ├── decls[52] > verb:
    │   │   ├── signature: @primitives$F64 sum(@primitives$Array<@primitives$F64, 4>, @primitives$List<@primitives$I64>) #53
    │   │   └── foreign: sum (pure, double (const double *, struct zane_span))
    │   ├── decls[53] > verb:
    │   │   ├── signature: @primitives$F64 fold(@primitives$F64[@primitives$F64, @primitives$I32], @primitives$F64) #54
    │   │   └── foreign: fold (pure, double (double (*)(double, int32_t), double))
    │   ├── decls[54] > verb:
    │   │   ├── signature: @primitives$String name(@primitives$I64) #55
    │   │   └── foreign: name (pure, struct zane_bytes (int64_t))
    │   ├── decls[55] > verb:
    │   │   ├── signature: @primitives$Unit reset() #56
    │   │   └── foreign: reset (pure, void (void))
    │   ├── decls[56] > verb:
    │   │   ├── signature: ^app$Deflater?@primitives$Unit deflater(@primitives$I32) #57
    │   │   └── foreign: deflater_new (pure, struct deflater_t * (int32_t))
    │   ├── decls[57] > verb:
    │   │   ├── signature: @primitives$String deflate(this app$Deflater, @primitives$String) mut #58
    │   │   └── foreign: deflate (pure, struct zane_bytes (struct deflater_t *, struct zane_bytes))
    │   ├── decls[58] > verb:
    │   │   ├── signature: @primitives$I64 totalIn(this app$Deflater) #59
    │   │   └── foreign: deflater_total_in (pure, int64_t (const struct deflater_t *))
    │   ├── decls[59] > verb:
    │   │   ├── signature: @primitives$I64 compare(this app$Deflater, app$Deflater) #60
    │   │   └── foreign: deflater_compare (pure, int64_t (const struct deflater_t *, const struct deflater_t *))
    │   ├── decls[60] > verb:
    │   │   ├── signature: app$Twin twinTypedef(app$Twin) #61
    │   │   └── foreign: twin_typedef (pure, twin (twin))
    │   ├── decls[61] > verb:
    │   │   ├── signature: app$TwinTag twinTagged(app$TwinTag) #62
    │   │   └── foreign: twin_tagged (pure, struct twin (struct twin))
    │   ├── decls[62] > verb:
    │   │   ├── signature: ^app$Cursor?@primitives$Unit cursor() #63
    │   │   └── foreign: cursor_new (pure, struct cursor * (void))
    │   ├── decls[63] > verb:
    │   │   ├── signature: app$N16 deep(app$N16) #64
    │   │   └── foreign: deep (pure, n16 (n16))
    │   ├── decls[64] > verb:
    │   │   ├── signature: @primitives$I32 wide(app$B16) #65
    │   │   └── foreign: wide (pure, int32_t (b16))
    │   ├── decls[65] > type:
    │   │   ├── name: Stream #66
    │   │   ├── kind: reference
    │   │   └── struct[0]: _deflater : app$Deflater
    │   ├── decls[66] > verb:
    │   │   ├── signature: @primitives$Unit replace(this app$Stream) mut #67
    │   │   ├── params[0]: this #1 : app$Stream
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: app$Deflater
    │   │   │   │   ├── target: this #1 : app$Stream
    │   │   │   │   └── field: _deflater (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Deflater
    │   │   │       ├── callee: deflater #57
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
    │   └── decls[67] > verb:
    │       ├── signature: @primitives$Unit main() #68
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
    │       │       ├── callee: open #78
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "app.log" : @concepts$String
    │       ├── body[2] > do > call:
    │       │   ├── type: @primitives$Unit
    │       │   ├── callee: write #79
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
    │       │       ├── callee: size #80
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
    │       │       ├── callee: size #80
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
    │       │       ├── callee: size #80
    │       │       ├── args[0]: other #8 : fs$Fs
    │       │       └── args[1]: log #4 : fs$File
    │       ├── body[8] > let:
    │       │   ├── local: d #11 : app$Deflater
    │       │   └── value > call:
    │       │       ├── type: app$Deflater
    │       │       ├── callee: deflater #57
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
    │       │       ├── callee: deflater #57
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
    │       │       ├── callee: open #78
    │       │       ├── args[0]: files #3 : fs$Fs
    │       │       └── args[1] > construct:
    │       │           ├── type: @primitives$String
    │       │           ├── ctor: @primitives$String
    │       │           └── args[0]: "b.log" : @concepts$String
    │       ├── body[11] > assign:
    │       │   ├── target: r #13 : fs$File
    │       │   └── value > call:
    │       │       ├── type: fs$File
    │       │       ├── callee: open #78
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
    │   │   ├── name: Unit #69
    │   │   └── target: @primitives$Unit
    │   ├── decls[1] > alias:
    │   │   ├── name: Bool #70
    │   │   └── target: @primitives$Bool
    │   ├── decls[2] > alias:
    │   │   ├── name: I32 #71
    │   │   └── target: @primitives$I32
    │   ├── decls[3] > alias:
    │   │   ├── name: I64 #72
    │   │   └── target: @primitives$I64
    │   ├── decls[4] > alias:
    │   │   ├── name: F32 #73
    │   │   └── target: @primitives$F32
    │   ├── decls[5] > alias:
    │   │   ├── name: F64 #74
    │   │   └── target: @primitives$F64
    │   ├── decls[6] > alias:
    │   │   ├── name: String #75
    │   │   └── target: @primitives$String
    │   ├── decls[7] > type:
    │   │   ├── name: Fs #76
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: capability
    │   │       └── cType: zane_fs_t
    │   ├── decls[8] > type:
    │   │   ├── name: File #77
    │   │   ├── kind: reference
    │   │   └── handle:
    │   │       ├── kind: outside
    │   │       ├── cType: zane_file_t
    │   │       └── free: zane_fclose
    │   ├── decls[9] > verb:
    │   │   ├── signature: ^fs$File open(this fs$Fs, @primitives$String) mut #78
    │   │   └── foreign: zane_fopen (writes, struct zane_file_t * (struct zane_fs_t *, struct zane_bytes))
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit write(this fs$Fs, fs$File, @primitives$String) mut #79
    │   │   └── foreign: zane_fwrite (writes, void (struct zane_fs_t *, struct zane_file_t *, struct zane_bytes))
    │   └── decls[11] > verb:
    │       ├── signature: @primitives$I64 size(this fs$Fs, fs$File) #80
    │       └── foreign: zane_fsize (reads, int64_t (const struct zane_fs_t *, const struct zane_file_t *))
    └── instances:
