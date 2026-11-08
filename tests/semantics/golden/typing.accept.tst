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
    │   │   │       ├── ctor: Vec2.zero #52
    │   │   │       └── args:
    │   │   ├── body[2] > let:
    │   │   │   ├── local: moved #25 : shapes$Vec2
    │   │   │   └── value > op:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #56
    │   │   │       ├── left: origin #24 : shapes$Vec2
    │   │   │       └── right: 3.0 : @concepts$Float
    │   │   ├── body[3] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: scale #58
    │   │   │   ├── args[0]: moved #25 : shapes$Vec2
    │   │   │   └── args[1] > construct:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── ctor: @primitives$F64
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[4] > let:
    │   │   │   ├── local: flat #26 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #53
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
    │   │   │       ├── callee: length #57
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
    │   │   │       ├── callee: area #68
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
    │   │   │   ├── local: intZeros #39 : app$Pair<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$I64>
    │   │   │       ├── ctor: Pair.zeros #38 with T = @primitives$I64
    │   │   │       └── args[0]: type @primitives$I64 : Type
    │   │   ├── body[17] > let:
    │   │   │   ├── local: smallZeros #40 : app$Pair<@primitives$I32>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$I32>
    │   │   │       ├── ctor: Pair.zeros #38 with T = @primitives$I32
    │   │   │       └── args[0]: type @primitives$I32 : Type
    │   │   ├── body[18] > let:
    │   │   │   ├── local: spare #41 : ^shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[19] > assign:
    │   │   │   ├── target: spare #41 : shapes$Shape
    │   │   │   └── value > call:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── callee: grown #26
    │   │   │       └── args[0]: spare #41 : shapes$Shape
    │   │   ├── body[20] > let:
    │   │   │   ├── local: crew #42 : app$Crew
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Crew
    │   │   │       ├── ctor: Crew #25
    │   │   │       ├── args[0]: spare #41 : shapes$Shape
    │   │   │       └── args[1]: shape #28 : shapes$Shape
    │   │   ├── body[21] > let:
    │   │   │   ├── local: lead #43 : &shapes$Shape
    │   │   │   └── value > call:
    │   │   │       ├── type: &shapes$Shape
    │   │   │       ├── callee: leadOf #27
    │   │   │       └── args[0]: crew #42 : app$Crew
    │   │   ├── body[22] > let:
    │   │   │   ├── local: shapes #44 : @primitives$ArrayRef<shapes$Shape, 2>
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
    │   │   ├── body[23] > let:
    │   │   │   ├── local: second #45 : &shapes$Shape
    │   │   │   └── value > subscript:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── impl: @primitives$[] with T = shapes$Shape, n = 2
    │   │   │       ├── target: shapes #44 : @primitives$ArrayRef<shapes$Shape, 2>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 2 : @concepts$Int
    │   │   ├── body[24] > let:
    │   │   │   ├── local: tiles #47 : @primitives$ArrayRef<@primitives$I64, 4>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<@primitives$I64, 4>
    │   │   │       ├── ctor: @primitives$ArrayRef.fill with T = @primitives$I64, n = 4
    │   │   │       ├── args[0]: 4 : @concepts$Int
    │   │   │       └── args[1] > lambda:
    │   │   │           ├── type: @primitives$I64[@primitives$I64]
    │   │   │           ├── params[0]: n #46 : @primitives$I64
    │   │   │           └── body[0] > return > call:
    │   │   │               ├── type: @primitives$I64
    │   │   │               ├── callee: @operators$multiply
    │   │   │               ├── args[0]: n #46 : @primitives$I64
    │   │   │               └── args[1]: n #46 : @primitives$I64
    │   │   ├── body[25] > let:
    │   │   │   ├── local: corners #48 : @primitives$ArrayRef<@primitives$I64, 2>
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
    │   │   ├── body[26] > let:
    │   │   │   ├── local: leads #49 : @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef with T = &shapes$Shape, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<&shapes$Shape, 2>
    │   │   │           ├── items[0]: lead #43 : &shapes$Shape
    │   │   │           └── items[1]: second #45 : &shapes$Shape
    │   │   ├── body[27] > let:
    │   │   │   ├── local: pointed #50 : @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<&shapes$Shape, 2>
    │   │   │       ├── ctor: @primitives$ArrayRef.refs with T = shapes$Shape, n = 2
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<&shapes$Shape, 2>
    │   │   │           ├── items[0]: shape #28 : shapes$Shape
    │   │   │           └── items[1]: lead #43 : &shapes$Shape
    │   │   ├── body[28] > let:
    │   │   │   ├── local: numbers #51 : @primitives$Array<@primitives$I64, 3>
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
    │   │   ├── body[29] > let:
    │   │   │   ├── local: first #52 : @primitives$I64
    │   │   │   └── value > subscript:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── impl: @primitives$[] with T = @primitives$I64, n = 3
    │   │   │       ├── target: numbers #51 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[30] > let:
    │   │   │   ├── local: length #53 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: count #16 with T = @primitives$I64, n = 3
    │   │   │       └── args[0]: numbers #51 : @primitives$Array<@primitives$I64, 3>
    │   │   ├── body[31] > let:
    │   │   │   ├── local: sized #54 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: measured #17 with n = 3
    │   │   │       ├── args[0]: numbers #51 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[32] > let:
    │   │   │   ├── local: like #55 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: sizedLike #20 with n = 3
    │   │   │       ├── args[0]: numbers #51 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[33] > let:
    │   │   │   ├── local: passed #56 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: forwarded #19 with count = 3
    │   │   │       ├── args[0]: numbers #51 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[34] > let:
    │   │   │   ├── local: ints #57 : app$Pair<@primitives$I64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$I64>
    │   │   │       ├── callee: pairOf #21
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[35] > let:
    │   │   │   ├── local: decimals #58 : app$Pair<@primitives$F64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$F64>
    │   │   │       ├── callee: pairOf #22
    │   │   │       ├── args[0]: 2.5 : @concepts$Float
    │   │   │       └── args[1]: 3.5 : @concepts$Float
    │   │   ├── body[36] > let:
    │   │   │   ├── local: label #59 : @primitives$String
    │   │   │   └── value > map_read:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: .topLeft : shapes$Corner
    │   │   │       └── map: label #62
    │   │   ├── body[37] > let:
    │   │   │   ├── local: side #60 : @primitives$String
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── callee: describe #32
    │   │   │       └── args[0]: .bottomRight : shapes$Corner
    │   │   ├── body[38] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0]: side #60 : @primitives$String
    │   │   ├── body[39] > let:
    │   │   │   ├── local: i #61 : @primitives$I64
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── ctor: @primitives$I64
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[40] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: to #10
    │   │   │   ├── args[0]: i #61 : @primitives$I64
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
    │   │   ├── body[41] > let:
    │   │   │   ├── local: double #63 : @primitives$F64[@primitives$F64]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: @primitives$F64[@primitives$F64]
    │   │   │       ├── params[0]: value #62 : @primitives$F64
    │   │   │       └── body[0] > return > call:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── callee: @operators$multiply
    │   │   │           ├── args[0]: value #62 : @primitives$F64
    │   │   │           └── args[1] > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[42] > let:
    │   │   │   ├── local: doubled #64 : @primitives$F64
    │   │   │   └── value > call_value:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: double #63 : @primitives$F64[@primitives$F64]
    │   │   │       └── args[0]: half #32 : @primitives$F64
    │   │   ├── body[43] > let:
    │   │   │   ├── local: chain #65 : @primitives$Bool
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
    │   │   ├── body[44] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: elif #8
    │   │   │   ├── args[0]: chain #65 : @primitives$Bool
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
    │   │   ├── body[45] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: else #9
    │   │   │   ├── args[0]: chain #65 : @primitives$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── ctor: @primitives$String
    │   │   │           └── args[0]: "large" : @concepts$String
    │   │   ├── body[46] > let:
    │   │   │   ├── local: drawn #66 : ^shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── ctor: @primitives$F64
    │   │   │           └── args[0]: 5.0 : @concepts$Float
    │   │   ├── body[47] > let:
    │   │   │   ├── local: team #67 : ^app$Crew
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Crew
    │   │   │       ├── ctor: Crew #25
    │   │   │       ├── args[0]: drawn #66 : shapes$Shape
    │   │   │       └── args[1]: shape #28 : shapes$Shape
    │   │   ├── body[48] > let:
    │   │   │   ├── local: kept #68 : app$Crew
    │   │   │   └── value: team #67 : app$Crew
    │   │   ├── body[49] > let:
    │   │   │   ├── local: boxed #69 : ^app$Holder<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Holder<@primitives$I64>
    │   │   │       ├── ctor: Holder #29 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[50] > let:
    │   │   │   ├── local: spelled #70 : ^app$Holder<@primitives$I64>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Holder<@primitives$I64>
    │   │   │       ├── ctor: Holder #29 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 2 : @concepts$Int
    │   │   ├── body[51] > let:
    │   │   │   ├── local: shelf #71 : app$Holder<@primitives$I64>
    │   │   │   └── value: boxed #69 : app$Holder<@primitives$I64>
    │   │   ├── body[52] > let:
    │   │   │   ├── local: relayedInt #72 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: relayed #30 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 5 : @concepts$Int
    │   │   ├── body[53] > let:
    │   │   │   ├── local: relayedShape #73 : shapes$Shape
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
    │   │   ├── body[54] > let:
    │   │   │   ├── local: nothing #74 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: zeroed #31 with T = @primitives$I64
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 7 : @concepts$Int
    │   │   ├── body[55] > let:
    │   │   │   ├── local: who #75 : @primitives$String
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "world" : @concepts$String
    │   │   ├── body[56] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0] > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String.escaped
    │   │   │       └── args[0] > text:
    │   │   │           ├── type: @concepts$String
    │   │   │           ├── pieces[0]: "hello "
    │   │   │           ├── pieces[1]: who #75 : @primitives$String
    │   │   │           └── pieces[2]: "\\n"
    │   │   └── body[57] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[33] > verb:
    │   │   ├── signature: T twice(T) #34
    │   │   └── body: checked per instance
    │   ├── decls[34] > verb:
    │   │   ├── signature: @primitives$I64 lowByte(@primitives$I64) #35
    │   │   ├── params[0]: value #76 : @primitives$I64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$I64
    │   │       ├── callee: @math$bitAnd
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$I64
    │   │       │   ├── callee: @math$shiftRightLogical
    │   │       │   ├── args[0]: value #76 : @primitives$I64
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
    │   │   ├── params[0]: a #77 : @primitives$F64
    │   │   ├── params[1]: b #78 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @math$sqrt
    │   │       └── args[0] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @math$fma
    │   │           ├── args[0]: a #77 : @primitives$F64
    │   │           ├── args[1]: a #77 : @primitives$F64
    │   │           └── args[2] > call:
    │   │               ├── type: @primitives$F64
    │   │               ├── callee: @operators$multiply
    │   │               ├── args[0]: b #78 : @primitives$F64
    │   │               └── args[1]: b #78 : @primitives$F64
    │   ├── decls[36] > verb:
    │   │   ├── signature: @primitives$F64 heading(@primitives$F64, @primitives$F64) #37
    │   │   ├── params[0]: y #79 : @primitives$F64
    │   │   ├── params[1]: x #80 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @math$atan2
    │   │       ├── args[0]: y #79 : @primitives$F64
    │   │       └── args[1]: x #80 : @primitives$F64
    │   ├── decls[37] > verb:
    │   │   ├── signature: Pair.zeros(T Type) #38
    │   │   └── body: checked per instance
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
    │   │   ├── signature: Rack(T Type) #42
    │   │   └── body: checked per instance
    │   ├── decls[42] > verb:
    │   │   ├── signature: Tally(T Type, n @concepts$Int) #43
    │   │   └── body: checked per instance
    │   ├── decls[43] > type:
    │   │   ├── name: Grid #44
    │   │   ├── params: T Type, n @concepts$Int
    │   │   ├── kind: reference
    │   │   └── struct[0]: rows : app$Tally<@primitives$Array<T, n>, n>
    │   ├── decls[44] > verb:
    │   │   ├── signature: Grid(T Type, n @concepts$Int) #45
    │   │   └── body: checked per instance
    │   └── decls[45] > verb:
    │       ├── signature: @primitives$Unit racks() #46
    │       ├── params:
    │       ├── body[0] > let:
    │       │   ├── local: ints #81 : app$Rack<@primitives$I64>
    │       │   └── value > construct:
    │       │       ├── type: app$Rack<@primitives$I64>
    │       │       ├── ctor: Rack #42 with T = @primitives$I64
    │       │       └── args[0]: type @primitives$I64 : Type
    │       ├── body[1] > let:
    │       │   ├── local: duos #82 : @primitives$ListRef<app$Duo<@primitives$F64>>
    │       │   └── value > construct:
    │       │       ├── type: @primitives$ListRef<app$Duo<@primitives$F64>>
    │       │       ├── ctor: @primitives$ListRef with T = app$Duo<@primitives$F64>
    │       │       └── args[0]: type app$Duo<@primitives$F64> : Type
    │       ├── body[2] > let:
    │       │   ├── local: pointed #83 : app$Tally<&shapes$Shape, 2>
    │       │   └── value > construct:
    │       │       ├── type: app$Tally<&shapes$Shape, 2>
    │       │       ├── ctor: Tally #43 with T = &shapes$Shape, n = 2
    │       │       ├── args[0]: type &shapes$Shape : Type
    │       │       └── args[1]: 2 : @concepts$Int
    │       ├── body[3] > let:
    │       │   ├── local: paired #84 : app$Tally<app$Duo<&shapes$Shape>, 3>
    │       │   └── value > construct:
    │       │       ├── type: app$Tally<app$Duo<&shapes$Shape>, 3>
    │       │       ├── ctor: Tally #43 with T = app$Duo<&shapes$Shape>, n = 3
    │       │       ├── args[0]: type app$Duo<&shapes$Shape> : Type
    │       │       └── args[1]: 3 : @concepts$Int
    │       ├── body[4] > let:
    │       │   ├── local: grid #85 : app$Grid<@primitives$I64, 4>
    │       │   └── value > construct:
    │       │       ├── type: app$Grid<@primitives$I64, 4>
    │       │       ├── ctor: Grid #45 with T = @primitives$I64, n = 4
    │       │       ├── args[0]: type @primitives$I64 : Type
    │       │       └── args[1]: 4 : @concepts$Int
    │       ├── body[5] > let:
    │       │   ├── local: calls #86 : app$Tally<@primitives$I64[@primitives$F64], 1>
    │       │   └── value > construct:
    │       │       ├── type: app$Tally<@primitives$I64[@primitives$F64], 1>
    │       │       ├── ctor: Tally #43 with T = @primitives$I64[@primitives$F64], n = 1
    │       │       ├── args[0]: type @primitives$I64[@primitives$F64] : Type
    │       │       └── args[1]: 1 : @concepts$Int
    │       ├── body[6] > let:
    │       │   ├── local: failing #87 : app$Tally<@primitives$I64?@primitives$String[app$Duo<@primitives$I64>], 1>
    │       │   └── value > construct:
    │       │       ├── type: app$Tally<@primitives$I64?@primitives$String[app$Duo<@primitives$I64>], 1>
    │       │       ├── ctor: Tally #43 with T = @primitives$I64?@primitives$String[app$Duo<@primitives$I64>], n = 1
    │       │       ├── args[0]: type @primitives$I64?@primitives$String[app$Duo<@primitives$I64>] : Type
    │       │       └── args[1]: 1 : @concepts$Int
    │       └── body[7] > return > construct:
    │           ├── type: @primitives$Unit
    │           ├── ctor: @primitives$Unit
    │           └── args:
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > alias:
    │   │   ├── name: Float #47
    │   │   └── target: @primitives$F64
    │   ├── decls[1] > alias:
    │   │   ├── name: Unit #48
    │   │   └── target: @primitives$Unit
    │   ├── decls[2] > alias:
    │   │   ├── name: String #49
    │   │   └── target: @primitives$String
    │   ├── decls[3] > type:
    │   │   ├── name: Vec2 #50
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$F64
    │   │   └── struct[1]: y : @primitives$F64
    │   ├── decls[4] > verb:
    │   │   ├── signature: Vec2(@primitives$F64, @primitives$F64) #51
    │   │   ├── params[0]: x #88 : @primitives$F64
    │   │   ├── params[1]: y #89 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #88 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #89 : @primitives$F64
    │   ├── decls[5] > verb:
    │   │   ├── signature: Vec2.zero() #52
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
    │   │   ├── signature: Vec2{x @primitives$F64; y @primitives$F64 = ...} #53
    │   │   ├── params[0]: x #92 : @primitives$F64
    │   │   ├── params[1]: y #93 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #92 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #93 : @primitives$F64
    │   ├── decls[7] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #54
    │   │   ├── params[0]: left #94 : shapes$Vec2
    │   │   ├── params[1]: right #95 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #51
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$add
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: left #94 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: right #95 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #94 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #95 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[8] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #55
    │   │   ├── params[0]: value #96 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #51
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$negate
    │   │       │   └── args[0] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: value #96 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$negate
    │   │           └── args[0] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: value #96 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[9] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, @concepts$Float) #56
    │   │   ├── params[0]: left #97 : shapes$Vec2
    │   │   ├── params[1]: right #98 : @concepts$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: shapes$Vec2
    │   │       ├── op: +
    │   │       ├── impl: + #54
    │   │       ├── left: left #97 : shapes$Vec2
    │   │       └── right > construct:
    │   │           ├── type: shapes$Vec2
    │   │           ├── ctor: Vec2 #59
    │   │           └── args[0]: right #98 : @concepts$Float
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$F64 length(this shapes$Vec2) #57
    │   │   ├── params[0]: this #99 : shapes$Vec2
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$add
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$multiply
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: this #99 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: this #99 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$multiply
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: this #99 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: this #99 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[11] > verb:
    │   │   ├── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$F64) mut #58
    │   │   ├── params[0]: this #100 : shapes$Vec2
    │   │   ├── params[1]: by #101 : @primitives$F64
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #100 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #100 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── args[1]: by #101 : @primitives$F64
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #100 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #100 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── args[1]: by #101 : @primitives$F64
    │   │   └── body[2] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[12] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Float) #59
    │   │   ├── params[0]: value #102 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── ctor: @primitives$F64
    │   │       │       └── args[0]: value #102 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$F64
    │   │               ├── ctor: @primitives$F64
    │   │               └── args[0]: value #102 : @concepts$Float
    │   ├── decls[13] > type:
    │   │   ├── name: Shape #60
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : @primitives$F64
    │   │   ├── variant[1]: square : @primitives$F64
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[14] > type:
    │   │   ├── name: Corner #61
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[15] > enum_map:
    │   │   ├── map: shapes$Corner.label #62
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
    │   │   ├── name: Meters #63
    │   │   ├── kind: value
    │   │   └── struct[0]: _value : @primitives$F64
    │   ├── decls[17] > verb:
    │   │   ├── signature: Meters(@primitives$F64) #64
    │   │   ├── params[0]: value #103 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Meters
    │   │       └── fields[0] > field:
    │   │           ├── name: _value (slot 0)
    │   │           └── value: value #103 : @primitives$F64
    │   ├── decls[18] > verb:
    │   │   ├── signature: shapes$Meters +(shapes$Meters, shapes$Meters) #65
    │   │   ├── params[0]: left #104 : shapes$Meters
    │   │   ├── params[1]: right #105 : shapes$Meters
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Meters
    │   │       ├── ctor: Meters #64
    │   │       └── args[0] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #104 : shapes$Meters
    │   │           │   └── field: _value (slot 0)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #105 : shapes$Meters
    │   │               └── field: _value (slot 0)
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$F64 inFeet(shapes$Meters) #66
    │   │   ├── params[0]: distance #106 : shapes$Meters
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$multiply
    │   │       ├── args[0] > field:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── target: distance #106 : shapes$Meters
    │   │       │   └── field: _value (slot 0)
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 3.28 : @concepts$Float
    │   ├── decls[20] > verb:
    │   │   ├── signature: @primitives$F64 _half(@primitives$F64) #67
    │   │   ├── params[0]: value #107 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$divide
    │   │       ├── args[0]: value #107 : @primitives$F64
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[21] > verb:
    │       ├── signature: @primitives$F64 area(&shapes$Shape) #68
    │       ├── params[0]: shape #108 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: @primitives$F64
    │           ├── scrutinees[0]: shape #108 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #109 : @primitives$F64 <- circle
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: @operators$multiply
    │           │       ├── args[0]: r #109 : @primitives$F64
    │           │       └── args[1]: r #109 : @primitives$F64
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #110 : @primitives$F64 <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: _half #67
    │           │       └── args[0] > call:
    │           │           ├── type: @primitives$F64
    │           │           ├── callee: @operators$add
    │           │           ├── args[0]: s #110 : @primitives$F64
    │           │           └── args[1]: s #110 : @primitives$F64
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: @primitives$F64
    │                   ├── ctor: @primitives$F64
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── instances[0] > instance:
    │   ├── of: pick #12 with T = @primitives$F64
    │   ├── params[0]: first #127 : @primitives$F64
    │   ├── params[1]: second #128 : @primitives$F64
    │   ├── params[2]: takeFirst #129 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #130 : @primitives$F64
    │   │   └── value: second #128 : @primitives$F64
    │   ├── body[1] > let:
    │   │   ├── local: ran #131 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #129 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #130 : @primitives$F64
    │   │           └── value: first #127 : @primitives$F64
    │   └── body[2] > return: chosen #130 : @primitives$F64
    ├── instances[1] > instance:
    │   ├── of: pick #12 with T = @primitives$I64
    │   ├── params[0]: first #132 : @primitives$I64
    │   ├── params[1]: second #133 : @primitives$I64
    │   ├── params[2]: takeFirst #134 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #135 : @primitives$I64
    │   │   └── value: second #133 : @primitives$I64
    │   ├── body[1] > let:
    │   │   ├── local: ran #136 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #134 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #135 : @primitives$I64
    │   │           └── value: first #132 : @primitives$I64
    │   └── body[2] > return: chosen #135 : @primitives$I64
    ├── instances[2] > instance:
    │   ├── of: Pair #14 with T = @primitives$F64
    │   ├── params[0]: left #137 : @primitives$F64
    │   ├── params[1]: right #138 : @primitives$F64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$F64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #137 : @primitives$F64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #138 : @primitives$F64
    ├── instances[3] > instance:
    │   ├── of: Pair #14 with T = @primitives$I64
    │   ├── params[0]: left #139 : @primitives$I64
    │   ├── params[1]: right #140 : @primitives$I64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$I64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #139 : @primitives$I64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #140 : @primitives$I64
    ├── instances[4] > instance:
    │   ├── of: sum #15 with T = @primitives$F64
    │   ├── params[0]: pair #125 : app$Pair<@primitives$F64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$F64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$F64
    │       │   ├── target: pair #125 : app$Pair<@primitives$F64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$F64
    │           ├── target: pair #125 : app$Pair<@primitives$F64>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #15 with T = @primitives$I64
    │   ├── params[0]: pair #126 : app$Pair<@primitives$I64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$I64
    │       │   ├── target: pair #126 : app$Pair<@primitives$I64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$I64
    │           ├── target: pair #126 : app$Pair<@primitives$I64>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #16 with T = @primitives$I64, n = 3
    │   ├── params[0]: values #124 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #17 with n = 3
    │   ├── params[0]: values #123 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #18 with n = 3
    │   ├── params[0]: values #119 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: measured #17 with n = 3
    │       ├── args[0]: values #119 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #19 with count = 3
    │   ├── params[0]: values #118 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: relayed #18 with n = 3
    │       ├── args[0]: values #118 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    ├── instances[10] > instance:
    │   ├── of: sizedLike #20 with n = 3
    │   ├── params[0]: values #120 : @primitives$Array<@primitives$I64, 3>
    │   ├── body[0] > let:
    │   │   ├── local: measure #122 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │   │   └── value > lambda:
    │   │       ├── type: @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │   │       ├── params[0]: held #121 : @primitives$Array<@primitives$I64, 3>
    │   │       └── body[0] > return > construct:
    │   │           ├── type: @primitives$I64
    │   │           ├── ctor: @primitives$I64
    │   │           └── args[0]: n = 3 : @concepts$Int
    │   └── body[1] > return > call_value:
    │       ├── type: @primitives$I64
    │       ├── callee: measure #122 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
    │       └── args[0]: values #120 : @primitives$Array<@primitives$I64, 3>
    ├── instances[11] > instance:
    │   ├── of: Holder #29 with T = @primitives$I64
    │   ├── params[0]: item #117 : @primitives$I64
    │   └── body[0] > return > init:
    │       ├── type: app$Holder<@primitives$I64>
    │       └── fields[0] > field:
    │           ├── name: item (slot 0)
    │           └── value: item #117 : @primitives$I64
    ├── instances[12] > instance:
    │   ├── of: relayed #30 with T = @primitives$I64
    │   ├── params[0]: seed #115 : ^@primitives$I64
    │   ├── body[0] > let:
    │   │   ├── local: kept #116 : @primitives$I64
    │   │   └── value: seed #115 : @primitives$I64
    │   └── body[1] > return: kept #116 : @primitives$I64
    ├── instances[13] > instance:
    │   ├── of: relayed #30 with T = shapes$Shape
    │   ├── params[0]: seed #113 : ^shapes$Shape
    │   ├── body[0] > let:
    │   │   ├── local: kept #114 : ^shapes$Shape
    │   │   └── value: seed #113 : shapes$Shape
    │   └── body[1] > return: kept #114 : shapes$Shape
    ├── instances[14] > instance:
    │   ├── of: zeroed #31 with T = @primitives$I64
    │   ├── params[0]: like #111 : @primitives$I64
    │   ├── body[0] > let:
    │   │   ├── local: made #112 : @primitives$I64
    │   │   └── value > construct:
    │   │       ├── type: @primitives$I64
    │   │       ├── ctor: @primitives$I64
    │   │       └── args[0]: 0 : @concepts$Int
    │   └── body[1] > return: made #112 : @primitives$I64
    ├── instances[15] > instance:
    │   ├── of: Pair.zeros #38 with T = @primitives$I32
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$I32>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value > construct:
    │       │       ├── type: @primitives$I32
    │       │       ├── ctor: @primitives$I32
    │       │       └── args[0]: 0 : @concepts$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value > construct:
    │               ├── type: @primitives$I32
    │               ├── ctor: @primitives$I32
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[16] > instance:
    │   ├── of: Pair.zeros #38 with T = @primitives$I64
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$I64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value > construct:
    │       │       ├── type: @primitives$I64
    │       │       ├── ctor: @primitives$I64
    │       │       └── args[0]: 0 : @concepts$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[17] > instance:
    │   ├── of: Rack #42 with T = @primitives$I64
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Rack<@primitives$I64>
    │       └── fields[0] > field:
    │           ├── name: duos (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$ListRef<app$Duo<@primitives$I64>>
    │               ├── ctor: @primitives$ListRef with T = app$Duo<@primitives$I64>
    │               └── args[0]: type app$Duo<@primitives$I64> : Type
    ├── instances[18] > instance:
    │   ├── of: Tally #43 with T = &shapes$Shape, n = 2
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Tally<&shapes$Shape, 2>
    │       └── fields[0] > field:
    │           ├── name: count (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[19] > instance:
    │   ├── of: Tally #43 with T = @primitives$Array<@primitives$I64, 4>, n = 4
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Tally<@primitives$Array<@primitives$I64, 4>, 4>
    │       └── fields[0] > field:
    │           ├── name: count (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[20] > instance:
    │   ├── of: Tally #43 with T = @primitives$I64?@primitives$String[app$Duo<@primitives$I64>], n = 1
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Tally<@primitives$I64?@primitives$String[app$Duo<@primitives$I64>], 1>
    │       └── fields[0] > field:
    │           ├── name: count (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[21] > instance:
    │   ├── of: Tally #43 with T = @primitives$I64[@primitives$F64], n = 1
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Tally<@primitives$I64[@primitives$F64], 1>
    │       └── fields[0] > field:
    │           ├── name: count (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    ├── instances[22] > instance:
    │   ├── of: Tally #43 with T = app$Duo<&shapes$Shape>, n = 3
    │   ├── params:
    │   └── body[0] > return > init:
    │       ├── type: app$Tally<app$Duo<&shapes$Shape>, 3>
    │       └── fields[0] > field:
    │           ├── name: count (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$I64
    │               ├── ctor: @primitives$I64
    │               └── args[0]: 0 : @concepts$Int
    └── instances[23] > instance:
        ├── of: Grid #45 with T = @primitives$I64, n = 4
        ├── params:
        └── body[0] > return > init:
            ├── type: app$Grid<@primitives$I64, 4>
            └── fields[0] > field:
                ├── name: rows (slot 0)
                └── value > construct:
                    ├── type: app$Tally<@primitives$Array<@primitives$I64, 4>, 4>
                    ├── ctor: Tally #43 with T = @primitives$Array<@primitives$I64, 4>, n = 4
                    ├── args[0]: type @primitives$Array<@primitives$I64, 4> : Type
                    └── args[1]: n = 4 : @concepts$Int
