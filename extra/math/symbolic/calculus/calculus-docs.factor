! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: help.markup help.syntax math math.symbolic ;
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
{ $description "The definite integral computed numerically with Simpson's rule from " { $vocab-link "math.numerical-integration" } "." } ;

HELP: doit
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Evaluates the unevaluated derivatives and integrals in an expression." }
{ $examples { $example "USING: math.symbolic math.symbolic.calculus ;" "symbolic[ x 3 ^ x D ] doit expr." "3*x^2" } } ;

ARTICLE: "math.symbolic.calculus" "Symbolic calculus"
"The " { $vocab-link "math.symbolic.calculus" } " vocabulary differentiates and integrates " { $vocab-link "math.symbolic" } " expressions."
{ $subsections differentiate integrate definite-integrate nintegrate doit } ;

ABOUT: "math.symbolic.calculus"
