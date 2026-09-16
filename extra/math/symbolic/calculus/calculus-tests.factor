! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: arrays kernel math math.functions math.symbolic
math.symbolic.calculus sequences tools.test ;
IN: math.symbolic.calculus.tests

<PRIVATE

: x-sym ( -- sym ) "x" <sym> ;

! integrate finds an antiderivative whose derivative equals the
! integrand at several points.
:: antiderivative-checks-at? ( integrand points -- ? )
    integrand x-sym integrate :> F
    F x-sym differentiate :> dF
    F integral? not
    points [| v |
        x-sym v 2array 1array :> at-v
        integrand at-v subs evalf dF at-v subs evalf - abs 1e-9 <
    ] all? and ;

! Inside the domain of the inverse functions
CONSTANT: unit-points { 0.2 0.5 0.9 }

: antiderivative-checks? ( integrand -- ? )
    { 0.3 0.7 1.9 } antiderivative-checks-at? ;

PRIVATE>

! Derivatives
{ "3*x^2" } [ symbolic[ x 3 ^ ] x-sym differentiate expr>string ] unit-test
{ "x*cos(x) + sin(x)" } [ symbolic[ x x sin * ] x-sym differentiate expr>string ] unit-test
{ "2*x*exp(x^2)" } [ symbolic[ x 2 ^ exp ] x-sym differentiate expr>string ] unit-test
{ "1/x" } [ symbolic[ x log ] x-sym differentiate expr>string ] unit-test
{ "1/cos(x)^2" } [ symbolic[ x tan ] x-sym differentiate expr>string ] unit-test
{ "x^x*(log(x) + 1)" } [ symbolic[ x x ^ ] x-sym differentiate expr>string ] unit-test
{ 0 } [ symbolic[ y sin ] x-sym differentiate ] unit-test

! Antiderivatives
{ "x^3/3" } [ symbolic[ x 2 ^ ] x-sym integrate expr>string ] unit-test
{ "log(x)" } [ symbolic[ 1 x / ] x-sym integrate expr>string ] unit-test
{ "-cos(2*x)/2" } [ symbolic[ 2 x * sin ] x-sym integrate expr>string ] unit-test
{ "x*exp(x) - exp(x)" } [ symbolic[ x x exp * ] x-sym integrate expr>string ] unit-test
{ "exp(x^2)" } [ symbolic[ 2 x * x 2 ^ exp * ] x-sym integrate expr>string ] unit-test
{ "-log(cos(x))" } [ symbolic[ x tan ] x-sym integrate expr>string ] unit-test
{ "integrate(exp(-x^2), x)" } [ symbolic[ x 2 ^ neg exp ] x-sym integrate expr>string ] unit-test

{ t } [ symbolic[ x 2 ^ x sin * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x 2 ^ x exp * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x x cos * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x exp x sin * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ 3 x * 1 + exp 2 x * cos * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x x log * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x log ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x sin 2 ^ ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x cos 2 ^ ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x sin x cos * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x 1 + 3 ^ ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ 1 2 x * 1 + / ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ 2 x ^ ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x x 2 ^ sin * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x 2 ^ 3 x * + 5 - ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ 3 x * 1 + tan ] antiderivative-checks? ] unit-test

! Definite integrals
{ 2 } [ symbolic[ x sin ] x-sym 0 symbolic[ pi ] definite-integrate ] unit-test
{ 1/3 } [ symbolic[ x 2 ^ ] x-sym 0 1 definite-integrate ] unit-test
{ "e - 1" } [ symbolic[ x exp ] x-sym 0 1 definite-integrate expr>string ] unit-test
{ t } [ symbolic[ x 2 ^ neg exp ] x-sym 0 1 nintegrate 0.7468241328 1e-8 ~ ] unit-test

! Unevaluated expressions
{ "3*x^2" } [ symbolic[ x 3 ^ x D ] doit expr>string ] unit-test
{ 2 } [ symbolic[ x sin x 0 pi definite-integral ] doit ] unit-test
{ "x^3/3 + cos(x)" } [ symbolic[ x 2 ^ x integral x cos + ] doit expr>string ] unit-test

! Leibniz rule
{ 1/2 } [ symbolic[ x y * x 0 1 definite-integral ] "y" <sym> differentiate ] unit-test
{ "2*t*sin(t^2)" } [ symbolic[ x sin x 0 t 2 ^ definite-integral ] "t" <sym> differentiate expr>string ] unit-test

! Gradient and Jacobian
{ "2*x*y" "x^2 + cos(y)" } [
    symbolic[ x 2 ^ y * y sin + ] { T{ sym f "x" } T{ sym f "y" } } gradient
    first2 [ expr>string ] bi@
] unit-test
{ { { "y" "x" } { "cos(x + y)" "cos(x + y)" } } } [
    symbolic[ x y * ] symbolic[ x y + sin ] 2array
    { T{ sym f "x" } T{ sym f "y" } } jacobian [ [ expr>string ] map ] map
] unit-test

! Integration by parts
{ "x*log(x) - integrate(1, x)" } [
    symbolic[ x log ] x-sym 1 by-parts-dv expr>string
] unit-test
{ "-x + x*log(x)" } [ symbolic[ x log ] x-sym 1 by-parts-dv doit expr>string ] unit-test
{ "x*exp(x) - integrate(exp(x), x)" } [
    symbolic[ x x exp * ] x-sym x-sym by-parts-u expr>string
] unit-test
{ "x*exp(x) - exp(x)" } [ symbolic[ x x exp * ] x-sym x-sym by-parts-u doit expr>string ] unit-test
{ "x^2*log(x)/2 - integrate(x/2, x)" } [
    symbolic[ x x log * ] x-sym symbolic[ x log ] by-parts-u expr>string
] unit-test
{ "x*sin(x) - integrate(sin(x), x)" } [
    x-sym x-sym symbolic[ x cos ] by-parts expr>string
] unit-test
{ "3*sin(x)" } [ x-sym 3 symbolic[ x cos ] by-parts expr>string ] unit-test
{ t } [
    symbolic[ x 2 ^ x exp * ] x-sym symbolic[ x 2 ^ ] by-parts-u doit
    x-sym differentiate
    { { T{ sym f "x" } 0.7 } } subs evalf
    symbolic[ 0.7 2 ^ 0.7 exp * ] evalf - abs 1e-9 <
] unit-test
[ symbolic[ x 2 ^ neg exp x * ] x-sym symbolic[ x ] by-parts-u ]
[ no-antiderivative? ] must-fail-with

! Definite integration by parts
{ "e - integrate(1, x, 1, e)" } [
    symbolic[ x log ] x-sym 1 symbolic[ e ] 1 definite-by-parts-dv expr>string
] unit-test
{ 1 } [ symbolic[ x log ] x-sym 1 symbolic[ e ] 1 definite-by-parts-dv doit ] unit-test
{ "e - integrate(exp(x), x, 0, 1)" } [
    symbolic[ x x exp * ] x-sym 0 1 x-sym definite-by-parts-u expr>string
] unit-test
{ 1 } [ symbolic[ x x exp * ] x-sym 0 1 x-sym definite-by-parts-u doit ] unit-test
{ t } [
    x-sym 0 symbolic[ pi ] x-sym symbolic[ x sin ] definite-by-parts doit
    symbolic[ pi ] =
] unit-test

! Inverse trigonometric and hyperbolic derivatives
{ "1/sqrt(-x^2 + 1)" } [ symbolic[ x asin ] x-sym differentiate expr>string ] unit-test
{ "-1/sqrt(-x^2 + 1)" } [ symbolic[ x acos ] x-sym differentiate expr>string ] unit-test
{ "1/(x^2 + 1)" } [ symbolic[ x atan ] x-sym differentiate expr>string ] unit-test
{ "cosh(x)" } [ symbolic[ x sinh ] x-sym differentiate expr>string ] unit-test
{ "sinh(x)" } [ symbolic[ x cosh ] x-sym differentiate expr>string ] unit-test
{ "1/cosh(x)^2" } [ symbolic[ x tanh ] x-sym differentiate expr>string ] unit-test
{ "1/sqrt(x^2 + 1)" } [ symbolic[ x asinh ] x-sym differentiate expr>string ] unit-test
{ "1/sqrt(x^2 - 1)" } [ symbolic[ x acosh ] x-sym differentiate expr>string ] unit-test
{ "1/(-x^2 + 1)" } [ symbolic[ x atanh ] x-sym differentiate expr>string ] unit-test

! Inverse trigonometric and hyperbolic antiderivatives
{ "cosh(x)" } [ symbolic[ x sinh ] x-sym integrate expr>string ] unit-test
{ "cosh(2*x)/2" } [ symbolic[ 2 x * sinh ] x-sym integrate expr>string ] unit-test
{ "log(cosh(x))" } [ symbolic[ x tanh ] x-sym integrate expr>string ] unit-test
{ t } [ symbolic[ x asin ] unit-points antiderivative-checks-at? ] unit-test
{ t } [ symbolic[ x acos ] unit-points antiderivative-checks-at? ] unit-test
{ t } [ symbolic[ x atan ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x sinh ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x cosh ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x tanh ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x asinh ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x atanh ] unit-points antiderivative-checks-at? ] unit-test
{ t } [ symbolic[ 2 x * 1 + atan ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x x sinh * ] antiderivative-checks? ] unit-test
{ t } [ symbolic[ x asin x 2 ^ neg 1 + sqrt / ] unit-points antiderivative-checks-at? ] unit-test

! Definite integrals by symmetry
{ 0 } [ symbolic[ x 3 ^ ] x-sym -1 1 definite-by-symmetry ] unit-test
{ t } [
    symbolic[ 1 x tan + log ] x-sym 0 symbolic[ pi 4 / ] definite-by-symmetry
    symbolic[ pi 2 log * 8 / ] = 
] unit-test
{ t } [
    symbolic[ 1 x tan + log ] x-sym 0 symbolic[ pi 4 / ] definite-by-symmetry evalf
    0.2721982612879503 1e-12 ~
] unit-test
! definite-integrate uses symmetry only when it is symbolically exact
{ 0 } [
    symbolic[ x 2 ^ sin x 1 - neg 2 ^ sin - ] x-sym 0 1 definite-integrate
] unit-test
{ "integrate(log(tan(x) + 1), x, 0, pi/4)" } [
    symbolic[ 1 x tan + log ] x-sym 0 symbolic[ pi 4 / ] definite-integrate expr>string
] unit-test
{ "integrate(exp(-x^2), x, 0, 1)" } [
    symbolic[ x 2 ^ neg exp ] x-sym 0 1 definite-by-symmetry expr>string
] unit-test

! Differentiation under the integral sign
{ 1/3 } [
    symbolic[ t x 2 ^ * x + ] x-sym 0 1 symbolic[ t ] feynman-derivative
] unit-test
{ t } [
    symbolic[ t x 2 ^ * x + ] x-sym 0 1 symbolic[ t ] 0 feynman-solve
    symbolic[ t x 2 ^ * x + ] x-sym 0 1 definite-integrate =
] unit-test
{ "t/3 + 1/2" } [
    symbolic[ t x 2 ^ * x + ] x-sym 0 1 symbolic[ t ] 0 feynman-solve expr>string
] unit-test
{ t } [
    symbolic[ t x 2 ^ neg exp * ] x-sym 0 1 symbolic[ t ] 1 feynman-solve integral?
] unit-test

! Limits
{ 0 } [ symbolic[ x x log * ] x-sym 0 limit ] unit-test
{ 1 } [ symbolic[ x sin x / ] x-sym 0 limit ] unit-test
{ 1/2 } [ symbolic[ 1 x cos - x 2 ^ / ] x-sym 0 limit ] unit-test
{ 2 } [ symbolic[ 2 x 2 ^ * 3 + x 2 ^ 1 - / ] x-sym symbolic[ inf ] limit ] unit-test
{ 0 } [ symbolic[ x x exp / ] x-sym symbolic[ inf ] limit ] unit-test
{ 0 } [ symbolic[ x log x / ] x-sym symbolic[ inf ] limit ] unit-test
{ "pi/2" } [ symbolic[ x atan ] x-sym symbolic[ inf ] limit expr>string ] unit-test
{ "inf" } [ symbolic[ x log ] x-sym symbolic[ inf ] limit expr>string ] unit-test
{ 0 } [ symbolic[ x neg exp ] x-sym symbolic[ inf ] limit ] unit-test
{ 1 } [ symbolic[ x tanh ] x-sym symbolic[ inf ] limit ] unit-test
{ 5 } [ symbolic[ 5 ] x-sym 0 limit ] unit-test
{ "limit(sin(x), x, inf)" } [ symbolic[ x sin ] x-sym symbolic[ inf ] limit expr>string ] unit-test
{ 0 } [ symbolic[ x x log * x 0 limit ] doit ] unit-test

! Improper integrals
{ 1 } [ symbolic[ x neg exp ] x-sym 0 symbolic[ inf ] definite-integrate ] unit-test
{ 1 } [ symbolic[ x -2 ^ ] x-sym 1 symbolic[ inf ] definite-integrate ] unit-test
{ 1 } [ symbolic[ x x neg exp * ] x-sym 0 symbolic[ inf ] definite-integrate ] unit-test
{ "pi/2" } [ symbolic[ x 2 ^ 1 + -1 ^ ] x-sym 0 symbolic[ inf ] definite-integrate expr>string ] unit-test
{ "inf" } [ symbolic[ 1 x / ] x-sym 1 symbolic[ inf ] definite-integrate expr>string ] unit-test
{ -1 } [ symbolic[ x log ] x-sym 0 1 definite-integrate ] unit-test

! The Gaussian integral
{ "sqrt(pi)" } [
    symbolic[ x 2 ^ neg exp ] x-sym symbolic[ inf neg ] symbolic[ inf ]
    definite-integrate expr>string
] unit-test
{ "3*sqrt(pi)" } [
    symbolic[ x 5 - 2 ^ 9 / neg exp ] x-sym symbolic[ inf neg ] symbolic[ inf ]
    definite-integrate expr>string
] unit-test
{ "2*sqrt(pi)" } [
    symbolic[ 2 x 2 ^ neg exp * ] x-sym symbolic[ inf neg ] symbolic[ inf ]
    definite-integrate expr>string
] unit-test
{ t } [
    symbolic[ x 2 ^ 2 / neg exp ] x-sym symbolic[ inf neg ] symbolic[ inf ]
    definite-integrate evalf 2 pi * sqrt 1e-9 ~
] unit-test
{ "sqrt(pi)/2" } [
    symbolic[ x 2 ^ neg exp ] x-sym 0 symbolic[ inf ]
    definite-integrate expr>string
] unit-test
! A half line with a linear term needs the error function
{ t } [
    symbolic[ x 5 - 2 ^ neg exp ] x-sym 0 symbolic[ inf ]
    definite-integrate integral?
] unit-test
! Not a Gaussian: the exponent is linear, and the integral diverges
{ "inf" } [
    symbolic[ x neg exp ] x-sym symbolic[ inf neg ] symbolic[ inf ]
    definite-integrate expr>string
] unit-test
