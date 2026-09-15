! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: assocs help.markup help.syntax kernel math strings ;
IN: math.symbolic

HELP: symbolic[
{ $syntax "symbolic[ tokens... ]" }
{ $description "Builds symbolic expressions at parse time from postfix tokens, pushing whatever remains as literals. Numbers are numbers; " { $snippet "+ - * / ^ neg sqrt sin cos tan exp log" } " combine expressions; " { $snippet "pi" } " and " { $snippet "e" } " are constants; " { $snippet "D" } " " { $snippet "( f x -- )" } ", " { $snippet "integral" } " " { $snippet "( f x -- )" } " and " { $snippet "definite-integral" } " " { $snippet "( f x a b -- )" } " build unevaluated calculus expressions; " { $snippet "?name" } " is a pattern variable, for " { $vocab-link "math.symbolic.rules" } "; every other token is a variable." }
{ $examples
    { $example "USING: math.symbolic ;" "symbolic[ 3 x sin * x + 4 y exp * + ] expr." "x + 3*sin(x) + 4*exp(y)" }
    { $example "USING: kernel math.symbolic ;" "symbolic[ x x + x x * ] [ expr. ] bi@" "2*x\nx^2" }
} ;

HELP: sym
{ $class-description "A variable." } ;

HELP: <sym>
{ $values { "name" string } { "sym" sym } }
{ $description "Creates a variable." } ;

HELP: pvar
{ $class-description "A pattern variable, written " { $snippet "?name" } ", which matches any expression in " { $vocab-link "math.symbolic.rules" } "." } ;

HELP: <pvar>
{ $values { "name" string } { "pvar" pvar } }
{ $description "Creates a pattern variable." } ;

HELP: parse-symbolic-tokens
{ $values { "tokens" { $sequence string } } { "exprs" { $sequence "expressions" } } }
{ $description "Runs tokens as " { $link POSTPONE: symbolic[ } " does, outputting the resulting expressions." } ;

HELP: const
{ $class-description "A named constant: " { $link pi-expr } " or " { $link e-expr } "." } ;

HELP: pi-expr
{ $description "The constant pi." } ;

HELP: e-expr
{ $description "The constant e." } ;

HELP: add
{ $class-description "A sum of two or more terms, in canonical order. Build sums with " { $link s+ } " or " { $link >add } "." } ;

HELP: mul
{ $class-description "A product of two or more factors, in canonical order, with any numeric coefficient first. Build products with " { $link s* } " or " { $link >mul } "." } ;

HELP: pow
{ $class-description "A power. Build powers with " { $link s^ } "." } ;

HELP: fn
{ $class-description "An application of " { $snippet "sin" } ", " { $snippet "cos" } ", " { $snippet "tan" } ", " { $snippet "exp" } " or " { $snippet "log" } "." } ;

HELP: derivative
{ $class-description "An unevaluated derivative, built with " { $link <derivative> } "." } ;

HELP: integral
{ $class-description "An unevaluated integral, built with " { $link <integral> } " or " { $link <definite-integral> } "." } ;

HELP: symbolic
{ $class-description "The class of symbolic expression tuples. Numbers are also expressions." } ;

HELP: <derivative>
{ $values { "expr" "an expression" } { "var" sym } { "derivative" derivative } }
{ $description "An unevaluated derivative of " { $snippet "expr" } " with respect to " { $snippet "var" } "." } ;

HELP: <integral>
{ $values { "expr" "an expression" } { "var" sym } { "integral" integral } }
{ $description "An unevaluated indefinite integral." } ;

HELP: <definite-integral>
{ $values { "expr" "an expression" } { "var" sym } { "from" "an expression" } { "to" "an expression" } { "integral" integral } }
{ $description "An unevaluated definite integral." } ;

HELP: s+
{ $values { "a" "an expression" } { "b" "an expression" } { "a+b" "an expression" } }
{ $description "Adds two expressions, combining like terms." } ;

HELP: s-
{ $values { "a" "an expression" } { "b" "an expression" } { "a-b" "an expression" } }
{ $description "Subtracts two expressions." } ;

HELP: s*
{ $values { "a" "an expression" } { "b" "an expression" } { "a*b" "an expression" } }
{ $description "Multiplies two expressions, combining powers of the same base." } ;

HELP: s/
{ $values { "a" "an expression" } { "b" "an expression" } { "a/b" "an expression" } }
{ $description "Divides two expressions." } ;

HELP: s^
{ $values { "base" "an expression" } { "exponent" "an expression" } { "base^exponent" "an expression" } }
{ $description "Raises an expression to a power." } ;

HELP: sneg
{ $values { "a" "an expression" } { "-a" "an expression" } }
{ $description "Negates an expression." } ;

HELP: ssqrt
{ $values { "a" "an expression" } { "sqrt[a]" "an expression" } }
{ $description "The square root, as a power of 1/2." } ;

HELP: ssin
{ $values { "u" "an expression" } { "sin[u]" "an expression" } }
{ $description "The sine, simplified at multiples of pi/2 and for negated arguments." } ;

HELP: scos
{ $values { "u" "an expression" } { "cos[u]" "an expression" } }
{ $description "The cosine, simplified at multiples of pi/2 and for negated arguments." } ;

HELP: stan
{ $values { "u" "an expression" } { "tan[u]" "an expression" } }
{ $description "The tangent." } ;

HELP: sexp
{ $values { "u" "an expression" } { "exp[u]" "an expression" } }
{ $description "The exponential." } ;

HELP: slog
{ $values { "u" "an expression" } { "log[u]" "an expression" } }
{ $description "The natural logarithm." } ;

HELP: sasin
{ $values { "u" "an expression" } { "asin[u]" "an expression" } }
{ $description "The arc sine, simplified at 0, 1 and -1, and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: sacos
{ $values { "u" "an expression" } { "acos[u]" "an expression" } }
{ $description "The arc cosine, simplified at 0, 1 and -1, and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: satan
{ $values { "u" "an expression" } { "atan[u]" "an expression" } }
{ $description "The arc tangent, simplified at 0, 1 and -1, and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: ssinh
{ $values { "u" "an expression" } { "sinh[u]" "an expression" } }
{ $description "The hyperbolic sine, simplified at 0 and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: scosh
{ $values { "u" "an expression" } { "cosh[u]" "an expression" } }
{ $description "The hyperbolic cosine, simplified at 0 and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: stanh
{ $values { "u" "an expression" } { "tanh[u]" "an expression" } }
{ $description "The hyperbolic tangent, simplified at 0 and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: sasinh
{ $values { "u" "an expression" } { "asinh[u]" "an expression" } }
{ $description "The inverse hyperbolic sine, simplified at 0 and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: sacosh
{ $values { "u" "an expression" } { "acosh[u]" "an expression" } }
{ $description "The inverse hyperbolic cosine, simplified at 1. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: satanh
{ $values { "u" "an expression" } { "atanh[u]" "an expression" } }
{ $description "The inverse hyperbolic tangent, simplified at 0 and for negated arguments. A function applied to its inverse, such as " { $snippet "sinh(asinh(x))" } ", simplifies to the argument." } ;

HELP: apply-fn
{ $values { "arg" "an expression" } { "name" string } { "expr" "an expression" } }
{ $description "Applies the function named " { $snippet "name" } " with simplification." } ;

HELP: >add
{ $values { "seq" "a sequence of expressions" } { "expr" "an expression" } }
{ $description "The simplified sum of a sequence of expressions." } ;

HELP: >mul
{ $values { "seq" "a sequence of expressions" } { "expr" "an expression" } }
{ $description "The simplified product of a sequence of expressions." } ;

HELP: subs
{ $values { "expr" "an expression" } { "assoc" assoc } { "expr'" "an expression" } }
{ $description "Replaces subexpressions that are keys of " { $snippet "assoc" } " with their values, simplifying the result." } ;

HELP: simplify
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Rebuilds an expression through the simplifying constructors, for expressions built directly from tuples." } ;

HELP: expand
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Multiplies out products of sums and positive integer powers of sums." }
{ $examples { $example "USING: math.symbolic ;" "symbolic[ x 1 + 2 ^ ] expand expr." "x^2 + 2*x + 1" } } ;

HELP: free-of?
{ $values { "expr" "an expression" } { "var" "an expression" } { "?" boolean } }
{ $description "Whether " { $snippet "var" } " does not occur in " { $snippet "expr" } "." } ;

HELP: evalf
{ $values { "expr" "an expression" } { "number" number } }
{ $description "Evaluates an expression with no variables as a float." }
{ $errors "Throws " { $link unbound-symbol } " for a variable and " { $link unevaluated-expression } " for a derivative or integral." } ;

HELP: unbound-symbol
{ $error-description "Thrown by " { $link evalf } " for a variable." } ;

HELP: unevaluated-expression
{ $error-description "Thrown by " { $link evalf } " for an unevaluated derivative or integral." } ;

HELP: unknown-function
{ $error-description "Thrown by " { $link apply-fn } " for an unknown function name." } ;

HELP: degree
{ $values { "expr" "an expression" } { "n" integer } }
{ $description "The total degree of a monomial in its variables, used to order terms." } ;

HELP: negative-term?
{ $values { "expr" "an expression" } { "?" boolean } }
{ $description "Whether an expression is a negative number or a product with a negative coefficient." } ;

HELP: negate-term
{ $values { "expr" "an expression" } { "expr'" "an expression" } }
{ $description "Negates a number or the coefficient of a product." } ;

HELP: expr>string
{ $values { "expr" "an expression" } { "string" string } }
{ $description "Conventional infix notation for an expression." } ;

HELP: expr.
{ $values { "expr" "an expression" } }
{ $description "Prints " { $link expr>string } "." } ;

HELP: expr>postfix
{ $values { "expr" "an expression" } { "string" string } }
{ $description "The tokens of a " { $link POSTPONE: symbolic[ } " literal for an expression." } ;

ARTICLE: "math.symbolic" "Symbolic algebra"
"The " { $vocab-link "math.symbolic" } " vocabulary represents polynomials, trigonometric, inverse trigonometric, hyperbolic and inverse hyperbolic functions, exponentials, logarithms, their products, and unevaluated derivatives and integrals. Expressions are kept simplified: like terms and powers are combined, numbers are folded exactly, and sums and products are in a canonical order. Calculus is in " { $vocab-link "math.symbolic.calculus" } "."
$nl
"Literals:"
{ $subsections POSTPONE: symbolic[ <sym> <pvar> pi-expr e-expr parse-symbolic-tokens }
"Arithmetic and functions:"
{ $subsections s+ s- s* s/ s^ sneg ssqrt >add >mul }
"Functions:"
{ $subsections ssin scos stan sexp slog sasin sacos satan ssinh scosh stanh sasinh sacosh satanh apply-fn }
"Calculus expressions:"
{ $subsections <derivative> <integral> <definite-integral> }
"Manipulation and evaluation:"
{ $subsections subs simplify expand free-of? evalf }
"Printing:"
{ $subsections expr>string expr. expr>postfix }
"Expression classes:"
{ $subsections symbolic sym const add mul pow fn derivative integral pvar }
"Simplification assumes real variables, so for example " { $snippet "log(exp(x))" } " becomes " { $snippet "x" } "." ;

ABOUT: "math.symbolic"
