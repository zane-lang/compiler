└── program:
    ├── packages[0] > package:
    │   ├── name: app
    │   ├── decls[0] > verb:
    │   │   ├── signature: T pick(T, T, core$Bool) #1
    │   │   └── body: checked per instance
    │   ├── decls[1] > type:
    │   │   ├── name: Pair #2
    │   │   ├── params: T Type
    │   │   ├── kind: value
    │   │   ├── struct[0]: left : T
    │   │   └── struct[1]: right : T
    │   ├── decls[2] > verb:
    │   │   ├── signature: Pair(T, T) #3
    │   │   └── body: checked per instance
    │   ├── decls[3] > verb:
    │   │   ├── signature: T sum(app$Pair<T>) #4
    │   │   └── body: checked per instance
    │   ├── decls[4] > verb:
    │   │   ├── signature: core$Int count(core$Array<T, n>) #5
    │   │   └── body: checked per instance
    │   ├── decls[5] > verb:
    │   │   ├── signature: core$Int measured(core$Array<core$Int, n>, n @concepts$Int) #6
    │   │   └── body: checked per instance
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Int relayed(core$Array<core$Int, 3>, n @concepts$Int) #7
    │   │   └── body: checked per instance
    │   ├── decls[7] > verb:
    │   │   ├── signature: core$Int forwarded(core$Array<core$Int, 3>, count @concepts$Int) #8
    │   │   └── body: checked per instance
    │   ├── decls[8] > verb:
    │   │   ├── signature: core$Int sizedLike(core$Array<core$Int, 3>, n @concepts$Int) #9
    │   │   └── body: checked per instance
    │   ├── decls[9] > verb:
    │   │   ├── signature: app$Pair<core$Int> pairOf(@concepts$Int, @concepts$Int) #10
    │   │   ├── params[0]: x #1 : @concepts$Int
    │   │   ├── params[1]: y #2 : @concepts$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<core$Int>
    │   │       ├── ctor: Pair #3 with T = core$Int
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: core$Int
    │   │       │   ├── ctor: Int #55
    │   │       │   └── args[0]: x #1 : @concepts$Int
    │   │       └── args[1] > construct:
    │   │           ├── type: core$Int
    │   │           ├── ctor: Int #55
    │   │           └── args[0]: y #2 : @concepts$Int
    │   ├── decls[10] > verb:
    │   │   ├── signature: app$Pair<core$Float> pairOf(@concepts$Float, @concepts$Float) #11
    │   │   ├── params[0]: x #3 : @concepts$Float
    │   │   ├── params[1]: y #4 : @concepts$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<core$Float>
    │   │       ├── ctor: Pair #3 with T = core$Float
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: core$Float
    │   │       │   ├── ctor: Float #65
    │   │       │   └── args[0]: x #3 : @concepts$Float
    │   │       └── args[1] > construct:
    │   │           ├── type: core$Float
    │   │           ├── ctor: Float #65
    │   │           └── args[0]: y #4 : @concepts$Float
    │   ├── decls[11] > verb:
    │   │   ├── signature: core$Float?core$String safeDivide(core$Float, core$Float) #12
    │   │   ├── params[0]: numerator #5 : core$Float
    │   │   ├── params[1]: denominator #6 : core$Float
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: core$Bool
    │   │   │   ├── callee: if #49
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: core$Bool
    │   │   │   │   ├── op: ==
    │   │   │   │   ├── impl: == #71
    │   │   │   │   ├── left: denominator #6 : core$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: core$Float
    │   │   │   │       ├── ctor: Float #65
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── args[0]: "zero" : @concepts$String
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: core$Bool
    │   │   │   ├── callee: if #49
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: core$Bool
    │   │   │   │   ├── op: <
    │   │   │   │   ├── impl: < #72
    │   │   │   │   ├── left: denominator #6 : core$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: core$Float
    │   │   │   │       ├── ctor: Float #65
    │   │   │   │       └── args[0]: 0.0 : @concepts$Float
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── args[0]: "negative" : @concepts$String
    │   │   └── body[2] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #69
    │   │       ├── left: numerator #5 : core$Float
    │   │       └── right: denominator #6 : core$Float
    │   ├── decls[12] > verb:
    │   │   ├── signature: core$String describe(shapes$Corner) #13
    │   │   ├── params[0]: corner #7 : shapes$Corner
    │   │   └── body[0] > return > match:
    │   │       ├── type: core$String
    │   │       ├── scrutinees[0]: corner #7 : shapes$Corner
    │   │       ├── arms[0] > arm:
    │   │       │   ├── patterns[0]: topLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #74
    │   │       │       └── args[0]: "top" : @concepts$String
    │   │       ├── arms[1] > arm:
    │   │       │   ├── patterns[0]: topRight
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #74
    │   │       │       └── args[0]: "top" : @concepts$String
    │   │       ├── arms[2] > arm:
    │   │       │   ├── patterns[0]: bottomLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #74
    │   │       │       └── args[0]: "bottom" : @concepts$String
    │   │       └── arms[3] > arm:
    │   │           ├── patterns[0]: bottomRight
    │   │           └── body[0] > return > construct:
    │   │               ├── type: core$String
    │   │               ├── ctor: String #74
    │   │               └── args[0]: "bottom" : @concepts$String
    │   ├── decls[13] > verb:
    │   │   ├── signature: core$Unit main() #14
    │   │   ├── params:
    │   │   ├── body[0] > let:
    │   │   │   ├── local: console #8 : core$Console
    │   │   │   └── value > construct:
    │   │   │       ├── type: core$Console
    │   │   │       ├── ctor: Console #38
    │   │   │       └── args[0]: @program$console : @runtime$Console
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: print #39
    │   │   │   ├── args[0]: console #8 : core$Console
    │   │   │   └── args[1] > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── value: "hello" : @concepts$String
    │   │   ├── body[2] > let:
    │   │   │   ├── local: origin #9 : shapes$Vec2
    │   │   │   └── value > construct:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2.zero #18
    │   │   │       └── args:
    │   │   ├── body[3] > let:
    │   │   │   ├── local: moved #10 : shapes$Vec2
    │   │   │   └── value > op:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #20
    │   │   │       ├── left: origin #9 : shapes$Vec2
    │   │   │       └── right > coerce:
    │   │   │           ├── type: shapes$Vec2
    │   │   │           ├── ctor: Vec2 #24
    │   │   │           └── value: 3.0 : @concepts$Float
    │   │   ├── body[4] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: scale #23
    │   │   │   ├── args[0]: moved #10 : shapes$Vec2
    │   │   │   └── args[1] > construct:
    │   │   │       ├── type: core$Float
    │   │   │       ├── ctor: Float #65
    │   │   │       └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[5] > let:
    │   │   │   ├── local: flat #11 : shapes$Vec2
    │   │   │   └── value > construct_fields:
    │   │   │       ├── type: shapes$Vec2
    │   │   │       ├── ctor: Vec2 #19
    │   │   │       └── fields[0] > field:
    │   │   │           ├── name: x (slot 0)
    │   │   │           └── value > construct:
    │   │   │               ├── type: core$Float
    │   │   │               ├── ctor: Float #65
    │   │   │               └── args[0]: 1.0 : @concepts$Float
    │   │   ├── body[6] > let:
    │   │   │   ├── local: size #12 : core$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: length #22
    │   │   │       └── args[0]: moved #10 : shapes$Vec2
    │   │   ├── body[7] > let:
    │   │   │   ├── local: shape #13 : shapes$Shape
    │   │   │   └── value > case:
    │   │   │       ├── type: shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── payload > construct:
    │   │   │           ├── type: core$Float
    │   │   │           ├── ctor: Float #65
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[8] > let:
    │   │   │   ├── local: covered #14 : core$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: area #29
    │   │   │       └── args[0]: shape #13 : shapes$Shape
    │   │   ├── body[9] > let:
    │   │   │   ├── local: radius #15 : core$Float
    │   │   │   └── value > case_read:
    │   │   │       ├── type: core$Float
    │   │   │       ├── target: shape #13 : shapes$Shape
    │   │   │       ├── case: circle
    │   │   │       └── handler:
    │   │   │           ├── binder: none
    │   │   │           └── body[0] > resolve > construct:
    │   │   │               ├── type: core$Float
    │   │   │               ├── ctor: Float #65
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[10] > let:
    │   │   │   ├── local: half #17 : core$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: safeDivide #12
    │   │   │       ├── args[0]: covered #14 : core$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── ctor: Float #65
    │   │   │       │   └── args[0]: 2.0 : @concepts$Float
    │   │   │       └── handler:
    │   │   │           ├── binder: reason #16 : core$String
    │   │   │           ├── body[0] > do > call:
    │   │   │           │   ├── type: core$Unit
    │   │   │           │   ├── callee: print #39
    │   │   │           │   ├── args[0]: console #8 : core$Console
    │   │   │           │   └── args[1]: reason #16 : core$String
    │   │   │           └── body[1] > resolve > construct:
    │   │   │               ├── type: core$Float
    │   │   │               ├── ctor: Float #65
    │   │   │               └── args[0]: 0.0 : @concepts$Float
    │   │   ├── body[11] > let:
    │   │   │   ├── local: picked #18 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: pick #1 with T = core$Int
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: core$Int
    │   │   │       │   ├── ctor: Int #55
    │   │   │       │   └── args[0]: 1 : @concepts$Int
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: core$Int
    │   │   │       │   ├── ctor: Int #55
    │   │   │       │   └── args[0]: 2 : @concepts$Int
    │   │   │       └── args[2] > coerce:
    │   │   │           ├── type: core$Bool
    │   │   │           ├── ctor: Bool #31
    │   │   │           └── value: true : @primitives$Bool
    │   │   ├── body[12] > let:
    │   │   │   ├── local: chance #19 : core$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: pick #1 with T = core$Float
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── ctor: Float #65
    │   │   │       │   └── args[0]: 0.5 : @concepts$Float
    │   │   │       ├── args[1] > construct:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── ctor: Float #65
    │   │   │       │   └── args[0]: 1.5 : @concepts$Float
    │   │   │       └── args[2] > coerce:
    │   │   │           ├── type: core$Bool
    │   │   │           ├── ctor: Bool #31
    │   │   │           └── value: false : @primitives$Bool
    │   │   ├── body[13] > let:
    │   │   │   ├── local: pair #20 : app$Pair<core$Int>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<core$Int>
    │   │   │       ├── ctor: Pair #3 with T = core$Int
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: core$Int
    │   │   │       │   ├── ctor: Int #55
    │   │   │       │   └── args[0]: 3 : @concepts$Int
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: core$Int
    │   │   │           ├── ctor: Int #55
    │   │   │           └── args[0]: 4 : @concepts$Int
    │   │   ├── body[14] > let:
    │   │   │   ├── local: total #21 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: sum #4 with T = core$Int
    │   │   │       └── args[0]: pair #20 : app$Pair<core$Int>
    │   │   ├── body[15] > let:
    │   │   │   ├── local: floats #22 : app$Pair<core$Float>
    │   │   │   └── value > construct:
    │   │   │       ├── type: app$Pair<core$Float>
    │   │   │       ├── ctor: Pair #3 with T = core$Float
    │   │   │       ├── args[0] > construct:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── ctor: Float #65
    │   │   │       │   └── args[0]: 1.0 : @concepts$Float
    │   │   │       └── args[1] > construct:
    │   │   │           ├── type: core$Float
    │   │   │           ├── ctor: Float #65
    │   │   │           └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[16] > let:
    │   │   │   ├── local: both #23 : core$Float
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: sum #4 with T = core$Float
    │   │   │       └── args[0]: floats #22 : app$Pair<core$Float>
    │   │   ├── body[17] > let:
    │   │   │   ├── local: numbers #24 : core$Array<core$Int, 3>
    │   │   │   └── value > construct:
    │   │   │       ├── type: core$Array<core$Int, 3>
    │   │   │       ├── ctor: Array #41 with T = core$Int, n = 3
    │   │   │       └── args[0] > array:
    │   │   │           ├── type: @concepts$Array<core$Int, 3>
    │   │   │           ├── items[0] > construct:
    │   │   │           │   ├── type: core$Int
    │   │   │           │   ├── ctor: Int #55
    │   │   │           │   └── args[0]: 1 : @concepts$Int
    │   │   │           ├── items[1] > construct:
    │   │   │           │   ├── type: core$Int
    │   │   │           │   ├── ctor: Int #55
    │   │   │           │   └── args[0]: 2 : @concepts$Int
    │   │   │           └── items[2] > construct:
    │   │   │               ├── type: core$Int
    │   │   │               ├── ctor: Int #55
    │   │   │               └── args[0]: 3 : @concepts$Int
    │   │   ├── body[18] > let:
    │   │   │   ├── local: first #27 : core$Int
    │   │   │   └── value > subscript:
    │   │   │       ├── type: core$Int
    │   │   │       ├── impl: [] #42 with T = core$Int, n = 3
    │   │   │       ├── target: numbers #24 : core$Array<core$Int, 3>
    │   │   │       └── args[0] > coerce:
    │   │   │           ├── type: core$Int
    │   │   │           ├── ctor: Int #55
    │   │   │           └── value: 1 : @concepts$Int
    │   │   ├── body[19] > let:
    │   │   │   ├── local: length #28 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: count #5 with T = core$Int, n = 3
    │   │   │       └── args[0]: numbers #24 : core$Array<core$Int, 3>
    │   │   ├── body[20] > let:
    │   │   │   ├── local: sized #29 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: measured #6 with n = 3
    │   │   │       ├── args[0]: numbers #24 : core$Array<core$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[21] > let:
    │   │   │   ├── local: like #30 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: sizedLike #9 with n = 3
    │   │   │       ├── args[0]: numbers #24 : core$Array<core$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[22] > let:
    │   │   │   ├── local: passed #31 : core$Int
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Int
    │   │   │       ├── callee: forwarded #8 with count = 3
    │   │   │       ├── args[0]: numbers #24 : core$Array<core$Int, 3>
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[23] > let:
    │   │   │   ├── local: ints #32 : app$Pair<core$Int>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<core$Int>
    │   │   │       ├── callee: pairOf #10
    │   │   │       ├── args[0]: 2 : @concepts$Int
    │   │   │       └── args[1]: 3 : @concepts$Int
    │   │   ├── body[24] > let:
    │   │   │   ├── local: decimals #33 : app$Pair<core$Float>
    │   │   │   └── value > call:
    │   │   │       ├── type: app$Pair<core$Float>
    │   │   │       ├── callee: pairOf #11
    │   │   │       ├── args[0]: 2.5 : @concepts$Float
    │   │   │       └── args[1]: 3.5 : @concepts$Float
    │   │   ├── body[25] > let:
    │   │   │   ├── local: label #34 : core$String
    │   │   │   └── value > map_read:
    │   │   │       ├── type: core$String
    │   │   │       ├── target: .topLeft : shapes$Corner
    │   │   │       └── map: label #27
    │   │   ├── body[26] > let:
    │   │   │   ├── local: side #35 : core$String
    │   │   │   └── value > call:
    │   │   │       ├── type: core$String
    │   │   │       ├── callee: describe #13
    │   │   │       └── args[0]: .bottomRight : shapes$Corner
    │   │   ├── body[27] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: print #39
    │   │   │   ├── args[0]: console #8 : core$Console
    │   │   │   └── args[1]: side #35 : core$String
    │   │   ├── body[28] > let:
    │   │   │   ├── local: i #36 : core$Int
    │   │   │   └── value > construct:
    │   │   │       ├── type: core$Int
    │   │   │       ├── ctor: Int #55
    │   │   │       └── args[0]: 1 : @concepts$Int
    │   │   ├── body[29] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: to #53
    │   │   │   ├── args[0]: i #36 : core$Int
    │   │   │   ├── args[1] > coerce:
    │   │   │   │   ├── type: core$Int
    │   │   │   │   ├── ctor: Int #55
    │   │   │   │   └── value: 3 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: core$Unit
    │   │   │       ├── callee: print #39
    │   │   │       ├── args[0]: console #8 : core$Console
    │   │   │       └── args[1] > call:
    │   │   │           ├── type: core$String
    │   │   │           ├── callee: describe #13
    │   │   │           └── args[0]: .topLeft : shapes$Corner
    │   │   ├── body[30] > let:
    │   │   │   ├── local: double #38 : core$Float[core$Float]
    │   │   │   └── value > lambda:
    │   │   │       ├── type: core$Float[core$Float]
    │   │   │       ├── params[0]: value #37 : core$Float
    │   │   │       └── body[0] > return > op:
    │   │   │           ├── type: core$Float
    │   │   │           ├── op: *
    │   │   │           ├── impl: * #68
    │   │   │           ├── left: value #37 : core$Float
    │   │   │           └── right > construct:
    │   │   │               ├── type: core$Float
    │   │   │               ├── ctor: Float #65
    │   │   │               └── args[0]: 2.0 : @concepts$Float
    │   │   ├── body[31] > let:
    │   │   │   ├── local: doubled #39 : core$Float
    │   │   │   └── value > call_value:
    │   │   │       ├── type: core$Float
    │   │   │       ├── callee: double #38 : core$Float[core$Float]
    │   │   │       └── args[0]: half #17 : core$Float
    │   │   ├── body[32] > let:
    │   │   │   ├── local: chain #40 : core$Bool
    │   │   │   └── value > call:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── callee: if #49
    │   │   │       ├── args[0] > op:
    │   │   │       │   ├── type: core$Bool
    │   │   │       │   ├── op: <
    │   │   │       │   ├── impl: < #63
    │   │   │       │   ├── left: total #21 : core$Int
    │   │   │       │   └── right > construct:
    │   │   │       │       ├── type: core$Int
    │   │   │       │       ├── ctor: Int #55
    │   │   │       │       └── args[0]: 5 : @concepts$Int
    │   │   │       └── args[1] > block[0] > do > call:
    │   │   │           ├── type: core$Unit
    │   │   │           ├── callee: print #39
    │   │   │           ├── args[0]: console #8 : core$Console
    │   │   │           └── args[1] > coerce:
    │   │   │               ├── type: core$String
    │   │   │               ├── ctor: String #74
    │   │   │               └── value: "small" : @concepts$String
    │   │   ├── body[33] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: elif #50
    │   │   │   ├── args[0]: chain #40 : core$Bool
    │   │   │   ├── args[1] > op:
    │   │   │   │   ├── type: core$Bool
    │   │   │   │   ├── op: ==
    │   │   │   │   ├── impl: == #62
    │   │   │   │   ├── left: total #21 : core$Int
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: core$Int
    │   │   │   │       ├── ctor: Int #55
    │   │   │   │       └── args[0]: 7 : @concepts$Int
    │   │   │   └── args[2] > block[0] > do > call:
    │   │   │       ├── type: core$Unit
    │   │   │       ├── callee: print #39
    │   │   │       ├── args[0]: console #8 : core$Console
    │   │   │       └── args[1] > coerce:
    │   │   │           ├── type: core$String
    │   │   │           ├── ctor: String #74
    │   │   │           └── value: "seven" : @concepts$String
    │   │   ├── body[34] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: else #51
    │   │   │   ├── args[0]: chain #40 : core$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: core$Unit
    │   │   │       ├── callee: print #39
    │   │   │       ├── args[0]: console #8 : core$Console
    │   │   │       └── args[1] > coerce:
    │   │   │           ├── type: core$String
    │   │   │           ├── ctor: String #74
    │   │   │           └── value: "large" : @concepts$String
    │   │   └── body[35] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   └── decls[14] > verb:
    │       ├── signature: T twice(T) #15
    │       └── body: checked per instance
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > type:
    │   │   ├── name: Vec2 #16
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : core$Float
    │   │   └── struct[1]: y : core$Float
    │   ├── decls[1] > verb:
    │   │   ├── signature: Vec2(core$Float, core$Float) #17
    │   │   ├── params[0]: x #41 : core$Float
    │   │   ├── params[1]: y #42 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #41 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #42 : core$Float
    │   ├── decls[2] > verb:
    │   │   ├── signature: Vec2.zero() #18
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #65
    │   │       │       └── args[0]: 0.0 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #65
    │   │               └── args[0]: 0.0 : @concepts$Float
    │   ├── decls[3] > verb:
    │   │   ├── signature: Vec2{x core$Float; y core$Float = ...} #19
    │   │   ├── params[0]: x #45 : core$Float
    │   │   ├── params[1]: y #46 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #45 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #46 : core$Float
    │   ├── decls[4] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #20
    │   │   ├── params[0]: left #47 : shapes$Vec2
    │   │   ├── params[1]: right #48 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #17
    │   │       ├── args[0] > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: +
    │   │       │   ├── impl: + #67
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: left #47 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: right #48 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > op:
    │   │           ├── type: core$Float
    │   │           ├── op: +
    │   │           ├── impl: + #67
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: left #47 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: right #48 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[5] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #21
    │   │   ├── params[0]: value #49 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #17
    │   │       ├── args[0] > flip:
    │   │       │   ├── type: core$Float
    │   │       │   ├── impl: ~ #70
    │   │       │   └── value > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: value #49 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > flip:
    │   │           ├── type: core$Float
    │   │           ├── impl: ~ #70
    │   │           └── value > field:
    │   │               ├── type: core$Float
    │   │               ├── target: value #49 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Float length(this shapes$Vec2) #22
    │   │   ├── params[0]: this #50 : shapes$Vec2
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: +
    │   │       ├── impl: + #67
    │   │       ├── left > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: *
    │   │       │   ├── impl: * #68
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: this #50 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: this #50 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── right > op:
    │   │           ├── type: core$Float
    │   │           ├── op: *
    │   │           ├── impl: * #68
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: this #50 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: this #50 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[7] > verb:
    │   │   ├── signature: core$Unit scale(this shapes$Vec2, core$Float) mut #23
    │   │   ├── params[0]: this #51 : shapes$Vec2
    │   │   ├── params[1]: by #52 : core$Float
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #51 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #68
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #51 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── right: by #52 : core$Float
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #51 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #68
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #51 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── right: by #52 : core$Float
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[8] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Float) #24
    │   │   ├── params[0]: value #53 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #65
    │   │       │       └── args[0]: value #53 : @concepts$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #65
    │   │               └── args[0]: value #53 : @concepts$Float
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
    │   │   ├── type: core$String
    │   │   ├── entries[0]:
    │   │   │   ├── member: topLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── value: "top left" : @concepts$String
    │   │   ├── entries[1]:
    │   │   │   ├── member: topRight
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── value: "top right" : @concepts$String
    │   │   ├── entries[2]:
    │   │   │   ├── member: bottomLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #74
    │   │   │       └── value: "bottom left" : @concepts$String
    │   │   └── entries[3]:
    │   │       ├── member: bottomRight
    │   │       └── value > coerce:
    │   │           ├── type: core$String
    │   │           ├── ctor: String #74
    │   │           └── value: "bottom right" : @concepts$String
    │   ├── decls[12] > verb:
    │   │   ├── signature: core$Float _half(core$Float) #28
    │   │   ├── params[0]: value #54 : core$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #69
    │   │       ├── left: value #54 : core$Float
    │   │       └── right > construct:
    │   │           ├── type: core$Float
    │   │           ├── ctor: Float #65
    │   │           └── args[0]: 2.0 : @concepts$Float
    │   └── decls[13] > verb:
    │       ├── signature: core$Float area(&shapes$Shape) #29
    │       ├── params[0]: shape #55 : &shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: core$Float
    │           ├── scrutinees[0]: shape #55 : &shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #56 : core$Float <- circle
    │           │   └── body[0] > return > op:
    │           │       ├── type: core$Float
    │           │       ├── op: *
    │           │       ├── impl: * #68
    │           │       ├── left: r #56 : core$Float
    │           │       └── right: r #56 : core$Float
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #57 : core$Float <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: core$Float
    │           │       ├── callee: _half #28
    │           │       └── args[0] > op:
    │           │           ├── type: core$Float
    │           │           ├── op: +
    │           │           ├── impl: + #67
    │           │           ├── left: s #57 : core$Float
    │           │           └── right: s #57 : core$Float
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: core$Float
    │                   ├── ctor: Float #65
    │                   └── args[0]: 0.0 : @concepts$Float
    ├── packages[2] > package:
    │   ├── name: core
    │   ├── decls[0] > type:
    │   │   ├── name: Bool #30
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Bool
    │   ├── decls[1] > verb:
    │   │   ├── signature: implicit Bool(@primitives$Bool) #31
    │   │   ├── params[0]: raw #58 : @primitives$Bool
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Bool
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #58 : @primitives$Bool
    │   ├── decls[2] > verb:
    │   │   ├── signature: implicit @primitives$Bool(core$Bool) #32
    │   │   ├── params[0]: value #59 : core$Bool
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Bool
    │   │       ├── target: value #59 : core$Bool
    │   │       └── field: raw (slot 0)
    │   ├── decls[3] > verb:
    │   │   ├── signature: core$Bool *(core$Bool, core$Bool) #33
    │   │   ├── params[0]: left #60 : core$Bool
    │   │   ├── params[1]: right #61 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #60 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #61 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[4] > verb:
    │   │   ├── signature: core$Bool +(core$Bool, core$Bool) #34
    │   │   ├── params[0]: left #62 : core$Bool
    │   │   ├── params[1]: right #63 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #62 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #63 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[5] > verb:
    │   │   ├── signature: core$Bool ==(core$Bool, core$Bool) #35
    │   │   ├── params[0]: left #64 : core$Bool
    │   │   ├── params[1]: right #65 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #64 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #65 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Bool ~(core$Bool) #36
    │   │   ├── params[0]: value #66 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Bool
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: value #66 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[7] > type:
    │   │   ├── name: Console #37
    │   │   ├── kind: reference
    │   │   └── struct[0]: _console : &@runtime$Console
    │   ├── decls[8] > verb:
    │   │   ├── signature: Console(&@runtime$Console) #38
    │   │   ├── params[0]: console #67 : &@runtime$Console
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Console
    │   │       └── fields[0] > field:
    │   │           ├── name: _console (slot 0)
    │   │           └── value: console #67 : &@runtime$Console
    │   ├── decls[9] > verb:
    │   │   ├── signature: core$Unit print(this core$Console, core$String) mut #39
    │   │   ├── params[0]: this #68 : core$Console
    │   │   ├── params[1]: text #69 : core$String
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @runtime$print
    │   │   │   ├── args[0] > field:
    │   │   │   │   ├── type: &@runtime$Console
    │   │   │   │   ├── target: this #68 : core$Console
    │   │   │   │   └── field: _console (slot 0)
    │   │   │   └── args[1] > field:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: text #69 : core$String
    │   │   │       └── field: raw (slot 0)
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[10] > type:
    │   │   ├── name: Array #40
    │   │   ├── params: T Type, n @concepts$Int
    │   │   ├── kind: value
    │   │   └── struct[0]: _items : @primitives$Array<T, n>
    │   ├── decls[11] > verb:
    │   │   ├── signature: Array(@concepts$Array<T, n>) #41
    │   │   └── body: checked per instance
    │   ├── decls[12] > subscript:
    │   │   ├── signature: (this core$Array<T, n>)[core$Int] #42
    │   │   └── body: checked per instance
    │   ├── decls[13] > verb:
    │   │   ├── signature: core$Int size(this core$Array<T, n>) #43
    │   │   └── body: checked per instance
    │   ├── decls[14] > type:
    │   │   ├── name: List #44
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: _items : @primitives$List<T>
    │   ├── decls[15] > verb:
    │   │   ├── signature: List(T Type) #45
    │   │   └── body: checked per instance
    │   ├── decls[16] > verb:
    │   │   ├── signature: core$Unit push(this core$List<T>, T) mut #46
    │   │   └── body: checked per instance
    │   ├── decls[17] > verb:
    │   │   ├── signature: core$Int size(this core$List<T>) #47
    │   │   └── body: checked per instance
    │   ├── decls[18] > subscript:
    │   │   ├── signature: (this core$List<T>)[core$Int] #48
    │   │   └── body: checked per instance
    │   ├── decls[19] > verb:
    │   │   ├── signature: core$Bool if(core$Bool, @concepts$Block) #49
    │   │   ├── params[0]: condition #70 : core$Bool
    │   │   ├── params[1]: body #71 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #32
    │   │   │   │   └── value: condition #70 : core$Bool
    │   │   │   └── args[1]: body #71 : @concepts$Block
    │   │   └── body[1] > return: condition #70 : core$Bool
    │   ├── decls[20] > verb:
    │   │   ├── signature: core$Unit elif(this core$Bool, core$Bool, @concepts$Block) mut #50
    │   │   ├── params[0]: this #72 : core$Bool
    │   │   ├── params[1]: condition #73 : core$Bool
    │   │   ├── params[2]: body #74 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #32
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── op: *
    │   │   │   │       ├── impl: * #33
    │   │   │   │       ├── left > flip:
    │   │   │   │       │   ├── type: core$Bool
    │   │   │   │       │   ├── impl: ~ #36
    │   │   │   │       │   └── value: this #72 : core$Bool
    │   │   │   │       └── right: condition #73 : core$Bool
    │   │   │   └── args[1]: body #74 : @concepts$Block
    │   │   ├── body[1] > assign:
    │   │   │   ├── target: this #72 : core$Bool
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #34
    │   │   │       ├── left: this #72 : core$Bool
    │   │   │       └── right: condition #73 : core$Bool
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[21] > verb:
    │   │   ├── signature: core$Unit else(this core$Bool, @concepts$Block) #51
    │   │   ├── params[0]: this #75 : core$Bool
    │   │   ├── params[1]: body #76 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #32
    │   │   │   │   └── value > flip:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── impl: ~ #36
    │   │   │   │       └── value: this #75 : core$Bool
    │   │   │   └── args[1]: body #76 : @concepts$Block
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[22] > verb:
    │   │   ├── signature: core$Unit guard(core$Bool) #52
    │   │   ├── params[0]: condition #77 : core$Bool
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #32
    │   │   │   │   └── value: condition #77 : core$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: @controlflow$exitFromCall
    │   │   │       └── args:
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[23] > verb:
    │   │   ├── signature: core$Unit to(this core$Int, core$Int, @concepts$Block) mut #53
    │   │   ├── params[0]: this #78 : core$Int
    │   │   ├── params[1]: end #79 : core$Int
    │   │   ├── params[2]: body #80 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$repeat
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── ctor: @primitives$Int #57
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Int
    │   │   │   │       ├── op: +
    │   │   │   │       ├── impl: + #58
    │   │   │   │       ├── left > op:
    │   │   │   │       │   ├── type: core$Int
    │   │   │   │       │   ├── op: +
    │   │   │   │       │   ├── impl: + #58
    │   │   │   │       │   ├── left: end #79 : core$Int
    │   │   │   │       │   └── right > flip:
    │   │   │   │       │       ├── type: core$Int
    │   │   │   │       │       ├── impl: ~ #61
    │   │   │   │       │       └── value: this #78 : core$Int
    │   │   │   │       └── right > construct:
    │   │   │   │           ├── type: core$Int
    │   │   │   │           ├── ctor: Int #55
    │   │   │   │           └── args[0]: 1 : @concepts$Int
    │   │   │   ├── args[1] > block[0] > do > call:
    │   │   │   │   ├── type: @primitives$Unit
    │   │   │   │   ├── callee: @controlflow$branch
    │   │   │   │   ├── args[0]: true : @primitives$Bool
    │   │   │   │   └── args[1]: body #80 : @concepts$Block
    │   │   │   └── args[1] > block[1] > assign:
    │   │   │       ├── target: this #78 : core$Int
    │   │   │       └── value > op:
    │   │   │           ├── type: core$Int
    │   │   │           ├── op: +
    │   │   │           ├── impl: + #58
    │   │   │           ├── left: this #78 : core$Int
    │   │   │           └── right > construct:
    │   │   │               ├── type: core$Int
    │   │   │               ├── ctor: Int #55
    │   │   │               └── args[0]: 1 : @concepts$Int
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #79
    │   │       └── args:
    │   ├── decls[24] > type:
    │   │   ├── name: Int #54
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Int
    │   ├── decls[25] > verb:
    │   │   ├── signature: implicit Int(@concepts$Int) #55
    │   │   ├── params[0]: value #81 : @concepts$Int
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Int
    │   │               ├── ctor: @primitives$Int
    │   │               └── args[0]: value #81 : @concepts$Int
    │   ├── decls[26] > verb:
    │   │   ├── signature: implicit Int(@primitives$Int) #56
    │   │   ├── params[0]: raw #82 : @primitives$Int
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #82 : @primitives$Int
    │   ├── decls[27] > verb:
    │   │   ├── signature: implicit @primitives$Int(core$Int) #57
    │   │   ├── params[0]: value #83 : core$Int
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Int
    │   │       ├── target: value #83 : core$Int
    │   │       └── field: raw (slot 0)
    │   ├── decls[28] > verb:
    │   │   ├── signature: core$Int +(core$Int, core$Int) #58
    │   │   ├── params[0]: left #84 : core$Int
    │   │   ├── params[1]: right #85 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #56
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #84 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #85 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[29] > verb:
    │   │   ├── signature: core$Int *(core$Int, core$Int) #59
    │   │   ├── params[0]: left #86 : core$Int
    │   │   ├── params[1]: right #87 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #56
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #86 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #87 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[30] > verb:
    │   │   ├── signature: core$Int /(core$Int, core$Int) #60
    │   │   ├── params[0]: left #88 : core$Int
    │   │   ├── params[1]: right #89 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #56
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #88 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #89 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[31] > verb:
    │   │   ├── signature: core$Int ~(core$Int) #61
    │   │   ├── params[0]: value #90 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #56
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Int
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: value #90 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[32] > verb:
    │   │   ├── signature: core$Bool ==(core$Int, core$Int) #62
    │   │   ├── params[0]: left #91 : core$Int
    │   │   ├── params[1]: right #92 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #91 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #92 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[33] > verb:
    │   │   ├── signature: core$Bool <(core$Int, core$Int) #63
    │   │   ├── params[0]: left #93 : core$Int
    │   │   ├── params[1]: right #94 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #93 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #94 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[34] > type:
    │   │   ├── name: Float #64
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Float
    │   ├── decls[35] > verb:
    │   │   ├── signature: implicit Float(@concepts$Float) #65
    │   │   ├── params[0]: value #95 : @concepts$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: value #95 : @concepts$Float
    │   ├── decls[36] > verb:
    │   │   ├── signature: implicit Float(@primitives$Float) #66
    │   │   ├── params[0]: raw #96 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #96 : @primitives$Float
    │   ├── decls[37] > verb:
    │   │   ├── signature: core$Float +(core$Float, core$Float) #67
    │   │   ├── params[0]: left #97 : core$Float
    │   │   ├── params[1]: right #98 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #66
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #97 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #98 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[38] > verb:
    │   │   ├── signature: core$Float *(core$Float, core$Float) #68
    │   │   ├── params[0]: left #99 : core$Float
    │   │   ├── params[1]: right #100 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #66
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #99 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #100 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[39] > verb:
    │   │   ├── signature: core$Float /(core$Float, core$Float) #69
    │   │   ├── params[0]: left #101 : core$Float
    │   │   ├── params[1]: right #102 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #66
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #101 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #102 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[40] > verb:
    │   │   ├── signature: core$Float ~(core$Float) #70
    │   │   ├── params[0]: value #103 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #66
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Float
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: value #103 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[41] > verb:
    │   │   ├── signature: core$Bool ==(core$Float, core$Float) #71
    │   │   ├── params[0]: left #104 : core$Float
    │   │   ├── params[1]: right #105 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #104 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #105 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[42] > verb:
    │   │   ├── signature: core$Bool <(core$Float, core$Float) #72
    │   │   ├── params[0]: left #106 : core$Float
    │   │   ├── params[1]: right #107 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #106 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #107 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[43] > type:
    │   │   ├── name: String #73
    │   │   ├── kind: reference
    │   │   └── struct[0]: raw : @primitives$String
    │   ├── decls[44] > verb:
    │   │   ├── signature: implicit String(@concepts$String) #74
    │   │   ├── params[0]: value #108 : @concepts$String
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$String
    │   │               ├── ctor: @primitives$String
    │   │               └── args[0]: value #108 : @concepts$String
    │   ├── decls[45] > verb:
    │   │   ├── signature: String(@primitives$String) #75
    │   │   ├── params[0]: raw #109 : @primitives$String
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #109 : @primitives$String
    │   ├── decls[46] > verb:
    │   │   ├── signature: core$String +(core$String, core$String) #76
    │   │   ├── params[0]: left #110 : core$String
    │   │   ├── params[1]: right #111 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$String
    │   │       ├── ctor: String #75
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$String
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #110 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #111 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[47] > verb:
    │   │   ├── signature: core$Bool ==(core$String, core$String) #77
    │   │   ├── params[0]: left #112 : core$String
    │   │   ├── params[1]: right #113 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #31
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #112 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #113 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[48] > type:
    │   │   ├── name: Unit #78
    │   │   ├── kind: value
    │   │   └── struct:
    │   ├── decls[49] > verb:
    │   │   ├── signature: Unit() #79
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Unit
    │   │       └── fields:
    │   └── decls[50] > verb:
    │       ├── signature: implicit Unit(@primitives$Unit) #80
    │       ├── params[0]: value #114 : @primitives$Unit
    │       └── body[0] > return > init:
    │           ├── type: core$Unit
    │           └── fields:
    ├── instances[0] > instance:
    │   ├── of: pick #1 with T = core$Float
    │   ├── params[0]: first #124 : core$Float
    │   ├── params[1]: second #125 : core$Float
    │   ├── params[2]: takeFirst #126 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #127 : core$Float
    │   │   └── value: second #125 : core$Float
    │   ├── body[1] > let:
    │   │   ├── local: ran #128 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #49
    │   │       ├── args[0]: takeFirst #126 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #127 : core$Float
    │   │           └── value: first #124 : core$Float
    │   └── body[2] > return: chosen #127 : core$Float
    ├── instances[1] > instance:
    │   ├── of: pick #1 with T = core$Int
    │   ├── params[0]: first #119 : core$Int
    │   ├── params[1]: second #120 : core$Int
    │   ├── params[2]: takeFirst #121 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #122 : core$Int
    │   │   └── value: second #120 : core$Int
    │   ├── body[1] > let:
    │   │   ├── local: ran #123 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #49
    │   │       ├── args[0]: takeFirst #121 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #122 : core$Int
    │   │           └── value: first #119 : core$Int
    │   └── body[2] > return: chosen #122 : core$Int
    ├── instances[2] > instance:
    │   ├── of: Pair #3 with T = core$Float
    │   ├── params[0]: left #117 : core$Float
    │   ├── params[1]: right #118 : core$Float
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Float>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #117 : core$Float
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #118 : core$Float
    ├── instances[3] > instance:
    │   ├── of: Pair #3 with T = core$Int
    │   ├── params[0]: left #115 : core$Int
    │   ├── params[1]: right #116 : core$Int
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Int>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #115 : core$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #116 : core$Int
    ├── instances[4] > instance:
    │   ├── of: sum #4 with T = core$Float
    │   ├── params[0]: pair #130 : app$Pair<core$Float>
    │   └── body[0] > return > op:
    │       ├── type: core$Float
    │       ├── op: +
    │       ├── impl: + #67
    │       ├── left > field:
    │       │   ├── type: core$Float
    │       │   ├── target: pair #130 : app$Pair<core$Float>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Float
    │           ├── target: pair #130 : app$Pair<core$Float>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #4 with T = core$Int
    │   ├── params[0]: pair #129 : app$Pair<core$Int>
    │   └── body[0] > return > op:
    │       ├── type: core$Int
    │       ├── op: +
    │       ├── impl: + #58
    │       ├── left > field:
    │       │   ├── type: core$Int
    │       │   ├── target: pair #129 : app$Pair<core$Int>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Int
    │           ├── target: pair #129 : app$Pair<core$Int>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #5 with T = core$Int, n = 3
    │   ├── params[0]: values #132 : core$Array<core$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: core$Int
    │       ├── ctor: Int #55
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[7] > instance:
    │   ├── of: measured #6 with n = 3
    │   ├── params[0]: values #133 : core$Array<core$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: core$Int
    │       ├── ctor: Int #55
    │       └── args[0]: n = 3 : @concepts$Int
    ├── instances[8] > instance:
    │   ├── of: relayed #7 with n = 3
    │   ├── params[0]: values #138 : core$Array<core$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: core$Int
    │       ├── callee: measured #6 with n = 3
    │       ├── args[0]: values #138 : core$Array<core$Int, 3>
    │       └── args[1]: n = 3 : @concepts$Int
    ├── instances[9] > instance:
    │   ├── of: forwarded #8 with count = 3
    │   ├── params[0]: values #137 : core$Array<core$Int, 3>
    │   └── body[0] > return > call:
    │       ├── type: core$Int
    │       ├── callee: relayed #7 with n = 3
    │       ├── args[0]: values #137 : core$Array<core$Int, 3>
    │       └── args[1]: count = 3 : @concepts$Int
    ├── instances[10] > instance:
    │   ├── of: sizedLike #9 with n = 3
    │   ├── params[0]: values #134 : core$Array<core$Int, 3>
    │   ├── body[0] > let:
    │   │   ├── local: measure #136 : core$Int[core$Array<core$Int, 3>]
    │   │   └── value > lambda:
    │   │       ├── type: core$Int[core$Array<core$Int, 3>]
    │   │       ├── params[0]: held #135 : core$Array<core$Int, 3>
    │   │       └── body[0] > return > construct:
    │   │           ├── type: core$Int
    │   │           ├── ctor: Int #55
    │   │           └── args[0]: n = 3 : @concepts$Int
    │   └── body[1] > return > call_value:
    │       ├── type: core$Int
    │       ├── callee: measure #136 : core$Int[core$Array<core$Int, 3>]
    │       └── args[0]: values #134 : core$Array<core$Int, 3>
    ├── instances[11] > instance:
    │   ├── of: Array #41 with T = core$Int, n = 3
    │   ├── params[0]: values #131 : @concepts$Array<core$Int, 3>
    │   └── body[0] > return > init:
    │       ├── type: core$Array<core$Int, 3>
    │       └── fields[0] > field:
    │           ├── name: _items (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$Array<core$Int, 3>
    │               ├── ctor: @primitives$Array with T = core$Int, n = 3
    │               └── args[0]: values #131 : @concepts$Array<core$Int, 3>
    └── instances[12] > instance:
        ├── of: [] #42 with T = core$Int, n = 3
        ├── params[0]: this #25 : core$Array<core$Int, 3>
        ├── params[1]: index #26 : core$Int
        └── body[0] > return > subscript:
            ├── type: core$Int
            ├── impl: @primitives$[] with T = core$Int, n = 3
            ├── target > field:
            │   ├── type: @primitives$Array<core$Int, 3>
            │   ├── target: this #25 : core$Array<core$Int, 3>
            │   └── field: _items (slot 0)
            └── args[0] > coerce:
                ├── type: @primitives$Int
                ├── ctor: @primitives$Int #57
                └── value: index #26 : core$Int
