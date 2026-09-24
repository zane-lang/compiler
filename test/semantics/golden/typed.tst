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
    │   │   ├── signature: core$Float?core$String safeDivide(core$Float, core$Float) #6
    │   │   ├── params[0]: numerator #1 : core$Float
    │   │   ├── params[1]: denominator #2 : core$Float
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: core$Unit
    │   │   │   ├── callee: guard #45
    │   │   │   └── args[0] > op:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── op: ==
    │   │   │       ├── impl: == #64
    │   │   │       ├── left: denominator #2 : core$Float
    │   │   │       └── right > construct:
    │   │   │           ├── type: core$Float
    │   │   │           ├── ctor: Float #58
    │   │   │           └── args[0]: 0 : @concepts$Number
    │   │   ├── body[1] > do > call:
    │   │   │   ├── type: core$Bool
    │   │   │   ├── callee: if #42
    │   │   │   ├── args[0] > op:
    │   │   │   │   ├── type: core$Bool
    │   │   │   │   ├── op: <
    │   │   │   │   ├── impl: < #65
    │   │   │   │   ├── left: denominator #2 : core$Float
    │   │   │   │   └── right > construct:
    │   │   │   │       ├── type: core$Float
    │   │   │   │       ├── ctor: Float #58
    │   │   │   │       └── args[0]: 0 : @concepts$Number
    │   │   │   └── args[1] > block[0] > abort > construct:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #67
    │   │   │       └── args[0]: "negative" : @concepts$Text
    │   │   └── body[2] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #62
    │   │       ├── left: numerator #1 : core$Float
    │   │       └── right: denominator #2 : core$Float
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$String describe(shapes$Corner) #7
    │   │   ├── params[0]: corner #3 : shapes$Corner
    │   │   └── body[0] > return > match:
    │   │       ├── type: core$String
    │   │       ├── scrutinees[0]: corner #3 : shapes$Corner
    │   │       ├── arms[0] > arm:
    │   │       │   ├── patterns[0]: topLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #67
    │   │       │       └── args[0]: "top" : @concepts$Text
    │   │       ├── arms[1] > arm:
    │   │       │   ├── patterns[0]: topRight
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #67
    │   │       │       └── args[0]: "top" : @concepts$Text
    │   │       ├── arms[2] > arm:
    │   │       │   ├── patterns[0]: bottomLeft
    │   │       │   └── body[0] > return > construct:
    │   │       │       ├── type: core$String
    │   │       │       ├── ctor: String #67
    │   │       │       └── args[0]: "bottom" : @concepts$Text
    │   │       └── arms[3] > arm:
    │   │           ├── patterns[0]: bottomRight
    │   │           └── body[0] > return > construct:
    │   │               ├── type: core$String
    │   │               ├── ctor: String #67
    │   │               └── args[0]: "bottom" : @concepts$Text
    │   └── decls[7] > verb:
    │       ├── signature: core$Unit main() #8
    │       ├── params:
    │       ├── body[0] > let:
    │       │   ├── local: console #4 : core$Console
    │       │   └── value > construct:
    │       │       ├── type: core$Console
    │       │       ├── ctor: Console #31
    │       │       └── args[0]: @program$console : @runtime$Console
    │       ├── body[1] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: print #32
    │       │   ├── args[0]: console #4 : core$Console
    │       │   └── args[1] > coerce:
    │       │       ├── type: core$String
    │       │       ├── ctor: String #67
    │       │       └── value: "hello" : @concepts$Text
    │       ├── body[2] > let:
    │       │   ├── local: origin #5 : shapes$Vec2
    │       │   └── value > construct:
    │       │       ├── type: shapes$Vec2
    │       │       ├── ctor: Vec2.zero #11
    │       │       └── args:
    │       ├── body[3] > let:
    │       │   ├── local: moved #6 : shapes$Vec2
    │       │   └── value > op:
    │       │       ├── type: shapes$Vec2
    │       │       ├── op: +
    │       │       ├── impl: + #13
    │       │       ├── left: origin #5 : shapes$Vec2
    │       │       └── right > coerce:
    │       │           ├── type: shapes$Vec2
    │       │           ├── ctor: Vec2 #17
    │       │           └── value: 3 : @concepts$Number
    │       ├── body[4] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: scale #16
    │       │   ├── args[0]: moved #6 : shapes$Vec2
    │       │   └── args[1] > construct:
    │       │       ├── type: core$Float
    │       │       ├── ctor: Float #58
    │       │       └── args[0]: 2 : @concepts$Number
    │       ├── body[5] > let:
    │       │   ├── local: flat #7 : shapes$Vec2
    │       │   └── value > construct_fields:
    │       │       ├── type: shapes$Vec2
    │       │       ├── ctor: Vec2 #12
    │       │       └── fields[0] > field:
    │       │           ├── name: x (slot 0)
    │       │           └── value > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #58
    │       │               └── args[0]: 1 : @concepts$Number
    │       ├── body[6] > let:
    │       │   ├── local: size #8 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: length #15
    │       │       └── args[0]: moved #6 : shapes$Vec2
    │       ├── body[7] > let:
    │       │   ├── local: shape #9 : shapes$Shape
    │       │   └── value > case:
    │       │       ├── type: shapes$Shape
    │       │       ├── case: circle
    │       │       └── payload > construct:
    │       │           ├── type: core$Float
    │       │           ├── ctor: Float #58
    │       │           └── args[0]: 2 : @concepts$Number
    │       ├── body[8] > let:
    │       │   ├── local: covered #10 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: area #22
    │       │       └── args[0]: shape #9 : shapes$Shape
    │       ├── body[9] > let:
    │       │   ├── local: radius #11 : core$Float
    │       │   └── value > case_read:
    │       │       ├── type: core$Float
    │       │       ├── target: shape #9 : shapes$Shape
    │       │       ├── case: circle
    │       │       └── handler:
    │       │           ├── binder: none
    │       │           └── body[0] > resolve > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #58
    │       │               └── args[0]: 0 : @concepts$Number
    │       ├── body[10] > let:
    │       │   ├── local: half #13 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: safeDivide #6
    │       │       ├── args[0]: covered #10 : core$Float
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$Float
    │       │       │   ├── ctor: Float #58
    │       │       │   └── args[0]: 2 : @concepts$Number
    │       │       └── handler:
    │       │           ├── binder: reason #12 : core$String
    │       │           ├── body[0] > do > call:
    │       │           │   ├── type: core$Unit
    │       │           │   ├── callee: print #32
    │       │           │   ├── args[0]: console #4 : core$Console
    │       │           │   └── args[1]: reason #12 : core$String
    │       │           └── body[1] > resolve > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #58
    │       │               └── args[0]: 0 : @concepts$Number
    │       ├── body[11] > let:
    │       │   ├── local: picked #14 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: pick #1 with T = core$Int
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #48
    │       │       │   └── args[0]: 1 : @concepts$Number
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #48
    │       │       │   └── args[0]: 2 : @concepts$Number
    │       │       └── args[2] > coerce:
    │       │           ├── type: core$Bool
    │       │           ├── ctor: Bool #24
    │       │           └── value: true : @primitives$Bool
    │       ├── body[12] > let:
    │       │   ├── local: name #15 : core$String
    │       │   └── value > call:
    │       │       ├── type: core$String
    │       │       ├── callee: pick #1 with T = core$String
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$String
    │       │       │   ├── ctor: String #67
    │       │       │   └── args[0]: "a" : @concepts$Text
    │       │       ├── args[1] > construct:
    │       │       │   ├── type: core$String
    │       │       │   ├── ctor: String #67
    │       │       │   └── args[0]: "b" : @concepts$Text
    │       │       └── args[2] > coerce:
    │       │           ├── type: core$Bool
    │       │           ├── ctor: Bool #24
    │       │           └── value: false : @primitives$Bool
    │       ├── body[13] > let:
    │       │   ├── local: pair #16 : app$Pair<core$Int>
    │       │   └── value > construct:
    │       │       ├── type: app$Pair<core$Int>
    │       │       ├── ctor: Pair #3 with T = core$Int
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Int
    │       │       │   ├── ctor: Int #48
    │       │       │   └── args[0]: 3 : @concepts$Number
    │       │       └── args[1] > construct:
    │       │           ├── type: core$Int
    │       │           ├── ctor: Int #48
    │       │           └── args[0]: 4 : @concepts$Number
    │       ├── body[14] > let:
    │       │   ├── local: total #17 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: sum #4 with T = core$Int
    │       │       └── args[0]: pair #16 : app$Pair<core$Int>
    │       ├── body[15] > let:
    │       │   ├── local: floats #18 : app$Pair<core$Float>
    │       │   └── value > construct:
    │       │       ├── type: app$Pair<core$Float>
    │       │       ├── ctor: Pair #3 with T = core$Float
    │       │       ├── args[0] > construct:
    │       │       │   ├── type: core$Float
    │       │       │   ├── ctor: Float #58
    │       │       │   └── args[0]: 1 : @concepts$Number
    │       │       └── args[1] > construct:
    │       │           ├── type: core$Float
    │       │           ├── ctor: Float #58
    │       │           └── args[0]: 2 : @concepts$Number
    │       ├── body[16] > let:
    │       │   ├── local: both #19 : core$Float
    │       │   └── value > call:
    │       │       ├── type: core$Float
    │       │       ├── callee: sum #4 with T = core$Float
    │       │       └── args[0]: floats #18 : app$Pair<core$Float>
    │       ├── body[17] > let:
    │       │   ├── local: numbers #20 : core$Array<core$Int, 3>
    │       │   └── value > construct:
    │       │       ├── type: core$Array<core$Int, 3>
    │       │       ├── ctor: Array #34 with T = core$Int, n = 3
    │       │       └── args[0] > array:
    │       │           ├── type: @concepts$Array<core$Int, 3>
    │       │           ├── items[0] > construct:
    │       │           │   ├── type: core$Int
    │       │           │   ├── ctor: Int #48
    │       │           │   └── args[0]: 1 : @concepts$Number
    │       │           ├── items[1] > construct:
    │       │           │   ├── type: core$Int
    │       │           │   ├── ctor: Int #48
    │       │           │   └── args[0]: 2 : @concepts$Number
    │       │           └── items[2] > construct:
    │       │               ├── type: core$Int
    │       │               ├── ctor: Int #48
    │       │               └── args[0]: 3 : @concepts$Number
    │       ├── body[18] > let:
    │       │   ├── local: first #23 : core$Int
    │       │   └── value > subscript:
    │       │       ├── type: core$Int
    │       │       ├── impl: [] #35 with T = core$Int, n = 3
    │       │       ├── target: numbers #20 : core$Array<core$Int, 3>
    │       │       └── args[0] > coerce:
    │       │           ├── type: core$Int
    │       │           ├── ctor: Int #48
    │       │           └── value: 1 : @concepts$Number
    │       ├── body[19] > let:
    │       │   ├── local: length #24 : core$Int
    │       │   └── value > call:
    │       │       ├── type: core$Int
    │       │       ├── callee: count #5 with T = core$Int, n = 3
    │       │       └── args[0]: numbers #20 : core$Array<core$Int, 3>
    │       ├── body[20] > let:
    │       │   ├── local: label #25 : core$String
    │       │   └── value > map_read:
    │       │       ├── type: core$String
    │       │       ├── target: .topLeft : shapes$Corner
    │       │       └── map: label #20
    │       ├── body[21] > let:
    │       │   ├── local: side #26 : core$String
    │       │   └── value > call:
    │       │       ├── type: core$String
    │       │       ├── callee: describe #7
    │       │       └── args[0]: .bottomRight : shapes$Corner
    │       ├── body[22] > let:
    │       │   ├── local: i #27 : core$Int
    │       │   └── value > construct:
    │       │       ├── type: core$Int
    │       │       ├── ctor: Int #48
    │       │       └── args[0]: 1 : @concepts$Number
    │       ├── body[23] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: to #46
    │       │   ├── args[0]: i #27 : core$Int
    │       │   ├── args[1] > coerce:
    │       │   │   ├── type: core$Int
    │       │   │   ├── ctor: Int #48
    │       │   │   └── value: 3 : @concepts$Number
    │       │   └── args[2] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #32
    │       │       ├── args[0]: console #4 : core$Console
    │       │       └── args[1]: side #26 : core$String
    │       ├── body[24] > let:
    │       │   ├── local: double #29 : core$Float[core$Float]
    │       │   └── value > lambda:
    │       │       ├── type: core$Float[core$Float]
    │       │       ├── params[0]: value #28 : core$Float
    │       │       └── body[0] > return > op:
    │       │           ├── type: core$Float
    │       │           ├── op: *
    │       │           ├── impl: * #61
    │       │           ├── left: value #28 : core$Float
    │       │           └── right > construct:
    │       │               ├── type: core$Float
    │       │               ├── ctor: Float #58
    │       │               └── args[0]: 2 : @concepts$Number
    │       ├── body[25] > let:
    │       │   ├── local: doubled #30 : core$Float
    │       │   └── value > call_value:
    │       │       ├── type: core$Float
    │       │       ├── callee: double #29 : core$Float[core$Float]
    │       │       └── args[0]: half #13 : core$Float
    │       ├── body[26] > let:
    │       │   ├── local: chain #31 : core$Bool
    │       │   └── value > call:
    │       │       ├── type: core$Bool
    │       │       ├── callee: if #42
    │       │       ├── args[0] > op:
    │       │       │   ├── type: core$Bool
    │       │       │   ├── op: <
    │       │       │   ├── impl: < #56
    │       │       │   ├── left: total #17 : core$Int
    │       │       │   └── right > construct:
    │       │       │       ├── type: core$Int
    │       │       │       ├── ctor: Int #48
    │       │       │       └── args[0]: 5 : @concepts$Number
    │       │       └── args[1] > block[0] > do > call:
    │       │           ├── type: core$Unit
    │       │           ├── callee: print #32
    │       │           ├── args[0]: console #4 : core$Console
    │       │           └── args[1] > coerce:
    │       │               ├── type: core$String
    │       │               ├── ctor: String #67
    │       │               └── value: "small" : @concepts$Text
    │       ├── body[27] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: elif #43
    │       │   ├── args[0]: chain #31 : core$Bool
    │       │   ├── args[1] > op:
    │       │   │   ├── type: core$Bool
    │       │   │   ├── op: ==
    │       │   │   ├── impl: == #55
    │       │   │   ├── left: total #17 : core$Int
    │       │   │   └── right > construct:
    │       │   │       ├── type: core$Int
    │       │   │       ├── ctor: Int #48
    │       │   │       └── args[0]: 7 : @concepts$Number
    │       │   └── args[2] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #32
    │       │       ├── args[0]: console #4 : core$Console
    │       │       └── args[1] > coerce:
    │       │           ├── type: core$String
    │       │           ├── ctor: String #67
    │       │           └── value: "seven" : @concepts$Text
    │       ├── body[28] > do > call:
    │       │   ├── type: core$Unit
    │       │   ├── callee: else #44
    │       │   ├── args[0]: chain #31 : core$Bool
    │       │   └── args[1] > block[0] > do > call:
    │       │       ├── type: core$Unit
    │       │       ├── callee: print #32
    │       │       ├── args[0]: console #4 : core$Console
    │       │       └── args[1] > coerce:
    │       │           ├── type: core$String
    │       │           ├── ctor: String #67
    │       │           └── value: "large" : @concepts$Text
    │       └── body[29] > return > construct:
    │           ├── type: core$Unit
    │           ├── ctor: Unit #72
    │           └── args:
    ├── packages[1] > package:
    │   ├── name: shapes
    │   ├── decls[0] > type:
    │   │   ├── name: Vec2 #9
    │   │   ├── kind: value
    │   │   ├── struct[0]: x : core$Float
    │   │   └── struct[1]: y : core$Float
    │   ├── decls[1] > verb:
    │   │   ├── signature: Vec2(core$Float, core$Float) #10
    │   │   ├── params[0]: x #32 : core$Float
    │   │   ├── params[1]: y #33 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #32 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #33 : core$Float
    │   ├── decls[2] > verb:
    │   │   ├── signature: Vec2.zero() #11
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #58
    │   │       │       └── args[0]: 0 : @concepts$Number
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #58
    │   │               └── args[0]: 0 : @concepts$Number
    │   ├── decls[3] > verb:
    │   │   ├── signature: Vec2{x core$Float; y core$Float = ...} #12
    │   │   ├── params[0]: x #36 : core$Float
    │   │   ├── params[1]: y #37 : core$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value: x #36 : core$Float
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value: y #37 : core$Float
    │   ├── decls[4] > verb:
    │   │   ├── signature: shapes$Vec2 +(shapes$Vec2, shapes$Vec2) #13
    │   │   ├── params[0]: left #38 : shapes$Vec2
    │   │   ├── params[1]: right #39 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #10
    │   │       ├── args[0] > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: +
    │   │       │   ├── impl: + #60
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: left #38 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: right #39 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > op:
    │   │           ├── type: core$Float
    │   │           ├── op: +
    │   │           ├── impl: + #60
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: left #38 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: right #39 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[5] > verb:
    │   │   ├── signature: shapes$Vec2 ~(shapes$Vec2) #14
    │   │   ├── params[0]: value #40 : shapes$Vec2
    │   │   └── body[0] > return > construct:
    │   │       ├── type: shapes$Vec2
    │   │       ├── ctor: Vec2 #10
    │   │       ├── args[0] > flip:
    │   │       │   ├── type: core$Float
    │   │       │   ├── impl: ~ #63
    │   │       │   └── value > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: value #40 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── args[1] > flip:
    │   │           ├── type: core$Float
    │   │           ├── impl: ~ #63
    │   │           └── value > field:
    │   │               ├── type: core$Float
    │   │               ├── target: value #40 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Float length(this shapes$Vec2) #15
    │   │   ├── params[0]: this #41 : shapes$Vec2
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: +
    │   │       ├── impl: + #60
    │   │       ├── left > op:
    │   │       │   ├── type: core$Float
    │   │       │   ├── op: *
    │   │       │   ├── impl: * #61
    │   │       │   ├── left > field:
    │   │       │   │   ├── type: core$Float
    │   │       │   │   ├── target: this #41 : shapes$Vec2
    │   │       │   │   └── field: x (slot 0)
    │   │       │   └── right > field:
    │   │       │       ├── type: core$Float
    │   │       │       ├── target: this #41 : shapes$Vec2
    │   │       │       └── field: x (slot 0)
    │   │       └── right > op:
    │   │           ├── type: core$Float
    │   │           ├── op: *
    │   │           ├── impl: * #61
    │   │           ├── left > field:
    │   │           │   ├── type: core$Float
    │   │           │   ├── target: this #41 : shapes$Vec2
    │   │           │   └── field: y (slot 1)
    │   │           └── right > field:
    │   │               ├── type: core$Float
    │   │               ├── target: this #41 : shapes$Vec2
    │   │               └── field: y (slot 1)
    │   ├── decls[7] > verb:
    │   │   ├── signature: core$Unit scale(this shapes$Vec2, core$Float) mut #16
    │   │   ├── params[0]: this #42 : shapes$Vec2
    │   │   ├── params[1]: by #43 : core$Float
    │   │   ├── body[0] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #42 : shapes$Vec2
    │   │   │   │   └── field: x (slot 0)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #61
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #42 : shapes$Vec2
    │   │   │       │   └── field: x (slot 0)
    │   │   │       └── right: by #43 : core$Float
    │   │   ├── body[1] > assign:
    │   │   │   ├── target > field:
    │   │   │   │   ├── type: core$Float
    │   │   │   │   ├── target: this #42 : shapes$Vec2
    │   │   │   │   └── field: y (slot 1)
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Float
    │   │   │       ├── op: *
    │   │   │       ├── impl: * #61
    │   │   │       ├── left > field:
    │   │   │       │   ├── type: core$Float
    │   │   │       │   ├── target: this #42 : shapes$Vec2
    │   │   │       │   └── field: y (slot 1)
    │   │   │       └── right: by #43 : core$Float
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[8] > verb:
    │   │   ├── signature: implicit Vec2(@concepts$Number) #17
    │   │   ├── params[0]: value #44 : @concepts$Number
    │   │   └── body[0] > return > init:
    │   │       ├── type: shapes$Vec2
    │   │       ├── fields[0] > field:
    │   │       │   ├── name: x (slot 0)
    │   │       │   └── value > construct:
    │   │       │       ├── type: core$Float
    │   │       │       ├── ctor: Float #58
    │   │       │       └── args[0]: value #44 : @concepts$Number
    │   │       └── fields[1] > field:
    │   │           ├── name: y (slot 1)
    │   │           └── value > construct:
    │   │               ├── type: core$Float
    │   │               ├── ctor: Float #58
    │   │               └── args[0]: value #44 : @concepts$Number
    │   ├── decls[9] > type:
    │   │   ├── name: Shape #18
    │   │   ├── kind: reference
    │   │   ├── variant[0]: circle : core$Float
    │   │   ├── variant[1]: square : core$Float
    │   │   └── variant[2]: point : shapes$Vec2
    │   ├── decls[10] > type:
    │   │   ├── name: Corner #19
    │   │   ├── kind: value
    │   │   ├── enum[0]: topLeft
    │   │   ├── enum[1]: topRight
    │   │   ├── enum[2]: bottomLeft
    │   │   └── enum[3]: bottomRight
    │   ├── decls[11] > enum_map:
    │   │   ├── map: shapes$Corner.label #20
    │   │   ├── type: core$String
    │   │   ├── entries[0]:
    │   │   │   ├── member: topLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #67
    │   │   │       └── value: "top left" : @concepts$Text
    │   │   ├── entries[1]:
    │   │   │   ├── member: topRight
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #67
    │   │   │       └── value: "top right" : @concepts$Text
    │   │   ├── entries[2]:
    │   │   │   ├── member: bottomLeft
    │   │   │   └── value > coerce:
    │   │   │       ├── type: core$String
    │   │   │       ├── ctor: String #67
    │   │   │       └── value: "bottom left" : @concepts$Text
    │   │   └── entries[3]:
    │   │       ├── member: bottomRight
    │   │       └── value > coerce:
    │   │           ├── type: core$String
    │   │           ├── ctor: String #67
    │   │           └── value: "bottom right" : @concepts$Text
    │   ├── decls[12] > verb:
    │   │   ├── signature: core$Float _half(core$Float) #21
    │   │   ├── params[0]: value #45 : core$Float
    │   │   └── body[0] > return > op:
    │   │       ├── type: core$Float
    │   │       ├── op: /
    │   │       ├── impl: / #62
    │   │       ├── left: value #45 : core$Float
    │   │       └── right > construct:
    │   │           ├── type: core$Float
    │   │           ├── ctor: Float #58
    │   │           └── args[0]: 2 : @concepts$Number
    │   └── decls[13] > verb:
    │       ├── signature: core$Float area(shapes$Shape) #22
    │       ├── params[0]: shape #46 : shapes$Shape
    │       └── body[0] > return > match:
    │           ├── type: core$Float
    │           ├── scrutinees[0]: shape #46 : shapes$Shape
    │           ├── arms[0] > arm:
    │           │   ├── patterns[0]: r #47 : core$Float <- circle
    │           │   └── body[0] > return > op:
    │           │       ├── type: core$Float
    │           │       ├── op: *
    │           │       ├── impl: * #61
    │           │       ├── left: r #47 : core$Float
    │           │       └── right: r #47 : core$Float
    │           ├── arms[1] > arm:
    │           │   ├── patterns[0]: s #48 : core$Float <- square
    │           │   └── body[0] > return > call:
    │           │       ├── type: core$Float
    │           │       ├── callee: _half #21
    │           │       └── args[0] > op:
    │           │           ├── type: core$Float
    │           │           ├── op: +
    │           │           ├── impl: + #60
    │           │           ├── left: s #48 : core$Float
    │           │           └── right: s #48 : core$Float
    │           └── arms[2] > arm:
    │               ├── patterns[0]: point
    │               └── body[0] > return > construct:
    │                   ├── type: core$Float
    │                   ├── ctor: Float #58
    │                   └── args[0]: 0 : @concepts$Number
    ├── packages[2] > package:
    │   ├── name: core
    │   ├── decls[0] > type:
    │   │   ├── name: Bool #23
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Bool
    │   ├── decls[1] > verb:
    │   │   ├── signature: implicit Bool(@primitives$Bool) #24
    │   │   ├── params[0]: raw #49 : @primitives$Bool
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Bool
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #49 : @primitives$Bool
    │   ├── decls[2] > verb:
    │   │   ├── signature: implicit @primitives$Bool(core$Bool) #25
    │   │   ├── params[0]: value #50 : core$Bool
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Bool
    │   │       ├── target: value #50 : core$Bool
    │   │       └── field: raw (slot 0)
    │   ├── decls[3] > verb:
    │   │   ├── signature: core$Bool *(core$Bool, core$Bool) #26
    │   │   ├── params[0]: left #51 : core$Bool
    │   │   ├── params[1]: right #52 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #51 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #52 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[4] > verb:
    │   │   ├── signature: core$Bool +(core$Bool, core$Bool) #27
    │   │   ├── params[0]: left #53 : core$Bool
    │   │   ├── params[1]: right #54 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #53 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #54 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[5] > verb:
    │   │   ├── signature: core$Bool ==(core$Bool, core$Bool) #28
    │   │   ├── params[0]: left #55 : core$Bool
    │   │   ├── params[1]: right #56 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Bool
    │   │           │   ├── target: left #55 : core$Bool
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: right #56 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[6] > verb:
    │   │   ├── signature: core$Bool ~(core$Bool) #29
    │   │   ├── params[0]: value #57 : core$Bool
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Bool
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Bool
    │   │               ├── target: value #57 : core$Bool
    │   │               └── field: raw (slot 0)
    │   ├── decls[7] > type:
    │   │   ├── name: Console #30
    │   │   ├── kind: reference
    │   │   └── struct[0]: _console : &@runtime$Console
    │   ├── decls[8] > verb:
    │   │   ├── signature: Console(&@runtime$Console) #31
    │   │   ├── params[0]: console #58 : &@runtime$Console
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Console
    │   │       └── fields[0] > field:
    │   │           ├── name: _console (slot 0)
    │   │           └── value: console #58 : &@runtime$Console
    │   ├── decls[9] > verb:
    │   │   ├── signature: core$Unit print(this core$Console, core$String) mut #32
    │   │   ├── params[0]: this #59 : core$Console
    │   │   ├── params[1]: text #60 : core$String
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @runtime$print
    │   │   │   ├── args[0] > field:
    │   │   │   │   ├── type: &@runtime$Console
    │   │   │   │   ├── target: this #59 : core$Console
    │   │   │   │   └── field: _console (slot 0)
    │   │   │   └── args[1] > field:
    │   │   │       ├── type: @primitives$String
    │   │   │       ├── target: text #60 : core$String
    │   │   │       └── field: raw (slot 0)
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[10] > type:
    │   │   ├── name: Array #33
    │   │   ├── params: T Type, n Number
    │   │   ├── kind: value
    │   │   └── struct[0]: _items : @primitives$Array<T, n>
    │   ├── decls[11] > verb:
    │   │   ├── signature: Array(@concepts$Array<T, n>) #34
    │   │   └── body: checked per instance
    │   ├── decls[12] > subscript:
    │   │   ├── signature: (this core$Array<T, n>)[core$Int] #35
    │   │   └── body: checked per instance
    │   ├── decls[13] > verb:
    │   │   ├── signature: core$Int size(this core$Array<T, n>) #36
    │   │   └── body: checked per instance
    │   ├── decls[14] > type:
    │   │   ├── name: List #37
    │   │   ├── params: T Type
    │   │   ├── kind: reference
    │   │   └── struct[0]: _items : @primitives$List<T>
    │   ├── decls[15] > verb:
    │   │   ├── signature: List(T Type) #38
    │   │   └── body: checked per instance
    │   ├── decls[16] > verb:
    │   │   ├── signature: core$Unit push(this core$List<T>, T) mut #39
    │   │   └── body: checked per instance
    │   ├── decls[17] > verb:
    │   │   ├── signature: core$Int size(this core$List<T>) #40
    │   │   └── body: checked per instance
    │   ├── decls[18] > subscript:
    │   │   ├── signature: (this core$List<T>)[core$Int] #41
    │   │   └── body: checked per instance
    │   ├── decls[19] > verb:
    │   │   ├── signature: core$Bool if(core$Bool, @concepts$Block) #42
    │   │   ├── params[0]: condition #61 : core$Bool
    │   │   ├── params[1]: body #62 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #25
    │   │   │   │   └── value: condition #61 : core$Bool
    │   │   │   └── args[1]: body #62 : @concepts$Block
    │   │   └── body[1] > return: condition #61 : core$Bool
    │   ├── decls[20] > verb:
    │   │   ├── signature: core$Unit elif(this core$Bool, core$Bool, @concepts$Block) mut #43
    │   │   ├── params[0]: this #63 : core$Bool
    │   │   ├── params[1]: condition #64 : core$Bool
    │   │   ├── params[2]: body #65 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #25
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── op: *
    │   │   │   │       ├── impl: * #26
    │   │   │   │       ├── left > flip:
    │   │   │   │       │   ├── type: core$Bool
    │   │   │   │       │   ├── impl: ~ #29
    │   │   │   │       │   └── value: this #63 : core$Bool
    │   │   │   │       └── right: condition #64 : core$Bool
    │   │   │   └── args[1]: body #65 : @concepts$Block
    │   │   ├── body[1] > assign:
    │   │   │   ├── target: this #63 : core$Bool
    │   │   │   └── value > op:
    │   │   │       ├── type: core$Bool
    │   │   │       ├── op: +
    │   │   │       ├── impl: + #27
    │   │   │       ├── left: this #63 : core$Bool
    │   │   │       └── right: condition #64 : core$Bool
    │   │   └── body[2] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[21] > verb:
    │   │   ├── signature: core$Unit else(this core$Bool, @concepts$Block) #44
    │   │   ├── params[0]: this #66 : core$Bool
    │   │   ├── params[1]: body #67 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #25
    │   │   │   │   └── value > flip:
    │   │   │   │       ├── type: core$Bool
    │   │   │   │       ├── impl: ~ #29
    │   │   │   │       └── value: this #66 : core$Bool
    │   │   │   └── args[1]: body #67 : @concepts$Block
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[22] > verb:
    │   │   ├── signature: core$Unit guard(core$Bool) #45
    │   │   ├── params[0]: condition #68 : core$Bool
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$branch
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Bool
    │   │   │   │   ├── ctor: @primitives$Bool #25
    │   │   │   │   └── value: condition #68 : core$Bool
    │   │   │   └── args[1] > block[0] > do > call:
    │   │   │       ├── type: @primitives$Unit
    │   │   │       ├── callee: @controlflow$exitFromCall
    │   │   │       └── args:
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[23] > verb:
    │   │   ├── signature: core$Unit to(this core$Int, core$Int, @concepts$Block) mut #46
    │   │   ├── params[0]: this #69 : core$Int
    │   │   ├── params[1]: end #70 : core$Int
    │   │   ├── params[2]: body #71 : @concepts$Block
    │   │   ├── body[0] > do > call:
    │   │   │   ├── type: @primitives$Unit
    │   │   │   ├── callee: @controlflow$repeat
    │   │   │   ├── args[0] > coerce:
    │   │   │   │   ├── type: @primitives$Int
    │   │   │   │   ├── ctor: @primitives$Int #50
    │   │   │   │   └── value > op:
    │   │   │   │       ├── type: core$Int
    │   │   │   │       ├── op: +
    │   │   │   │       ├── impl: + #51
    │   │   │   │       ├── left > op:
    │   │   │   │       │   ├── type: core$Int
    │   │   │   │       │   ├── op: +
    │   │   │   │       │   ├── impl: + #51
    │   │   │   │       │   ├── left: end #70 : core$Int
    │   │   │   │       │   └── right > flip:
    │   │   │   │       │       ├── type: core$Int
    │   │   │   │       │       ├── impl: ~ #54
    │   │   │   │       │       └── value: this #69 : core$Int
    │   │   │   │       └── right > construct:
    │   │   │   │           ├── type: core$Int
    │   │   │   │           ├── ctor: Int #48
    │   │   │   │           └── args[0]: 1 : @concepts$Number
    │   │   │   ├── args[1] > block[0] > do > call:
    │   │   │   │   ├── type: @primitives$Unit
    │   │   │   │   ├── callee: @controlflow$branch
    │   │   │   │   ├── args[0]: true : @primitives$Bool
    │   │   │   │   └── args[1]: body #71 : @concepts$Block
    │   │   │   └── args[1] > block[1] > assign:
    │   │   │       ├── target: this #69 : core$Int
    │   │   │       └── value > op:
    │   │   │           ├── type: core$Int
    │   │   │           ├── op: +
    │   │   │           ├── impl: + #51
    │   │   │           ├── left: this #69 : core$Int
    │   │   │           └── right > construct:
    │   │   │               ├── type: core$Int
    │   │   │               ├── ctor: Int #48
    │   │   │               └── args[0]: 1 : @concepts$Number
    │   │   └── body[1] > return > construct:
    │   │       ├── type: core$Unit
    │   │       ├── ctor: Unit #72
    │   │       └── args:
    │   ├── decls[24] > type:
    │   │   ├── name: Int #47
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Int
    │   ├── decls[25] > verb:
    │   │   ├── signature: implicit Int(@concepts$Number) #48
    │   │   ├── params[0]: value #72 : @concepts$Number
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Int
    │   │               ├── ctor: @primitives$Int
    │   │               └── args[0]: value #72 : @concepts$Number
    │   ├── decls[26] > verb:
    │   │   ├── signature: implicit Int(@primitives$Int) #49
    │   │   ├── params[0]: raw #73 : @primitives$Int
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Int
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #73 : @primitives$Int
    │   ├── decls[27] > verb:
    │   │   ├── signature: implicit @primitives$Int(core$Int) #50
    │   │   ├── params[0]: value #74 : core$Int
    │   │   └── body[0] > return > field:
    │   │       ├── type: @primitives$Int
    │   │       ├── target: value #74 : core$Int
    │   │       └── field: raw (slot 0)
    │   ├── decls[28] > verb:
    │   │   ├── signature: core$Int +(core$Int, core$Int) #51
    │   │   ├── params[0]: left #75 : core$Int
    │   │   ├── params[1]: right #76 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #49
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #75 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #76 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[29] > verb:
    │   │   ├── signature: core$Int *(core$Int, core$Int) #52
    │   │   ├── params[0]: left #77 : core$Int
    │   │   ├── params[1]: right #78 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #49
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #77 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #78 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[30] > verb:
    │   │   ├── signature: core$Int /(core$Int, core$Int) #53
    │   │   ├── params[0]: left #79 : core$Int
    │   │   ├── params[1]: right #80 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #49
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Int
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #79 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #80 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[31] > verb:
    │   │   ├── signature: core$Int ~(core$Int) #54
    │   │   ├── params[0]: value #81 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Int
    │   │       ├── ctor: Int #49
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Int
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: value #81 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[32] > verb:
    │   │   ├── signature: core$Bool ==(core$Int, core$Int) #55
    │   │   ├── params[0]: left #82 : core$Int
    │   │   ├── params[1]: right #83 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #82 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #83 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[33] > verb:
    │   │   ├── signature: core$Bool <(core$Int, core$Int) #56
    │   │   ├── params[0]: left #84 : core$Int
    │   │   ├── params[1]: right #85 : core$Int
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Int
    │   │           │   ├── target: left #84 : core$Int
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Int
    │   │               ├── target: right #85 : core$Int
    │   │               └── field: raw (slot 0)
    │   ├── decls[34] > type:
    │   │   ├── name: Float #57
    │   │   ├── kind: value
    │   │   └── struct[0]: raw : @primitives$Float
    │   ├── decls[35] > verb:
    │   │   ├── signature: implicit Float(@concepts$Number) #58
    │   │   ├── params[0]: value #86 : @concepts$Number
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$Float
    │   │               ├── ctor: @primitives$Float
    │   │               └── args[0]: value #86 : @concepts$Number
    │   ├── decls[36] > verb:
    │   │   ├── signature: implicit Float(@primitives$Float) #59
    │   │   ├── params[0]: raw #87 : @primitives$Float
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Float
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #87 : @primitives$Float
    │   ├── decls[37] > verb:
    │   │   ├── signature: core$Float +(core$Float, core$Float) #60
    │   │   ├── params[0]: left #88 : core$Float
    │   │   ├── params[1]: right #89 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #59
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #88 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #89 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[38] > verb:
    │   │   ├── signature: core$Float *(core$Float, core$Float) #61
    │   │   ├── params[0]: left #90 : core$Float
    │   │   ├── params[1]: right #91 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #59
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: *
    │   │           ├── impl: @primitives$*
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #90 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #91 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[39] > verb:
    │   │   ├── signature: core$Float /(core$Float, core$Float) #62
    │   │   ├── params[0]: left #92 : core$Float
    │   │   ├── params[1]: right #93 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #59
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Float
    │   │           ├── op: /
    │   │           ├── impl: @primitives$/
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #92 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #93 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[40] > verb:
    │   │   ├── signature: core$Float ~(core$Float) #63
    │   │   ├── params[0]: value #94 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Float
    │   │       ├── ctor: Float #59
    │   │       └── args[0] > flip:
    │   │           ├── type: @primitives$Float
    │   │           ├── impl: @primitives$~
    │   │           └── value > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: value #94 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[41] > verb:
    │   │   ├── signature: core$Bool ==(core$Float, core$Float) #64
    │   │   ├── params[0]: left #95 : core$Float
    │   │   ├── params[1]: right #96 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #95 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #96 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[42] > verb:
    │   │   ├── signature: core$Bool <(core$Float, core$Float) #65
    │   │   ├── params[0]: left #97 : core$Float
    │   │   ├── params[1]: right #98 : core$Float
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: <
    │   │           ├── impl: @primitives$<
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$Float
    │   │           │   ├── target: left #97 : core$Float
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$Float
    │   │               ├── target: right #98 : core$Float
    │   │               └── field: raw (slot 0)
    │   ├── decls[43] > type:
    │   │   ├── name: String #66
    │   │   ├── kind: reference
    │   │   └── struct[0]: raw : @primitives$String
    │   ├── decls[44] > verb:
    │   │   ├── signature: implicit String(@concepts$Text) #67
    │   │   ├── params[0]: value #99 : @concepts$Text
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value > construct:
    │   │               ├── type: @primitives$String
    │   │               ├── ctor: @primitives$String
    │   │               └── args[0]: value #99 : @concepts$Text
    │   ├── decls[45] > verb:
    │   │   ├── signature: String(@primitives$String) #68
    │   │   ├── params[0]: raw #100 : @primitives$String
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$String
    │   │       └── fields[0] > field:
    │   │           ├── name: raw (slot 0)
    │   │           └── value: raw #100 : @primitives$String
    │   ├── decls[46] > verb:
    │   │   ├── signature: core$String +(core$String, core$String) #69
    │   │   ├── params[0]: left #101 : core$String
    │   │   ├── params[1]: right #102 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$String
    │   │       ├── ctor: String #68
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$String
    │   │           ├── op: +
    │   │           ├── impl: @primitives$+
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #101 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #102 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[47] > verb:
    │   │   ├── signature: core$Bool ==(core$String, core$String) #70
    │   │   ├── params[0]: left #103 : core$String
    │   │   ├── params[1]: right #104 : core$String
    │   │   └── body[0] > return > construct:
    │   │       ├── type: core$Bool
    │   │       ├── ctor: Bool #24
    │   │       └── args[0] > op:
    │   │           ├── type: @primitives$Bool
    │   │           ├── op: ==
    │   │           ├── impl: @primitives$==
    │   │           ├── left > field:
    │   │           │   ├── type: @primitives$String
    │   │           │   ├── target: left #103 : core$String
    │   │           │   └── field: raw (slot 0)
    │   │           └── right > field:
    │   │               ├── type: @primitives$String
    │   │               ├── target: right #104 : core$String
    │   │               └── field: raw (slot 0)
    │   ├── decls[48] > type:
    │   │   ├── name: Unit #71
    │   │   ├── kind: value
    │   │   └── struct:
    │   ├── decls[49] > verb:
    │   │   ├── signature: Unit() #72
    │   │   ├── params:
    │   │   └── body[0] > return > init:
    │   │       ├── type: core$Unit
    │   │       └── fields:
    │   └── decls[50] > verb:
    │       ├── signature: implicit Unit(@primitives$Unit) #73
    │       ├── params[0]: value #105 : @primitives$Unit
    │       └── body[0] > return > init:
    │           ├── type: core$Unit
    │           └── fields:
    ├── instances[0] > instance:
    │   ├── of: pick #1 with T = core$Int
    │   ├── params[0]: first #106 : core$Int
    │   ├── params[1]: second #107 : core$Int
    │   ├── params[2]: takeFirst #108 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #109 : core$Int
    │   │   └── value: second #107 : core$Int
    │   ├── body[1] > let:
    │   │   ├── local: ran #110 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #42
    │   │       ├── args[0]: takeFirst #108 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #109 : core$Int
    │   │           └── value: first #106 : core$Int
    │   └── body[2] > return: chosen #109 : core$Int
    ├── instances[1] > instance:
    │   ├── of: pick #1 with T = core$String
    │   ├── params[0]: first #111 : core$String
    │   ├── params[1]: second #112 : core$String
    │   ├── params[2]: takeFirst #113 : core$Bool
    │   ├── body[0] > let:
    │   │   ├── local: chosen #114 : core$String
    │   │   └── value: second #112 : core$String
    │   ├── body[1] > let:
    │   │   ├── local: ran #115 : core$Bool
    │   │   └── value > call:
    │   │       ├── type: core$Bool
    │   │       ├── callee: if #42
    │   │       ├── args[0]: takeFirst #113 : core$Bool
    │   │       └── args[1] > block[0] > assign:
    │   │           ├── target: chosen #114 : core$String
    │   │           └── value: first #111 : core$String
    │   └── body[2] > return: chosen #114 : core$String
    ├── instances[2] > instance:
    │   ├── of: Pair #3 with T = core$Float
    │   ├── params[0]: left #119 : core$Float
    │   ├── params[1]: right #120 : core$Float
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Float>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #119 : core$Float
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #120 : core$Float
    ├── instances[3] > instance:
    │   ├── of: Pair #3 with T = core$Int
    │   ├── params[0]: left #116 : core$Int
    │   ├── params[1]: right #117 : core$Int
    │   └── body[0] > return > init:
    │       ├── type: app$Pair<core$Int>
    │       ├── fields[0] > field:
    │       │   ├── name: left (slot 0)
    │       │   └── value: left #116 : core$Int
    │       └── fields[1] > field:
    │           ├── name: right (slot 1)
    │           └── value: right #117 : core$Int
    ├── instances[4] > instance:
    │   ├── of: sum #4 with T = core$Float
    │   ├── params[0]: pair #121 : app$Pair<core$Float>
    │   └── body[0] > return > op:
    │       ├── type: core$Float
    │       ├── op: +
    │       ├── impl: + #60
    │       ├── left > field:
    │       │   ├── type: core$Float
    │       │   ├── target: pair #121 : app$Pair<core$Float>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Float
    │           ├── target: pair #121 : app$Pair<core$Float>
    │           └── field: right (slot 1)
    ├── instances[5] > instance:
    │   ├── of: sum #4 with T = core$Int
    │   ├── params[0]: pair #118 : app$Pair<core$Int>
    │   └── body[0] > return > op:
    │       ├── type: core$Int
    │       ├── op: +
    │       ├── impl: + #51
    │       ├── left > field:
    │       │   ├── type: core$Int
    │       │   ├── target: pair #118 : app$Pair<core$Int>
    │       │   └── field: left (slot 0)
    │       └── right > field:
    │           ├── type: core$Int
    │           ├── target: pair #118 : app$Pair<core$Int>
    │           └── field: right (slot 1)
    ├── instances[6] > instance:
    │   ├── of: count #5 with T = core$Int, n = 3
    │   ├── params[0]: values #123 : core$Array<core$Int, 3>
    │   └── body[0] > return > construct:
    │       ├── type: core$Int
    │       ├── ctor: Int #48
    │       └── args[0]: n = 3 : @concepts$Number
    ├── instances[7] > instance:
    │   ├── of: Array #34 with T = core$Int, n = 3
    │   ├── params[0]: values #122 : @concepts$Array<core$Int, 3>
    │   └── body[0] > return > init:
    │       ├── type: core$Array<core$Int, 3>
    │       └── fields[0] > field:
    │           ├── name: _items (slot 0)
    │           └── value > construct:
    │               ├── type: @primitives$Array<core$Int, 3>
    │               ├── ctor: @primitives$Array with T = core$Int, n = 3
    │               └── args[0]: values #122 : @concepts$Array<core$Int, 3>
    └── instances[8] > instance:
        ├── of: [] #35 with T = core$Int, n = 3
        ├── params[0]: this #21 : core$Array<core$Int, 3>
        ├── params[1]: index #22 : core$Int
        └── body[0] > return > subscript:
            ├── type: core$Int
            ├── impl: @primitives$[] with T = core$Int, n = 3
            ├── target > field:
            │   ├── type: @primitives$Array<core$Int, 3>
            │   ├── target: this #21 : core$Array<core$Int, 3>
            │   └── field: _items (slot 0)
            └── args[0] > coerce:
                ├── type: @primitives$Int
                ├── ctor: @primitives$Int #50
                └── value: index #22 : core$Int
