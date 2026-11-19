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
    │   ├── decls[27] > type:
    │   │   ├── name: Holder #28
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: item : T
    │   ├── decls[28] > verb:
    │   │   └── signature: Holder(T) #29
    │   ├── decls[29] > verb:
    │   │   └── signature: ^T relayed(^T) #30
    │   ├── decls[30] > verb:
    │   │   └── signature: ^T zeroed(T) #31
    │   ├── decls[31] > verb:
    │   │   └── signature: @primitives$String describe(shapes$Corner) #32
    │   ├── decls[32] > verb:
    │   │   └── signature: @primitives$Unit?@primitives$String main() #33
    │   ├── decls[33] > verb:
    │   │   └── signature: T twice(T) #34
    │   ├── decls[34] > verb:
    │   │   └── signature: @primitives$I64 lowByte(@primitives$I64) #35
    │   ├── decls[35] > verb:
    │   │   └── signature: @primitives$F64 hypotenuse(@primitives$F64, @primitives$F64) #36
    │   ├── decls[36] > verb:
    │   │   └── signature: @primitives$F64 heading(@primitives$F64, @primitives$F64) #37
    │   ├── decls[37] > verb:
    │   │   └── signature: Pair.zeros(T Type) #38
    │   ├── decls[38] > type:
    │   │   ├── name: Duo #39
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   ├── struct[0]: left : T
    │   │   └── struct[1]: right : T
    │   ├── decls[39] > type:
    │   │   ├── name: Rack #40
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: duos : @primitives$ListRef<app$Duo<T>>
    │   ├── decls[40] > type:
    │   │   ├── name: Tally #41
    │   │   ├── params: T Type, n @concepts$Int
    │   │   ├── kind: reference
    │   │   └── struct[0]: count : @primitives$I64
    │   ├── decls[41] > verb:
    │   │   └── signature: Rack(T Type) #42
    │   ├── decls[42] > verb:
    │   │   └── signature: Tally(T Type, n @concepts$Int) #43
    │   ├── decls[43] > type:
    │   │   ├── name: Grid #44
    │   │   ├── params: T Type, n @concepts$Int
    │   │   ├── kind: reference
    │   │   └── struct[0]: rows : app$Tally<@primitives$Array<T, n>, n>
    │   ├── decls[44] > verb:
    │   │   └── signature: Grid(T Type, n @concepts$Int) #45
    │   ├── decls[45] > verb:
    │   │   └── signature: @primitives$Unit racks() #46
    │   ├── decls[46] > verb:
    │   │   └── signature: ^@primitives$ListRef<T> emptyOf(T Type) #47
    │   ├── decls[47] > verb:
    │   │   └── signature: T zeroOf(T Type) #48
    │   ├── decls[48] > verb:
    │   │   └── signature: @primitives$I64 sized(this @primitives$I64, T Type) #49
    │   ├── decls[49] > verb:
    │   │   └── signature: @primitives$Unit bump(this @primitives$I64, T Type) mut #50
    │   ├── decls[50] > verb:
    │   │   └── signature: T unusedZero(T Type) #51
    │   ├── decls[51] > verb:
    │   │   └── signature: @primitives$Unit takers() #52
    │   ├── decls[52] > type:
    │   │   ├── name: Steps #53
    │   │   ├── kind: value
    │   │   └── struct[0]: n : @primitives$I64
    │   ├── decls[53] > verb:
    │   │   └── signature: Steps() #54
    │   └── decls[54] > verb:
    │       └── signature: @primitives$Unit drives() #55
    └── packages[1] > package:
        ├── name: shapes
        ├── decls[0] > alias:
        │   ├── name: Float #56
        │   └── target: @primitives$F64
        ├── decls[1] > alias:
        │   ├── name: Unit #57
        │   └── target: @primitives$Unit
        ├── decls[2] > alias:
        │   ├── name: String #58
        │   └── target: @primitives$String
        ├── decls[3] > type:
        │   ├── name: Vec2 #59
        │   ├── kind: value
        │   ├── struct[0]: x : @primitives$F64
        │   └── struct[1]: y : @primitives$F64
        ├── decls[4] > verb:
        │   └── signature: Vec2(@primitives$F64, @primitives$F64) #60
        ├── decls[5] > verb:
        │   └── signature: Vec2.zero() #61
        ├── decls[6] > verb:
        │   └── signature: Vec2{x @primitives$F64; y @primitives$F64 = ...} #62
        ├── decls[7] > verb:
        │   └── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #63
        ├── decls[8] > verb:
        │   └── signature: shapes$Vec2 ~(shapes$Vec2) #64
        ├── decls[9] > verb:
        │   └── signature: shapes$Vec2 +(shapes$Vec2, @concepts$Float) #65
        ├── decls[10] > verb:
        │   └── signature: @primitives$F64 length(this shapes$Vec2) #66
        ├── decls[11] > verb:
        │   └── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$F64) mut #67
        ├── decls[12] > verb:
        │   └── signature: implicit Vec2(@concepts$Float) #68
        ├── decls[13] > type:
        │   ├── name: Shape #69
        │   ├── kind: reference
        │   ├── variant[0]: circle : @primitives$F64
        │   ├── variant[1]: square : @primitives$F64
        │   └── variant[2]: point : shapes$Vec2
        ├── decls[14] > type:
        │   ├── name: Corner #70
        │   ├── kind: value
        │   ├── enum[0]: topLeft
        │   ├── enum[1]: topRight
        │   ├── enum[2]: bottomLeft
        │   └── enum[3]: bottomRight
        ├── decls[15] > enum_map:
        │   ├── map: shapes$Corner.label #71
        │   └── type: @primitives$String
        ├── decls[16] > type:
        │   ├── name: Meters #72
        │   ├── kind: value
        │   └── struct[0]: _value : @primitives$F64
        ├── decls[17] > verb:
        │   └── signature: Meters(@primitives$F64) #73
        ├── decls[18] > verb:
        │   └── signature: shapes$Meters +(shapes$Meters, shapes$Meters) #74
        ├── decls[19] > verb:
        │   └── signature: @primitives$F64 inFeet(shapes$Meters) #75
        ├── decls[20] > verb:
        │   └── signature: @primitives$F64 _half(@primitives$F64) #76
        ├── decls[21] > verb:
        │   └── signature: @primitives$F64 area(&shapes$Shape) #77
        ├── decls[22] > verb:
        │   └── signature: @primitives$Unit drive(this S, @primitives$Bool[this S] mut) mut #78
        └── decls[23] > verb:
            └── signature: implicit @primitives$String(shapes$Vec2) #79
