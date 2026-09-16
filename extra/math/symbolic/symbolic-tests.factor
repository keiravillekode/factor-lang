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

! Inverse trigonometric and hyperbolic functions
{ 0 } [ symbolic[ 0 asin ] ] unit-test
{ "pi/2" } [ symbolic[ 1 asin ] expr>string ] unit-test
{ "-pi/2" } [ symbolic[ -1 asin ] expr>string ] unit-test
{ "pi/2" } [ symbolic[ 0 acos ] expr>string ] unit-test
{ 0 } [ symbolic[ 1 acos ] ] unit-test
{ "pi" } [ symbolic[ -1 acos ] expr>string ] unit-test
{ "pi/4" } [ symbolic[ 1 atan ] expr>string ] unit-test
{ 0 } [ symbolic[ 0 sinh ] ] unit-test
{ 1 } [ symbolic[ 0 cosh ] ] unit-test
{ 0 } [ symbolic[ 0 tanh ] ] unit-test
{ 0 } [ symbolic[ 1 acosh ] ] unit-test
{ "-asin(x)" } [ symbolic[ x neg asin ] expr>string ] unit-test
{ "-acos(x) + pi" } [ symbolic[ x neg acos ] expr>string ] unit-test
{ "-sinh(x)" } [ symbolic[ x neg sinh ] expr>string ] unit-test
{ "cosh(x)" } [ symbolic[ x neg cosh ] expr>string ] unit-test
{ "-atanh(x)" } [ symbolic[ x neg atanh ] expr>string ] unit-test
{ "x" } [ symbolic[ x asin sin ] expr>string ] unit-test
{ "x" } [ symbolic[ x atan tan ] expr>string ] unit-test
{ "x" } [ symbolic[ x asinh sinh ] expr>string ] unit-test
{ "x" } [ symbolic[ x sinh asinh ] expr>string ] unit-test
{ "asin(sin(x))" } [ symbolic[ x sin asin ] expr>string ] unit-test
{ "tanh(atanh(x) + 1)" } [ symbolic[ x atanh 1 + tanh ] expr>string ] unit-test
{ t } [ symbolic[ 0.5 asin ] symbolic[ pi 6 / ] evalf 1e-12 ~ ] unit-test
{ t } [ symbolic[ 1.0 cosh ] 1.5430806348152437 1e-12 ~ ] unit-test

! Infinity and unevaluated limits
{ "inf" } [ symbolic[ inf ] expr>string ] unit-test
{ "-inf" } [ symbolic[ inf neg ] expr>string ] unit-test
{ t } [ symbolic[ inf ] infinite? ] unit-test
{ t } [ symbolic[ inf neg ] infinite? ] unit-test
{ f } [ symbolic[ x ] infinite? ] unit-test
{ "limit(x*log(x), x, 0)" } [ symbolic[ x x log * x 0 limit ] expr>string ] unit-test
{ "symbolic[ x x log * x 0 limit ]" } [ symbolic[ x x log * x 0 limit ] unparse ] unit-test
{ t } [ symbolic[ x 1 + ] defined? ] unit-test
{ f } [ symbolic[ 1 0 / ] defined? ] unit-test
{ f } [ symbolic[ 0 log ] defined? ] unit-test
{ f } [ symbolic[ inf ] defined? ] unit-test

! Exact values at multiples of pi/6 and pi/4
{ 1/2 } [ symbolic[ pi 6 / sin ] ] unit-test
{ "sqrt(3)/2" } [ symbolic[ pi 6 / cos ] expr>string ] unit-test
{ "1/sqrt(3)" } [ symbolic[ pi 6 / tan ] expr>string ] unit-test
{ "sqrt(3)/2" } [ symbolic[ pi 3 / sin ] expr>string ] unit-test
{ 1/2 } [ symbolic[ pi 3 / cos ] ] unit-test
{ "sqrt(3)" } [ symbolic[ pi 3 / tan ] expr>string ] unit-test
{ "sqrt(3)/2" } [ symbolic[ 2 pi * 3 / sin ] expr>string ] unit-test
{ -1/2 } [ symbolic[ 2 pi * 3 / cos ] ] unit-test
{ -1/2 } [ symbolic[ 7 pi * 6 / sin ] ] unit-test
{ -1/2 } [ symbolic[ pi 6 / neg sin ] ] unit-test
{ "sqrt(3)/2" } [ symbolic[ pi 6 / neg cos ] expr>string ] unit-test
{ "tan(pi/2)" } [ symbolic[ pi 2 / tan ] expr>string ] unit-test
{ 1 } [ symbolic[ pi 6 / sin 2 ^ pi 6 / cos 2 ^ + ] ] unit-test
{ t } [ symbolic[ pi 3 / sin ] evalf 3 sqrt 2 / 1e-12 ~ ] unit-test

! The inverses give the same angles
{ "pi/6" } [ symbolic[ 1 2 / asin ] expr>string ] unit-test
{ "pi/3" } [ symbolic[ 1 2 / acos ] expr>string ] unit-test
{ "pi/6" } [ symbolic[ 3 sqrt 2 / acos ] expr>string ] unit-test
{ "pi/3" } [ symbolic[ 3 sqrt 2 / asin ] expr>string ] unit-test
{ "pi/6" } [ symbolic[ 1 3 sqrt / atan ] expr>string ] unit-test
{ "pi/3" } [ symbolic[ 3 sqrt atan ] expr>string ] unit-test
{ "pi/4" } [ symbolic[ 1 2 sqrt / asin ] expr>string ] unit-test
{ "-pi/6" } [ symbolic[ 1 2 / neg asin ] expr>string ] unit-test
{ "2*pi/3" } [ symbolic[ 1 2 / neg acos ] expr>string ] unit-test
{ "-pi/3" } [ symbolic[ 3 sqrt neg atan ] expr>string ] unit-test

! Square roots of perfect squares
{ 3 } [ symbolic[ 9 sqrt ] ] unit-test
{ 2/3 } [ symbolic[ 4 9 / sqrt ] ] unit-test
{ "3*sqrt(pi)" } [ symbolic[ 9 pi * sqrt ] expr>string ] unit-test
{ "sqrt(2)" } [ symbolic[ 2 sqrt ] expr>string ] unit-test
{ "2*sqrt(x)" } [ symbolic[ 4 x * sqrt ] expr>string ] unit-test

! The gamma function
{ 24 } [ symbolic[ 5 gamma ] ] unit-test
{ 1 } [ symbolic[ 1 gamma ] ] unit-test
{ 720 } [ symbolic[ 7 gamma ] ] unit-test
{ "sqrt(pi)" } [ symbolic[ 1 2 / gamma ] expr>string ] unit-test
{ "sqrt(pi)/2" } [ symbolic[ 3 2 / gamma ] expr>string ] unit-test
{ "3*sqrt(pi)/4" } [ symbolic[ 5 2 / gamma ] expr>string ] unit-test
{ "gamma(x)" } [ symbolic[ x gamma ] expr>string ] unit-test
{ "gamma(-1/2)" } [ symbolic[ 1 2 / neg gamma ] expr>string ] unit-test
{ t } [ symbolic[ 5.5 gamma ] 52.34277778455352 1e-6 ~ ] unit-test
{ t } [ symbolic[ 4 gamma ] evalf 6.0 1e-9 ~ ] unit-test

! 0^p folds to 0 for positive p, ratio exponents included
{ 0 } [ symbolic[ 0 3/2 ^ ] ] unit-test
{ 0 } [ symbolic[ 0 1/2 ^ ] ] unit-test
{ 0 } [ symbolic[ 0 sqrt ] ] unit-test
{ 1 } [ symbolic[ 0 0 ^ ] ] unit-test
! Negative powers of 0 are left unevaluated
{ t } [ symbolic[ 0 -1 ^ ] pow? ] unit-test
{ t } [ symbolic[ 0 -3/2 ^ ] pow? ] unit-test
