└── program:
    ├── packages[0] > package:
    │   ├── name: app
    │   ├── decls[0] > verb:
    │   │   └── signature: T pick(T, T, core$Bool) #1
    │   ├── decls[1] > type:
    │   │   ├── name: Pair #2
    │   │   ├── params: T Type
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : T
    │   │   └── struct[1]: right : T
    │   ├── decls[2] > verb:
    │   │   └── signature: Pair(T, T) #3
    │   ├── decls[3] > verb:
    │   │   └── signature: T sum(app$Pair<T>) #4
    │   ├── decls[4] > verb:
    │   │   └── signature: core$Int count(core$Array<T, n>) #5
    │   ├── decls[5] > verb:
    │   │   └── signature: core$Int measured(core$Array<core$Int, n>, n @concepts$Int) #6
    │   ├── decls[6] > verb:
    │   │   └── signature: core$Int relayed(core$Array<core$Int, 3>, n @concepts$Int) #7
    │   ├── decls[7] > verb:
    │   │   └── signature: core$Int forwarded(core$Array<core$Int, 3>, count @concepts$Int) #8
    │   ├── decls[8] > verb:
    │   │   └── signature: core$Int sizedLike(core$Array<core$Int, 3>, n @concepts$Int) #9
    │   ├── decls[9] > verb:
    │   │   └── signature: app$Pair<core$Int> pairOf(@concepts$Int, @concepts$Int) #10
    │   ├── decls[10] > verb:
    │   │   └── signature: app$Pair<core$Float> pairOf(@concepts$Float, @concepts$Float) #11
    │   ├── decls[11] > verb:
    │   │   └── signature: core$Float?core$String safeDivide(core$Float, core$Float) #12
    │   ├── decls[12] > verb:
    │   │   └── signature: core$String describe(shapes$Corner) #13
    │   ├── decls[13] > verb:
    │   │   └── signature: core$Unit main() #14
    │   └── decls[14] > verb:
    │       └── signature: T twice(T) #15
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > type:
    │   │   ├── name: Vec2 #16
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : core$Float
    │   │   └── struct[1]: y : core$Float
    │   ├── decls[1] > verb:
    │   │   └── signature: Vec2(core$Float, core$Float) #17
    │   ├── decls[2] > verb:
    │   │   └── signature: Vec2.zero() #18
    │   ├── decls[3] > verb:
    │   │   └── signature: Vec2{x core$Float; y core$Float = ...} #19
    │   ├── decls[4] > verb:
    │   │   └── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #20
    │   ├── decls[5] > verb:
    │   │   └── signature: shapes$Vec2 ~(shapes$Vec2) #21
    │   ├── decls[6] > verb:
    │   │   └── signature: core$Float length(this shapes$Vec2) #22
    │   ├── decls[7] > verb:
    │   │   └── signature: core$Unit scale(this shapes$Vec2, core$Float) mut #23
    │   ├── decls[8] > verb:
    │   │   └── signature: implicit Vec2(@concepts$Float) #24
    │   ├── decls[9] > type:
    │   │   ├── name: Shape #25
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : core$Float
    │   │   ├── variant[1]: square : core$Float
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[10] > type:
    │   │   ├── name: Corner #26
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[11] > enum_map:
    │   │   ├── map: shapes$Corner.label #27
    │   │   └── type: core$String
    │   ├── decls[12] > verb:
    │   │   └── signature: core$Float _half(core$Float) #28
    │   └── decls[13] > verb:
    │       └── signature: core$Float area(&shapes$Shape) #29
    └── packages[2] > package:
        ├── name: core
        ├── decls[0] > type:
        │   ├── name: Bool #30
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Bool
        ├── decls[1] > verb:
        │   └── signature: implicit Bool(@primitives$Bool) #31
        ├── decls[2] > verb:
        │   └── signature: implicit @primitives$Bool(core$Bool) #32
        ├── decls[3] > verb:
        │   └── signature: core$Bool *(core$Bool, core$Bool) #33
        ├── decls[4] > verb:
        │   └── signature: core$Bool +(core$Bool, core$Bool) #34
        ├── decls[5] > verb:
        │   └── signature: core$Bool ==(core$Bool, core$Bool) #35
        ├── decls[6] > verb:
        │   └── signature: core$Bool ~(core$Bool) #36
        ├── decls[7] > type:
        │   ├── name: Console #37
        │   ├── kind: reference
        │   └── struct[0]: _console : &@runtime$Console
        ├── decls[8] > verb:
        │   └── signature: Console(&@runtime$Console) #38
        ├── decls[9] > verb:
        │   └── signature: core$Unit print(this core$Console, core$String) mut #39
        ├── decls[10] > type:
        │   ├── name: Array #40
        │   ├── params: T Type, n @concepts$Int
        │   ├── kind: value
        │   └── struct[0]: _items : @primitives$Array<T, n>
        ├── decls[11] > verb:
        │   └── signature: Array(@concepts$Array<T, n>) #41
        ├── decls[12] > subscript:
        │   └── signature: (this core$Array<T, n>)[core$Int] #42
        ├── decls[13] > verb:
        │   └── signature: core$Int size(this core$Array<T, n>) #43
        ├── decls[14] > type:
        │   ├── name: List #44
        │   ├── params: T Type
        │   ├── kind: reference
        │   └── struct[0]: _items : @primitives$List<T>
        ├── decls[15] > verb:
        │   └── signature: List(T Type) #45
        ├── decls[16] > verb:
        │   └── signature: core$Unit push(this core$List<T>, T) mut #46
        ├── decls[17] > verb:
        │   └── signature: core$Int size(this core$List<T>) #47
        ├── decls[18] > subscript:
        │   └── signature: (this core$List<T>)[core$Int] #48
        ├── decls[19] > verb:
        │   └── signature: core$Bool if(core$Bool, @concepts$Block) #49
        ├── decls[20] > verb:
        │   └── signature: core$Unit elif(this core$Bool, core$Bool, @concepts$Block) mut #50
        ├── decls[21] > verb:
        │   └── signature: core$Unit else(this core$Bool, @concepts$Block) #51
        ├── decls[22] > verb:
        │   └── signature: core$Unit guard(core$Bool) #52
        ├── decls[23] > verb:
        │   └── signature: core$Unit to(this core$Int, core$Int, @concepts$Block) mut #53
        ├── decls[24] > type:
        │   ├── name: Int #54
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Int
        ├── decls[25] > verb:
        │   └── signature: implicit Int(@concepts$Int) #55
        ├── decls[26] > verb:
        │   └── signature: implicit Int(@primitives$Int) #56
        ├── decls[27] > verb:
        │   └── signature: implicit @primitives$Int(core$Int) #57
        ├── decls[28] > verb:
        │   └── signature: core$Int +(core$Int, core$Int) #58
        ├── decls[29] > verb:
        │   └── signature: core$Int *(core$Int, core$Int) #59
        ├── decls[30] > verb:
        │   └── signature: core$Int /(core$Int, core$Int) #60
        ├── decls[31] > verb:
        │   └── signature: core$Int ~(core$Int) #61
        ├── decls[32] > verb:
        │   └── signature: core$Bool ==(core$Int, core$Int) #62
        ├── decls[33] > verb:
        │   └── signature: core$Bool <(core$Int, core$Int) #63
        ├── decls[34] > type:
        │   ├── name: Float #64
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Float
        ├── decls[35] > verb:
        │   └── signature: implicit Float(@concepts$Float) #65
        ├── decls[36] > verb:
        │   └── signature: implicit Float(@primitives$Float) #66
        ├── decls[37] > verb:
        │   └── signature: core$Float +(core$Float, core$Float) #67
        ├── decls[38] > verb:
        │   └── signature: core$Float *(core$Float, core$Float) #68
        ├── decls[39] > verb:
        │   └── signature: core$Float /(core$Float, core$Float) #69
        ├── decls[40] > verb:
        │   └── signature: core$Float ~(core$Float) #70
        ├── decls[41] > verb:
        │   └── signature: core$Bool ==(core$Float, core$Float) #71
        ├── decls[42] > verb:
        │   └── signature: core$Bool <(core$Float, core$Float) #72
        ├── decls[43] > type:
        │   ├── name: String #73
        │   ├── kind: reference
        │   └── struct[0]: raw : @primitives$String
        ├── decls[44] > verb:
        │   └── signature: implicit String(@concepts$String) #74
        ├── decls[45] > verb:
        │   └── signature: String(@primitives$String) #75
        ├── decls[46] > verb:
        │   └── signature: core$String +(core$String, core$String) #76
        ├── decls[47] > verb:
        │   └── signature: core$Bool ==(core$String, core$String) #77
        ├── decls[48] > type:
        │   ├── name: Unit #78
        │   ├── kind: value
        │   └── struct:
        ├── decls[49] > verb:
        │   └── signature: Unit() #79
        └── decls[50] > verb:
            └── signature: implicit Unit(@primitives$Unit) #80
