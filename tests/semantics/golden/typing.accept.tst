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
    │   │   ├── signature: @primitives$Bool if(@primitives$Bool, @concepts$Block) #7
    │   │   ├── params[0]: condition #1 : @primitives$Bool
    │   │   ├── params[1]: body #2 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0]: condition #1 : @primitives$Bool
    │   │   │   └── args[1]: body #2 : @concepts$Block
    │   │   └── body[1] > return: condition #1 : @primitives$Bool
    │   ├── decls[7] > verb:
    │   │   ├── signature: @primitives$Unit elif(this @primitives$Bool, @primitives$Bool, @concepts$Block) mut #8
    │   │   ├── params[0]: this #3 : @primitives$Bool
    │   │   ├── params[1]: condition #4 : @primitives$Bool
    │   │   ├── params[2]: body #5 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > call:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── callee: @operators$conjoin
    │   │   │   │   ├── args[0] > call:
    │   │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   │   ├── callee: @operators$not
    │   │   │   │   │   └── args[0]: this #3 : @primitives$Bool
    │   │   │   │   └── args[1]: condition #4 : @primitives$Bool
    │   │   │   └── args[1]: body #5 : @concepts$Block
    │   │   ├── body[1] > assign:
    │   │   │   ├── target: this #3 : @primitives$Bool
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Bool
    │   │   │       ├── callee: @operators$disjoin
    │   │   │       ├── args[0]: this #3 : @primitives$Bool
    │   │   │       └── args[1]: condition #4 : @primitives$Bool
    │   │   └── body[2] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[8] > verb:
    │   │   ├── signature: @primitives$Unit else(this @primitives$Bool, @concepts$Block) #9
    │   │   ├── params[0]: this #6 : @primitives$Bool
    │   │   ├── params[1]: body #7 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > call:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── callee: @operators$not
    │   │   │   │   └── args[0]: this #6 : @primitives$Bool
    │   │   │   └── args[1]: body #7 : @concepts$Block
    │   │   └── body[1] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[9] > verb:
    │   │   ├── signature: @primitives$Unit to(this @primitives$I64, @primitives$I64, @concepts$Block) mut #10
    │   │   ├── params[0]: this #8 : @primitives$I64
    │   │   ├── params[1]: end #9 : @primitives$I64
    │   │   ├── params[2]: body #10 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$repeat
    │   │   │   ├── args[0] > call:
    │   │   │   │   ├── type: @primitives$I64
    │   │   │   │   ├── callee: @operators$add
    │   │   │   │   ├── args[0] > call:
    │   │   │   │   │   ├── type: @primitives$I64
    │   │   │   │   │   ├── callee: @operators$add
    │   │   │   │   │   ├── args[0]: end #9 : @primitives$I64
    │   │   │   │   │   └── args[1] > call:
    │   │   │   │   │       ├── type: @primitives$I64
    │   │   │   │   │       ├── callee: @operators$negate
    │   │   │   │   │       └── args[0]: this #8 : @primitives$I64
    │   │   │   │   └── args[1] > construct:
    │   │   │   │       ├── type: @primitives$I64
    │   │   │   │       ├── ctor: @primitives$I64
    │   │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   │   ├── args[1] > block[0] > do > call:
    │   │   │   │   ├── type: @primitives$Unit
    │   │   │   │   ├── callee: @controlflow$branch
    │   │   │   │   ├── args[0]: true : @primitives$Bool
    │   │   │   │   └── args[1]: body #10 : @concepts$Block
    │   │   │   └── args[1] > block[1] > assign:
    │   │   │       ├── target: this #8 : @primitives$I64
    │   │   │       └── value > call:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── callee: @operators$add
    │   │   │           ├── args[0]: this #8 : @primitives$I64
    │   │   │           └── args[1] > construct:
    │   │   │               ├── type: @primitives$I64
    │   │   │               ├── ctor: @primitives$I64
    │   │   │               └── args[0]: 1 : @concepts$Int
    │   │   └── body[1] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit say(@primitives$String) #11
    │   │   ├── params[0]: text #11 : @primitives$String
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @runtime$print
    │   │   │   ├── args[0]: @program$console : @runtime$Console
    │   │   │   └── args[1]: text #11 : @primitives$String
    │   │   └── body[1] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[11] > verb:
    │   │   ├── signature: T pick(T, T, @primitives$Bool) #12
    │   │   └── body: checked per instance
    │   ├── decls[12] > type:
    │   │   ├── name: Pair #13
    │   │   ├── params: T Type
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : T
    │   │   └── struct[1]: right : T
    │   ├── decls[13] > verb:
    │   │   ├── signature: Pair(T, T) #14
    │   │   └── body: checked per instance
    │   ├── decls[14] > verb:
    │   │   ├── signature: T sum(app$Pair<T>) #15
    │   │   └── body: checked per instance
    │   ├── decls[15] > verb:
    │   │   ├── signature: @primitives$I64 count(@primitives$Array<T, n>) #16
    │   │   └── body: checked per instance
    │   ├── decls[16] > verb:
    │   │   ├── signature: @primitives$I64 measured(@primitives$Array<@primitives$I64, n>, n @concepts$Int) #17
    │   │   └── body: checked per instance
    │   ├── decls[17] > verb:
    │   │   ├── signature: @primitives$I64 relayed(@primitives$Array<@primitives$I64, 3>, n @concepts$Int) #18
    │   │   └── body: checked per instance
    │   ├── decls[18] > verb:
    │   │   ├── signature: @primitives$I64 forwarded(@primitives$Array<@primitives$I64, 3>, count @concepts$Int) #19
    │   │   └── body: checked per instance
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$I64 sizedLike(@primitives$Array<@primitives$I64, 3>, n @concepts$Int) #20
    │   │   └── body: checked per instance
    │   ├── decls[20] > verb:
    │   │   ├── signature: app$Pair<@primitives$I64> pairOf(@concepts$Int, @concepts$Int) #21
    │   │   ├── params[0]: x #12 : @concepts$Int
    │   │   ├── params[1]: y #13 : @concepts$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<@primitives$I64>
    │   │       ├── ctor: Pair #14 with T = @primitives$I64
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: @primitives$I64
    │   │       │   ├── ctor: @primitives$I64
    │   │       │   └── args[0]: x #12 : @concepts$Int
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$I64
    │   │           ├── ctor: @primitives$I64
    │   │           └── args[0]: y #13 : @concepts$Int
    │   ├── decls[21] > verb:
    │   │   ├── signature: app$Pair<@primitives$F64> pairOf(@concepts$Float, @concepts$Float) #22
    │   │   ├── params[0]: x #14 : @concepts$Float
    │   │   ├── params[1]: y #15 : @concepts$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<@primitives$F64>
    │   │       ├── ctor: Pair #14 with T = @primitives$F64
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── ctor: @primitives$F64
    │   │       │   └── args[0]: x #14 : @concepts$Float
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: y #15 : @concepts$Float
    │   ├── decls[22] > verb:
    │   │   ├── signature: @primitives$F64?@primitives$String safeDivide(@primitives$F64, @primitives$F64) #23
    │   │   ├── params[0]: numerator #16 : @primitives$F64
    │   │   ├── params[1]: denominator #17 : @primitives$F64
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Bool
    │   │   │   ├── callee: if #7
    │   │   │   ├── args[0] > call:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── callee: @operators$equal
    │   │   │   │   ├── args[0]: denominator #17 : @primitives$F64
    │   │   │   │   └── args[1] > construct:
    │   │   │   │       ├── type: @primitives$F64
    │   │   │   │       ├── ctor: @primitives$F64
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "zero" : @concepts$String
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: @primitives$Bool
    │   │   │   ├── callee: if #7
    │   │   │   ├── args[0] > call:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── callee: @operators$lessThan
    │   │   │   │   ├── args[0]: denominator #17 : @primitives$F64
    │   │   │   │   └── args[1] > construct:
    │   │   │   │       ├── type: @primitives$F64
    │   │   │   │       ├── ctor: @primitives$F64
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "negative" : @concepts$String
    │   │   └── body[2] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$divide
    │   │       ├── args[0]: numerator #16 : @primitives$F64
    │   │       └── args[1]: denominator #17 : @primitives$F64
    │   ├── decls[23] > type:
    │   │   ├── name: Crew #24
    │   │   ├── kind: reference
    │   │   ├── struct[0]: lead : shapes$Shape
    │   │   └── struct[1]: backup : &shapes$Shape
    │   ├── decls[24] > verb:
    │   │   ├── signature: Crew(^shapes$Shape, &shapes$Shape) #25
    │   │   ├── params[0]: lead #18 : ^shapes$Shape
    │   │   ├── params[1]: backup #19 : &shapes$Shape
    │   │   └── body[0] > return > init:
    │   │       ├── type: app$Crew
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: lead (slot 0)
    │   │       │   └── value: lead #18 : shapes$Shape
    │   │       └── fields[1] > field:
    │   │           ├── name: backup (slot 1)
    │   │           └── value: backup #19 : &shapes$Shape
    │   ├── decls[25] > verb:
    │   │   ├── signature: ^shapes$Shape grown(^shapes$Shape) #26
    │   │   ├── params[0]: shape #20 : ^shapes$Shape
    │   │   ├── body[0] > let:
    │   │   │   ├── local: kept #21 : ^shapes$Shape
    │   │   │   └── value: shape #20 : shapes$Shape
    │   │   └── body[1] > return: kept #21 : shapes$Shape
    │   ├── decls[26] > verb:
    │   │   ├── signature: &shapes$Shape leadOf(&app$Crew) #27
    │   │   ├── params[0]: crew #22 : &app$Crew
    │   │   └── body[0] > return > field:
    │   │       ├── type: shapes$Shape
    │   │       ├── target: crew #22 : &app$Crew
    │   │       └── field: lead (slot 0)
    │   ├── decls[27] > type:
    │   │   ├── name: Holder #28
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: item : T
    │   ├── decls[28] > verb:
    │   │   ├── signature: Holder(T) #29
    │   │   └── body: checked per instance
    │   ├── decls[29] > verb:
    │   │   ├── signature: ^T relayed(^T) #30
    │   │   └── body: checked per instance
    │   ├── decls[30] > verb:
    │   │   ├── signature: ^T zeroed(T) #31
    │   │   └── body: checked per instance
    │   ├── decls[31] > verb:
    │   │   ├── signature: @primitives$String describe(shapes$Corner) #32
    │   │   ├── params[0]: corner #23 : shapes$Corner
    │   │   └── body[0] > return > match:
    │   │       ├── type: @primitives$String
    │   │       ├── scrutinees[0]: corner #23 : shapes$Corner
    │   │       ├── arms[0] > arm:
    │   │       │   ├── patterns[0]: topLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: @primitives$String
    │   │       │       ├── ctor: @primitives$String
    │   │       │       └── args[0]: "top" : @concepts$String
    │   │       ├── arms[1] > arm:
    │   │       │   ├── patterns[0]: topRight
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: @primitives$String
    │   │       │       ├── ctor: @primitives$String
    │   │       │       └── args[0]: "top" : @concepts$String
    │   │       ├── arms[2] > arm:
    │   │       │   ├── patterns[0]: bottomLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: @primitives$String
    │   │       │       ├── ctor: @primitives$String
    │   │       │       └── args[0]: "bottom" : @concepts$String
    │   │       └── arms[3] > arm:
    │   │           ├── patterns[0]: bottomRight
    │   │           └── body[0] > return > construct:
    │   │               ├── type: @primitives$String
    │   │               ├── ctor: @primitives$String
    │   │               └── args[0]: "bottom" : @concepts$String
    │   ├── decls[32] > verb:
    │   │   ├── signature: @primitives$Unit main() #33
    │   │   ├── params:
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0] > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "hello" : @concepts$String
    │   │   ├── body[1] > let:
    │   │   │   ├── local: origin #24 : shapes$Vec2
    │   │   │   └── value > construct:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2.zero #43
    │   │   │       └── args:
    │   │   ├── body[2] > let:
    │   │   │   ├── local: moved #25 : shapes$Vec2
    │   │   │   └── value > op:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #47
    │   │   │       ├── left: origin #24 : shapes$Vec2
    │   │   │       └── right: 3.0 : @concepts$Float
    │   │   ├── body[3] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: scale #49
    │   │   │   ├── args[0]: moved #25 : shapes$Vec2
    │   │   │   └── args[1] > construct:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── ctor: @primitives$F64
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[4] > let:
    │   │   │   ├── local: flat #26 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #44
    │   │   │       └── fields[0] > field:
    │   │   │           ├── name: x (slot 0)
    │   │   │           └── value > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[5] > let:
    │   │   │   ├── local: size #27 : @primitives$F64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: length #48
    │   │   │       └── args[0]: moved #25 : shapes$Vec2
    │   │   ├── body[6] > let:
    │   │   │   ├── local: shape #28 : shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[7] > let:
    │   │   │   ├── local: covered #29 : @primitives$F64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: area #59
    │   │   │       └── args[0]: shape #28 : shapes$Shape
    │   │   ├── body[8] > let:
    │   │   │   ├── local: radius #30 : @primitives$F64
    │   │   │   └── value > case_read:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── target: shape #28 : shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── handler:
    │   │   │           ├── binder: none
    │   │   │           └── body[0] > resolve > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[9] > let:
    │   │   │   ├── local: half #32 : @primitives$F64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: safeDivide #23
    │   │   │       ├── args[0]: covered #29 : @primitives$F64
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── ctor: @primitives$F64
    │   │   │       │   └── args[0]: 2.0 : @concepts$Float
    │   │   │       └── handler:
    │   │   │           ├── binder: reason #31 : @primitives$String
    │   │   │           ├── body[0] > do > call:
    │   │   │           │   ├── type: @primitives$Unit
    │   │   │           │   ├── callee: say #11
    │   │   │           │   └── args[0]: reason #31 : @primitives$String
    │   │   │           └── body[1] > resolve > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[10] > let:
    │   │   │   ├── local: picked #33 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: pick #12 with T = @primitives$I64
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$I64
    │   │   │       │   ├── ctor: @primitives$I64
    │   │   │       │   └── args[0]: 1 : @concepts$Int
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$I64
    │   │   │       │   ├── ctor: @primitives$I64
    │   │   │       │   └── args[0]: 2 : @concepts$Int
    │   │   │       └── args[2]: true : @primitives$Bool
    │   │   ├── body[11] > let:
    │   │   │   ├── local: chance #34 : @primitives$F64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: pick #12 with T = @primitives$F64
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── ctor: @primitives$F64
    │   │   │       │   └── args[0]: 0.5 : @concepts$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── ctor: @primitives$F64
    │   │   │       │   └── args[0]: 1.5 : @concepts$Float
    │   │   │       └── args[2]: false : @primitives$Bool
    │   │   ├── body[12] > let:
    │   │   │   ├── local: pair #35 : app$Pair<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$I64>
    │   │   │       ├── ctor: Pair #14 with T = @primitives$I64
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$I64
    │   │   │       │   ├── ctor: @primitives$I64
    │   │   │       │   └── args[0]: 3 : @concepts$Int
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 4 : @concepts$Int
    │   │   ├── body[13] > let:
    │   │   │   ├── local: total #36 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: sum #15 with T = @primitives$I64
    │   │   │       └── args[0]: pair #35 : app$Pair<@primitives$I64>
    │   │   ├── body[14] > let:
    │   │   │   ├── local: floats #37 : app$Pair<@primitives$F64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$F64>
    │   │   │       ├── ctor: Pair #14 with T = @primitives$F64
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── ctor: @primitives$F64
    │   │   │       │   └── args[0]: 1.0 : @concepts$Float
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[15] > let:
    │   │   │   ├── local: both #38 : @primitives$F64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: sum #15 with T = @primitives$F64
    │   │   │       └── args[0]: floats #37 : app$Pair<@primitives$F64>
    │   │   ├── body[16] > let:
    │   │   │   ├── local: spare #39 : ^shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[17] > assign:
    │   │   │   ├── target: spare #39 : shapes$Shape
    │   │   │   └── value > call:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── callee: grown #26
    │   │   │       └── args[0]: spare #39 : shapes$Shape
    │   │   ├── body[18] > let:
    │   │   │   ├── local: crew #40 : app$Crew
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Crew
    │   │   │       ├── ctor: Crew #25
    │   │   │       ├── args[0]: spare #39 : shapes$Shape
    │   │   │       └── args[1]: shape #28 : shapes$Shape
    │   │   ├── body[19] > let:
    │   │   │   ├── local: lead #41 : &shapes$Shape
    │   │   │   └── value > call:
    │   │   │       ├── type: &shapes$Shape
    │   │   │       ├── callee: leadOf #27
    │   │   │       └── args[0]: crew #40 : app$Crew
    │   │   ├── body[20] > let:
    │   │   │   ├── local: shapes #42 : @primitives$ArrayRef<shapes$Shape, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<shapes$Shape, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef.roaming with T = shapes$Shape, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<shapes$Shape, 2>
    │   │   │           ├── items[0] > case:
    │   │   │           │   ├── type: shapes$Shape
    │   │   │           │   ├── case: circle
    │   │   │           │   └── payload > construct:
    │   │   │           │       ├── type: @primitives$F64
    │   │   │           │       ├── ctor: @primitives$F64
    │   │   │           │       └── args[0]: 3.0 : @concepts$Float
    │   │   │           └── items[1] > case:
    │   │   │               ├── type: shapes$Shape
    │   │   │               ├── case: circle
    │   │   │               └── payload > construct:
    │   │   │                   ├── type: @primitives$F64
    │   │   │                   ├── ctor: @primitives$F64
    │   │   │                   └── args[0]: 4.0 : @concepts$Float
    │   │   ├── body[21] > let:
    │   │   │   ├── local: second #43 : &shapes$Shape
    │   │   │   └── value > subscript:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── impl: @primitives$[] with T = shapes$Shape, n = 2
    │   │   │       ├── target: shapes #42 : @primitives$ArrayRef<shapes$Shape, 2>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 2 : @concepts$Int
    │   │   ├── body[22] > let:
    │   │   │   ├── local: tiles #45 : @primitives$ArrayRef<@primitives$I64, 4>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<@primitives$I64, 4>
    │   │   │       ├── ctor: @primitives$ArrayRef.fill with T = @primitives$I64, n = 4
    │   │   │       ├── args[0]: 4 : @concepts$Int
    │   │   │       └── args[1] > lambda:
    │   │   │           ├── type: @primitives$I64[@primitives$I64]
    │   │   │           ├── params[0]: n #44 : @primitives$I64
    │   │   │           └── body[0] > return > call:
    │   │   │               ├── type: @primitives$I64
    │   │   │               ├── callee: @operators$multiply
    │   │   │               ├── args[0]: n #44 : @primitives$I64
    │   │   │               └── args[1]: n #44 : @primitives$I64
    │   │   ├── body[23] > let:
    │   │   │   ├── local: corners #46 : @primitives$ArrayRef<@primitives$I64, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<@primitives$I64, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef with T = @primitives$I64, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<@primitives$I64, 2>
    │   │   │           ├── items[0] > construct:
    │   │   │           │   ├── type: @primitives$I64
    │   │   │           │   ├── ctor: @primitives$I64
    │   │   │           │   └── args[0]: 1 : @concepts$Int
    │   │   │           └── items[1] > construct:
    │   │   │               ├── type: @primitives$I64
    │   │   │               ├── ctor: @primitives$I64
    │   │   │               └── args[0]: 2 : @concepts$Int
    │   │   ├── body[24] > let:
    │   │   │   ├── local: leads #47 : @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef with T = &shapes$Shape, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<&shapes$Shape, 2>
    │   │   │           ├── items[0]: lead #41 : &shapes$Shape
    │   │   │           └── items[1]: second #43 : &shapes$Shape
    │   │   ├── body[25] > let:
    │   │   │   ├── local: pointed #48 : @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef.refs with T = shapes$Shape, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<&shapes$Shape, 2>
    │   │   │           ├── items[0]: shape #28 : shapes$Shape
    │   │   │           └── items[1]: lead #41 : &shapes$Shape
    │   │   ├── body[26] > let:
    │   │   │   ├── local: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$Array<@primitives$I64, 3>
    │   │   │       ├── ctor: @primitives$Array with T = @primitives$I64, n = 3
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<@primitives$I64, 3>
    │   │   │           ├── items[0] > construct:
    │   │   │           │   ├── type: @primitives$I64
    │   │   │           │   ├── ctor: @primitives$I64
    │   │   │           │   └── args[0]: 1 : @concepts$Int
    │   │   │           ├── items[1] > construct:
    │   │   │           │   ├── type: @primitives$I64
    │   │   │           │   ├── ctor: @primitives$I64
    │   │   │           │   └── args[0]: 2 : @concepts$Int
    │   │   │           └── items[2] > construct:
    │   │   │               ├── type: @primitives$I64
    │   │   │               ├── ctor: @primitives$I64
    │   │   │               └── args[0]: 3 : @concepts$Int
    │   │   ├── body[27] > let:
    │   │   │   ├── local: first #50 : @primitives$I64
    │   │   │   └── value > subscript:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── impl: @primitives$[] with T = @primitives$I64, n = 3
    │   │   │       ├── target: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[28] > let:
    │   │   │   ├── local: length #51 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: count #16 with T = @primitives$I64, n = 3
    │   │   │       └── args[0]: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   ├── body[29] > let:
    │   │   │   ├── local: sized #52 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: measured #17 with n = 3
    │   │   │       ├── args[0]: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[30] > let:
    │   │   │   ├── local: like #53 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: sizedLike #20 with n = 3
    │   │   │       ├── args[0]: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[31] > let:
    │   │   │   ├── local: passed #54 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: forwarded #19 with count = 3
    │   │   │       ├── args[0]: numbers #49 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[32] > let:
    │   │   │   ├── local: ints #55 : app$Pair<@primitives$I64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$I64>
    │   │   │       ├── callee: pairOf #21
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[33] > let:
    │   │   │   ├── local: decimals #56 : app$Pair<@primitives$F64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$F64>
    │   │   │       ├── callee: pairOf #22
    │   │   │       ├── args[0]: 2.5 : @concepts$Float
    │   │   │       └── args[1]: 3.5 : @concepts$Float
    │   │   ├── body[34] > let:
    │   │   │   ├── local: label #57 : @primitives$String
    │   │   │   └── value > map_read:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: .topLeft : shapes$Corner
    │   │   │       └── map: label #53
    │   │   ├── body[35] > let:
    │   │   │   ├── local: side #58 : @primitives$String
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── callee: describe #32
    │   │   │       └── args[0]: .bottomRight : shapes$Corner
    │   │   ├── body[36] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0]: side #58 : @primitives$String
    │   │   ├── body[37] > let:
    │   │   │   ├── local: i #59 : @primitives$I64
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── ctor: @primitives$I64
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[38] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: to #10
    │   │   │   ├── args[0]: i #59 : @primitives$I64
    │   │   │   ├── args[1] > construct:
    │   │   │   │   ├── type: @primitives$I64
    │   │   │   │   ├── ctor: @primitives$I64
    │   │   │   │   └── args[0]: 3 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > call:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── callee: describe #32
    │   │   │           └── args[0]: .topLeft : shapes$Corner
    │   │   ├── body[39] > let:
    │   │   │   ├── local: double #61 : @primitives$F64[@primitives$F64]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: @primitives$F64[@primitives$F64]
    │   │   │       ├── params[0]: value #60 : @primitives$F64
    │   │   │       └── body[0] > return > call:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── callee: @operators$multiply
    │   │   │           ├── args[0]: value #60 : @primitives$F64
    │   │   │           └── args[1] > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[40] > let:
    │   │   │   ├── local: doubled #62 : @primitives$F64
    │   │   │   └── value > call_value:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: double #61 : @primitives$F64[@primitives$F64]
    │   │   │       └── args[0]: half #32 : @primitives$F64
    │   │   ├── body[41] > let:
    │   │   │   ├── local: chain #63 : @primitives$Bool
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Bool
    │   │   │       ├── callee: if #7
    │   │   │       ├── args[0] > call:
    │   │   │       │   ├── type: @primitives$Bool
    │   │   │       │   ├── callee: @operators$lessThan
    │   │   │       │   ├── args[0]: total #36 : @primitives$I64
    │   │   │       │   └── args[1] > construct:
    │   │   │       │       ├── type: @primitives$I64
    │   │   │       │       ├── ctor: @primitives$I64
    │   │   │       │       └── args[0]: 5 : @concepts$Int
    │   │   │       └── args[1] > block[0] > do > call:
    │   │   │           ├── type: @primitives$Unit
    │   │   │           ├── callee: say #11
    │   │   │           └── args[0] > construct:
    │   │   │               ├── type: @primitives$String
    │   │   │               ├── ctor: @primitives$String
    │   │   │               └── args[0]: "small" : @concepts$String
    │   │   ├── body[42] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: elif #8
    │   │   │   ├── args[0]: chain #63 : @primitives$Bool
    │   │   │   ├── args[1] > call:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── callee: @operators$equal
    │   │   │   │   ├── args[0]: total #36 : @primitives$I64
    │   │   │   │   └── args[1] > construct:
    │   │   │   │       ├── type: @primitives$I64
    │   │   │   │       ├── ctor: @primitives$I64
    │   │   │   │       └── args[0]: 7 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── ctor: @primitives$String
    │   │   │           └── args[0]: "seven" : @concepts$String
    │   │   ├── body[43] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: else #9
    │   │   │   ├── args[0]: chain #63 : @primitives$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── ctor: @primitives$String
    │   │   │           └── args[0]: "large" : @concepts$String
    │   │   ├── body[44] > let:
    │   │   │   ├── local: drawn #64 : ^shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 5.0 : @concepts$Float
    │   │   ├── body[45] > let:
    │   │   │   ├── local: team #65 : ^app$Crew
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Crew
    │   │   │       ├── ctor: Crew #25
    │   │   │       ├── args[0]: drawn #64 : shapes$Shape
    │   │   │       └── args[1]: shape #28 : shapes$Shape
    │   │   ├── body[46] > let:
    │   │   │   ├── local: kept #66 : app$Crew
    │   │   │   └── value: team #65 : app$Crew
    │   │   ├── body[47] > let:
    │   │   │   ├── local: boxed #67 : ^app$Holder<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Holder<@primitives$I64>
    │   │   │       ├── ctor: Holder #29 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[48] > let:
    │   │   │   ├── local: spelled #68 : ^app$Holder<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Holder<@primitives$I64>
    │   │   │       ├── ctor: Holder #29 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 2 : @concepts$Int
    │   │   ├── body[49] > let:
    │   │   │   ├── local: shelf #69 : app$Holder<@primitives$I64>
    │   │   │   └── value: boxed #67 : app$Holder<@primitives$I64>
    │   │   ├── body[50] > let:
    │   │   │   ├── local: relayedInt #70 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: relayed #30 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 5 : @concepts$Int
    │   │   ├── body[51] > let:
    │   │   │   ├── local: relayedShape #71 : shapes$Shape
    │   │   │   └── value > call:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── callee: relayed #30 with T = shapes$Shape
    │   │   │       └── args[0] > case:
    │   │   │           ├── type: shapes$Shape
    │   │   │           ├── case: circle
    │   │   │           └── payload > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 6.0 : @concepts$Float
    │   │   ├── body[52] > let:
    │   │   │   ├── local: nothing #72 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: zeroed #31 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 7 : @concepts$Int
    │   │   ├── body[53] > let:
    │   │   │   ├── local: who #73 : @primitives$String
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "world" : @concepts$String
    │   │   ├── body[54] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0] > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String.escaped
    │   │   │       └── args[0] > text:
    │   │   │           ├── type: @concepts$String
    │   │   │           ├── pieces[0]: "hello "
    │   │   │           ├── pieces[1]: who #73 : @primitives$String
    │   │   │           └── pieces[2]: "\\n"
    │   │   └── body[55] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[33] > verb:
    │   │   ├── signature: T twice(T) #34
    │   │   └── body: checked per instance
    │   ├── decls[34] > verb:
    │   │   ├── signature: @primitives$I64 lowByte(@primitives$I64) #35
    │   │   ├── params[0]: value #74 : @primitives$I64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$I64
    │   │       ├── callee: @math$bitAnd
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$I64
    │   │       │   ├── callee: @math$shiftRightLogical
    │   │       │   ├── args[0]: value #74 : @primitives$I64
    │   │       │   └── args[1] > construct:
    │   │       │       ├── type: @primitives$I64
    │   │       │       ├── ctor: @primitives$I64
    │   │       │       └── args[0]: 8 : @concepts$Int
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$I64
    │   │           ├── ctor: @primitives$I64
    │   │           └── args[0]: 255 : @concepts$Int
    │   ├── decls[35] > verb:
    │   │   ├── signature: @primitives$F64 hypotenuse(@primitives$F64, @primitives$F64) #36
    │   │   ├── params[0]: a #75 : @primitives$F64
    │   │   ├── params[1]: b #76 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @math$sqrt
    │   │       └── args[0] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @math$fma
    │   │           ├── args[0]: a #75 : @primitives$F64
    │   │           ├── args[1]: a #75 : @primitives$F64
    │   │           └── args[2] > call:
    │   │               ├── type: @primitives$F64
    │   │               ├── callee: @operators$multiply
    │   │               ├── args[0]: b #76 : @primitives$F64
    │   │               └── args[1]: b #76 : @primitives$F64
    │   └── decls[36] > verb:
    │       ├── signature: @primitives$F64 heading(@primitives$F64, @primitives$F64) #37
    │       ├── params[0]: y #77 : @primitives$F64
    │       ├── params[1]: x #78 : @primitives$F64
    │       └── body[0] > return > call:
    │           ├── type: @primitives$F64
    │           ├── callee: @math$atan2
    │           ├── args[0]: y #77 : @primitives$F64
    │           └── args[1]: x #78 : @primitives$F64
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > alias:
    │   │   ├── name: Float #38
    │   │   └── target: @primitives$F64
    │   ├── decls[1] > alias:
    │   │   ├── name: Unit #39
    │   │   └── target: @primitives$Unit
    │   ├── decls[2] > alias:
    │   │   ├── name: String #40
    │   │   └── target: @primitives$String
    │   ├── decls[3] > type:
    │   │   ├── name: Vec2 #41
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$F64
    │   │   └── struct[1]: y : @primitives$F64
    │   ├── decls[4] > verb:
    │   │   ├── signature: Vec2(@primitives$F64, @primitives$F64) #42
    │   │   ├── params[0]: x #79 : @primitives$F64
    │   │   ├── params[1]: y #80 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #79 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #80 : @primitives$F64
    │   ├── decls[5] > verb:
    │   │   ├── signature: Vec2.zero() #43
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── ctor: @primitives$F64
    │   │       │       └── args[0]: 0.0 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$F64
    │   │               ├── ctor: @primitives$F64
    │   │               └── args[0]: 0.0 : @concepts$Float
    │   ├── decls[6] > verb:
    │   │   ├── signature: Vec2{x @primitives$F64; y @primitives$F64 = ...} #44
    │   │   ├── params[0]: x #83 : @primitives$F64
    │   │   ├── params[1]: y #84 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #83 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #84 : @primitives$F64
    │   ├── decls[7] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #45
    │   │   ├── params[0]: left #85 : shapes$Vec2
    │   │   ├── params[1]: right #86 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #42
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$add
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: left #85 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: right #86 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #85 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #86 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[8] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #46
    │   │   ├── params[0]: value #87 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #42
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$negate
    │   │       │   └── args[0] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: value #87 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$negate
    │   │           └── args[0] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: value #87 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[9] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, @concepts$Float) #47
    │   │   ├── params[0]: left #88 : shapes$Vec2
    │   │   ├── params[1]: right #89 : @concepts$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: shapes$Vec2
    │   │       ├── op: +
    │   │       ├── impl: + #45
    │   │       ├── left: left #88 : shapes$Vec2
    │   │       └── right > construct:
    │   │           ├── type: shapes$Vec2
    │   │           ├── ctor: Vec2 #50
    │   │           └── args[0]: right #89 : @concepts$Float
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$F64 length(this shapes$Vec2) #48
    │   │   ├── params[0]: this #90 : shapes$Vec2
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$add
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$multiply
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: this #90 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: this #90 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$multiply
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: this #90 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: this #90 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[11] > verb:
    │   │   ├── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$F64) mut #49
    │   │   ├── params[0]: this #91 : shapes$Vec2
    │   │   ├── params[1]: by #92 : @primitives$F64
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #91 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #91 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── args[1]: by #92 : @primitives$F64
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #91 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #91 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── args[1]: by #92 : @primitives$F64
    │   │   └── body[2] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[12] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Float) #50
    │   │   ├── params[0]: value #93 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── ctor: @primitives$F64
    │   │       │       └── args[0]: value #93 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$F64
    │   │               ├── ctor: @primitives$F64
    │   │               └── args[0]: value #93 : @concepts$Float
    │   ├── decls[13] > type:
    │   │   ├── name: Shape #51
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : @primitives$F64
    │   │   ├── variant[1]: square : @primitives$F64
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[14] > type:
    │   │   ├── name: Corner #52
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[15] > enum_map:
    │   │   ├── map: shapes$Corner.label #53
    │   │   ├── type: @primitives$String
    │   │   ├── entries[0]:
    │   │   │   ├── member: topLeft
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "top left" : @concepts$String
    │   │   ├── entries[1]:
    │   │   │   ├── member: topRight
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "top right" : @concepts$String
    │   │   ├── entries[2]:
    │   │   │   ├── member: bottomLeft
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "bottom left" : @concepts$String
    │   │   └── entries[3]:
    │   │       ├── member: bottomRight
    │   │       └── value > construct:
    │   │           ├── type: @primitives$String
    │   │           ├── ctor: @primitives$String
    │   │           └── args[0]: "bottom right" : @concepts$String
    │   ├── decls[16] > type:
    │   │   ├── name: Meters #54
    │   │   ├── kind: value
    │   │   └── struct[0]: _value : @primitives$F64
    │   ├── decls[17] > verb:
    │   │   ├── signature: Meters(@primitives$F64) #55
    │   │   ├── params[0]: value #94 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Meters
    │   │       └── fields[0] > field:
    │   │           ├── name: _value (slot 0)
    │   │           └── value: value #94 : @primitives$F64
    │   ├── decls[18] > verb:
    │   │   ├── signature: shapes$Meters +(shapes$Meters, shapes$Meters) #56
    │   │   ├── params[0]: left #95 : shapes$Meters
    │   │   ├── params[1]: right #96 : shapes$Meters
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Meters
    │   │       ├── ctor: Meters #55
    │   │       └── args[0] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #95 : shapes$Meters
    │   │           │   └── field: _value (slot 0)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #96 : shapes$Meters
    │   │               └── field: _value (slot 0)
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$F64 inFeet(shapes$Meters) #57
    │   │   ├── params[0]: distance #97 : shapes$Meters
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$multiply
    │   │       ├── args[0] > field:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── target: distance #97 : shapes$Meters
    │   │       │   └── field: _value (slot 0)
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 3.28 : @concepts$Float
    │   ├── decls[20] > verb:
    │   │   ├── signature: @primitives$F64 _half(@primitives$F64) #58
    │   │   ├── params[0]: value #98 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$divide
    │   │       ├── args[0]: value #98 : @primitives$F64
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[21] > verb:
    │       ├── signature: @primitives$F64 area(&shapes$Shape) #59
    │       ├── params[0]: shape #99 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: @primitives$F64
    │           ├── scrutinees[0]: shape #99 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #100 : @primitives$F64 <- circle
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: @operators$multiply
    │           │       ├── args[0]: r #100 : @primitives$F64
    │           │       └── args[1]: r #100 : @primitives$F64
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #101 : @primitives$F64 <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: _half #58
    │           │       └── args[0] > call:
    │           │           ├── type: @primitives$F64
    │           │           ├── callee: @operators$add
    │           │           ├── args[0]: s #101 : @primitives$F64
    │           │           └── args[1]: s #101 : @primitives$F64
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: @primitives$F64
    │                   ├── ctor: @primitives$F64
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── instances[0] > instance:
    │   ├── of: pick #12 with T = @primitives$F64
    │   ├── params[0]: first #118 : @primitives$F64
    │   ├── params[1]: second #119 : @primitives$F64
    │   ├── params[2]: takeFirst #120 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #121 : @primitives$F64
    │   │   └── value: second #119 : @primitives$F64
    │   ├── body[1] > let:
    │   │   ├── local: ran #122 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #120 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #121 : @primitives$F64
    │   │           └── value: first #118 : @primitives$F64
    │   └── body[2] > return: chosen #121 : @primitives$F64
    ├── instances[1] > instance:
    │   ├── of: pick #12 with T = @primitives$I64
    │   ├── params[0]: first #123 : @primitives$I64
    │   ├── params[1]: second #124 : @primitives$I64
    │   ├── params[2]: takeFirst #125 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #126 : @primitives$I64
    │   │   └── value: second #124 : @primitives$I64
    │   ├── body[1] > let:
    │   │   ├── local: ran #127 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #125 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #126 : @primitives$I64
    │   │           └── value: first #123 : @primitives$I64
    │   └── body[2] > return: chosen #126 : @primitives$I64
    ├── instances[2] > instance:
    │   ├── of: Pair #14 with T = @primitives$F64
    │   ├── params[0]: left #128 : @primitives$F64
    │   ├── params[1]: right #129 : @primitives$F64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$F64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #128 : @primitives$F64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #129 : @primitives$F64
    ├── instances[3] > instance:
    │   ├── of: Pair #14 with T = @primitives$I64
    │   ├── params[0]: left #130 : @primitives$I64
    │   ├── params[1]: right #131 : @primitives$I64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$I64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #130 : @primitives$I64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #131 : @primitives$I64
    ├── instances[4] > instance:
    │   ├── of: sum #15 with T = @primitives$F64
    │   ├── params[0]: pair #116 : app$Pair<@primitives$F64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$F64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$F64
    │       │   ├── target: pair #116 : app$Pair<@primitives$F64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$F64
    │           ├── target: pair #116 : app$Pair<@primitives$F64>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #15 with T = @primitives$I64
    │   ├── params[0]: pair #117 : app$Pair<@primitives$I64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$I64
    │       │   ├── target: pair #117 : app$Pair<@primitives$I64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$I64
    │           ├── target: pair #117 : app$Pair<@primitives$I64>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #16 with T = @primitives$I64, n = 3
    │   ├── params[0]: values #115 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #17 with n = 3
    │   ├── params[0]: values #114 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #18 with n = 3
    │   ├── params[0]: values #110 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: measured #17 with n = 3
    │       ├── args[0]: values #110 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #19 with count = 3
    │   ├── params[0]: values #109 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: relayed #18 with n = 3
    │       ├── args[0]: values #109 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    ├── instances[10] > instance:
    │   ├── of: sizedLike #20 with n = 3
    │   ├── params[0]: values #111 : @primitives$Array<@primitives$I64, 3>
    │   ├── body[0] > let:
    │   │   ├── local: measure #113 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │   │   └── value > lambda:
    │   │       ├── type: @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │   │       ├── params[0]: held #112 : @primitives$Array<@primitives$I64, 3>
    │   │       └── body[0] > return > construct:
    │   │           ├── type: @primitives$I64
    │   │           ├── ctor: @primitives$I64
    │   │           └── args[0]: n = 3 : @concepts$Int
    │   └── body[1] > return > call_value:
    │       ├── type: @primitives$I64
    │       ├── callee: measure #113 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │       └── args[0]: values #111 : @primitives$Array<@primitives$I64, 3>
    ├── instances[11] > instance:
    │   ├── of: Holder #29 with T = @primitives$I64
    │   ├── params[0]: item #108 : @primitives$I64
    │   └── body[0] > return > init:
    │       ├── type: app$Holder<@primitives$I64>
    │       └── fields[0] > field:
    │           ├── name: item (slot 0)
    │           └── value: item #108 : @primitives$I64
    ├── instances[12] > instance:
    │   ├── of: relayed #30 with T = @primitives$I64
    │   ├── params[0]: seed #106 : ^@primitives$I64
    │   ├── body[0] > let:
    │   │   ├── local: kept #107 : @primitives$I64
    │   │   └── value: seed #106 : @primitives$I64
    │   └── body[1] > return: kept #107 : @primitives$I64
    ├── instances[13] > instance:
    │   ├── of: relayed #30 with T = shapes$Shape
    │   ├── params[0]: seed #104 : ^shapes$Shape
    │   ├── body[0] > let:
    │   │   ├── local: kept #105 : ^shapes$Shape
    │   │   └── value: seed #104 : shapes$Shape
    │   └── body[1] > return: kept #105 : shapes$Shape
    └── instances[14] > instance:
        ├── of: zeroed #31 with T = @primitives$I64
        ├── params[0]: like #102 : @primitives$I64
        ├── body[0] > let:
        │   ├── local: made #103 : @primitives$I64
        │   └── value > construct:
        │       ├── type: @primitives$I64
        │       ├── ctor: @primitives$I64
        │       └── args[0]: 0 : @concepts$Int
        └── body[1] > return: made #103 : @primitives$I64
