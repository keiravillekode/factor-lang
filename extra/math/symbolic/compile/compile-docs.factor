! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: help.markup help.syntax math.symbolic quotations sequences
words ;
IN: math.symbolic.compile

HELP: expr>quot
{ $values { "expr" "an expression" } { "vars" { $sequence sym } } { "quot" quotation } }
{ $description "A quotation " { $snippet "( value1 ... valuen -- result )" } " that evaluates " { $snippet "expr" } " with the values of " { $snippet "vars" } ", using ordinary arithmetic words, so exact inputs give exact results where possible." }
{ $errors "Throws " { $link unbound-symbol } " for a variable not in " { $snippet "vars" } ", and " { $link not-compilable } " for derivatives, integrals and pattern variables." }
{ $examples { $example "USING: math.symbolic math.symbolic.compile prettyprint ;" "3 4 symbolic[ x 2 ^ y 2 ^ + ] { T{ sym f \"x\" } T{ sym f \"y\" } }\nexpr>quot call( x y -- r ) ." "25" } } ;

HELP: expr>word
{ $values { "expr" "an expression" } { "vars" { $sequence sym } } { "word" word } }
{ $description "Like " { $link expr>quot } ", compiled into a new word whose stack effect names its inputs after " { $snippet "vars" } ". Call it with " { $link POSTPONE: execute( } "." } ;

HELP: not-compilable
{ $error-description "Thrown by " { $link expr>quot } " for an expression that has no numeric value, such as an unevaluated derivative." } ;

ARTICLE: "math.symbolic.compile" "Compiling symbolic expressions"
"The " { $vocab-link "math.symbolic.compile" } " vocabulary turns " { $vocab-link "math.symbolic" } " expressions into quotations and compiled words, for evaluating them many times."
{ $subsections expr>quot expr>word not-compilable } ;

ABOUT: "math.symbolic.compile"
