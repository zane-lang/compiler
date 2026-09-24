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
    │   │   ├── signature: core$Int measured(core$Array<core$Int, n>, n @concepts$Integer) #6
    │   │   └── body: checked per instance
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Int sizedLike(core$Array<core$Int, 3>, n @concepts$Integer) #7
    │   │   └── body: checked per instance
    │   ├── decls[7] > verb:
    │   │   ├── signature: app$Pair<core$Int> pairOf(@concepts$Integer, @concepts$Integer) #8
    │   │   ├── params[0]: x #1 : @concepts$Integer
    │   │   ├── params[1]: y #2 : @concepts$Integer
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<core$Int>
    │   │       ├── ctor: Pair #3 with T = core$Int
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: core$Int
    │   │       │   ├── ctor: Int #52
    │   │       │   └── args[0]: x #1 : @concepts$Integer
    │   │       └── args[1] > construct:
    │   │           ├── type: core$Int
    │   │           ├── ctor: Int #52
    │   │           └── args[0]: y #2 : @concepts$Integer
    │   ├── decls[8] > verb:
    │   │   ├── signature: app$Pair<core$Float> pairOf(@concepts$Decimal, @concepts$Decimal) #9
    │   │   ├── params[0]: x #3 : @concepts$Decimal
    │   │   ├── params[1]: y #4 : @concepts$Decimal
    │   │   └── body[0] > return > construct:
    │   │       ├── type: app$Pair<core$Float>
    │   │       ├── ctor: Pair #3 with T = core$Float
    │   │       ├── args[0] > construct:
    │   │       │   ├── type: core$Float
    │   │       │   ├── ctor: Float #62
    │   │       │   └── args[0]: x #3 : @concepts$Decimal
    │   │       └── args[1] > construct:
    │   │           ├── type: core$Float
    │   │           ├── ctor: Float #62
    │   │           └── args[0]: y #4 : @concepts$Decimal
    │   ├── decls[9] > verb:
    │   │   ├── signature: core$Float?core$String safeDivide(core$Float, core$Float) #10
    │   │   ├── params[0]: numerator #5 : core$Float
    │   │   ├── params[1]: denominator #6 : core$Float
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: guard #49
    │   │   │   └── args[0] > op:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── op: ==
    │   │   │       ├── impl: == #68
    │   │   │       ├── left: denominator #6 : core$Float
    │   │   │       └── right > construct:
    │   │   │           ├── type: core$Float
    │   │   │           ├── ctor: Float #62
    │   │   │           └── args[0]: 0.0 : @concepts$Decimal
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: core$Bool
    │   │   │   ├── callee: if #46
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: core$Bool
    │   │   │   │   ├── op: <
    │   │   │   │   ├── impl: < #69
    │   │   │   │   ├── left: denominator #6 : core$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: core$Float
    │   │   │   │       ├── ctor: Float #62
    │   │   │   │       └── args[0]: 0.0 : @concepts$Decimal
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #71
    │   │   │       └── args[0]: "negative" : @concepts$Text
    │   │   └── body[2] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #66
    │   │       ├── left: numerator #5 : core$Float
    │   │       └── right: denominator #6 : core$Float
    │   ├── decls[10] > verb:
    │   │   ├── signature: core$String describe(shapes$Corner) #11
    │   │   ├── params[0]: corner #7 : shapes$Corner
    │   │   └── body[0] > return > match:
    │   │       ├── type: core$String
    │   │       ├── scrutinees[0]: corner #7 : shapes$Corner
    │   │       ├── arms[0] > arm:
    │   │       │   ├── patterns[0]: topLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #71
    │   │       │       └── args[0]: "top" : @concepts$Text
    │   │       ├── arms[1] > arm:
    │   │       │   ├── patterns[0]: topRight
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #71
    │   │       │       └── args[0]: "top" : @concepts$Text
    │   │       ├── arms[2] > arm:
    │   │       │   ├── patterns[0]: bottomLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #71
    │   │       │       └── args[0]: "bottom" : @concepts$Text
    │   │       └── arms[3] > arm:
    │   │           ├── patterns[0]: bottomRight
    │   │           └── body[0] > return > construct:
    │   │               ├── type: core$String
    │   │               ├── ctor: String #71
    │   │               └── args[0]: "bottom" : @concepts$Text
    │   └── decls[11] > verb:
    │       ├── signature: core$Unit main() #12
    │       ├── params:
    │       ├── body[0] > let:
    │       │   ├── local: console #8 : core$Console
    │       │   └── value > construct:
    │       │       ├── type: core$Console
    │       │       ├── ctor: Console #35
    │       │       └── args[0]: @program$console : @runtime$Console
    │       ├── body[1] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: print #36
    │       │   ├── args[0]: console #8 : core$Console
    │       │   └── args[1] > coerce:
    │       │       ├── type: core$String
    │       │       ├── ctor: String #71
    │       │       └── value: "hello" : @concepts$Text
    │       ├── body[2] > let:
    │       │   ├── local: origin #9 : shapes$Vec2
    │       │   └── value > construct:
    │       │       ├── type: shapes$Vec2
    │       │       ├── ctor: Vec2.zero #15
    │       │       └── args:
    │       ├── body[3] > let:
    │       │   ├── local: moved #10 : shapes$Vec2
    │       │   └── value > op:
    │       │       ├── type: shapes$Vec2
    │       │       ├── op: +
    │       │       ├── impl: + #17
    │       │       ├── left: origin #9 : shapes$Vec2
    │       │       └── right > coerce:
    │       │           ├── type: shapes$Vec2
    │       │           ├── ctor: Vec2 #21
    │       │           └── value: 3.0 : @concepts$Decimal
    │       ├── body[4] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: scale #20
    │       │   ├── args[0]: moved #10 : shapes$Vec2
    │       │   └── args[1] > construct:
    │       │       ├── type: core$Float
    │       │       ├── ctor: Float #62
    │       │       └── args[0]: 2.0 : @concepts$Decimal
    │       ├── body[5] > let:
    │       │   ├── local: flat #11 : shapes$Vec2
    │       │   └── value > construct_fields:
    │       │       ├── type: shapes$Vec2
    │       │       ├── ctor: Vec2 #16
    │       │       └── fields[0] > field:
    │       │           ├── name: x (slot 0)
    │       │           └── value > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #62
    │       │               └── args[0]: 1.0 : @concepts$Decimal
    │       ├── body[6] > let:
    │       │   ├── local: size #12 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: length #19
    │       │       └── args[0]: moved #10 : shapes$Vec2
    │       ├── body[7] > let:
    │       │   ├── local: shape #13 : shapes$Shape
    │       │   └── value > case:
    │       │       ├── type: shapes$Shape
    │       │       ├── case: circle
    │       │       └── payload > construct:
    │       │           ├── type: core$Float
    │       │           ├── ctor: Float #62
    │       │           └── args[0]: 2.0 : @concepts$Decimal
    │       ├── body[8] > let:
    │       │   ├── local: covered #14 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: area #26
    │       │       └── args[0]: shape #13 : shapes$Shape
    │       ├── body[9] > let:
    │       │   ├── local: radius #15 : core$Float
    │       │   └── value > case_read:
    │       │       ├── type: core$Float
    │       │       ├── target: shape #13 : shapes$Shape
    │       │       ├── case: circle
    │       │       └── handler:
    │       │           ├── binder: none
    │       │           └── body[0] > resolve > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #62
    │       │               └── args[0]: 0.0 : @concepts$Decimal
    │       ├── body[10] > let:
    │       │   ├── local: half #17 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: safeDivide #10
    │       │       ├── args[0]: covered #14 : core$Float
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$Float
    │       │       │   ├── ctor: Float #62
    │       │       │   └── args[0]: 2.0 : @concepts$Decimal
    │       │       └── handler:
    │       │           ├── binder: reason #16 : core$String
    │       │           ├── body[0] > do > call:
    │       │           │   ├── type: core$Unit
    │       │           │   ├── callee: print #36
    │       │           │   ├── args[0]: console #8 : core$Console
    │       │           │   └── args[1]: reason #16 : core$String
    │       │           └── body[1] > resolve > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #62
    │       │               └── args[0]: 0.0 : @concepts$Decimal
    │       ├── body[11] > let:
    │       │   ├── local: picked #18 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: pick #1 with T = core$Int
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #52
    │       │       │   └── args[0]: 1 : @concepts$Integer
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #52
    │       │       │   └── args[0]: 2 : @concepts$Integer
    │       │       └── args[2] > coerce:
    │       │           ├── type: core$Bool
    │       │           ├── ctor: Bool #28
    │       │           └── value: true : @primitives$Bool
    │       ├── body[12] > let:
    │       │   ├── local: name #19 : core$String
    │       │   └── value > call:
    │       │       ├── type: core$String
    │       │       ├── callee: pick #1 with T = core$String
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$String
    │       │       │   ├── ctor: String #71
    │       │       │   └── args[0]: "a" : @concepts$Text
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$String
    │       │       │   ├── ctor: String #71
    │       │       │   └── args[0]: "b" : @concepts$Text
    │       │       └── args[2] > coerce:
    │       │           ├── type: core$Bool
    │       │           ├── ctor: Bool #28
    │       │           └── value: false : @primitives$Bool
    │       ├── body[13] > let:
    │       │   ├── local: pair #20 : app$Pair<core$Int>
    │       │   └── value > construct:
    │       │       ├── type: app$Pair<core$Int>
    │       │       ├── ctor: Pair #3 with T = core$Int
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #52
    │       │       │   └── args[0]: 3 : @concepts$Integer
    │       │       └── args[1] > construct:
    │       │           ├── type: core$Int
    │       │           ├── ctor: Int #52
    │       │           └── args[0]: 4 : @concepts$Integer
    │       ├── body[14] > let:
    │       │   ├── local: total #21 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: sum #4 with T = core$Int
    │       │       └── args[0]: pair #20 : app$Pair<core$Int>
    │       ├── body[15] > let:
    │       │   ├── local: floats #22 : app$Pair<core$Float>
    │       │   └── value > construct:
    │       │       ├── type: app$Pair<core$Float>
    │       │       ├── ctor: Pair #3 with T = core$Float
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Float
    │       │       │   ├── ctor: Float #62
    │       │       │   └── args[0]: 1.0 : @concepts$Decimal
    │       │       └── args[1] > construct:
    │       │           ├── type: core$Float
    │       │           ├── ctor: Float #62
    │       │           └── args[0]: 2.0 : @concepts$Decimal
    │       ├── body[16] > let:
    │       │   ├── local: both #23 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: sum #4 with T = core$Float
    │       │       └── args[0]: floats #22 : app$Pair<core$Float>
    │       ├── body[17] > let:
    │       │   ├── local: numbers #24 : core$Array<core$Int, 3>
    │       │   └── value > construct:
    │       │       ├── type: core$Array<core$Int, 3>
    │       │       ├── ctor: Array #38 with T = core$Int, n = 3
    │       │       └── args[0] > array:
    │       │           ├── type: @concepts$Array<core$Int, 3>
    │       │           ├── items[0] > construct:
    │       │           │   ├── type: core$Int
    │       │           │   ├── ctor: Int #52
    │       │           │   └── args[0]: 1 : @concepts$Integer
    │       │           ├── items[1] > construct:
    │       │           │   ├── type: core$Int
    │       │           │   ├── ctor: Int #52
    │       │           │   └── args[0]: 2 : @concepts$Integer
    │       │           └── items[2] > construct:
    │       │               ├── type: core$Int
    │       │               ├── ctor: Int #52
    │       │               └── args[0]: 3 : @concepts$Integer
    │       ├── body[18] > let:
    │       │   ├── local: first #27 : core$Int
    │       │   └── value > subscript:
    │       │       ├── type: core$Int
    │       │       ├── impl: [] #39 with T = core$Int, n = 3
    │       │       ├── target: numbers #24 : core$Array<core$Int, 3>
    │       │       └── args[0] > coerce:
    │       │           ├── type: core$Int
    │       │           ├── ctor: Int #52
    │       │           └── value: 1 : @concepts$Integer
    │       ├── body[19] > let:
    │       │   ├── local: length #28 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: count #5 with T = core$Int, n = 3
    │       │       └── args[0]: numbers #24 : core$Array<core$Int, 3>
    │       ├── body[20] > let:
    │       │   ├── local: sized #29 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: measured #6 with n = 3
    │       │       ├── args[0]: numbers #24 : core$Array<core$Int, 3>
    │       │       └── args[1]: 3 : @concepts$Integer
    │       ├── body[21] > let:
    │       │   ├── local: like #30 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: sizedLike #7 with n = 3
    │       │       ├── args[0]: numbers #24 : core$Array<core$Int, 3>
    │       │       └── args[1]: 3 : @concepts$Integer
    │       ├── body[22] > let:
    │       │   ├── local: ints #31 : app$Pair<core$Int>
    │       │   └── value > call:
    │       │       ├── type: app$Pair<core$Int>
    │       │       ├── callee: pairOf #8
    │       │       ├── args[0]: 2 : @concepts$Integer
    │       │       └── args[1]: 3 : @concepts$Integer
    │       ├── body[23] > let:
    │       │   ├── local: decimals #32 : app$Pair<core$Float>
    │       │   └── value > call:
    │       │       ├── type: app$Pair<core$Float>
    │       │       ├── callee: pairOf #9
    │       │       ├── args[0]: 2.5 : @concepts$Decimal
    │       │       └── args[1]: 3.5 : @concepts$Decimal
    │       ├── body[24] > let:
    │       │   ├── local: label #33 : core$String
    │       │   └── value > map_read:
    │       │       ├── type: core$String
    │       │       ├── target: .topLeft : shapes$Corner
    │       │       └── map: label #24
    │       ├── body[25] > let:
    │       │   ├── local: side #34 : core$String
    │       │   └── value > call:
    │       │       ├── type: core$String
    │       │       ├── callee: describe #11
    │       │       └── args[0]: .bottomRight : shapes$Corner
    │       ├── body[26] > let:
    │       │   ├── local: i #35 : core$Int
    │       │   └── value > construct:
    │       │       ├── type: core$Int
    │       │       ├── ctor: Int #52
    │       │       └── args[0]: 1 : @concepts$Integer
    │       ├── body[27] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: to #50
    │       │   ├── args[0]: i #35 : core$Int
    │       │   ├── args[1] > coerce:
    │       │   │   ├── type: core$Int
    │       │   │   ├── ctor: Int #52
    │       │   │   └── value: 3 : @concepts$Integer
    │       │   └── args[2] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #36
    │       │       ├── args[0]: console #8 : core$Console
    │       │       └── args[1]: side #34 : core$String
    │       ├── body[28] > let:
    │       │   ├── local: double #37 : core$Float[core$Float]
    │       │   └── value > lambda:
    │       │       ├── type: core$Float[core$Float]
    │       │       ├── params[0]: value #36 : core$Float
    │       │       └── body[0] > return > op:
    │       │           ├── type: core$Float
    │       │           ├── op: *
    │       │           ├── impl: * #65
    │       │           ├── left: value #36 : core$Float
    │       │           └── right > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #62
    │       │               └── args[0]: 2.0 : @concepts$Decimal
    │       ├── body[29] > let:
    │       │   ├── local: doubled #38 : core$Float
    │       │   └── value > call_value:
    │       │       ├── type: core$Float
    │       │       ├── callee: double #37 : core$Float[core$Float]
    │       │       └── args[0]: half #17 : core$Float
    │       ├── body[30] > let:
    │       │   ├── local: chain #39 : core$Bool
    │       │   └── value > call:
    │       │       ├── type: core$Bool
    │       │       ├── callee: if #46
    │       │       ├── args[0] > op:
    │       │       │   ├── type: core$Bool
    │       │       │   ├── op: <
    │       │       │   ├── impl: < #60
    │       │       │   ├── left: total #21 : core$Int
    │       │       │   └── right > construct:
    │       │       │       ├── type: core$Int
    │       │       │       ├── ctor: Int #52
    │       │       │       └── args[0]: 5 : @concepts$Integer
    │       │       └── args[1] > block[0] > do > call:
    │       │           ├── type: core$Unit
    │       │           ├── callee: print #36
    │       │           ├── args[0]: console #8 : core$Console
    │       │           └── args[1] > coerce:
    │       │               ├── type: core$String
    │       │               ├── ctor: String #71
    │       │               └── value: "small" : @concepts$Text
    │       ├── body[31] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: elif #47
    │       │   ├── args[0]: chain #39 : core$Bool
    │       │   ├── args[1] > op:
    │       │   │   ├── type: core$Bool
    │       │   │   ├── op: ==
    │       │   │   ├── impl: == #59
    │       │   │   ├── left: total #21 : core$Int
    │       │   │   └── right > construct:
    │       │   │       ├── type: core$Int
    │       │   │       ├── ctor: Int #52
    │       │   │       └── args[0]: 7 : @concepts$Integer
    │       │   └── args[2] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #36
    │       │       ├── args[0]: console #8 : core$Console
    │       │       └── args[1] > coerce:
    │       │           ├── type: core$String
    │       │           ├── ctor: String #71
    │       │           └── value: "seven" : @concepts$Text
    │       ├── body[32] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: else #48
    │       │   ├── args[0]: chain #39 : core$Bool
    │       │   └── args[1] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #36
    │       │       ├── args[0]: console #8 : core$Console
    │       │       └── args[1] > coerce:
    │       │           ├── type: core$String
    │       │           ├── ctor: String #71
    │       │           └── value: "large" : @concepts$Text
    │       └── body[33] > return > construct:
    │           ├── type: core$Unit
    │           ├── ctor: Unit #76
    │           └── args:
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > type:
    │   │   ├── name: Vec2 #13
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : core$Float
    │   │   └── struct[1]: y : core$Float
    │   ├── decls[1] > verb:
    │   │   ├── signature: Vec2(core$Float, core$Float) #14
    │   │   ├── params[0]: x #40 : core$Float
    │   │   ├── params[1]: y #41 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #40 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #41 : core$Float
    │   ├── decls[2] > verb:
    │   │   ├── signature: Vec2.zero() #15
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #62
    │   │       │       └── args[0]: 0.0 : @concepts$Decimal
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #62
    │   │               └── args[0]: 0.0 : @concepts$Decimal
    │   ├── decls[3] > verb:
    │   │   ├── signature: Vec2{x core$Float; y core$Float = ...} #16
    │   │   ├── params[0]: x #44 : core$Float
    │   │   ├── params[1]: y #45 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #44 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #45 : core$Float
    │   ├── decls[4] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #17
    │   │   ├── params[0]: left #46 : shapes$Vec2
    │   │   ├── params[1]: right #47 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #14
    │   │       ├── args[0] > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: +
    │   │       │   ├── impl: + #64
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: left #46 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: right #47 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > op:
    │   │           ├── type: core$Float
    │   │           ├── op: +
    │   │           ├── impl: + #64
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: left #46 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: right #47 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[5] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #18
    │   │   ├── params[0]: value #48 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #14
    │   │       ├── args[0] > flip:
    │   │       │   ├── type: core$Float
    │   │       │   ├── impl: ~ #67
    │   │       │   └── value > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: value #48 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > flip:
    │   │           ├── type: core$Float
    │   │           ├── impl: ~ #67
    │   │           └── value > field:
    │   │               ├── type: core$Float
    │   │               ├── target: value #48 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Float length(this shapes$Vec2) #19
    │   │   ├── params[0]: this #49 : shapes$Vec2
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: +
    │   │       ├── impl: + #64
    │   │       ├── left > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: *
    │   │       │   ├── impl: * #65
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: this #49 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: this #49 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── right > op:
    │   │           ├── type: core$Float
    │   │           ├── op: *
    │   │           ├── impl: * #65
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: this #49 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: this #49 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[7] > verb:
    │   │   ├── signature: core$Unit scale(this shapes$Vec2, core$Float) mut #20
    │   │   ├── params[0]: this #50 : shapes$Vec2
    │   │   ├── params[1]: by #51 : core$Float
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #50 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #65
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #50 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── right: by #51 : core$Float
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #50 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #65
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #50 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── right: by #51 : core$Float
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[8] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Decimal) #21
    │   │   ├── params[0]: value #52 : @concepts$Decimal
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #62
    │   │       │       └── args[0]: value #52 : @concepts$Decimal
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #62
    │   │               └── args[0]: value #52 : @concepts$Decimal
    │   ├── decls[9] > type:
    │   │   ├── name: Shape #22
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : core$Float
    │   │   ├── variant[1]: square : core$Float
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[10] > type:
    │   │   ├── name: Corner #23
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[11] > enum_map:
    │   │   ├── map: shapes$Corner.label #24
    │   │   ├── type: core$String
    │   │   ├── entries[0]:
    │   │   │   ├── member: topLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #71
    │   │   │       └── value: "top left" : @concepts$Text
    │   │   ├── entries[1]:
    │   │   │   ├── member: topRight
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #71
    │   │   │       └── value: "top right" : @concepts$Text
    │   │   ├── entries[2]:
    │   │   │   ├── member: bottomLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #71
    │   │   │       └── value: "bottom left" : @concepts$Text
    │   │   └── entries[3]:
    │   │       ├── member: bottomRight
    │   │       └── value > coerce:
    │   │           ├── type: core$String
    │   │           ├── ctor: String #71
    │   │           └── value: "bottom right" : @concepts$Text
    │   ├── decls[12] > verb:
    │   │   ├── signature: core$Float _half(core$Float) #25
    │   │   ├── params[0]: value #53 : core$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #66
    │   │       ├── left: value #53 : core$Float
    │   │       └── right > construct:
    │   │           ├── type: core$Float
    │   │           ├── ctor: Float #62
    │   │           └── args[0]: 2.0 : @concepts$Decimal
    │   └── decls[13] > verb:
    │       ├── signature: core$Float area(shapes$Shape) #26
    │       ├── params[0]: shape #54 : shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: core$Float
    │           ├── scrutinees[0]: shape #54 : shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #55 : core$Float <- circle
    │           │   └── body[0] > return > op:
    │           │       ├── type: core$Float
    │           │       ├── op: *
    │           │       ├── impl: * #65
    │           │       ├── left: r #55 : core$Float
    │           │       └── right: r #55 : core$Float
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #56 : core$Float <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: core$Float
    │           │       ├── callee: _half #25
    │           │       └── args[0] > op:
    │           │           ├── type: core$Float
    │           │           ├── op: +
    │           │           ├── impl: + #64
    │           │           ├── left: s #56 : core$Float
    │           │           └── right: s #56 : core$Float
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: core$Float
    │                   ├── ctor: Float #62
    │                   └── args[0]: 0.0 : @concepts$Decimal
    ├── packages[2] > package:
    │   ├── name: core
    │   ├── decls[0] > type:
    │   │   ├── name: Bool #27
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Bool
    │   ├── decls[1] > verb:
    │   │   ├── signature: implicit Bool(@primitives$Bool) #28
    │   │   ├── params[0]: raw #57 : @primitives$Bool
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Bool
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #57 : @primitives$Bool
    │   ├── decls[2] > verb:
    │   │   ├── signature: implicit @primitives$Bool(core$Bool) #29
    │   │   ├── params[0]: value #58 : core$Bool
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Bool
    │   │       ├── target: value #58 : core$Bool
    │   │       └── field: raw (slot 0)
    │   ├── decls[3] > verb:
    │   │   ├── signature: core$Bool *(core$Bool, core$Bool) #30
    │   │   ├── params[0]: left #59 : core$Bool
    │   │   ├── params[1]: right #60 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #59 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #60 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[4] > verb:
    │   │   ├── signature: core$Bool +(core$Bool, core$Bool) #31
    │   │   ├── params[0]: left #61 : core$Bool
    │   │   ├── params[1]: right #62 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #61 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #62 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[5] > verb:
    │   │   ├── signature: core$Bool ==(core$Bool, core$Bool) #32
    │   │   ├── params[0]: left #63 : core$Bool
    │   │   ├── params[1]: right #64 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #63 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #64 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Bool ~(core$Bool) #33
    │   │   ├── params[0]: value #65 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Bool
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: value #65 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[7] > type:
    │   │   ├── name: Console #34
    │   │   ├── kind: reference
    │   │   └── struct[0]: _console : &@runtime$Console
    │   ├── decls[8] > verb:
    │   │   ├── signature: Console(&@runtime$Console) #35
    │   │   ├── params[0]: console #66 : &@runtime$Console
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Console
    │   │       └── fields[0] > field:
    │   │           ├── name: _console (slot 0)
    │   │           └── value: console #66 : &@runtime$Console
    │   ├── decls[9] > verb:
    │   │   ├── signature: core$Unit print(this core$Console, core$String) mut #36
    │   │   ├── params[0]: this #67 : core$Console
    │   │   ├── params[1]: text #68 : core$String
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @runtime$print
    │   │   │   ├── args[0] > field:
    │   │   │   │   ├── type: &@runtime$Console
    │   │   │   │   ├── target: this #67 : core$Console
    │   │   │   │   └── field: _console (slot 0)
    │   │   │   └── args[1] > field:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: text #68 : core$String
    │   │   │       └── field: raw (slot 0)
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[10] > type:
    │   │   ├── name: Array #37
    │   │   ├── params: T Type, n @concepts$Integer
    │   │   ├── kind: value
    │   │   └── struct[0]: _items : @primitives$Array<T, n>
    │   ├── decls[11] > verb:
    │   │   ├── signature: Array(@concepts$Array<T, n>) #38
    │   │   └── body: checked per instance
    │   ├── decls[12] > subscript:
    │   │   ├── signature: (this core$Array<T, n>)[core$Int] #39
    │   │   └── body: checked per instance
    │   ├── decls[13] > verb:
    │   │   ├── signature: core$Int size(this core$Array<T, n>) #40
    │   │   └── body: checked per instance
    │   ├── decls[14] > type:
    │   │   ├── name: List #41
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: _items : @primitives$List<T>
    │   ├── decls[15] > verb:
    │   │   ├── signature: List(T Type) #42
    │   │   └── body: checked per instance
    │   ├── decls[16] > verb:
    │   │   ├── signature: core$Unit push(this core$List<T>, T) mut #43
    │   │   └── body: checked per instance
    │   ├── decls[17] > verb:
    │   │   ├── signature: core$Int size(this core$List<T>) #44
    │   │   └── body: checked per instance
    │   ├── decls[18] > subscript:
    │   │   ├── signature: (this core$List<T>)[core$Int] #45
    │   │   └── body: checked per instance
    │   ├── decls[19] > verb:
    │   │   ├── signature: core$Bool if(core$Bool, @concepts$Block) #46
    │   │   ├── params[0]: condition #69 : core$Bool
    │   │   ├── params[1]: body #70 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #29
    │   │   │   │   └── value: condition #69 : core$Bool
    │   │   │   └── args[1]: body #70 : @concepts$Block
    │   │   └── body[1] > return: condition #69 : core$Bool
    │   ├── decls[20] > verb:
    │   │   ├── signature: core$Unit elif(this core$Bool, core$Bool, @concepts$Block) mut #47
    │   │   ├── params[0]: this #71 : core$Bool
    │   │   ├── params[1]: condition #72 : core$Bool
    │   │   ├── params[2]: body #73 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #29
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── op: *
    │   │   │   │       ├── impl: * #30
    │   │   │   │       ├── left > flip:
    │   │   │   │       │   ├── type: core$Bool
    │   │   │   │       │   ├── impl: ~ #33
    │   │   │   │       │   └── value: this #71 : core$Bool
    │   │   │   │       └── right: condition #72 : core$Bool
    │   │   │   └── args[1]: body #73 : @concepts$Block
    │   │   ├── body[1] > assign:
    │   │   │   ├── target: this #71 : core$Bool
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #31
    │   │   │       ├── left: this #71 : core$Bool
    │   │   │       └── right: condition #72 : core$Bool
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[21] > verb:
    │   │   ├── signature: core$Unit else(this core$Bool, @concepts$Block) #48
    │   │   ├── params[0]: this #74 : core$Bool
    │   │   ├── params[1]: body #75 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #29
    │   │   │   │   └── value > flip:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── impl: ~ #33
    │   │   │   │       └── value: this #74 : core$Bool
    │   │   │   └── args[1]: body #75 : @concepts$Block
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[22] > verb:
    │   │   ├── signature: core$Unit guard(core$Bool) #49
    │   │   ├── params[0]: condition #76 : core$Bool
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #29
    │   │   │   │   └── value: condition #76 : core$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: @controlflow$exitFromCall
    │   │   │       └── args:
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[23] > verb:
    │   │   ├── signature: core$Unit to(this core$Int, core$Int, @concepts$Block) mut #50
    │   │   ├── params[0]: this #77 : core$Int
    │   │   ├── params[1]: end #78 : core$Int
    │   │   ├── params[2]: body #79 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$repeat
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── ctor: @primitives$Int #54
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Int
    │   │   │   │       ├── op: +
    │   │   │   │       ├── impl: + #55
    │   │   │   │       ├── left > op:
    │   │   │   │       │   ├── type: core$Int
    │   │   │   │       │   ├── op: +
    │   │   │   │       │   ├── impl: + #55
    │   │   │   │       │   ├── left: end #78 : core$Int
    │   │   │   │       │   └── right > flip:
    │   │   │   │       │       ├── type: core$Int
    │   │   │   │       │       ├── impl: ~ #58
    │   │   │   │       │       └── value: this #77 : core$Int
    │   │   │   │       └── right > construct:
    │   │   │   │           ├── type: core$Int
    │   │   │   │           ├── ctor: Int #52
    │   │   │   │           └── args[0]: 1 : @concepts$Integer
    │   │   │   ├── args[1] > block[0] > do > call:
    │   │   │   │   ├── type: @primitives$Unit
    │   │   │   │   ├── callee: @controlflow$branch
    │   │   │   │   ├── args[0]: true : @primitives$Bool
    │   │   │   │   └── args[1]: body #79 : @concepts$Block
    │   │   │   └── args[1] > block[1] > assign:
    │   │   │       ├── target: this #77 : core$Int
    │   │   │       └── value > op:
    │   │   │           ├── type: core$Int
    │   │   │           ├── op: +
    │   │   │           ├── impl: + #55
    │   │   │           ├── left: this #77 : core$Int
    │   │   │           └── right > construct:
    │   │   │               ├── type: core$Int
    │   │   │               ├── ctor: Int #52
    │   │   │               └── args[0]: 1 : @concepts$Integer
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #76
    │   │       └── args:
    │   ├── decls[24] > type:
    │   │   ├── name: Int #51
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Int
    │   ├── decls[25] > verb:
    │   │   ├── signature: implicit Int(@concepts$Integer) #52
    │   │   ├── params[0]: value #80 : @concepts$Integer
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Int
    │   │               ├── ctor: @primitives$Int
    │   │               └── args[0]: value #80 : @concepts$Integer
    │   ├── decls[26] > verb:
    │   │   ├── signature: implicit Int(@primitives$Int) #53
    │   │   ├── params[0]: raw #81 : @primitives$Int
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #81 : @primitives$Int
    │   ├── decls[27] > verb:
    │   │   ├── signature: implicit @primitives$Int(core$Int) #54
    │   │   ├── params[0]: value #82 : core$Int
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Int
    │   │       ├── target: value #82 : core$Int
    │   │       └── field: raw (slot 0)
    │   ├── decls[28] > verb:
    │   │   ├── signature: core$Int +(core$Int, core$Int) #55
    │   │   ├── params[0]: left #83 : core$Int
    │   │   ├── params[1]: right #84 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #53
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #83 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #84 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[29] > verb:
    │   │   ├── signature: core$Int *(core$Int, core$Int) #56
    │   │   ├── params[0]: left #85 : core$Int
    │   │   ├── params[1]: right #86 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #53
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #85 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #86 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[30] > verb:
    │   │   ├── signature: core$Int /(core$Int, core$Int) #57
    │   │   ├── params[0]: left #87 : core$Int
    │   │   ├── params[1]: right #88 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #53
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #87 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #88 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[31] > verb:
    │   │   ├── signature: core$Int ~(core$Int) #58
    │   │   ├── params[0]: value #89 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #53
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Int
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: value #89 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[32] > verb:
    │   │   ├── signature: core$Bool ==(core$Int, core$Int) #59
    │   │   ├── params[0]: left #90 : core$Int
    │   │   ├── params[1]: right #91 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #90 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #91 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[33] > verb:
    │   │   ├── signature: core$Bool <(core$Int, core$Int) #60
    │   │   ├── params[0]: left #92 : core$Int
    │   │   ├── params[1]: right #93 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #92 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #93 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[34] > type:
    │   │   ├── name: Float #61
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Float
    │   ├── decls[35] > verb:
    │   │   ├── signature: implicit Float(@concepts$Decimal) #62
    │   │   ├── params[0]: value #94 : @concepts$Decimal
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: value #94 : @concepts$Decimal
    │   ├── decls[36] > verb:
    │   │   ├── signature: implicit Float(@primitives$Float) #63
    │   │   ├── params[0]: raw #95 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #95 : @primitives$Float
    │   ├── decls[37] > verb:
    │   │   ├── signature: core$Float +(core$Float, core$Float) #64
    │   │   ├── params[0]: left #96 : core$Float
    │   │   ├── params[1]: right #97 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #63
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #96 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #97 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[38] > verb:
    │   │   ├── signature: core$Float *(core$Float, core$Float) #65
    │   │   ├── params[0]: left #98 : core$Float
    │   │   ├── params[1]: right #99 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #63
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #98 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #99 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[39] > verb:
    │   │   ├── signature: core$Float /(core$Float, core$Float) #66
    │   │   ├── params[0]: left #100 : core$Float
    │   │   ├── params[1]: right #101 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #63
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #100 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #101 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[40] > verb:
    │   │   ├── signature: core$Float ~(core$Float) #67
    │   │   ├── params[0]: value #102 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #63
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Float
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: value #102 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[41] > verb:
    │   │   ├── signature: core$Bool ==(core$Float, core$Float) #68
    │   │   ├── params[0]: left #103 : core$Float
    │   │   ├── params[1]: right #104 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #103 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #104 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[42] > verb:
    │   │   ├── signature: core$Bool <(core$Float, core$Float) #69
    │   │   ├── params[0]: left #105 : core$Float
    │   │   ├── params[1]: right #106 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #105 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #106 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[43] > type:
    │   │   ├── name: String #70
    │   │   ├── kind: reference
    │   │   └── struct[0]: raw : @primitives$String
    │   ├── decls[44] > verb:
    │   │   ├── signature: implicit String(@concepts$Text) #71
    │   │   ├── params[0]: value #107 : @concepts$Text
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$String
    │   │               ├── ctor: @primitives$String
    │   │               └── args[0]: value #107 : @concepts$Text
    │   ├── decls[45] > verb:
    │   │   ├── signature: String(@primitives$String) #72
    │   │   ├── params[0]: raw #108 : @primitives$String
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #108 : @primitives$String
    │   ├── decls[46] > verb:
    │   │   ├── signature: core$String +(core$String, core$String) #73
    │   │   ├── params[0]: left #109 : core$String
    │   │   ├── params[1]: right #110 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$String
    │   │       ├── ctor: String #72
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$String
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #109 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #110 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[47] > verb:
    │   │   ├── signature: core$Bool ==(core$String, core$String) #74
    │   │   ├── params[0]: left #111 : core$String
    │   │   ├── params[1]: right #112 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #28
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #111 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #112 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[48] > type:
    │   │   ├── name: Unit #75
    │   │   ├── kind: value
    │   │   └── struct:
    │   ├── decls[49] > verb:
    │   │   ├── signature: Unit() #76
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Unit
    │   │       └── fields:
    │   └── decls[50] > verb:
    │       ├── signature: implicit Unit(@primitives$Unit) #77
    │       ├── params[0]: value #113 : @primitives$Unit
    │       └── body[0] > return > init:
    │           ├── type: core$Unit
    │           └── fields:
    ├── instances[0] > instance:
    │   ├── of: pick #1 with T = core$Int
    │   ├── params[0]: first #118 : core$Int
    │   ├── params[1]: second #119 : core$Int
    │   ├── params[2]: takeFirst #120 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #121 : core$Int
    │   │   └── value: second #119 : core$Int
    │   ├── body[1] > let:
    │   │   ├── local: ran #122 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #46
    │   │       ├── args[0]: takeFirst #120 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #121 : core$Int
    │   │           └── value: first #118 : core$Int
    │   └── body[2] > return: chosen #121 : core$Int
    ├── instances[1] > instance:
    │   ├── of: pick #1 with T = core$String
    │   ├── params[0]: first #123 : core$String
    │   ├── params[1]: second #124 : core$String
    │   ├── params[2]: takeFirst #125 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #126 : core$String
    │   │   └── value: second #124 : core$String
    │   ├── body[1] > let:
    │   │   ├── local: ran #127 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #46
    │   │       ├── args[0]: takeFirst #125 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #126 : core$String
    │   │           └── value: first #123 : core$String
    │   └── body[2] > return: chosen #126 : core$String
    ├── instances[2] > instance:
    │   ├── of: Pair #3 with T = core$Float
    │   ├── params[0]: left #116 : core$Float
    │   ├── params[1]: right #117 : core$Float
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Float>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #116 : core$Float
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #117 : core$Float
    ├── instances[3] > instance:
    │   ├── of: Pair #3 with T = core$Int
    │   ├── params[0]: left #114 : core$Int
    │   ├── params[1]: right #115 : core$Int
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Int>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #114 : core$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #115 : core$Int
    ├── instances[4] > instance:
    │   ├── of: sum #4 with T = core$Float
    │   ├── params[0]: pair #129 : app$Pair<core$Float>
    │   └── body[0] > return > op:
    │       ├── type: core$Float
    │       ├── op: +
    │       ├── impl: + #64
    │       ├── left > field:
    │       │   ├── type: core$Float
    │       │   ├── target: pair #129 : app$Pair<core$Float>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Float
    │           ├── target: pair #129 : app$Pair<core$Float>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #4 with T = core$Int
    │   ├── params[0]: pair #128 : app$Pair<core$Int>
    │   └── body[0] > return > op:
    │       ├── type: core$Int
    │       ├── op: +
    │       ├── impl: + #55
    │       ├── left > field:
    │       │   ├── type: core$Int
    │       │   ├── target: pair #128 : app$Pair<core$Int>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Int
    │           ├── target: pair #128 : app$Pair<core$Int>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #5 with T = core$Int, n = 3
    │   ├── params[0]: values #131 : core$Array<core$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: core$Int
    │       ├── ctor: Int #52
    │       └── args[0]: n = 3 : @concepts$Integer
    ├── instances[7] > instance:
    │   ├── of: measured #6 with n = 3
    │   ├── params[0]: values #132 : core$Array<core$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: core$Int
    │       ├── ctor: Int #52
    │       └── args[0]: n = 3 : @concepts$Integer
    ├── instances[8] > instance:
    │   ├── of: sizedLike #7 with n = 3
    │   ├── params[0]: values #133 : core$Array<core$Int, 3>
    │   ├── body[0] > let:
    │   │   ├── local: measure #135 : core$Int[core$Array<core$Int, 3>]
    │   │   └── value > lambda:
    │   │       ├── type: core$Int[core$Array<core$Int, 3>]
    │   │       ├── params[0]: held #134 : core$Array<core$Int, 3>
    │   │       └── body[0] > return > construct:
    │   │           ├── type: core$Int
    │   │           ├── ctor: Int #52
    │   │           └── args[0]: n = 3 : @concepts$Integer
    │   └── body[1] > return > call_value:
    │       ├── type: core$Int
    │       ├── callee: measure #135 : core$Int[core$Array<core$Int, 3>]
    │       └── args[0]: values #133 : core$Array<core$Int, 3>
    ├── instances[9] > instance:
    │   ├── of: Array #38 with T = core$Int, n = 3
    │   ├── params[0]: values #130 : @concepts$Array<core$Int, 3>
    │   └── body[0] > return > init:
    │       ├── type: core$Array<core$Int, 3>
    │       └── fields[0] > field:
    │           ├── name: _items (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$Array<core$Int, 3>
    │               ├── ctor: @primitives$Array with T = core$Int, n = 3
    │               └── args[0]: values #130 : @concepts$Array<core$Int, 3>
    └── instances[10] > instance:
        ├── of: [] #39 with T = core$Int, n = 3
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
                ├── ctor: @primitives$Int #54
                └── value: index #26 : core$Int
