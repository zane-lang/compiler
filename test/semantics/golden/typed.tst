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
    │   ├── decls[23] > verb:
    │   │   ├── signature: @primitives$String describe(shapes$Corner) #24
    │   │   ├── params[0]: corner #18 : shapes$Corner
    │   │   └── body[0] > return > match:
    │   │       ├── type: @primitives$String
    │   │       ├── scrutinees[0]: corner #18 : shapes$Corner
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
    │   ├── decls[24] > verb:
    │   │   ├── signature: @primitives$Unit main() #25
    │   │   ├── params:
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0] > construct:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── ctor: @primitives$String
    │   │   │       └── args[0]: "hello" : @concepts$String
    │   │   ├── body[1] > let:
    │   │   │   ├── local: origin #19 : shapes$Vec2
    │   │   │   └── value > construct:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2.zero #32
    │   │   │       └── args:
    │   │   ├── body[2] > let:
    │   │   │   ├── local: moved #20 : shapes$Vec2
    │   │   │   └── value > op:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #34
    │   │   │       ├── left: origin #19 : shapes$Vec2
    │   │   │       └── right > coerce:
    │   │   │           ├── type: shapes$Vec2
    │   │   │           ├── ctor: Vec2 #38
    │   │   │           └── value: 3.0 : @concepts$Float
    │   │   ├── body[3] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: scale #37
    │   │   │   ├── args[0]: moved #20 : shapes$Vec2
    │   │   │   └── args[1] > construct:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── ctor: @primitives$Float
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[4] > let:
    │   │   │   ├── local: flat #21 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #33
    │   │   │       └── fields[0] > field:
    │   │   │           ├── name: x (slot 0)
    │   │   │           └── value > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[5] > let:
    │   │   │   ├── local: size #22 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: length #36
    │   │   │       └── args[0]: moved #20 : shapes$Vec2
    │   │   ├── body[6] > let:
    │   │   │   ├── local: shape #23 : shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── ctor: @primitives$Float
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[7] > let:
    │   │   │   ├── local: covered #24 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: area #43
    │   │   │       └── args[0]: shape #23 : shapes$Shape
    │   │   ├── body[8] > let:
    │   │   │   ├── local: radius #25 : @primitives$Float
    │   │   │   └── value > case_read:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── target: shape #23 : shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── handler:
    │   │   │           ├── binder: none
    │   │   │           └── body[0] > resolve > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[9] > let:
    │   │   │   ├── local: half #27 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: safeDivide #23
    │   │   │       ├── args[0]: covered #24 : @primitives$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── ctor: @primitives$Float
    │   │   │       │   └── args[0]: 2.0 : @concepts$Float
    │   │   │       └── handler:
    │   │   │           ├── binder: reason #26 : @primitives$String
    │   │   │           ├── body[0] > do > call:
    │   │   │           │   ├── type: @primitives$Unit
    │   │   │           │   ├── callee: say #11
    │   │   │           │   └── args[0]: reason #26 : @primitives$String
    │   │   │           └── body[1] > resolve > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[10] > let:
    │   │   │   ├── local: picked #28 : @primitives$Int
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
    │   │   │   ├── local: chance #29 : @primitives$Float
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
    │   │   │   ├── local: pair #30 : app$Pair<@primitives$Int>
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
    │   │   │   ├── local: total #31 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: sum #15 with T = @primitives$Int
    │   │   │       └── args[0]: pair #30 : app$Pair<@primitives$Int>
    │   │   ├── body[14] > let:
    │   │   │   ├── local: floats #32 : app$Pair<@primitives$Float>
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
    │   │   │   ├── local: both #33 : @primitives$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: sum #15 with T = @primitives$Float
    │   │   │       └── args[0]: floats #32 : app$Pair<@primitives$Float>
    │   │   ├── body[16] > let:
    │   │   │   ├── local: numbers #34 : @primitives$Array<@primitives$Int, 3>
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
    │   │   ├── body[17] > let:
    │   │   │   ├── local: first #35 : @primitives$Int
    │   │   │   └── value > subscript:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── impl: @primitives$[] with T = @primitives$Int, n = 3
    │   │   │       ├── target: numbers #34 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$Int
    │   │   │           ├── ctor: @primitives$Int
    │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   ├── body[18] > let:
    │   │   │   ├── local: length #36 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: count #16 with T = @primitives$Int, n = 3
    │   │   │       └── args[0]: numbers #34 : @primitives$Array<@primitives$Int, 3>
    │   │   ├── body[19] > let:
    │   │   │   ├── local: sized #37 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: measured #17 with n = 3
    │   │   │       ├── args[0]: numbers #34 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[20] > let:
    │   │   │   ├── local: like #38 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: sizedLike #20 with n = 3
    │   │   │       ├── args[0]: numbers #34 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[21] > let:
    │   │   │   ├── local: passed #39 : @primitives$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── callee: forwarded #19 with count = 3
    │   │   │       ├── args[0]: numbers #34 : @primitives$Array<@primitives$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[22] > let:
    │   │   │   ├── local: ints #40 : app$Pair<@primitives$Int>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$Int>
    │   │   │       ├── callee: pairOf #21
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[23] > let:
    │   │   │   ├── local: decimals #41 : app$Pair<@primitives$Float>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<@primitives$Float>
    │   │   │       ├── callee: pairOf #22
    │   │   │       ├── args[0]: 2.5 : @concepts$Float
    │   │   │       └── args[1]: 3.5 : @concepts$Float
    │   │   ├── body[24] > let:
    │   │   │   ├── local: label #42 : @primitives$String
    │   │   │   └── value > map_read:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: .topLeft : shapes$Corner
    │   │   │       └── map: label #41
    │   │   ├── body[25] > let:
    │   │   │   ├── local: side #43 : @primitives$String
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── callee: describe #24
    │   │   │       └── args[0]: .bottomRight : shapes$Corner
    │   │   ├── body[26] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: say #11
    │   │   │   └── args[0]: side #43 : @primitives$String
    │   │   ├── body[27] > let:
    │   │   │   ├── local: i #44 : @primitives$Int
    │   │   │   └── value > construct:
    │   │   │       ├── type: @primitives$Int
    │   │   │       ├── ctor: @primitives$Int
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[28] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: to #10
    │   │   │   ├── args[0]: i #44 : @primitives$Int
    │   │   │   ├── args[1] > construct:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── ctor: @primitives$Int
    │   │   │   │   └── args[0]: 3 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > call:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── callee: describe #24
    │   │   │           └── args[0]: .topLeft : shapes$Corner
    │   │   ├── body[29] > let:
    │   │   │   ├── local: double #46 : @primitives$Float[@primitives$Float]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: @primitives$Float[@primitives$Float]
    │   │   │       ├── params[0]: value #45 : @primitives$Float
    │   │   │       └── body[0] > return > op:
    │   │   │           ├── type: @primitives$Float
    │   │   │           ├── op: *
    │   │   │           ├── impl: @primitives$*
    │   │   │           ├── left: value #45 : @primitives$Float
    │   │   │           └── right > construct:
    │   │   │               ├── type: @primitives$Float
    │   │   │               ├── ctor: @primitives$Float
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[30] > let:
    │   │   │   ├── local: doubled #47 : @primitives$Float
    │   │   │   └── value > call_value:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── callee: double #46 : @primitives$Float[@primitives$Float]
    │   │   │       └── args[0]: half #27 : @primitives$Float
    │   │   ├── body[31] > let:
    │   │   │   ├── local: chain #48 : @primitives$Bool
    │   │   │   └── value > call:
    │   │   │       ├── type: @primitives$Bool
    │   │   │       ├── callee: if #7
    │   │   │       ├── args[0] > op:
    │   │   │       │   ├── type: @primitives$Bool
    │   │   │       │   ├── op: <
    │   │   │       │   ├── impl: @primitives$<
    │   │   │       │   ├── left: total #31 : @primitives$Int
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
    │   │   ├── body[32] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: elif #8
    │   │   │   ├── args[0]: chain #48 : @primitives$Bool
    │   │   │   ├── args[1] > op:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── op: ==
    │   │   │   │   ├── impl: @primitives$==
    │   │   │   │   ├── left: total #31 : @primitives$Int
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
    │   │   ├── body[33] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: else #9
    │   │   │   ├── args[0]: chain #48 : @primitives$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: say #11
    │   │   │       └── args[0] > construct:
    │   │   │           ├── type: @primitives$String
    │   │   │           ├── ctor: @primitives$String
    │   │   │           └── args[0]: "large" : @concepts$String
    │   │   └── body[34] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   └── decls[25] > verb:
    │       ├── signature: T twice(T) #26
    │       └── body: checked per instance
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > alias:
    │   │   ├── name: Float #27
    │   │   └── target: @primitives$Float
    │   ├── decls[1] > alias:
    │   │   ├── name: Unit #28
    │   │   └── target: @primitives$Unit
    │   ├── decls[2] > alias:
    │   │   ├── name: String #29
    │   │   └── target: @primitives$String
    │   ├── decls[3] > type:
    │   │   ├── name: Vec2 #30
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : @primitives$Float
    │   │   └── struct[1]: y : @primitives$Float
    │   ├── decls[4] > verb:
    │   │   ├── signature: Vec2(@primitives$Float, @primitives$Float) #31
    │   │   ├── params[0]: x #49 : @primitives$Float
    │   │   ├── params[1]: y #50 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #49 : @primitives$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #50 : @primitives$Float
    │   ├── decls[5] > verb:
    │   │   ├── signature: Vec2.zero() #32
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
    │   │   ├── signature: Vec2{x @primitives$Float; y @primitives$Float = ...} #33
    │   │   ├── params[0]: x #53 : @primitives$Float
    │   │   ├── params[1]: y #54 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #53 : @primitives$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #54 : @primitives$Float
    │   ├── decls[7] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #34
    │   │   ├── params[0]: left #55 : shapes$Vec2
    │   │   ├── params[1]: right #56 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #31
    │   │       ├── args[0] > op:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── op: +
    │   │       │   ├── impl: @primitives$+
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: @primitives$Float
    │   │       │   │   ├── target: left #55 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: right #56 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #55 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #56 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[8] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #35
    │   │   ├── params[0]: value #57 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #31
    │   │       ├── args[0] > flip:
    │   │       │   ├── type: @primitives$Float
    │   │       │   ├── impl: @primitives$~
    │   │       │   └── value > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: value #57 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > flip:
    │   │           ├── type: @primitives$Float
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: value #57 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[9] > verb:
    │   │   ├── signature: @primitives$Float length(this shapes$Vec2) #36
    │   │   ├── params[0]: this #58 : shapes$Vec2
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
    │   │       │   │   ├── target: this #58 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── target: this #58 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── right > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: this #58 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: this #58 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[10] > verb:
    │   │   ├── signature: @primitives$Unit scale(this shapes$Vec2, @primitives$Float) mut #37
    │   │   ├── params[0]: this #59 : shapes$Vec2
    │   │   ├── params[1]: by #60 : @primitives$Float
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$Float
    │   │   │   │   ├── target: this #59 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > op:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: @primitives$*
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── target: this #59 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── right: by #60 : @primitives$Float
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: @primitives$Float
    │   │   │   │   ├── target: this #59 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > op:
    │   │   │       ├── type: @primitives$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: @primitives$*
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: @primitives$Float
    │   │   │       │   ├── target: this #59 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── right: by #60 : @primitives$Float
    │   │   └── body[2] > return > construct:
    │   │       ├── type: @primitives$Unit
    │   │       ├── ctor: @primitives$Unit
    │   │       └── args:
    │   ├── decls[11] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Float) #38
    │   │   ├── params[0]: value #61 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: @primitives$Float
    │   │       │       ├── ctor: @primitives$Float
    │   │       │       └── args[0]: value #61 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: value #61 : @concepts$Float
    │   ├── decls[12] > type:
    │   │   ├── name: Shape #39
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : @primitives$Float
    │   │   ├── variant[1]: square : @primitives$Float
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[13] > type:
    │   │   ├── name: Corner #40
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[14] > enum_map:
    │   │   ├── map: shapes$Corner.label #41
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
    │   │   ├── signature: @primitives$Float _half(@primitives$Float) #42
    │   │   ├── params[0]: value #62 : @primitives$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: @primitives$Float
    │   │       ├── op: /
    │   │       ├── impl: @primitives$/
    │   │       ├── left: value #62 : @primitives$Float
    │   │       └── right > construct:
    │   │           ├── type: @primitives$Float
    │   │           ├── ctor: @primitives$Float
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[16] > verb:
    │       ├── signature: @primitives$Float area(&shapes$Shape) #43
    │       ├── params[0]: shape #63 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: @primitives$Float
    │           ├── scrutinees[0]: shape #63 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #64 : @primitives$Float <- circle
    │           │   └── body[0] > return > op:
    │           │       ├── type: @primitives$Float
    │           │       ├── op: *
    │           │       ├── impl: @primitives$*
    │           │       ├── left: r #64 : @primitives$Float
    │           │       └── right: r #64 : @primitives$Float
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #65 : @primitives$Float <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: @primitives$Float
    │           │       ├── callee: _half #42
    │           │       └── args[0] > op:
    │           │           ├── type: @primitives$Float
    │           │           ├── op: +
    │           │           ├── impl: @primitives$+
    │           │           ├── left: s #65 : @primitives$Float
    │           │           └── right: s #65 : @primitives$Float
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: @primitives$Float
    │                   ├── ctor: @primitives$Float
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── instances[0] > instance:
    │   ├── of: pick #12 with T = @primitives$Float
    │   ├── params[0]: first #75 : @primitives$Float
    │   ├── params[1]: second #76 : @primitives$Float
    │   ├── params[2]: takeFirst #77 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #78 : @primitives$Float
    │   │   └── value: second #76 : @primitives$Float
    │   ├── body[1] > let:
    │   │   ├── local: ran #79 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #77 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #78 : @primitives$Float
    │   │           └── value: first #75 : @primitives$Float
    │   └── body[2] > return: chosen #78 : @primitives$Float
    ├── instances[1] > instance:
    │   ├── of: pick #12 with T = @primitives$Int
    │   ├── params[0]: first #70 : @primitives$Int
    │   ├── params[1]: second #71 : @primitives$Int
    │   ├── params[2]: takeFirst #72 : @primitives$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #73 : @primitives$Int
    │   │   └── value: second #71 : @primitives$Int
    │   ├── body[1] > let:
    │   │   ├── local: ran #74 : @primitives$Bool
    │   │   └── value > call:
    │   │       ├── type: @primitives$Bool
    │   │       ├── callee: if #7
    │   │       ├── args[0]: takeFirst #72 : @primitives$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #73 : @primitives$Int
    │   │           └── value: first #70 : @primitives$Int
    │   └── body[2] > return: chosen #73 : @primitives$Int
    ├── instances[2] > instance:
    │   ├── of: Pair #14 with T = @primitives$Float
    │   ├── params[0]: left #68 : @primitives$Float
    │   ├── params[1]: right #69 : @primitives$Float
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$Float>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #68 : @primitives$Float
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #69 : @primitives$Float
    ├── instances[3] > instance:
    │   ├── of: Pair #14 with T = @primitives$Int
    │   ├── params[0]: left #66 : @primitives$Int
    │   ├── params[1]: right #67 : @primitives$Int
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<@primitives$Int>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #66 : @primitives$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #67 : @primitives$Int
    ├── instances[4] > instance:
    │   ├── of: sum #15 with T = @primitives$Float
    │   ├── params[0]: pair #81 : app$Pair<@primitives$Float>
    │   └── body[0] > return > op:
    │       ├── type: @primitives$Float
    │       ├── op: +
    │       ├── impl: @primitives$+
    │       ├── left > field:
    │       │   ├── type: @primitives$Float
    │       │   ├── target: pair #81 : app$Pair<@primitives$Float>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: @primitives$Float
    │           ├── target: pair #81 : app$Pair<@primitives$Float>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #15 with T = @primitives$Int
    │   ├── params[0]: pair #80 : app$Pair<@primitives$Int>
    │   └── body[0] > return > op:
    │       ├── type: @primitives$Int
    │       ├── op: +
    │       ├── impl: @primitives$+
    │       ├── left > field:
    │       │   ├── type: @primitives$Int
    │       │   ├── target: pair #80 : app$Pair<@primitives$Int>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: @primitives$Int
    │           ├── target: pair #80 : app$Pair<@primitives$Int>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #16 with T = @primitives$Int, n = 3
    │   ├── params[0]: values #82 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$Int
    │       ├── ctor: @primitives$Int
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #17 with n = 3
    │   ├── params[0]: values #83 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: @primitives$Int
    │       ├── ctor: @primitives$Int
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #18 with n = 3
    │   ├── params[0]: values #88 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$Int
    │       ├── callee: measured #17 with n = 3
    │       ├── args[0]: values #88 : @primitives$Array<@primitives$Int, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #19 with count = 3
    │   ├── params[0]: values #87 : @primitives$Array<@primitives$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: @primitives$Int
    │       ├── callee: relayed #18 with n = 3
    │       ├── args[0]: values #87 : @primitives$Array<@primitives$Int, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    └── instances[10] > instance:
        ├── of: sizedLike #20 with n = 3
        ├── params[0]: values #84 : @primitives$Array<@primitives$Int, 3>
        ├── body[0] > let:
        │   ├── local: measure #86 : @primitives$Int[@primitives$Array<@primitives$Int, 3>]
        │   └── value > lambda:
        │       ├── type: @primitives$Int[@primitives$Array<@primitives$Int, 3>]
        │       ├── params[0]: held #85 : @primitives$Array<@primitives$Int, 3>
        │       └── body[0] > return > construct:
        │           ├── type: @primitives$Int
        │           ├── ctor: @primitives$Int
        │           └── args[0]: n = 3 : @concepts$Int
        └── body[1] > return > call_value:
            ├── type: @primitives$Int
            ├── callee: measure #86 : @primitives$Int[@primitives$Array<@primitives$Int, 3>]
            └── args[0]: values #84 : @primitives$Array<@primitives$Int, 3>
