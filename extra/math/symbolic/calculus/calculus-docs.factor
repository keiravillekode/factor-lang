! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: help.markup help.syntax kernel math math.numerical-integration
math.symbolic math.symbolic.compile sequences ;
IN: math.symbolic.calculus

HELP: differentiate
{ $values { "expr" "an expression" } { "var" sym } { "expr'" "an expression" } }
{ $description "The derivative of " { $snippet "expr" } " with respect to " { $snippet "var" } ". Derivatives of definite integrals use the Leibniz rule." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x x sin * ] symbolic[ x ] differentiate expr." "x*cos(x) + sin(x)" } } ;

HELP: integrate
{ $values { "expr" "an expression" } { "x" sym } { "expr'" "an expression" } }
{ $description "An antiderivative of " { $snippet "expr" } " with respect to " { $snippet "x" } ", without a constant of integration, or an unevaluated " { $link integral } " when none is found. Handles powers, and " { $snippet "sin cos tan exp log" } ", the inverse trigonometric functions, and the hyperbolic and inverse hyperbolic functions, of linear arguments, sums, constant factors, " { $snippet "sin^2" } " and " { $snippet "cos^2" } ", polynomials times " { $snippet "exp sin cos log" } " (by parts), exponentials times sines and cosines, " { $snippet "1/(u^2 + c)" } " as an arc tangent, and substitution when the rest of a product is a constant times the derivative of an inner expression. " { $snippet "1/x" } " integrates to " { $snippet "log(x)" } ", assuming " { $snippet "x > 0" } "." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x x exp * ] symbolic[ x ] integrate expr." "x*exp(x) - exp(x)" } } ;

HELP: definite-integrate
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "expr'" "an expression" } }
{ $description "The definite integral from an antiderivative, or an unevaluated " { $link integral } " when none is found. A bound may be " { $link infinity-expr } " or its negative, and a bound where the antiderivative is undefined is evaluated with " { $link limit } ", so improper integrals work. Gaussian integrals are recognized: " { $snippet "k*exp(-a*x^2 + b*x + c)" } " over the whole line is " { $snippet "k*sqrt(pi/a)*exp(b^2/(4*a) + c)" } ", and half that over a half line when " { $snippet "b" } " is 0. The integral of " { $snippet "x^n*exp(-a*x)" } " from 0 to infinity is " { $snippet "gamma(n + 1)/a^(n + 1)" } " for positive " { $snippet "a" } " and " { $snippet "n > -1" } ". Singularities inside the interval are not detected." }
{ $examples
    { $example "USING: math.symbolic math.symbolic.calculus prettyprint ;" "symbolic[ x sin ] symbolic[ x ] 0 symbolic[ pi ] definite-integrate ." "2" }
    { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x 5 - 2 ^ 9 / neg exp ] symbolic[ x ]\nsymbolic[ inf neg ] symbolic[ inf ] definite-integrate expr." "3*sqrt(pi)" }
} ;

HELP: nintegrate
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "value" float } }
{ $description "The definite integral computed numerically with Simpson's rule from " { $vocab-link "math.numerical-integration" } ". With " { $link num-steps } " of 1000 or more, the integrand is first compiled with " { $link expr>word } ", which costs a few milliseconds but evaluates each point several times faster." } ;

HELP: gradient
{ $values { "expr" "an expression" } { "vars" { $sequence sym } } { "exprs" { $sequence "expressions" } } }
{ $description "The partial derivatives of " { $snippet "expr" } " with respect to each of " { $snippet "vars" } "." }
{ $examples { $example "USING: kernel math.symbolic math.symbolic.calculus sequences ;" "symbolic[ x 2 ^ y * y sin + ] { T{ sym f \"x\" } T{ sym f \"y\" } } gradient\n[ expr. ] each" "2*x*y\nx^2 + cos(y)" } } ;

HELP: jacobian
{ $values { "exprs" { $sequence "expressions" } } { "vars" { $sequence sym } } { "matrix" "a sequence of sequences" } }
{ $description "The Jacobian matrix: one row, the " { $link gradient } ", for each expression." } ;

HELP: taylor
{ $values { "expr" "an expression" } { "x" sym } { "point" "an expression" } { "n" integer } { "expr'" "an expression" } }
{ $description "The Taylor polynomial of " { $snippet "expr" } " about " { $snippet "point" } ", up to the term in " { $snippet "(x - point)^n" } ": the sum of " { $snippet "f(k)(point)*(x - point)^k/k!" } " for k from 0 to n. The remainder is not represented." }
{ $errors "Throws " { $link undefined-at-point } " when a derivative has no value at " { $snippet "point" } ", as for " { $snippet "log(x)" } " at 0." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x exp ] symbolic[ x ] 0 3 taylor expr." "x^3/6 + x^2/2 + x + 1" } } ;

HELP: maclaurin
{ $values { "expr" "an expression" } { "x" sym } { "n" integer } { "expr'" "an expression" } }
{ $description "The " { $link taylor } " polynomial about 0." } ;

HELP: undefined-at-point
{ $error-description "Thrown by " { $link taylor } " when the expression or one of its derivatives has no value at the point." } ;

HELP: limit
{ $values { "expr" "an expression" } { "x" sym } { "point" "an expression" } { "expr'" "an expression" } }
{ $description "The limit of " { $snippet "expr" } " as " { $snippet "x" } " approaches " { $snippet "point" } ", which may be " { $link infinity-expr } " or its negative. Uses substitution, the limits of " { $snippet "exp log atan tanh sinh cosh asinh acosh" } " at infinity, l'Hopital's rule for " { $snippet "0/0" } " and " { $snippet "infinity/infinity" } ", and rewrites " { $snippet "0*infinity" } " as a quotient. Outputs an unevaluated " { $link limit-expr } " when it finds no value." }
{ $notes "One-sided limits are not distinguished; " { $snippet "log(x)" } " at 0 is taken from the right." }
{ $examples
    { $example "USING: math.symbolic math.symbolic.calculus prettyprint ;" "symbolic[ x x log * ] symbolic[ x ] 0 limit ." "0" }
    { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x atan ] symbolic[ x ] symbolic[ inf ] limit expr." "pi/2" }
} ;

HELP: definite-by-symmetry
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "expr'" "an expression" } }
{ $description "The definite integral from the symmetry " { $snippet "f(x) + f(a + b - x) = c" } ", which gives " { $snippet "(b - a)*c/2" } ". " { $snippet "c" } " is the sum at " { $snippet "from" } ", that is " { $snippet "f(a) + f(b)" } ". Outputs the unevaluated " { $link integral } " when the sum is not constant." }
{ $notes "When the sum is not symbolically constant, it is only checked numerically, at seven points of the interval, so the result is not a proof. " { $link definite-integrate } " uses this only in the symbolically exact case." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ 1 x tan + log ] symbolic[ x ] 0 symbolic[ pi 4 / ]\ndefinite-by-symmetry expr." "log(2)*pi/8" } } ;

HELP: feynman-derivative
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "t" sym } { "expr'" "an expression" } }
{ $description "Differentiation under the integral sign: the derivative with respect to the parameter " { $snippet "t" } " of the definite integral of " { $snippet "expr" } " over " { $snippet "x" } ", that is the definite integral of " { $snippet "d expr / dt" } "." } ;

HELP: feynman-solve
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "t" sym } { "t0" "an expression" } { "expr'" "an expression" } }
{ $description "Feynman's trick: recovers " { $snippet "F(t)" } ", the definite integral of " { $snippet "expr" } " over " { $snippet "x" } ", from " { $link feynman-derivative } " and the value at " { $snippet "t0" } ", as " { $snippet "G(t) - G(t0) + F(t0)" } " for an antiderivative " { $snippet "G" } " of " { $snippet "F'" } ". Outputs the unevaluated " { $link integral } " when any step has no closed form." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ t x 2 ^ * x + ] symbolic[ x ] 0 1 symbolic[ t ] 0\nfeynman-solve expr." "t/3 + 1/2" } } ;

HELP: by-substitution
{ $values { "expr" "an expression" } { "x" sym } { "u" "an expression" } { "expr'" "an expression" } }
{ $description "Integrates " { $snippet "expr" } " by the substitution " { $snippet "u = g(x)" } ": divides by " { $snippet "u'" } ", writes occurrences of " { $snippet "g(x)" } " as a new variable, integrates, and substitutes back. Outputs the unevaluated " { $link integral } " when the result still mentions " { $snippet "x" } ", or when the integral in the new variable is not found." }
{ $notes "The integrand must mention " { $snippet "g(x)" } " after dividing by " { $snippet "u'" } ". For example " { $snippet "sin(x)/cos(x)" } " fits " { $snippet "u = cos(x)" } ", but the equal expression " { $snippet "tan(x)" } " does not, because the simplifier keeps " { $snippet "tan" } " as it is." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x sin x cos / ] symbolic[ x ] symbolic[ x cos ]\nby-substitution expr." "-log(cos(x))" } } ;

HELP: definite-by-substitution
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "u" "an expression" } { "expr'" "an expression" } }
{ $description "Like " { $link by-substitution } " for a definite integral: the limits become " { $snippet "u(from)" } " and " { $snippet "u(to)" } ", so there is no substituting back." } ;

HELP: by-parts
{ $values { "x" sym } { "u" "an expression" } { "dv" "an expression" } { "expr'" "an expression" } }
{ $description "Integrates " { $snippet "u*dv" } " by parts: " { $snippet "u*v - integrate(v*u', x)" } ", where " { $snippet "v" } " is an antiderivative of " { $snippet "dv" } ". The remaining integral is left unevaluated; " { $link doit } " evaluates it. It is omitted when " { $snippet "u" } " is constant." }
{ $errors "Throws " { $link no-antiderivative } " when no antiderivative of " { $snippet "dv" } " is found." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x ] symbolic[ x ] symbolic[ x cos ] by-parts expr." "x*sin(x) - integrate(sin(x), x)" } } ;

HELP: by-parts-u
{ $values { "expr" "an expression" } { "x" sym } { "u" "an expression" } { "expr'" "an expression" } }
{ $description "Integrates " { $snippet "expr" } " by parts with the given " { $snippet "u" } ", taking " { $snippet "dv" } " as " { $snippet "expr/u" } ". See " { $link by-parts } "." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x x exp * ] symbolic[ x ] symbolic[ x ] by-parts-u expr." "x*exp(x) - integrate(exp(x), x)" } } ;

HELP: by-parts-dv
{ $values { "expr" "an expression" } { "x" sym } { "dv" "an expression" } { "expr'" "an expression" } }
{ $description "Integrates " { $snippet "expr" } " by parts with the given " { $snippet "dv" } ", taking " { $snippet "u" } " as " { $snippet "expr/dv" } ". " { $snippet "dv" } " may be 1, as for logarithms. See " { $link by-parts } "." }
{ $examples
    { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x log ] symbolic[ x ] 1 by-parts-dv expr." "x*log(x) - integrate(1, x)" }
    { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x log ] symbolic[ x ] 1 by-parts-dv doit expr." "-x + x*log(x)" }
} ;

HELP: definite-by-parts
{ $values { "x" sym } { "from" "an expression" } { "to" "an expression" } { "u" "an expression" } { "dv" "an expression" } { "expr'" "an expression" } }
{ $description "Integrates " { $snippet "u*dv" } " from " { $snippet "from" } " to " { $snippet "to" } " by parts: " { $snippet "u*v" } " at " { $snippet "to" } " minus at " { $snippet "from" } ", minus the unevaluated definite integral of " { $snippet "v*u'" } ". See " { $link by-parts } "." } ;

HELP: definite-by-parts-u
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "u" "an expression" } { "expr'" "an expression" } }
{ $description "Like " { $link by-parts-u } " for a definite integral. See " { $link definite-by-parts } "." } ;

HELP: definite-by-parts-dv
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "dv" "an expression" } { "expr'" "an expression" } }
{ $description "Like " { $link by-parts-dv } " for a definite integral. See " { $link definite-by-parts } "." }
{ $examples { $example "USING: kernel math.symbolic math.symbolic.calculus prettyprint ;" "symbolic[ x log ] symbolic[ x ] 1 symbolic[ e ] 1 definite-by-parts-dv\n[ expr. ] [ doit . ] bi" "e - integrate(1, x, 1, e)\n1" } } ;

HELP: no-antiderivative
{ $error-description "Thrown by the integration by parts words when no antiderivative of " { $snippet "dv" } " is found." } ;

HELP: hessian
{ $values { "expr" "an expression" } { "vars" { $sequence sym } } { "matrix" "a sequence of sequences" } }
{ $description "The Hessian matrix of second partial derivatives: the " { $link jacobian } " of the " { $link gradient } ". The matrix is symmetric for expressions with continuous second derivatives." }
{ $examples { $example "USING: kernel math.symbolic math.symbolic.calculus sequences ;" "symbolic[ x 3 ^ 3 x * y * - y 3 ^ + ]\n{ T{ sym f \"x\" } T{ sym f \"y\" } } hessian [ [ expr. ] each ] each" "6*x\n-3\n-3\n6*y" } } ;

HELP: doit
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Evaluates the unevaluated derivatives and integrals in an expression." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x 3 ^ x D ] doit expr." "3*x^2" } } ;

ARTICLE: "math.symbolic.calculus" "Symbolic calculus"
"The " { $vocab-link "math.symbolic.calculus" } " vocabulary differentiates and integrates " { $vocab-link "math.symbolic" } " expressions."
{ $subsections differentiate gradient jacobian hessian integrate definite-integrate nintegrate doit }
"Limits and series:"
{ $subsections limit taylor maclaurin undefined-at-point }
"Definite integrals by symmetry, and Feynman's trick:"
{ $subsections definite-by-symmetry feynman-derivative feynman-solve }
"Integration by a chosen substitution:"
{ $subsections by-substitution definite-by-substitution }
"Integration by parts, one step at a time:"
{ $subsections by-parts by-parts-u by-parts-dv definite-by-parts definite-by-parts-u definite-by-parts-dv no-antiderivative } ;

ABOUT: "math.symbolic.calculus"
