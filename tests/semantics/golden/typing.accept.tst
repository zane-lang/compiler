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
    │   │   │   │   ├── callee: @operators$and
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
    │   │   │       ├── callee: @operators$or
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
    │   ├── decls[27] > verb:
    │   │   ├── signature: @primitives$String describe(shapes$Corner) #28
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
    │   ├── decls[28] > verb:
    │   │   ├── signature: @primitives$Unit main() #29
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
    │   │   │       ├── ctor: Vec2.zero #36
    │   │   │       └── args:
    │   │   ├── body[2] > let:
    │   │   │   ├── local: moved #25 : shapes$Vec2
    │   │   │   └── value > op:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #38
    │   │   │       ├── left: origin #24 : shapes$Vec2
    │   │   │       └── right > coerce:
    │   │   │           ├── type: shapes$Vec2
    │   │   │           ├── ctor: Vec2 #42
    │   │   │           └── value: 3.0 : @concepts$Float
    │   │   ├── body[3] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: scale #41
    │   │   │   ├── args[0]: moved #25 : shapes$Vec2
    │   │   │   └── args[1] > construct:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── ctor: @primitives$F64
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[4] > let:
    │   │   │   ├── local: flat #26 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #37
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
    │   │   │       ├── callee: length #40
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
    │   │   │       ├── callee: area #51
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
    │   │   │       ├── ctor: @primitives$ArrayRef with T = shapes$Shape, n = 2
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
    │   │   │   ├── local: numbers #46 : @primitives$Array<@primitives$I64, 3>
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
    │   │   ├── body[24] > let:
    │   │   │   ├── local: first #47 : @primitives$I64
    │   │   │   └── value > subscript:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── impl: @primitives$[] with T = @primitives$I64, n = 3
    │   │   │       ├── target: numbers #46 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$I64
    │   │   │           ├── ctor: @primitives$I64
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[25] > let:
    │   │   │   ├── local: length #48 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: count #16 with T = @primitives$I64, n = 3
    │   │   │       └── args[0]: numbers #46 : @primitives$Array<@primitives$I64, 3>
    │   │   ├── body[26] > let:
    │   │   │   ├── local: sized #49 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: measured #17 with n = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[27] > let:
    │   │   │   ├── local: like #50 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: sizedLike #20 with n = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[28] > let:
    │   │   │   ├── local: passed #51 : @primitives$I64
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── callee: forwarded #19 with count = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$I64, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[29] > let:
    │   │   │   ├── local: ints #52 : app$Pair<@primitives$I64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$I64>
    │   │   │       ├── callee: pairOf #21
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[30] > let:
    │   │   │   ├── local: decimals #53 : app$Pair<@primitives$F64>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$F64>
    │   │   │       ├── callee: pairOf #22
    │   │   │       ├── args[0]: 2.5 : @concepts$Float
    │   │   │       └── args[1]: 3.5 : @concepts$Float
    │   │   ├── body[31] > let:
    │   │   │   ├── local: label #54 : @primitives$String
    │   │   │   └── value > map_read:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: .topLeft : shapes$Corner
    │   │   │       └── map: label #45
    │   │   ├── body[32] > let:
    │   │   │   ├── local: side #55 : @primitives$String
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── callee: describe #28
    │   │   │       └── args[0]: .bottomRight : shapes$Corner
    │   │   ├── body[33] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0]: side #55 : @primitives$String
    │   │   ├── body[34] > let:
    │   │   │   ├── local: i #56 : @primitives$I64
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$I64
    │   │   │       ├── ctor: @primitives$I64
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[35] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: to #10
    │   │   │   ├── args[0]: i #56 : @primitives$I64
    │   │   │   ├── args[1] > construct:
    │   │   │   │   ├── type: @primitives$I64
    │   │   │   │   ├── ctor: @primitives$I64
    │   │   │   │   └── args[0]: 3 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > call:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── callee: describe #28
    │   │   │           └── args[0]: .topLeft : shapes$Corner
    │   │   ├── body[36] > let:
    │   │   │   ├── local: double #58 : @primitives$F64[@primitives$F64]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: @primitives$F64[@primitives$F64]
    │   │   │       ├── params[0]: value #57 : @primitives$F64
    │   │   │       └── body[0] > return > call:
    │   │   │           ├── type: @primitives$F64
    │   │   │           ├── callee: @operators$multiply
    │   │   │           ├── args[0]: value #57 : @primitives$F64
    │   │   │           └── args[1] > construct:
    │   │   │               ├── type: @primitives$F64
    │   │   │               ├── ctor: @primitives$F64
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[37] > let:
    │   │   │   ├── local: doubled #59 : @primitives$F64
    │   │   │   └── value > call_value:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: double #58 : @primitives$F64[@primitives$F64]
    │   │   │       └── args[0]: half #32 : @primitives$F64
    │   │   ├── body[38] > let:
    │   │   │   ├── local: chain #60 : @primitives$Bool
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
    │   │   ├── body[39] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: elif #8
    │   │   │   ├── args[0]: chain #60 : @primitives$Bool
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
    │   │   ├── body[40] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: else #9
    │   │   │   ├── args[0]: chain #60 : @primitives$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── ctor: @primitives$String
    │   │   │           └── args[0]: "large" : @concepts$String
    │   │   └── body[41] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   └── decls[29] > verb:
    │       ├── signature: T twice(T) #30
    │       └── body: checked per instance
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > alias:
    │   │   ├── name: Float #31
    │   │   └── target: @primitives$F64
    │   ├── decls[1] > alias:
    │   │   ├── name: Unit #32
    │   │   └── target: @primitives$Unit
    │   ├── decls[2] > alias:
    │   │   ├── name: String #33
    │   │   └── target: @primitives$String
    │   ├── decls[3] > type:
    │   │   ├── name: Vec2 #34
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$F64
    │   │   └── struct[1]: y : @primitives$F64
    │   ├── decls[4] > verb:
    │   │   ├── signature: Vec2(@primitives$F64, @primitives$F64) #35
    │   │   ├── params[0]: x #61 : @primitives$F64
    │   │   ├── params[1]: y #62 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #61 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #62 : @primitives$F64
    │   ├── decls[5] > verb:
    │   │   ├── signature: Vec2.zero() #36
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
    │   │   ├── signature: Vec2{x @primitives$F64; y @primitives$F64 = ...} #37
    │   │   ├── params[0]: x #65 : @primitives$F64
    │   │   ├── params[1]: y #66 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #65 : @primitives$F64
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #66 : @primitives$F64
    │   ├── decls[7] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #38
    │   │   ├── params[0]: left #67 : shapes$Vec2
    │   │   ├── params[1]: right #68 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #35
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$add
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: left #67 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: right #68 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #67 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #68 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[8] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #39
    │   │   ├── params[0]: value #69 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #35
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$negate
    │   │       │   └── args[0] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: value #69 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$negate
    │   │           └── args[0] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: value #69 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[9] > verb:
    │   │   ├── signature: @primitives$F64 length(this shapes$Vec2) #40
    │   │   ├── params[0]: this #70 : shapes$Vec2
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$add
    │   │       ├── args[0] > call:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── callee: @operators$multiply
    │   │       │   ├── args[0] > field:
    │   │       │   │   ├── type: @primitives$F64
    │   │       │   │   ├── target: this #70 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── args[1] > field:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── target: this #70 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$multiply
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: this #70 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: this #70 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$F64) mut #41
    │   │   ├── params[0]: this #71 : shapes$Vec2
    │   │   ├── params[1]: by #72 : @primitives$F64
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #71 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #71 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── args[1]: by #72 : @primitives$F64
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$F64
    │   │   │   │   ├── target: this #71 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$F64
    │   │   │       ├── callee: @operators$multiply
    │   │   │       ├── args[0] > field:
    │   │   │       │   ├── type: @primitives$F64
    │   │   │       │   ├── target: this #71 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── args[1]: by #72 : @primitives$F64
    │   │   └── body[2] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[11] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Float) #42
    │   │   ├── params[0]: value #73 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$F64
    │   │       │       ├── ctor: @primitives$F64
    │   │       │       └── args[0]: value #73 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$F64
    │   │               ├── ctor: @primitives$F64
    │   │               └── args[0]: value #73 : @concepts$Float
    │   ├── decls[12] > type:
    │   │   ├── name: Shape #43
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : @primitives$F64
    │   │   ├── variant[1]: square : @primitives$F64
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[13] > type:
    │   │   ├── name: Corner #44
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[14] > enum_map:
    │   │   ├── map: shapes$Corner.label #45
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
    │   ├── decls[15] > type:
    │   │   ├── name: Meters #46
    │   │   ├── kind: value
    │   │   └── struct[0]: _value : @primitives$F64
    │   ├── decls[16] > verb:
    │   │   ├── signature: Meters(@primitives$F64) #47
    │   │   ├── params[0]: value #74 : @primitives$F64
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Meters
    │   │       └── fields[0] > field:
    │   │           ├── name: _value (slot 0)
    │   │           └── value: value #74 : @primitives$F64
    │   ├── decls[17] > verb:
    │   │   ├── signature: shapes$Meters +(shapes$Meters, shapes$Meters) #48
    │   │   ├── params[0]: left #75 : shapes$Meters
    │   │   ├── params[1]: right #76 : shapes$Meters
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Meters
    │   │       ├── ctor: Meters #47
    │   │       └── args[0] > call:
    │   │           ├── type: @primitives$F64
    │   │           ├── callee: @operators$add
    │   │           ├── args[0] > field:
    │   │           │   ├── type: @primitives$F64
    │   │           │   ├── target: left #75 : shapes$Meters
    │   │           │   └── field: _value (slot 0)
    │   │           └── args[1] > field:
    │   │               ├── type: @primitives$F64
    │   │               ├── target: right #76 : shapes$Meters
    │   │               └── field: _value (slot 0)
    │   ├── decls[18] > verb:
    │   │   ├── signature: @primitives$F64 inFeet(shapes$Meters) #49
    │   │   ├── params[0]: distance #77 : shapes$Meters
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$multiply
    │   │       ├── args[0] > field:
    │   │       │   ├── type: @primitives$F64
    │   │       │   ├── target: distance #77 : shapes$Meters
    │   │       │   └── field: _value (slot 0)
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 3.28 : @concepts$Float
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$F64 _half(@primitives$F64) #50
    │   │   ├── params[0]: value #78 : @primitives$F64
    │   │   └── body[0] > return > call:
    │   │       ├── type: @primitives$F64
    │   │       ├── callee: @operators$divide
    │   │       ├── args[0]: value #78 : @primitives$F64
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$F64
    │   │           ├── ctor: @primitives$F64
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[20] > verb:
    │       ├── signature: @primitives$F64 area(&shapes$Shape) #51
    │       ├── params[0]: shape #79 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: @primitives$F64
    │           ├── scrutinees[0]: shape #79 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #80 : @primitives$F64 <- circle
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: @operators$multiply
    │           │       ├── args[0]: r #80 : @primitives$F64
    │           │       └── args[1]: r #80 : @primitives$F64
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #81 : @primitives$F64 <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$F64
    │           │       ├── callee: _half #50
    │           │       └── args[0] > call:
    │           │           ├── type: @primitives$F64
    │           │           ├── callee: @operators$add
    │           │           ├── args[0]: s #81 : @primitives$F64
    │           │           └── args[1]: s #81 : @primitives$F64
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: @primitives$F64
    │                   ├── ctor: @primitives$F64
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── instances[0] > instance:
    │   ├── of: pick #12 with T = @primitives$F64
    │   ├── params[0]: first #91 : @primitives$F64
    │   ├── params[1]: second #92 : @primitives$F64
    │   ├── params[2]: takeFirst #93 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #94 : @primitives$F64
    │   │   └── value: second #92 : @primitives$F64
    │   ├── body[1] > let:
    │   │   ├── local: ran #95 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #93 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #94 : @primitives$F64
    │   │           └── value: first #91 : @primitives$F64
    │   └── body[2] > return: chosen #94 : @primitives$F64
    ├── instances[1] > instance:
    │   ├── of: pick #12 with T = @primitives$I64
    │   ├── params[0]: first #86 : @primitives$I64
    │   ├── params[1]: second #87 : @primitives$I64
    │   ├── params[2]: takeFirst #88 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #89 : @primitives$I64
    │   │   └── value: second #87 : @primitives$I64
    │   ├── body[1] > let:
    │   │   ├── local: ran #90 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #88 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #89 : @primitives$I64
    │   │           └── value: first #86 : @primitives$I64
    │   └── body[2] > return: chosen #89 : @primitives$I64
    ├── instances[2] > instance:
    │   ├── of: Pair #14 with T = @primitives$F64
    │   ├── params[0]: left #84 : @primitives$F64
    │   ├── params[1]: right #85 : @primitives$F64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$F64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #84 : @primitives$F64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #85 : @primitives$F64
    ├── instances[3] > instance:
    │   ├── of: Pair #14 with T = @primitives$I64
    │   ├── params[0]: left #82 : @primitives$I64
    │   ├── params[1]: right #83 : @primitives$I64
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$I64>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #82 : @primitives$I64
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #83 : @primitives$I64
    ├── instances[4] > instance:
    │   ├── of: sum #15 with T = @primitives$F64
    │   ├── params[0]: pair #97 : app$Pair<@primitives$F64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$F64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$F64
    │       │   ├── target: pair #97 : app$Pair<@primitives$F64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$F64
    │           ├── target: pair #97 : app$Pair<@primitives$F64>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #15 with T = @primitives$I64
    │   ├── params[0]: pair #96 : app$Pair<@primitives$I64>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: @operators$add
    │       ├── args[0] > field:
    │       │   ├── type: @primitives$I64
    │       │   ├── target: pair #96 : app$Pair<@primitives$I64>
    │       │   └── field: left (slot 0)
    │       └── args[1] > field:
    │           ├── type: @primitives$I64
    │           ├── target: pair #96 : app$Pair<@primitives$I64>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #16 with T = @primitives$I64, n = 3
    │   ├── params[0]: values #98 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #17 with n = 3
    │   ├── params[0]: values #99 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$I64
    │       ├── ctor: @primitives$I64
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #18 with n = 3
    │   ├── params[0]: values #104 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: measured #17 with n = 3
    │       ├── args[0]: values #104 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #19 with count = 3
    │   ├── params[0]: values #103 : @primitives$Array<@primitives$I64, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$I64
    │       ├── callee: relayed #18 with n = 3
    │       ├── args[0]: values #103 : @primitives$Array<@primitives$I64, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    └── instances[10] > instance:
        ├── of: sizedLike #20 with n = 3
        ├── params[0]: values #100 : @primitives$Array<@primitives$I64, 3>
        ├── body[0] > let:
        │   ├── local: measure #102 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
        │   └── value > lambda:
        │       ├── type: @primitives$I64[@primitives$Array<@primitives$I64, 3>]
        │       ├── params[0]: held #101 : @primitives$Array<@primitives$I64, 3>
        │       └── body[0] > return > construct:
        │           ├── type: @primitives$I64
        │           ├── ctor: @primitives$I64
        │           └── args[0]: n = 3 : @concepts$Int
        └── body[1] > return > call_value:
            ├── type: @primitives$I64
            ├── callee: measure #102 : @primitives$I64[@primitives$Array<@primitives$I64, 3>]
            └── args[0]: values #100 : @primitives$Array<@primitives$I64, 3>
