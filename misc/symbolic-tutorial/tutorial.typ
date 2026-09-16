#set page(margin: 2.5cm)
#set text(size: 11pt)
#set heading(numbering: "1.")
#show raw.where(block: true): it => block(
  fill: luma(245), inset: 8pt, radius: 3pt, width: 100%, it,
)

= Symbolic algebra in Factor

A tour of #raw("math.symbolic") and its companion vocabularies, as
forty-odd worked problems. Every Factor block here is run by
#raw("misc/symbolic-tutorial/check.py"), which compares what Factor prints
against the #raw("! =>") lines, so the outputs in this document are the
real ones.

Expressions are written in postfix inside #raw("symbolic[ ... ]"):
numbers are numbers, #raw("+ - * / ^ neg sqrt sin cos tan exp log") and
the inverse, hyperbolic and gamma functions build expressions,
#raw("pi"), #raw("e") and #raw("inf") are constants, #raw("?x") is a
pattern variable, and any other token is a variable. #raw("expr.") prints
an expression in ordinary notation, while #raw(".") prints the underlying
value.

= Expressions and simplification

== Like terms and powers

$ x + x, quad x dot x dot x, quad x^2 / x $

Sums and products are simplified as they are built.

```factor
symbolic[ x x + ] expr.
! => 2*x
symbolic[ x x * x * ] expr.
! => x^3
symbolic[ x 2 ^ x / ] expr.
! => x
symbolic[ x x - ] .
! => 0
```

== Exact arithmetic

Rationals stay exact, and a number multiplying a sum is distributed.

$ 1/2 + 1/3 = 5/6, quad 2(x + 1) = 2x + 2 $

```factor
symbolic[ 1 2 / 1 3 / + ] .
! => 5/6
symbolic[ 2 x 1 + * ] expr.
! => 2*x + 2
symbolic[ e e 1 - - ] .
! => 1
```

== Expanding

$ (x + 1)^2, quad (x + y)(x - y) $

```factor
symbolic[ x 1 + 2 ^ ] expand expr.
! => x^2 + 2*x + 1
symbolic[ x y + x y - * ] expand expr.
! => x^2 - y^2
```

== Printing and reading back

An expression prettyprints as a literal that reads back in, while
#raw("expr.") gives ordinary notation.

```factor
symbolic[ 3 x sin * x + ] .
! => symbolic[ x 3 x sin * + ]
symbolic[ 3 x sin * x + ] expr.
! => x + 3*sin(x)
symbolic[ 1 x / ] expr.
! => 1/x
symbolic[ 2 3 x * / ] expr.
! => 2/(3*x)
```

== Substituting and evaluating

$ x^2 + 1 "at" x = 2, quad sin(pi/4) sqrt(2) $

```factor
symbolic[ x 2 ^ 1 + ] { { T{ sym f "x" } 2 } } subs .
! => 5
symbolic[ x x sin + ] { { T{ sym f "x" } T{ sym f "y" } } } subs expr.
! => y + sin(y)
symbolic[ pi 4 / sin 2 sqrt * ] evalf .
! => 1.0
```

== Exact angles

$ sin(pi/6) = 1/2, quad cos(pi/6) = sqrt(3)/2, quad tan(pi/3) = sqrt(3) $

The inverse functions give the same angles back.

```factor
symbolic[ pi 6 / sin ] .
! => 1/2
symbolic[ pi 6 / cos ] expr.
! => sqrt(3)/2
symbolic[ pi 3 / tan ] expr.
! => sqrt(3)
symbolic[ 1 2 / asin ] expr.
! => pi/6
symbolic[ 3 sqrt atan ] expr.
! => pi/3
```

= Differentiation

== The product rule

$ dif / (dif x) (x sin x) = x cos x + sin x $

```factor
symbolic[ x x sin * ] symbolic[ x ] differentiate expr.
! => x*cos(x) + sin(x)
```

== The chain rule

$ dif / (dif x) e^(x^2) = 2 x e^(x^2) $

```factor
symbolic[ x 2 ^ exp ] symbolic[ x ] differentiate expr.
! => 2*x*exp(x^2)
symbolic[ 3 x * 1 + sin ] symbolic[ x ] differentiate expr.
! => 3*cos(3*x + 1)
```

== Quotients and powers

$ dif / (dif x) x/(x^2 + 1), quad dif / (dif x) x^x $

```factor
symbolic[ x x 2 ^ 1 + / ] symbolic[ x ] differentiate expand expr.
! => -2*x^2/(x^2 + 1)^2 + 1/(x^2 + 1)
symbolic[ x x ^ ] symbolic[ x ] differentiate expr.
! => x^x*(log(x) + 1)
```

== Inverse and hyperbolic functions

$ dif / (dif x) arctan x = 1/(x^2 + 1), quad dif / (dif x) tanh x = 1/cosh^2 x $

```factor
symbolic[ x atan ] symbolic[ x ] differentiate expr.
! => 1/(x^2 + 1)
symbolic[ x asin ] symbolic[ x ] differentiate expr.
! => 1/sqrt(-x^2 + 1)
symbolic[ x tanh ] symbolic[ x ] differentiate expr.
! => 1/cosh(x)^2
```

== Gradients and Jacobians

For the polar map $(r, theta) |-> (r cos theta, r sin theta)$ the Jacobian
determinant is the $r$ of $dif x dif y = r dif r dif theta$.

```factor
CONSTANT: polar { T{ sym f "r" } T{ sym f "theta" } }

symbolic[ r theta cos * ] symbolic[ r theta sin * ] 2array polar jacobian
[ [ expr. ] each ] each
! => cos(theta)
! => -r*sin(theta)
! => sin(theta)
! => r*cos(theta)
```

```factor
CONSTANT: polar { T{ sym f "r" } T{ sym f "theta" } }

:: det2 ( matrix -- expr )
    matrix first first2 :> ( a b )
    matrix second first2 :> ( c d )
    a d s* b c s* s- ;

symbolic[ r theta cos * ] symbolic[ r theta sin * ] 2array polar jacobian
det2 pythagorean-rules rewrite expr.
! => r
```

== Classifying a critical point

$ f(x, y) = x^3 - 3 x y + y^3 $

The gradient vanishes at $(1, 1)$ and at the origin. The Hessian
determinant settles which is which.

```factor
CONSTANT: vars { T{ sym f "x" } T{ sym f "y" } }
CONSTANT: f symbolic[ x 3 ^ 3 x * y * - y 3 ^ + ]

f vars gradient [ expr. ] each
! => 3*x^2 - 3*y
! => 3*y^2 - 3*x
f vars hessian [ [ expr. ] each ] each
! => 6*x
! => -3
! => -3
! => 6*y
```

With $f_(x x) = 6 > 0$ and determinant $27 > 0$ at $(1, 1)$ it is a local
minimum; at the origin the determinant is negative, so that is a saddle.

```factor
CONSTANT: vars { T{ sym f "x" } T{ sym f "y" } }
CONSTANT: f symbolic[ x 3 ^ 3 x * y * - y 3 ^ + ]

:: det2 ( matrix -- expr )
    matrix first first2 :> ( a b )
    matrix second first2 :> ( c d )
    a d s* b c s* s- ;

f vars hessian det2 expr.
! => 36*x*y - 9
f vars hessian det2 { { T{ sym f "x" } 1 } { T{ sym f "y" } 1 } } subs .
! => 27
f vars hessian det2 { { T{ sym f "x" } 0 } { T{ sym f "y" } 0 } } subs .
! => -9
```

== Derivatives left unevaluated

#raw("D") writes a derivative down without computing it; #raw("doit")
computes it.

```factor
symbolic[ x 3 ^ x D ] expr.
! => D(x^3, x)
symbolic[ x 3 ^ x D ] doit expr.
! => 3*x^2
```

= Antiderivatives

== Powers, trigonometry and exponentials

$ integral x^2 dif x = x^3/3, quad integral 1/x dif x = log x $

```factor
symbolic[ x 2 ^ ] symbolic[ x ] integrate expr.
! => x^3/3
symbolic[ 1 x / ] symbolic[ x ] integrate expr.
! => log(x)
symbolic[ x exp ] symbolic[ x ] integrate expr.
! => exp(x)
```

== Linear arguments

$ integral sin 2x dif x = -cos(2x)/2, quad integral 1/(2x + 1) dif x $

```factor
symbolic[ 2 x * sin ] symbolic[ x ] integrate expr.
! => -cos(2*x)/2
symbolic[ 1 2 x * 1 + / ] symbolic[ x ] integrate expr.
! => log(2*x + 1)/2
symbolic[ 3 x * 1 + exp ] symbolic[ x ] integrate expr.
! => exp(3*x + 1)/3
```

== An arc tangent and a logarithm

$ integral 1/(x^2 + 1) dif x = arctan x, quad integral tan x dif x $

```factor
symbolic[ x 2 ^ 1 + -1 ^ ] symbolic[ x ] integrate expr.
! => atan(x)
symbolic[ x tan ] symbolic[ x ] integrate expr.
! => -log(cos(x))
```

== Squares of sine and cosine

$ integral sin^2 x dif x = x/2 - (sin 2x)/4 $

```factor
symbolic[ x sin 2 ^ ] symbolic[ x ] integrate expr.
! => x/2 - sin(2*x)/4
symbolic[ x sin x cos * ] symbolic[ x ] integrate expr.
! => -cos(x)^2/2
```

== When the derivative divides

$ integral 2 x e^(x^2) dif x = e^(x^2) $

This one is found automatically: the rest of the product is a constant
times the derivative of the inner expression.

```factor
symbolic[ 2 x * x 2 ^ exp * ] symbolic[ x ] integrate expr.
! => exp(x^2)
symbolic[ x x 2 ^ 1 + / ] symbolic[ x ] integrate expr.
! => log(x^2 + 1)/2
```

== No elementary antiderivative

The integral comes back unevaluated rather than wrong.

```factor
symbolic[ x 2 ^ neg exp ] symbolic[ x ] integrate expr.
! => integrate(exp(-x^2), x)
symbolic[ x sin x / ] symbolic[ x ] integrate expr.
! => integrate(sin(x)/x, x)
```

= Integration by hand

== By parts, choosing u

$ integral x e^x dif x = x e^x - integral e^x dif x $

#raw("by-parts-u") leaves the remaining integral unevaluated, so the step
is visible; #raw("doit") finishes it.

```factor
symbolic[ x x exp * ] symbolic[ x ] symbolic[ x ] by-parts-u expr.
! => x*exp(x) - integrate(exp(x), x)
symbolic[ x x exp * ] symbolic[ x ] symbolic[ x ] by-parts-u doit expr.
! => x*exp(x) - exp(x)
```

== By parts, choosing dv

$ integral x log x dif x, quad dif v = x dif x $

Choosing $dif v$ instead fixes $u = log x$, whose derivative is simple.

```factor
symbolic[ x x log * ] symbolic[ x ] symbolic[ x ] by-parts-dv expr.
! => x^2*log(x)/2 - integrate(x/2, x)
symbolic[ x x log * ] symbolic[ x ] symbolic[ x ] by-parts-dv doit expr.
! => x^2*log(x)/2 - x^2/4
```

== The dv = 1 trick

$ integral log x dif x = x log x - integral 1 dif x $

For a single logarithm there is nothing else to be $dif v$, so take
$dif v = dif x$.

```factor
symbolic[ x log ] symbolic[ x ] 1 by-parts-dv expr.
! => x*log(x) - integrate(1, x)
symbolic[ x log ] symbolic[ x ] 1 by-parts-dv doit expr.
! => -x + x*log(x)
```

== Repeated parts

$ integral x^2 sin x dif x $

Each application lowers the power of $x$ by one.

```factor
symbolic[ x 2 ^ x sin * ] symbolic[ x ] symbolic[ x 2 ^ ] by-parts-u expr.
! => -x^2*cos(x) - integrate(-2*x*cos(x), x)
symbolic[ x 2 ^ x sin * ] symbolic[ x ] integrate expr.
! => -x^2*cos(x) + 2*x*sin(x) + 2*cos(x)
```

== A substitution you choose

$ integral 2 x e^(x^2) dif x, quad u = x^2 $

```factor
symbolic[ 2 x * x 2 ^ exp * ] symbolic[ x ] symbolic[ x 2 ^ ]
by-substitution expr.
! => exp(x^2)
symbolic[ x sin x cos * ] symbolic[ x ] symbolic[ x sin ]
by-substitution expr.
! => sin(x)^2/2
```

The integrand has to mention the substituted expression after dividing by
$u'$: $sin x \/ cos x$ fits $u = cos x$, while the equal expression
$tan x$ does not.

```factor
symbolic[ x sin x cos / ] symbolic[ x ] symbolic[ x cos ]
by-substitution expr.
! => -log(cos(x))
symbolic[ x tan ] symbolic[ x ] symbolic[ x cos ] by-substitution expr.
! => integrate(tan(x), x)
```

= Definite, improper and special integrals

== Definite integrals

$ integral_0^pi sin x dif x = 2, quad integral_0^1 x^2 dif x = 1/3 $

```factor
symbolic[ x sin ] symbolic[ x ] 0 symbolic[ pi ] definite-integrate .
! => 2
symbolic[ x 2 ^ ] symbolic[ x ] 0 1 definite-integrate .
! => 1/3
symbolic[ x exp ] symbolic[ x ] 0 1 definite-integrate expr.
! => e - 1
```

== Substituting the limits

A definite substitution maps the limits to $u(a)$ and $u(b)$, so there is
nothing to substitute back.

$ integral_0^1 2 x e^(x^2) dif x = e - 1 $

```factor
symbolic[ 2 x * x 2 ^ exp * ] symbolic[ x ] 0 1 symbolic[ x 2 ^ ]
definite-by-substitution expr.
! => e - 1
symbolic[ x sin x cos * ] symbolic[ x ] 0 symbolic[ pi 2 / ]
symbolic[ x sin ] definite-by-substitution .
! => 1/2
```

== To infinity

$ integral_0^infinity e^(-x) dif x = 1, quad integral_1^infinity 1/x^2 dif x = 1 $

```factor
symbolic[ x neg exp ] symbolic[ x ] 0 symbolic[ inf ] definite-integrate .
! => 1
symbolic[ x -2 ^ ] symbolic[ x ] 1 symbolic[ inf ] definite-integrate .
! => 1
symbolic[ x 2 ^ 1 + -1 ^ ] symbolic[ x ] 0 symbolic[ inf ]
definite-integrate expr.
! => pi/2
```

== Divergence, and a singular endpoint

$ integral_1^infinity 1/x dif x = infinity, quad integral_0^1 log x dif x = -1 $

The second integrand is unbounded at 0, and the endpoint is evaluated as a
limit.

```factor
symbolic[ 1 x / ] symbolic[ x ] 1 symbolic[ inf ] definite-integrate expr.
! => inf
symbolic[ x log ] symbolic[ x ] 0 1 definite-integrate .
! => -1
```

== The Gaussian integral

$ integral_(-infinity)^infinity e^(-(x - 5)^2 \/ 9) dif x = 3 sqrt(pi) $

There is no elementary antiderivative, so this is a rule of its own.

```factor
symbolic[ x 2 ^ neg exp ] symbolic[ x ] symbolic[ inf neg ] symbolic[ inf ]
definite-integrate expr.
! => sqrt(pi)
symbolic[ x 5 - 2 ^ 9 / neg exp ] symbolic[ x ]
symbolic[ inf neg ] symbolic[ inf ] definite-integrate expr.
! => 3*sqrt(pi)
```

== The gamma function

$ integral_0^infinity x^n e^(-a x) dif x = Gamma(n + 1)/a^(n + 1) $

```factor
symbolic[ x 2 ^ x neg exp * ] symbolic[ x ] 0 symbolic[ inf ]
definite-integrate .
! => 2
symbolic[ x 2 x * neg exp * ] symbolic[ x ] 0 symbolic[ inf ]
definite-integrate .
! => 1/4
symbolic[ 5 gamma ] .
! => 24
symbolic[ 3 2 / gamma ] expr.
! => sqrt(pi)/2
```

== Symmetry

$ integral_0^(pi\/4) log(1 + tan x) dif x = (pi log 2)/8 $

Here $f(x) + f(a + b - x)$ is constant, so the integral is
$(b - a) c \/ 2$ without any antiderivative.

```factor
symbolic[ 1 x tan + log ] symbolic[ x ] 0 symbolic[ pi 4 / ]
definite-by-symmetry expr.
! => log(2)*pi/8
```

== Differentiating under the integral sign

$ F(t) = integral_0^1 (t x^2 + x) dif x, quad F'(t) = integral_0^1 x^2 dif x $

```factor
symbolic[ t x 2 ^ * x + ] symbolic[ x ] 0 1 symbolic[ t ]
feynman-derivative .
! => 1/3
symbolic[ t x 2 ^ * x + ] symbolic[ x ] 0 1 symbolic[ t ] 0
feynman-solve expr.
! => t/3 + 1/2
```

= Limits and series

== Indeterminate quotients

$ lim_(x -> 0) (sin x)/x = 1, quad lim_(x -> 0) (1 - cos x)/x^2 = 1/2 $

```factor
symbolic[ x sin x / ] symbolic[ x ] 0 limit .
! => 1
symbolic[ 1 x cos - x 2 ^ / ] symbolic[ x ] 0 limit .
! => 1/2
```

== Zero times infinity

$ lim_(x -> 0) x log x = 0 $

```factor
symbolic[ x x log * ] symbolic[ x ] 0 limit .
! => 0
```

== Limits at infinity

$ lim_(x -> infinity) (2x^2 + 3)/(x^2 - 1) = 2, quad lim_(x -> infinity) x/e^x = 0 $

```factor
symbolic[ 2 x 2 ^ * 3 + x 2 ^ 1 - / ] symbolic[ x ] symbolic[ inf ] limit .
! => 2
symbolic[ x x exp / ] symbolic[ x ] symbolic[ inf ] limit .
! => 0
symbolic[ x atan ] symbolic[ x ] symbolic[ inf ] limit expr.
! => pi/2
```

== One to the infinity

$ lim_(x -> 0) (1 + x)^(1\/x) = e, quad lim_(x -> 0) (1 + sin 5x)^(7\/x) = e^35 $

Writing $f^g$ as $exp(g log f)$ turns this into a product the engine can
already do.

```factor
symbolic[ 1 x + 1 x / ^ ] symbolic[ x ] 0 limit expr.
! => e
symbolic[ 1 5 x * sin + 7 x / ^ ] symbolic[ x ] 0 limit expr.
! => exp(35)
```

An exponent that tends to 0 is not indeterminate, and needs no such
treatment.

```factor
symbolic[ 1 5 x * sin + x 7 / ^ ] symbolic[ x ] 0 limit .
! => 1
```

== No limit

$ lim_(x -> infinity) sin x "does not exist" $

```factor
symbolic[ x sin ] symbolic[ x ] symbolic[ inf ] limit expr.
! => limit(sin(x), x, inf)
```

== Maclaurin series

$ e^x approx 1 + x + x^2/2 + x^3/6 $

```factor
symbolic[ x exp ] symbolic[ x ] 3 maclaurin expr.
! => x^3/6 + x^2/2 + x + 1
symbolic[ x sin ] symbolic[ x ] 5 maclaurin expr.
! => x^5/120 - x^3/6 + x
symbolic[ 1 x + log ] symbolic[ x ] 3 maclaurin expr.
! => x^3/3 - x^2/2 + x
```

== Expanding about another point

$ e^x "about" x = 1 $

```factor
symbolic[ x exp ] symbolic[ x ] 1 2 taylor expr.
! => e + e*(x - 1) + e*(x - 1)^2/2
symbolic[ x 3 ^ 2 x 2 ^ * - 5 + ] symbolic[ x ] 4 maclaurin expr.
! => x^3 - 2*x^2 + 5
```

= Rules, compilation and numerics

== The Pythagorean identity

$ sin^2 x + cos^2 x = 1 $

A rule set rewrites matching subexpressions, in any order of terms, and
leaves the rest alone.

```factor
symbolic[ x sin 2 ^ x cos 2 ^ + ] pythagorean-rules rewrite .
! => 1
symbolic[ y 1 + sin 2 ^ y 1 + cos 2 ^ + z + ] pythagorean-rules rewrite expr.
! => z + 1
symbolic[ x sin 2 ^ y cos 2 ^ + ] pythagorean-rules rewrite expr.
! => cos(y)^2 + sin(x)^2
```

== Rules you write

A rule literal uses pattern variables written #raw("?x").

```factor
symbolic[ a b + c * ] rule[ ?x ?y + ?z * => ?x ?z * ?y ?z * + ] 1array
rewrite expr.
! => a*c + b*c
symbolic[ x y 3 ^ * log ] log-expand-rules rewrite expr.
! => 3*log(y) + log(x)
symbolic[ x exp y exp * z * ] exp-rules rewrite expr.
! => z*exp(x + y)
```

== Conditional rules

A rule can carry a test, here that the exponent is an integer.

```factor
symbolic[ x 2 ^ log x y ^ log + ]
symbolic[ ?a ?n ^ log ] symbolic[ ?n ?a log * ] [ "n" binding integer? ]
<conditional-rule> 1array rewrite expr.
! => 2*log(x) + log(x^y)
```

== Compiling an expression

An expression becomes a quotation, or a compiled word, taking the
variables' values.

```factor
3 4 symbolic[ x 2 ^ y 2 ^ + ] { T{ sym f "x" } T{ sym f "y" } }
expr>quot call( x y -- r ) .
! => 25
2 symbolic[ x -3 ^ ] { T{ sym f "x" } } expr>quot call( x -- r ) .
! => 1/8
```

== Numeric integration

$ integral_0^1 e^(-x^2) dif x approx 0.7468 $

```factor
symbolic[ x 2 ^ neg exp ] T{ sym f "x" } 0 1 nintegrate .
! => 0.7468241328202144
```

== Checking an antiderivative numerically

Differentiating the result and evaluating both at a point is a quick check
that a rule did the right thing.

```factor
symbolic[ x 2 ^ x sin * ] symbolic[ x ] integrate
symbolic[ x ] differentiate { { T{ sym f "x" } 0.7 } } subs evalf .
! => 0.31566666674646854
symbolic[ 0.7 2 ^ 0.7 sin * ] evalf .
! => 0.31566666674646854
```
