└── program:
    ├── packages[0] > package:
    │   ├── name: app
    │   ├── decls[0] > alias:
    │   │   ├── name: Int #1
    │   │   └── target: @primitives$Int
    │   ├── decls[1] > alias:
    │   │   ├── name: Float #2
    │   │   └── target: @primitives$Float
    │   ├── decls[2] > alias:
    │   │   ├── name: Bool #3
    │   │   └── target: @primitives$Bool
    │   ├── decls[3] > alias:
    │   │   ├── name: Unit #4
    │   │   └── target: @primitives$Unit
    │   ├── decls[4] > alias:
    │   │   ├── name: String #5
    │   │   └── target: @primitives$String
    │   ├── decls[5] > alias:
    │   │   ├── name: Array #6
    │   │   ├── params: T Type, n @concepts$Int
    │   │   └── target: @primitives$Array<T, n>
    │   ├── decls[6] > verb:
    │   │   └── signature: @primitives$Bool if(@primitives$Bool, @concepts$Block) #7
    │   ├── decls[7] > verb:
    │   │   └── signature: @primitives$Unit elif(this @primitives$Bool, @primitives$Bool, @concepts$Block) mut #8
    │   ├── decls[8] > verb:
    │   │   └── signature: @primitives$Unit else(this @primitives$Bool, @concepts$Block) #9
    │   ├── decls[9] > verb:
    │   │   └── signature: @primitives$Unit to(this @primitives$Int, @primitives$Int, @concepts$Block) mut #10
    │   ├── decls[10] > verb:
    │   │   └── signature: @primitives$Unit say(@primitives$String) #11
    │   ├── decls[11] > verb:
    │   │   └── signature: T pick(T, T, @primitives$Bool) #12
    │   ├── decls[12] > type:
    │   │   ├── name: Pair #13
    │   │   ├── params: T Type
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : T
    │   │   └── struct[1]: right : T
    │   ├── decls[13] > verb:
    │   │   └── signature: Pair(T, T) #14
    │   ├── decls[14] > verb:
    │   │   └── signature: T sum(app$Pair<T>) #15
    │   ├── decls[15] > verb:
    │   │   └── signature: @primitives$Int count(@primitives$Array<T, n>) #16
    │   ├── decls[16] > verb:
    │   │   └── signature: @primitives$Int measured(@primitives$Array<@primitives$Int, n>, n @concepts$Int) #17
    │   ├── decls[17] > verb:
    │   │   └── signature: @primitives$Int relayed(@primitives$Array<@primitives$Int, 3>, n @concepts$Int) #18
    │   ├── decls[18] > verb:
    │   │   └── signature: @primitives$Int forwarded(@primitives$Array<@primitives$Int, 3>, count @concepts$Int) #19
    │   ├── decls[19] > verb:
    │   │   └── signature: @primitives$Int sizedLike(@primitives$Array<@primitives$Int, 3>, n @concepts$Int) #20
    │   ├── decls[20] > verb:
    │   │   └── signature: app$Pair<@primitives$Int> pairOf(@concepts$Int, @concepts$Int) #21
    │   ├── decls[21] > verb:
    │   │   └── signature: app$Pair<@primitives$Float> pairOf(@concepts$Float, @concepts$Float) #22
    │   ├── decls[22] > verb:
    │   │   └── signature: @primitives$Float?@primitives$String safeDivide(@primitives$Float, @primitives$Float) #23
    │   ├── decls[23] > verb:
    │   │   └── signature: @primitives$String describe(shapes$Corner) #24
    │   ├── decls[24] > verb:
    │   │   └── signature: @primitives$Unit main() #25
    │   └── decls[25] > verb:
    │       └── signature: T twice(T) #26
    └── packages[1] > package:
        ├── name: shapes
        ├── decls[0] > alias:
        │   ├── name: Float #27
        │   └── target: @primitives$Float
        ├── decls[1] > alias:
        │   ├── name: Unit #28
        │   └── target: @primitives$Unit
        ├── decls[2] > alias:
        │   ├── name: String #29
        │   └── target: @primitives$String
        ├── decls[3] > type:
        │   ├── name: Vec2 #30
        │   ├── kind: value
        │   ├── struct[0]: x : @primitives$Float
        │   └── struct[1]: y : @primitives$Float
        ├── decls[4] > verb:
        │   └── signature: Vec2(@primitives$Float, @primitives$Float) #31
        ├── decls[5] > verb:
        │   └── signature: Vec2.zero() #32
        ├── decls[6] > verb:
        │   └── signature: Vec2{x @primitives$Float; y @primitives$Float = ...} #33
        ├── decls[7] > verb:
        │   └── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #34
        ├── decls[8] > verb:
        │   └── signature: shapes$Vec2 ~(shapes$Vec2) #35
        ├── decls[9] > verb:
        │   └── signature: @primitives$Float length(this shapes$Vec2) #36
        ├── decls[10] > verb:
        │   └── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$Float) mut #37
        ├── decls[11] > verb:
        │   └── signature: implicit Vec2(@concepts$Float) #38
        ├── decls[12] > type:
        │   ├── name: Shape #39
        │   ├── kind: reference
        │   ├── variant[0]: circle : @primitives$Float
        │   ├── variant[1]: square : @primitives$Float
        │   └── variant[2]: point : shapes$Vec2
        ├── decls[13] > type:
        │   ├── name: Corner #40
        │   ├── kind: value
        │   ├── enum[0]: topLeft
        │   ├── enum[1]: topRight
        │   ├── enum[2]: bottomLeft
        │   └── enum[3]: bottomRight
        ├── decls[14] > enum_map:
        │   ├── map: shapes$Corner.label #41
        │   └── type: @primitives$String
        ├── decls[15] > verb:
        │   └── signature: @primitives$Float _half(@primitives$Float) #42
        └── decls[16] > verb:
            └── signature: @primitives$Float area(&shapes$Shape) #43
