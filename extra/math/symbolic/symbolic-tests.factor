! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: eval generalizations kernel math math.functions
math.symbolic prettyprint sequences tools.test ;
IN: math.symbolic.tests

! Simplification and printing
{ "2*x" } [ symbolic[ x x + ] expr>string ] unit-test
{ "x^3" } [ symbolic[ x x * x * ] expr>string ] unit-test
{ 0 } [ symbolic[ x x - ] ] unit-test
{ "6*x" } [ symbolic[ 2 3 x * * ] expr>string ] unit-test
{ "x" } [ symbolic[ x 2 ^ x / ] expr>string ] unit-test
{ 5/6 } [ symbolic[ 1 2 / 1 3 / + ] ] unit-test
{ "x^2 - 3*x + 1" } [ symbolic[ 1 x 3 * - x 2 ^ + ] expr>string ] unit-test
{ "-x" } [ symbolic[ x neg ] expr>string ] unit-test
{ "x/2" } [ symbolic[ x 2 / ] expr>string ] unit-test
{ "1/x" } [ symbolic[ 1 x / ] expr>string ] unit-test
{ "2/(3*x)" } [ symbolic[ 2 3 x * / ] expr>string ] unit-test
{ "sqrt(x)" } [ symbolic[ x sqrt ] expr>string ] unit-test
{ "(x + 1)^2" } [ symbolic[ x 1 + 2 ^ ] expr>string ] unit-test
{ "x + 3*sin(x) + 4*exp(y)" } [ symbolic[ 3 x sin * x + 4 y exp * + ] expr>string ] unit-test

! Expansion
{ "x^2 + 2*x + 1" } [ symbolic[ x 1 + 2 ^ ] expand expr>string ] unit-test
{ "x^2 - y^2" } [ symbolic[ x y + x y - * ] expand expr>string ] unit-test

! Functions
{ -1 } [ symbolic[ 0 sin pi cos + ] ] unit-test
{ 1 } [ symbolic[ pi 2 / sin ] ] unit-test
{ 0 } [ symbolic[ pi 2 / cos ] ] unit-test
{ 0 } [ symbolic[ pi 3 * tan ] ] unit-test
{ "x" } [ symbolic[ x log exp ] expr>string ] unit-test
{ "x" } [ symbolic[ x exp log ] expr>string ] unit-test
{ "-sin(x)" } [ symbolic[ x neg sin ] expr>string ] unit-test
{ "cos(x)" } [ symbolic[ x neg cos ] expr>string ] unit-test
{ "exp(x)" } [ symbolic[ e x ^ ] expr>string ] unit-test
{ "e" } [ symbolic[ 1 exp ] expr>string ] unit-test

! Substitution and evaluation
{ 5 } [ symbolic[ x 2 ^ 1 + ] { { T{ sym f "x" } 2 } } subs ] unit-test
{ "y + sin(y)" } [ symbolic[ x x sin + ] { { T{ sym f "x" } T{ sym f "y" } } } subs expr>string ] unit-test
{ t } [ symbolic[ pi 4 / sin 2 sqrt * ] evalf 1.0 1e-12 ~ ] unit-test
{ t } [ symbolic[ x sin y * ] T{ sym f "z" } free-of? ] unit-test
{ f } [ symbolic[ x sin y * ] T{ sym f "x" } free-of? ] unit-test
[ symbolic[ x 1 + ] evalf ] [ unbound-symbol? ] must-fail-with
[ symbolic[ x x D ] evalf ] [ unevaluated-expression? ] must-fail-with

! Literals
{ "3" "x + sin(x)" "exp(4)" "y" }
[ symbolic[ 3 x sin x + 4 exp y ] [ expr>string ] 4 napply ] unit-test
{ "symbolic[ x 3 x sin * + ]" } [ symbolic[ 3 x sin * x + ] unparse ] unit-test
{ t } [
    symbolic[ x 2 ^ 1 + sin x D ]
    dup unparse "USING: math.symbolic ; " prepend eval( -- expr ) =
] unit-test
{ "D(x^3, x)" } [ symbolic[ x 3 ^ x D ] expr>string ] unit-test
{ "integrate(sin(x), x, 0, pi)" } [ symbolic[ x sin x 0 pi definite-integral ] expr>string ] unit-test
[ "USING: math.symbolic ; symbolic[ + ]" eval( -- expr ) ] must-fail

! Pattern variables
{ "sin(?x)^2" } [ symbolic[ ?x sin 2 ^ ] expr>string ] unit-test
{ "symbolic[ ?x sin ]" } [ symbolic[ ?x sin ] unparse ] unit-test
{ { 2 T{ sym f "x" } T{ pvar f "y" } } } [ { "2" "x" "?y" } parse-symbolic-tokens ] unit-test

! A number times a sum is distributed
{ "2*x + 2" } [ symbolic[ 2 x 1 + * ] expr>string ] unit-test
{ "-x + 1" } [ symbolic[ x 1 - neg ] expr>string ] unit-test
{ 1 } [ symbolic[ e e 1 - - ] ] unit-test
{ "x*(x + 1)" } [ symbolic[ x x 1 + * ] expr>string ] unit-test
{ "-x*(x + 1) + y" } [ symbolic[ y x x 1 + * - ] expr>string ] unit-test
! A subtracted sum is parenthesized, for expressions built from tuples
{ "y - (x + 1)" } [
    T{ add f { T{ sym f "y" } T{ mul f { -1 T{ add f { T{ sym f "x" } 1 } } } } } } expr>string
] unit-test
