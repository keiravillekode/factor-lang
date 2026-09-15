! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: effects kernel math math.functions math.symbolic
math.symbolic.compile tools.test words ;
IN: math.symbolic.compile.tests

{ 25 } [
    3 4 symbolic[ x 2 ^ y 2 ^ + ] { T{ sym f "x" } T{ sym f "y" } }
    expr>quot call( x y -- r )
] unit-test

{ 1/8 } [ 2 symbolic[ x -3 ^ ] { T{ sym f "x" } } expr>quot call( x -- r ) ] unit-test

{ 42 } [ symbolic[ 42 ] { } expr>quot call( -- r ) ] unit-test

{ t } [
    3 0.5 symbolic[ x 2 ^ y sin * 1 + ] { T{ sym f "x" } T{ sym f "y" } }
    expr>word execute( x y -- r )
    symbolic[ 3 2 ^ 0.5 sin * 1 + ] evalf 1e-12 ~
] unit-test

{ t } [
    2.0 symbolic[ pi x * sin e x ^ + x log + x tan - ] { T{ sym f "x" } }
    expr>word execute( x -- r )
    symbolic[ pi 2.0 * sin e 2.0 ^ + 2.0 log + 2.0 tan - ] evalf 1e-12 ~
] unit-test

{ ( x y -- result ) } [
    symbolic[ x y * ] { T{ sym f "x" } T{ sym f "y" } } expr>word stack-effect
] unit-test

[ symbolic[ x z + ] { T{ sym f "x" } } expr>quot ] [ unbound-symbol? ] must-fail-with

[ symbolic[ x x D ] { T{ sym f "x" } } expr>quot ] [ not-compilable? ] must-fail-with

! Inverse trigonometric and hyperbolic functions
{ t } [
    0.4 symbolic[ x asin x acos + x atan + ] { T{ sym f "x" } } expr>word execute( x -- r )
    symbolic[ 0.4 asin 0.4 acos + 0.4 atan + ] evalf 1e-12 ~
] unit-test
{ t } [
    0.4 symbolic[ x sinh x cosh + x tanh + ] { T{ sym f "x" } } expr>word execute( x -- r )
    symbolic[ 0.4 sinh 0.4 cosh + 0.4 tanh + ] evalf 1e-12 ~
] unit-test
{ t } [
    1.4 symbolic[ x asinh x acosh + 1 x / atanh + ] { T{ sym f "x" } } expr>word execute( x -- r )
    symbolic[ 1.4 asinh 1.4 acosh + 1 1.4 / atanh + ] evalf 1e-12 ~
] unit-test
