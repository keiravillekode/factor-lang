! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: arrays kernel math math.functions math.symbolic
math.symbolic.calculus sequences tools.test ;
IN: math.symbolic.calculus.tests

<PRIVATE

: x-sym ( -- sym ) "x" <sym> ;

! integrate finds an antiderivative whose derivative equals the
! integrand at several points.
:: antiderivative-checks? ( integrand -- ? )
    integrand x-sym integrate :> F
    F x-sym differentiate :> dF
    F integral? not
    { 0.3 0.7 1.9 } [| v |
        x-sym v 2array 1array :> at-v
        integrand at-v subs evalf dF at-v subs evalf - abs 1e-9 <
    ] all? and ;

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
