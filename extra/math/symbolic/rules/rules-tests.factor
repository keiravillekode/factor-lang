! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: arrays eval kernel math math.symbolic math.symbolic.rules
sequences tools.test ;
IN: math.symbolic.rules.tests

! Built-in rule sets
{ 1 } [ symbolic[ x sin 2 ^ x cos 2 ^ + ] pythagorean-rules rewrite ] unit-test
{ "z + 1" } [ symbolic[ y 1 + sin 2 ^ y 1 + cos 2 ^ + z + ] pythagorean-rules rewrite expr>string ] unit-test
{ 3 } [ symbolic[ 3 x sin 2 ^ * 3 x cos 2 ^ * + ] pythagorean-rules rewrite ] unit-test
{ "cos(y)^2 + sin(x)^2" } [ symbolic[ x sin 2 ^ y cos 2 ^ + ] pythagorean-rules rewrite expr>string ] unit-test
{ "e" } [ symbolic[ x sin 2 ^ x cos 2 ^ + exp ] pythagorean-rules rewrite expr>string ] unit-test
{ "sin(x)/cos(x)" } [ symbolic[ x tan ] trig-rules rewrite expr>string ] unit-test
{ "sin(2*x)" } [ symbolic[ 2 x sin * x cos * ] trig-rules rewrite expr>string ] unit-test
{ "3*log(y) + log(x)" } [ symbolic[ x y 3 ^ * log ] log-expand-rules rewrite expr>string ] unit-test
{ "z*exp(x + y)" } [ symbolic[ x exp y exp * z * ] exp-rules rewrite expr>string ] unit-test
{ "exp(6*x)" } [ symbolic[ x exp 6 ^ ] exp-rules rewrite expr>string ] unit-test

! Matching
{ t } [
    symbolic[ ?x sin ?y * ] symbolic[ z 1 + sin w * ] match
    [ "x" binding symbolic[ z 1 + ] = ] [ "y" binding symbolic[ w ] = ] bi and
] unit-test
{ f } [ symbolic[ ?x sin ?x cos + ] symbolic[ a sin b cos + ] match ] unit-test
{ f } [ symbolic[ ?x sin ] symbolic[ a cos ] match ] unit-test

! User-defined rules
{ "a*c + b*c" } [
    symbolic[ a b + c * ] rule[ ?x ?y + ?z * => ?x ?z * ?y ?z * + ] 1array rewrite expr>string
] unit-test

{ "x^2 + 2*x + y + 1" } [
    symbolic[ x 1 + 2 ^ y + ]
    symbolic[ ?a ?b + ?n ^ ]
    [ [ "a" binding ] [ "b" binding ] [ "n" binding ] tri [ s+ ] dip s^ expand ]
    <rule> 1array rewrite expr>string
] unit-test

{ "2*log(x) + log(x^y)" } [
    symbolic[ x 2 ^ log x y ^ log + ]
    symbolic[ ?a ?n ^ log ] symbolic[ ?n ?a log * ] [ "n" binding integer? ]
    <conditional-rule> 1array rewrite expr>string
] unit-test

{ f } [ symbolic[ x cos ] rule[ ?x sin => 0 ] apply-rule ] unit-test

[ "USING: math.symbolic.rules ; rule[ x y ]" eval( -- rule ) ] must-fail
[ "USING: math.symbolic.rules ; rule[ x y => z ]" eval( -- rule ) ] must-fail
