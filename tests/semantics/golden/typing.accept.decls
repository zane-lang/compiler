└── program:
    ├── packages[0] > package:
    │   ├── name: app
    │   ├── decls[0] > alias:
    │   │   ├── name: Int #1
    │   │   └── target: @primitives$I64
    │   ├── decls[1] > alias:
    │   │   ├── name: Float #2
    │   │   └── target: @primitives$F64
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
    │   │   └── signature: @primitives$Unit to(this @primitives$I64, @primitives$I64, @concepts$Block) mut #10
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
    │   │   └── signature: @primitives$I64 count(@primitives$Array<T, n>) #16
    │   ├── decls[16] > verb:
    │   │   └── signature: @primitives$I64 measured(@primitives$Array<@primitives$I64, n>, n @concepts$Int) #17
    │   ├── decls[17] > verb:
    │   │   └── signature: @primitives$I64 relayed(@primitives$Array<@primitives$I64, 3>, n @concepts$Int) #18
    │   ├── decls[18] > verb:
    │   │   └── signature: @primitives$I64 forwarded(@primitives$Array<@primitives$I64, 3>, count @concepts$Int) #19
    │   ├── decls[19] > verb:
    │   │   └── signature: @primitives$I64 sizedLike(@primitives$Array<@primitives$I64, 3>, n @concepts$Int) #20
    │   ├── decls[20] > verb:
    │   │   └── signature: app$Pair<@primitives$I64> pairOf(@concepts$Int, @concepts$Int) #21
    │   ├── decls[21] > verb:
    │   │   └── signature: app$Pair<@primitives$F64> pairOf(@concepts$Float, @concepts$Float) #22
    │   ├── decls[22] > verb:
    │   │   └── signature: @primitives$F64?@primitives$String safeDivide(@primitives$F64, @primitives$F64) #23
    │   ├── decls[23] > type:
    │   │   ├── name: Crew #24
    │   │   ├── kind: reference
    │   │   ├── struct[0]: lead : shapes$Shape
    │   │   └── struct[1]: backup : &shapes$Shape
    │   ├── decls[24] > verb:
    │   │   └── signature: Crew(^shapes$Shape, &shapes$Shape) #25
    │   ├── decls[25] > verb:
    │   │   └── signature: ^shapes$Shape grown(^shapes$Shape) #26
    │   ├── decls[26] > verb:
    │   │   └── signature: &shapes$Shape leadOf(&app$Crew) #27
    │   ├── decls[27] > verb:
    │   │   └── signature: @primitives$String describe(shapes$Corner) #28
    │   ├── decls[28] > verb:
    │   │   └── signature: @primitives$Unit main() #29
    │   └── decls[29] > verb:
    │       └── signature: T twice(T) #30
    └── packages[1] > package:
        ├── name: shapes
        ├── decls[0] > alias:
        │   ├── name: Float #31
        │   └── target: @primitives$F64
        ├── decls[1] > alias:
        │   ├── name: Unit #32
        │   └── target: @primitives$Unit
        ├── decls[2] > alias:
        │   ├── name: String #33
        │   └── target: @primitives$String
        ├── decls[3] > type:
        │   ├── name: Vec2 #34
        │   ├── kind: value
        │   ├── struct[0]: x : @primitives$F64
        │   └── struct[1]: y : @primitives$F64
        ├── decls[4] > verb:
        │   └── signature: Vec2(@primitives$F64, @primitives$F64) #35
        ├── decls[5] > verb:
        │   └── signature: Vec2.zero() #36
        ├── decls[6] > verb:
        │   └── signature: Vec2{x @primitives$F64; y @primitives$F64 = ...} #37
        ├── decls[7] > verb:
        │   └── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #38
        ├── decls[8] > verb:
        │   └── signature: shapes$Vec2 ~(shapes$Vec2) #39
        ├── decls[9] > verb:
        │   └── signature: @primitives$F64 length(this shapes$Vec2) #40
        ├── decls[10] > verb:
        │   └── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$F64) mut #41
        ├── decls[11] > verb:
        │   └── signature: implicit Vec2(@concepts$Float) #42
        ├── decls[12] > type:
        │   ├── name: Shape #43
        │   ├── kind: reference
        │   ├── variant[0]: circle : @primitives$F64
        │   ├── variant[1]: square : @primitives$F64
        │   └── variant[2]: point : shapes$Vec2
        ├── decls[13] > type:
        │   ├── name: Corner #44
        │   ├── kind: value
        │   ├── enum[0]: topLeft
        │   ├── enum[1]: topRight
        │   ├── enum[2]: bottomLeft
        │   └── enum[3]: bottomRight
        ├── decls[14] > enum_map:
        │   ├── map: shapes$Corner.label #45
        │   └── type: @primitives$String
        ├── decls[15] > type:
        │   ├── name: Meters #46
        │   ├── kind: value
        │   └── struct[0]: _value : @primitives$F64
        ├── decls[16] > verb:
        │   └── signature: Meters(@primitives$F64) #47
        ├── decls[17] > verb:
        │   └── signature: shapes$Meters +(shapes$Meters, shapes$Meters) #48
        ├── decls[18] > verb:
        │   └── signature: @primitives$F64 inFeet(shapes$Meters) #49
        ├── decls[19] > verb:
        │   └── signature: @primitives$F64 _half(@primitives$F64) #50
        └── decls[20] > verb:
            └── signature: @primitives$F64 area(&shapes$Shape) #51
