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
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── op: *
    │   │   │   │   ├── impl: @primitives$*
    │   │   │   │   ├── left > flip:
    │   │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   │   ├── impl: @primitives$~
    │   │   │   │   │   └── value: this #3 : @primitives$Bool
    │   │   │   │   └── right: condition #4 : @primitives$Bool
    │   │   │   └── args[1]: body #5 : @concepts$Block
    │   │   ├── body[1] > assign:
    │   │   │   ├── target: this #3 : @primitives$Bool
    │   │   │   └── value > op:
    │   │   │       ├── type: @primitives$Bool
    │   │   │       ├── op: +
    │   │   │       ├── impl: @primitives$+
    │   │   │       ├── left: this #3 : @primitives$Bool
    │   │   │       └── right: condition #4 : @primitives$Bool
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
    │   │   │   ├── args[0] > flip:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── impl: @primitives$~
    │   │   │   │   └── value: this #6 : @primitives$Bool
    │   │   │   └── args[1]: body #7 : @concepts$Block
    │   │   └── body[1] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[9] > verb:
    │   │   ├── signature: @primitives$Unit to(this @primitives$Int, @primitives$Int, @concepts$Block) mut #10
    │   │   ├── params[0]: this #8 : @primitives$Int
    │   │   ├── params[1]: end #9 : @primitives$Int
    │   │   ├── params[2]: body #10 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$repeat
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── op: +
    │   │   │   │   ├── impl: @primitives$+
    │   │   │   │   ├── left > op:
    │   │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   │   ├── op: +
    │   │   │   │   │   ├── impl: @primitives$+
    │   │   │   │   │   ├── left: end #9 : @primitives$Int
    │   │   │   │   │   └── right > flip:
    │   │   │   │   │       ├── type: @primitives$Int
    │   │   │   │   │       ├── impl: @primitives$~
    │   │   │   │   │       └── value: this #8 : @primitives$Int
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: @primitives$Int
    │   │   │   │       ├── ctor: @primitives$Int
    │   │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   │   ├── args[1] > block[0] > do > call:
    │   │   │   │   ├── type: @primitives$Unit
    │   │   │   │   ├── callee: @controlflow$branch
    │   │   │   │   ├── args[0]: true : @primitives$Bool
    │   │   │   │   └── args[1]: body #10 : @concepts$Block
    │   │   │   └── args[1] > block[1] > assign:
    │   │   │       ├── target: this #8 : @primitives$Int
    │   │   │       └── value > op:
    │   │   │           ├── type: @primitives$Int
    │   │   │           ├── op: +
    │   │   │           ├── impl: @primitives$+
    │   │   │           ├── left: this #8 : @primitives$Int
    │   │   │           └── right > construct:
    │   │   │               ├── type: @primitives$Int
    │   │   │               ├── ctor: @primitives$Int
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
    │   │   ├── signature: @primitives$Int count(@primitives$Array<T, n>) #16
    │   │   └── body: checked per instance
    │   ├── decls[16] > verb:
    │   │   ├── signature: @primitives$Int measured(@primitives$Array<@primitives$Int, n>, n @concepts$Int) #17
    │   │   └── body: checked per instance
    │   ├── decls[17] > verb:
    │   │   ├── signature: @primitives$Int relayed(@primitives$Array<@primitives$Int, 3>, n @concepts$Int) #18
    │   │   └── body: checked per instance
    │   ├── decls[18] > verb:
    │   │   ├── signature: @primitives$Int forwarded(@primitives$Array<@primitives$Int, 3>, count @concepts$Int) #19
    │   │   └── body: checked per instance
    │   ├── decls[19] > verb:
    │   │   ├── signature: @primitives$Int sizedLike(@primitives$Array<@primitives$Int, 3>, n @concepts$Int) #20
    │   │   └── body: checked per instance
    │   ├── decls[20] > verb:
    │   │   ├── signature: app$Pair<@primitives$Int> pairOf(@concepts$Int, @concepts$Int) #21
    │   │   ├── params[0]: x #12 : @concepts$Int
    │   │   ├── params[1]: y #13 : @concepts$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<@primitives$Int>
    │   │       ├── ctor: Pair #14 with T = @primitives$Int
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: @primitives$Int
    │   │       │   ├── ctor: @primitives$Int
    │   │       │   └── args[0]: x #12 : @concepts$Int
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$Int
    │   │           ├── ctor: @primitives$Int
    │   │           └── args[0]: y #13 : @concepts$Int
    │   ├── decls[21] > verb:
    │   │   ├── signature: app$Pair<@primitives$Float> pairOf(@concepts$Float, @concepts$Float) #22
    │   │   ├── params[0]: x #14 : @concepts$Float
    │   │   ├── params[1]: y #15 : @concepts$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<@primitives$Float>
    │   │       ├── ctor: Pair #14 with T = @primitives$Float
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── ctor: @primitives$Float
    │   │       │   └── args[0]: x #14 : @concepts$Float
    │   │       └── args[1] > construct:
    │   │           ├── type: @primitives$Float
    │   │           ├── ctor: @primitives$Float
    │   │           └── args[0]: y #15 : @concepts$Float
    │   ├── decls[22] > verb:
    │   │   ├── signature: @primitives$Float?@primitives$String safeDivide(@primitives$Float, @primitives$Float) #23
    │   │   ├── params[0]: numerator #16 : @primitives$Float
    │   │   ├── params[1]: denominator #17 : @primitives$Float
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Bool
    │   │   │   ├── callee: if #7
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── op: ==
    │   │   │   │   ├── impl: @primitives$==
    │   │   │   │   ├── left: denominator #17 : @primitives$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: @primitives$Float
    │   │   │   │       ├── ctor: @primitives$Float
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "zero" : @concepts$String
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: @primitives$Bool
    │   │   │   ├── callee: if #7
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── op: <
    │   │   │   │   ├── impl: @primitives$<
    │   │   │   │   ├── left: denominator #17 : @primitives$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: @primitives$Float
    │   │   │   │       ├── ctor: @primitives$Float
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "negative" : @concepts$String
    │   │   └── body[2] > return > op:
    │   │       ├── type: @primitives$Float
    │   │       ├── op: /
    │   │       ├── impl: @primitives$/
    │   │       ├── left: numerator #16 : @primitives$Float
    │   │       └── right: denominator #17 : @primitives$Float
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
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── ctor: @primitives$Float
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[4] > let:
    │   │   │   ├── local: flat #26 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #37
    │   │   │       └── fields[0] > field:
    │   │   │           ├── name: x (slot 0)
    │   │   │           └── value > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[5] > let:
    │   │   │   ├── local: size #27 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: length #40
    │   │   │       └── args[0]: moved #25 : shapes$Vec2
    │   │   ├── body[6] > let:
    │   │   │   ├── local: shape #28 : shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── ctor: @primitives$Float
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[7] > let:
    │   │   │   ├── local: covered #29 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: area #47
    │   │   │       └── args[0]: shape #28 : shapes$Shape
    │   │   ├── body[8] > let:
    │   │   │   ├── local: radius #30 : @primitives$Float
    │   │   │   └── value > case_read:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── target: shape #28 : shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── handler:
    │   │   │           ├── binder: none
    │   │   │           └── body[0] > resolve > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[9] > let:
    │   │   │   ├── local: half #32 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: safeDivide #23
    │   │   │       ├── args[0]: covered #29 : @primitives$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── ctor: @primitives$Float
    │   │   │       │   └── args[0]: 2.0 : @concepts$Float
    │   │   │       └── handler:
    │   │   │           ├── binder: reason #31 : @primitives$String
    │   │   │           ├── body[0] > do > call:
    │   │   │           │   ├── type: @primitives$Unit
    │   │   │           │   ├── callee: say #11
    │   │   │           │   └── args[0]: reason #31 : @primitives$String
    │   │   │           └── body[1] > resolve > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[10] > let:
    │   │   │   ├── local: picked #33 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: pick #12 with T = @primitives$Int
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$Int
    │   │   │       │   ├── ctor: @primitives$Int
    │   │   │       │   └── args[0]: 1 : @concepts$Int
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$Int
    │   │   │       │   ├── ctor: @primitives$Int
    │   │   │       │   └── args[0]: 2 : @concepts$Int
    │   │   │       └── args[2]: true : @primitives$Bool
    │   │   ├── body[11] > let:
    │   │   │   ├── local: chance #34 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: pick #12 with T = @primitives$Float
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── ctor: @primitives$Float
    │   │   │       │   └── args[0]: 0.5 : @concepts$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── ctor: @primitives$Float
    │   │   │       │   └── args[0]: 1.5 : @concepts$Float
    │   │   │       └── args[2]: false : @primitives$Bool
    │   │   ├── body[12] > let:
    │   │   │   ├── local: pair #35 : app$Pair<@primitives$Int>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$Int>
    │   │   │       ├── ctor: Pair #14 with T = @primitives$Int
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$Int
    │   │   │       │   ├── ctor: @primitives$Int
    │   │   │       │   └── args[0]: 3 : @concepts$Int
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: @primitives$Int
    │   │   │           ├── ctor: @primitives$Int
    │   │   │           └── args[0]: 4 : @concepts$Int
    │   │   ├── body[13] > let:
    │   │   │   ├── local: total #36 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: sum #15 with T = @primitives$Int
    │   │   │       └── args[0]: pair #35 : app$Pair<@primitives$Int>
    │   │   ├── body[14] > let:
    │   │   │   ├── local: floats #37 : app$Pair<@primitives$Float>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<@primitives$Float>
    │   │   │       ├── ctor: Pair #14 with T = @primitives$Float
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── ctor: @primitives$Float
    │   │   │       │   └── args[0]: 1.0 : @concepts$Float
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── ctor: @primitives$Float
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[15] > let:
    │   │   │   ├── local: both #38 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: sum #15 with T = @primitives$Float
    │   │   │       └── args[0]: floats #37 : app$Pair<@primitives$Float>
    │   │   ├── body[16] > let:
    │   │   │   ├── local: spare #39 : ^shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── ctor: @primitives$Float
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
    │   │   │           │       ├── type: @primitives$Float
    │   │   │           │       ├── ctor: @primitives$Float
    │   │   │           │       └── args[0]: 3.0 : @concepts$Float
    │   │   │           └── items[1] > case:
    │   │   │               ├── type: shapes$Shape
    │   │   │               ├── case: circle
    │   │   │               └── payload > construct:
    │   │   │                   ├── type: @primitives$Float
    │   │   │                   ├── ctor: @primitives$Float
    │   │   │                   └── args[0]: 4.0 : @concepts$Float
    │   │   ├── body[21] > let:
    │   │   │   ├── local: second #43 : &shapes$Shape
    │   │   │   └── value > subscript:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── impl: @primitives$[] with T = shapes$Shape, n = 2
    │   │   │       ├── target: shapes #42 : @primitives$ArrayRef<shapes$Shape, 2>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$Int
    │   │   │           ├── ctor: @primitives$Int
    │   │   │           └── args[0]: 2 : @concepts$Int
    │   │   ├── body[22] > let:
    │   │   │   ├── local: tiles #45 : @primitives$ArrayRef<@primitives$Int, 4>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$ArrayRef<@primitives$Int, 4>
    │   │   │       ├── ctor: @primitives$ArrayRef.fill with T = @primitives$Int, n = 4
    │   │   │       ├── args[0]: 4 : @concepts$Int
    │   │   │       └── args[1] > lambda:
    │   │   │           ├── type: @primitives$Int[@primitives$Int]
    │   │   │           ├── params[0]: n #44 : @primitives$Int
    │   │   │           └── body[0] > return > op:
    │   │   │               ├── type: @primitives$Int
    │   │   │               ├── op: *
    │   │   │               ├── impl: @primitives$*
    │   │   │               ├── left: n #44 : @primitives$Int
    │   │   │               └── right: n #44 : @primitives$Int
    │   │   ├── body[23] > let:
    │   │   │   ├── local: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$Array<@primitives$Int, 3>
    │   │   │       ├── ctor: @primitives$Array with T = @primitives$Int, n = 3
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<@primitives$Int, 3>
    │   │   │           ├── items[0] > construct:
    │   │   │           │   ├── type: @primitives$Int
    │   │   │           │   ├── ctor: @primitives$Int
    │   │   │           │   └── args[0]: 1 : @concepts$Int
    │   │   │           ├── items[1] > construct:
    │   │   │           │   ├── type: @primitives$Int
    │   │   │           │   ├── ctor: @primitives$Int
    │   │   │           │   └── args[0]: 2 : @concepts$Int
    │   │   │           └── items[2] > construct:
    │   │   │               ├── type: @primitives$Int
    │   │   │               ├── ctor: @primitives$Int
    │   │   │               └── args[0]: 3 : @concepts$Int
    │   │   ├── body[24] > let:
    │   │   │   ├── local: first #47 : @primitives$Int
    │   │   │   └── value > subscript:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── impl: @primitives$[] with T = @primitives$Int, n = 3
    │   │   │       ├── target: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$Int
    │   │   │           ├── ctor: @primitives$Int
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[25] > let:
    │   │   │   ├── local: length #48 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: count #16 with T = @primitives$Int, n = 3
    │   │   │       └── args[0]: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   ├── body[26] > let:
    │   │   │   ├── local: sized #49 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: measured #17 with n = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[27] > let:
    │   │   │   ├── local: like #50 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: sizedLike #20 with n = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[28] > let:
    │   │   │   ├── local: passed #51 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: forwarded #19 with count = 3
    │   │   │       ├── args[0]: numbers #46 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[29] > let:
    │   │   │   ├── local: ints #52 : app$Pair<@primitives$Int>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$Int>
    │   │   │       ├── callee: pairOf #21
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[30] > let:
    │   │   │   ├── local: decimals #53 : app$Pair<@primitives$Float>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$Float>
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
    │   │   │   ├── local: i #56 : @primitives$Int
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── ctor: @primitives$Int
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[35] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: to #10
    │   │   │   ├── args[0]: i #56 : @primitives$Int
    │   │   │   ├── args[1] > construct:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── ctor: @primitives$Int
    │   │   │   │   └── args[0]: 3 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > call:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── callee: describe #28
    │   │   │           └── args[0]: .topLeft : shapes$Corner
    │   │   ├── body[36] > let:
    │   │   │   ├── local: double #58 : @primitives$Float[@primitives$Float]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: @primitives$Float[@primitives$Float]
    │   │   │       ├── params[0]: value #57 : @primitives$Float
    │   │   │       └── body[0] > return > op:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── op: *
    │   │   │           ├── impl: @primitives$*
    │   │   │           ├── left: value #57 : @primitives$Float
    │   │   │           └── right > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[37] > let:
    │   │   │   ├── local: doubled #59 : @primitives$Float
    │   │   │   └── value > call_value:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: double #58 : @primitives$Float[@primitives$Float]
    │   │   │       └── args[0]: half #32 : @primitives$Float
    │   │   ├── body[38] > let:
    │   │   │   ├── local: chain #60 : @primitives$Bool
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Bool
    │   │   │       ├── callee: if #7
    │   │   │       ├── args[0] > op:
    │   │   │       │   ├── type: @primitives$Bool
    │   │   │       │   ├── op: <
    │   │   │       │   ├── impl: @primitives$<
    │   │   │       │   ├── left: total #36 : @primitives$Int
    │   │   │       │   └── right > construct:
    │   │   │       │       ├── type: @primitives$Int
    │   │   │       │       ├── ctor: @primitives$Int
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
    │   │   │   ├── args[1] > op:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── op: ==
    │   │   │   │   ├── impl: @primitives$==
    │   │   │   │   ├── left: total #36 : @primitives$Int
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: @primitives$Int
    │   │   │   │       ├── ctor: @primitives$Int
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
    │   │   └── target: @primitives$Float
    │   ├── decls[1] > alias:
    │   │   ├── name: Unit #32
    │   │   └── target: @primitives$Unit
    │   ├── decls[2] > alias:
    │   │   ├── name: String #33
    │   │   └── target: @primitives$String
    │   ├── decls[3] > type:
    │   │   ├── name: Vec2 #34
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$Float
    │   │   └── struct[1]: y : @primitives$Float
    │   ├── decls[4] > verb:
    │   │   ├── signature: Vec2(@primitives$Float, @primitives$Float) #35
    │   │   ├── params[0]: x #61 : @primitives$Float
    │   │   ├── params[1]: y #62 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #61 : @primitives$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #62 : @primitives$Float
    │   ├── decls[5] > verb:
    │   │   ├── signature: Vec2.zero() #36
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── ctor: @primitives$Float
    │   │       │       └── args[0]: 0.0 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: 0.0 : @concepts$Float
    │   ├── decls[6] > verb:
    │   │   ├── signature: Vec2{x @primitives$Float; y @primitives$Float = ...} #37
    │   │   ├── params[0]: x #65 : @primitives$Float
    │   │   ├── params[1]: y #66 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #65 : @primitives$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #66 : @primitives$Float
    │   ├── decls[7] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #38
    │   │   ├── params[0]: left #67 : shapes$Vec2
    │   │   ├── params[1]: right #68 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #35
    │   │       ├── args[0] > op:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── op: +
    │   │       │   ├── impl: @primitives$+
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: @primitives$Float
    │   │       │   │   ├── target: left #67 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: right #68 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #67 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #68 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[8] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #39
    │   │   ├── params[0]: value #69 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #35
    │   │       ├── args[0] > flip:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── impl: @primitives$~
    │   │       │   └── value > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: value #69 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > flip:
    │   │           ├── type: @primitives$Float
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: value #69 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[9] > verb:
    │   │   ├── signature: @primitives$Float length(this shapes$Vec2) #40
    │   │   ├── params[0]: this #70 : shapes$Vec2
    │   │   └── body[0] > return > op:
    │   │       ├── type: @primitives$Float
    │   │       ├── op: +
    │   │       ├── impl: @primitives$+
    │   │       ├── left > op:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── op: *
    │   │       │   ├── impl: @primitives$*
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: @primitives$Float
    │   │       │   │   ├── target: this #70 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: this #70 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── right > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: this #70 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: this #70 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$Float) mut #41
    │   │   ├── params[0]: this #71 : shapes$Vec2
    │   │   ├── params[1]: by #72 : @primitives$Float
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$Float
    │   │   │   │   ├── target: this #71 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > op:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: @primitives$*
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── target: this #71 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── right: by #72 : @primitives$Float
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$Float
    │   │   │   │   ├── target: this #71 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > op:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: @primitives$*
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── target: this #71 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── right: by #72 : @primitives$Float
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
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── ctor: @primitives$Float
    │   │       │       └── args[0]: value #73 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: value #73 : @concepts$Float
    │   ├── decls[12] > type:
    │   │   ├── name: Shape #43
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : @primitives$Float
    │   │   ├── variant[1]: square : @primitives$Float
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
    │   ├── decls[15] > verb:
    │   │   ├── signature: @primitives$Float _half(@primitives$Float) #46
    │   │   ├── params[0]: value #74 : @primitives$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: @primitives$Float
    │   │       ├── op: /
    │   │       ├── impl: @primitives$/
    │   │       ├── left: value #74 : @primitives$Float
    │   │       └── right > construct:
    │   │           ├── type: @primitives$Float
    │   │           ├── ctor: @primitives$Float
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[16] > verb:
    │       ├── signature: @primitives$Float area(&shapes$Shape) #47
    │       ├── params[0]: shape #75 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: @primitives$Float
    │           ├── scrutinees[0]: shape #75 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #76 : @primitives$Float <- circle
    │           │   └── body[0] > return > op:
    │           │       ├── type: @primitives$Float
    │           │       ├── op: *
    │           │       ├── impl: @primitives$*
    │           │       ├── left: r #76 : @primitives$Float
    │           │       └── right: r #76 : @primitives$Float
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #77 : @primitives$Float <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$Float
    │           │       ├── callee: _half #46
    │           │       └── args[0] > op:
    │           │           ├── type: @primitives$Float
    │           │           ├── op: +
    │           │           ├── impl: @primitives$+
    │           │           ├── left: s #77 : @primitives$Float
    │           │           └── right: s #77 : @primitives$Float
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: @primitives$Float
    │                   ├── ctor: @primitives$Float
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── instances[0] > instance:
    │   ├── of: pick #12 with T = @primitives$Float
    │   ├── params[0]: first #87 : @primitives$Float
    │   ├── params[1]: second #88 : @primitives$Float
    │   ├── params[2]: takeFirst #89 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #90 : @primitives$Float
    │   │   └── value: second #88 : @primitives$Float
    │   ├── body[1] > let:
    │   │   ├── local: ran #91 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #89 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #90 : @primitives$Float
    │   │           └── value: first #87 : @primitives$Float
    │   └── body[2] > return: chosen #90 : @primitives$Float
    ├── instances[1] > instance:
    │   ├── of: pick #12 with T = @primitives$Int
    │   ├── params[0]: first #82 : @primitives$Int
    │   ├── params[1]: second #83 : @primitives$Int
    │   ├── params[2]: takeFirst #84 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #85 : @primitives$Int
    │   │   └── value: second #83 : @primitives$Int
    │   ├── body[1] > let:
    │   │   ├── local: ran #86 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #84 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #85 : @primitives$Int
    │   │           └── value: first #82 : @primitives$Int
    │   └── body[2] > return: chosen #85 : @primitives$Int
    ├── instances[2] > instance:
    │   ├── of: Pair #14 with T = @primitives$Float
    │   ├── params[0]: left #80 : @primitives$Float
    │   ├── params[1]: right #81 : @primitives$Float
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$Float>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #80 : @primitives$Float
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #81 : @primitives$Float
    ├── instances[3] > instance:
    │   ├── of: Pair #14 with T = @primitives$Int
    │   ├── params[0]: left #78 : @primitives$Int
    │   ├── params[1]: right #79 : @primitives$Int
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$Int>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #78 : @primitives$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #79 : @primitives$Int
    ├── instances[4] > instance:
    │   ├── of: sum #15 with T = @primitives$Float
    │   ├── params[0]: pair #93 : app$Pair<@primitives$Float>
    │   └── body[0] > return > op:
    │       ├── type: @primitives$Float
    │       ├── op: +
    │       ├── impl: @primitives$+
    │       ├── left > field:
    │       │   ├── type: @primitives$Float
    │       │   ├── target: pair #93 : app$Pair<@primitives$Float>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: @primitives$Float
    │           ├── target: pair #93 : app$Pair<@primitives$Float>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #15 with T = @primitives$Int
    │   ├── params[0]: pair #92 : app$Pair<@primitives$Int>
    │   └── body[0] > return > op:
    │       ├── type: @primitives$Int
    │       ├── op: +
    │       ├── impl: @primitives$+
    │       ├── left > field:
    │       │   ├── type: @primitives$Int
    │       │   ├── target: pair #92 : app$Pair<@primitives$Int>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: @primitives$Int
    │           ├── target: pair #92 : app$Pair<@primitives$Int>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #16 with T = @primitives$Int, n = 3
    │   ├── params[0]: values #94 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$Int
    │       ├── ctor: @primitives$Int
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #17 with n = 3
    │   ├── params[0]: values #95 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$Int
    │       ├── ctor: @primitives$Int
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #18 with n = 3
    │   ├── params[0]: values #100 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$Int
    │       ├── callee: measured #17 with n = 3
    │       ├── args[0]: values #100 : @primitives$Array<@primitives$Int, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #19 with count = 3
    │   ├── params[0]: values #99 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$Int
    │       ├── callee: relayed #18 with n = 3
    │       ├── args[0]: values #99 : @primitives$Array<@primitives$Int, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    └── instances[10] > instance:
        ├── of: sizedLike #20 with n = 3
        ├── params[0]: values #96 : @primitives$Array<@primitives$Int, 3>
        ├── body[0] > let:
        │   ├── local: measure #98 : @primitives$Int[@primitives$Array<@primitives$Int, 3>]
        │   └── value > lambda:
        │       ├── type: @primitives$Int[@primitives$Array<@primitives$Int, 3>]
        │       ├── params[0]: held #97 : @primitives$Array<@primitives$Int, 3>
        │       └── body[0] > return > construct:
        │           ├── type: @primitives$Int
        │           ├── ctor: @primitives$Int
        │           └── args[0]: n = 3 : @concepts$Int
        └── body[1] > return > call_value:
            ├── type: @primitives$Int
            ├── callee: measure #98 : @primitives$Int[@primitives$Array<@primitives$Int, 3>]
            └── args[0]: values #96 : @primitives$Array<@primitives$Int, 3>
