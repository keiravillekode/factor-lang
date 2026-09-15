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
{ $description "An antiderivative of " { $snippet "expr" } " with respect to " { $snippet "x" } ", without a constant of integration, or an unevaluated " { $link integral } " when none is found. Handles powers and " { $snippet "sin cos tan exp log" } " of linear arguments, sums, constant factors, " { $snippet "sin^2" } " and " { $snippet "cos^2" } ", polynomials times " { $snippet "exp sin cos log" } " (by parts), exponentials times sines and cosines, and substitution when the rest of a product is a constant times the derivative of an inner expression. " { $snippet "1/x" } " integrates to " { $snippet "log(x)" } ", assuming " { $snippet "x > 0" } "." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x x exp * ] symbolic[ x ] integrate expr." "x*exp(x) - exp(x)" } } ;

HELP: definite-integrate
{ $values { "expr" "an expression" } { "x" sym } { "from" "an expression" } { "to" "an expression" } { "expr'" "an expression" } }
{ $description "The definite integral from an antiderivative, or an unevaluated " { $link integral } " when none is found. Singularities in the interval are not detected." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus prettyprint ;" "symbolic[ x sin ] symbolic[ x ] 0 symbolic[ pi ] definite-integrate ." "2" } } ;

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

HELP: doit
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Evaluates the unevaluated derivatives and integrals in an expression." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x 3 ^ x D ] doit expr." "3*x^2" } } ;

ARTICLE: "math.symbolic.calculus" "Symbolic calculus"
"The " { $vocab-link "math.symbolic.calculus" } " vocabulary differentiates and integrates " { $vocab-link "math.symbolic" } " expressions."
{ $subsections differentiate gradient jacobian integrate definite-integrate nintegrate doit }
"Integration by parts, one step at a time:"
{ $subsections by-parts by-parts-u by-parts-dv definite-by-parts definite-by-parts-u definite-by-parts-dv no-antiderivative } ;

ABOUT: "math.symbolic.calculus"
