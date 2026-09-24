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
    │   │   └── signature: core$Float?core$String safeDivide(core$Float, core$Float) #6
    │   ├── decls[6] > verb:
    │   │   └── signature: core$String describe(shapes$Corner) #7
    │   └── decls[7] > verb:
    │       └── signature: core$Unit main() #8
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > type:
    │   │   ├── name: Vec2 #9
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : core$Float
    │   │   └── struct[1]: y : core$Float
    │   ├── decls[1] > verb:
    │   │   └── signature: Vec2(core$Float, core$Float) #10
    │   ├── decls[2] > verb:
    │   │   └── signature: Vec2.zero() #11
    │   ├── decls[3] > verb:
    │   │   └── signature: Vec2{x core$Float; y core$Float = ...} #12
    │   ├── decls[4] > verb:
    │   │   └── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #13
    │   ├── decls[5] > verb:
    │   │   └── signature: shapes$Vec2 ~(shapes$Vec2) #14
    │   ├── decls[6] > verb:
    │   │   └── signature: core$Float length(this shapes$Vec2) #15
    │   ├── decls[7] > verb:
    │   │   └── signature: core$Unit scale(this shapes$Vec2, core$Float) mut #16
    │   ├── decls[8] > verb:
    │   │   └── signature: implicit Vec2(@concepts$Number) #17
    │   ├── decls[9] > type:
    │   │   ├── name: Shape #18
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : core$Float
    │   │   ├── variant[1]: square : core$Float
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[10] > type:
    │   │   ├── name: Corner #19
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[11] > enum_map:
    │   │   ├── map: shapes$Corner.label #20
    │   │   └── type: core$String
    │   ├── decls[12] > verb:
    │   │   └── signature: core$Float _half(core$Float) #21
    │   └── decls[13] > verb:
    │       └── signature: core$Float area(shapes$Shape) #22
    └── packages[2] > package:
        ├── name: core
        ├── decls[0] > type:
        │   ├── name: Bool #23
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Bool
        ├── decls[1] > verb:
        │   └── signature: implicit Bool(@primitives$Bool) #24
        ├── decls[2] > verb:
        │   └── signature: implicit @primitives$Bool(core$Bool) #25
        ├── decls[3] > verb:
        │   └── signature: core$Bool *(core$Bool, core$Bool) #26
        ├── decls[4] > verb:
        │   └── signature: core$Bool +(core$Bool, core$Bool) #27
        ├── decls[5] > verb:
        │   └── signature: core$Bool ==(core$Bool, core$Bool) #28
        ├── decls[6] > verb:
        │   └── signature: core$Bool ~(core$Bool) #29
        ├── decls[7] > type:
        │   ├── name: Console #30
        │   ├── kind: reference
        │   └── struct[0]: _console : &@runtime$Console
        ├── decls[8] > verb:
        │   └── signature: Console(&@runtime$Console) #31
        ├── decls[9] > verb:
        │   └── signature: core$Unit print(this core$Console, core$String) mut #32
        ├── decls[10] > type:
        │   ├── name: Array #33
        │   ├── params: T Type, n Number
        │   ├── kind: value
        │   └── struct[0]: _items : @primitives$Array<T, n>
        ├── decls[11] > verb:
        │   └── signature: Array(@concepts$Array<T, n>) #34
        ├── decls[12] > subscript:
        │   └── signature: (this core$Array<T, n>)[core$Int] #35
        ├── decls[13] > verb:
        │   └── signature: core$Int size(this core$Array<T, n>) #36
        ├── decls[14] > type:
        │   ├── name: List #37
        │   ├── params: T Type
        │   ├── kind: reference
        │   └── struct[0]: _items : @primitives$List<T>
        ├── decls[15] > verb:
        │   └── signature: List(T Type) #38
        ├── decls[16] > verb:
        │   └── signature: core$Unit push(this core$List<T>, T) mut #39
        ├── decls[17] > verb:
        │   └── signature: core$Int size(this core$List<T>) #40
        ├── decls[18] > subscript:
        │   └── signature: (this core$List<T>)[core$Int] #41
        ├── decls[19] > verb:
        │   └── signature: core$Bool if(core$Bool, @concepts$Block) #42
        ├── decls[20] > verb:
        │   └── signature: core$Unit elif(this core$Bool, core$Bool, @concepts$Block) mut #43
        ├── decls[21] > verb:
        │   └── signature: core$Unit else(this core$Bool, @concepts$Block) #44
        ├── decls[22] > verb:
        │   └── signature: core$Unit guard(core$Bool) #45
        ├── decls[23] > verb:
        │   └── signature: core$Unit to(this core$Int, core$Int, @concepts$Block) mut #46
        ├── decls[24] > type:
        │   ├── name: Int #47
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Int
        ├── decls[25] > verb:
        │   └── signature: implicit Int(@concepts$Number) #48
        ├── decls[26] > verb:
        │   └── signature: implicit Int(@primitives$Int) #49
        ├── decls[27] > verb:
        │   └── signature: implicit @primitives$Int(core$Int) #50
        ├── decls[28] > verb:
        │   └── signature: core$Int +(core$Int, core$Int) #51
        ├── decls[29] > verb:
        │   └── signature: core$Int *(core$Int, core$Int) #52
        ├── decls[30] > verb:
        │   └── signature: core$Int /(core$Int, core$Int) #53
        ├── decls[31] > verb:
        │   └── signature: core$Int ~(core$Int) #54
        ├── decls[32] > verb:
        │   └── signature: core$Bool ==(core$Int, core$Int) #55
        ├── decls[33] > verb:
        │   └── signature: core$Bool <(core$Int, core$Int) #56
        ├── decls[34] > type:
        │   ├── name: Float #57
        │   ├── kind: value
        │   └── struct[0]: raw : @primitives$Float
        ├── decls[35] > verb:
        │   └── signature: implicit Float(@concepts$Number) #58
        ├── decls[36] > verb:
        │   └── signature: implicit Float(@primitives$Float) #59
        ├── decls[37] > verb:
        │   └── signature: core$Float +(core$Float, core$Float) #60
        ├── decls[38] > verb:
        │   └── signature: core$Float *(core$Float, core$Float) #61
        ├── decls[39] > verb:
        │   └── signature: core$Float /(core$Float, core$Float) #62
        ├── decls[40] > verb:
        │   └── signature: core$Float ~(core$Float) #63
        ├── decls[41] > verb:
        │   └── signature: core$Bool ==(core$Float, core$Float) #64
        ├── decls[42] > verb:
        │   └── signature: core$Bool <(core$Float, core$Float) #65
        ├── decls[43] > type:
        │   ├── name: String #66
        │   ├── kind: reference
        │   └── struct[0]: raw : @primitives$String
        ├── decls[44] > verb:
        │   └── signature: implicit String(@concepts$Text) #67
        ├── decls[45] > verb:
        │   └── signature: String(@primitives$String) #68
        ├── decls[46] > verb:
        │   └── signature: core$String +(core$String, core$String) #69
        ├── decls[47] > verb:
        │   └── signature: core$Bool ==(core$String, core$String) #70
        ├── decls[48] > type:
        │   ├── name: Unit #71
        │   ├── kind: value
        │   └── struct:
        ├── decls[49] > verb:
        │   └── signature: Unit() #72
        └── decls[50] > verb:
            └── signature: implicit Unit(@primitives$Unit) #73
