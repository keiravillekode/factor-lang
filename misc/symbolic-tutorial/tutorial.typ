#set page(margin: 2.5cm)
#set text(size: 11pt)
#set heading(numbering: "1.")
#show raw.where(block: true): it => block(
  fill: luma(245), inset: 8pt, radius: 3pt, width: 100%, it,
)

= Symbolic algebra in Factor

A tour of #raw("math.symbolic") and its companion vocabularies, as worked
problems. Every Factor block here is run by
#raw("misc/symbolic-tutorial/check.py"), which compares what Factor prints
against the #raw("! =>") lines, so the outputs in this document are the
real ones.

Expressions are written in postfix inside #raw("symbolic[ ... ]"):
numbers are numbers, #raw("+ - * / ^ neg sqrt sin cos tan exp log") and
the inverse, hyperbolic and gamma functions build expressions,
#raw("pi"), #raw("e") and #raw("inf") are constants, and any other token
is a variable. #raw("expr.") prints an expression in ordinary notation.

== Simplifying and expanding

$ x + x, quad x dot x dot x, quad (x + 1)^2 $

Sums and products are simplified as they are built, and #raw("expand")
multiplies out.

```factor
symbolic[ x x + ] expr.
! => 2*x
symbolic[ x x * x * ] expr.
! => x^3
symbolic[ x 1 + 2 ^ ] expand expr.
! => x^2 + 2*x + 1
```

Numbers stay exact, and a number multiplying a sum is distributed.

```factor
symbolic[ 1 2 / 1 3 / + ] .
! => 5/6
symbolic[ 2 x 1 + * ] expr.
! => 2*x + 2
```

== Differentiating a product

$ dif / (dif x) (x sin x) = x cos x + sin x $

```factor
symbolic[ x x sin * ] symbolic[ x ] differentiate expr.
! => x*cos(x) + sin(x)
```

The chain rule and the general power rule work too.

```factor
symbolic[ x 2 ^ exp ] symbolic[ x ] differentiate expr.
! => 2*x*exp(x^2)
symbolic[ x x ^ ] symbolic[ x ] differentiate expr.
! => x^x*(log(x) + 1)
```

== Classifying a critical point

$ f(x, y) = x^3 - 3 x y + y^3 $

The gradient vanishes at $(1, 1)$. The Hessian and its determinant settle
what kind of point it is.

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

With $f_(x x) = 6 > 0$ and determinant $36 x y - 9 = 27 > 0$ at $(1, 1)$,
it is a local minimum; at the origin the determinant is negative, so that
is a saddle.

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

== Antiderivatives by rule

$ integral x^2 dif x, quad integral sin 2 x dif x, quad integral 1/x dif x $

```factor
symbolic[ x 2 ^ ] symbolic[ x ] integrate expr.
! => x^3/3
symbolic[ 2 x * sin ] symbolic[ x ] integrate expr.
! => -cos(2*x)/2
symbolic[ 1 x / ] symbolic[ x ] integrate expr.
! => log(x)
```

When no rule applies the integral is returned unevaluated, which is the
honest answer rather than a wrong one.

```factor
symbolic[ x 2 ^ neg exp ] symbolic[ x ] integrate expr.
! => integrate(exp(-x^2), x)
```

== Integration by parts

$ integral x e^x dif x = x e^x - integral e^x dif x $

#raw("by-parts-u") takes the $u$ you choose and leaves the remaining
integral unevaluated, so the step is visible; #raw("doit") finishes it.

```factor
symbolic[ x x exp * ] symbolic[ x ] symbolic[ x ] by-parts-u expr.
! => x*exp(x) - integrate(exp(x), x)
symbolic[ x x exp * ] symbolic[ x ] symbolic[ x ] by-parts-u doit expr.
! => x*exp(x) - exp(x)
```

For $integral log x dif x$ the trick is $dif v = dif x$, that is
#raw("dv") of 1.

```factor
symbolic[ x log ] symbolic[ x ] 1 by-parts-dv expr.
! => x*log(x) - integrate(1, x)
symbolic[ x log ] symbolic[ x ] 1 by-parts-dv doit expr.
! => -x + x*log(x)
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

A definite integral substitutes the limits too, so there is nothing to
substitute back.

```factor
symbolic[ 2 x * x 2 ^ exp * ] symbolic[ x ] 0 1 symbolic[ x 2 ^ ]
definite-by-substitution expr.
! => e - 1
```

== Definite, improper and Gaussian integrals

$ integral_0^pi sin x dif x = 2, quad integral_0^infinity e^(-x) dif x = 1 $

```factor
symbolic[ x sin ] symbolic[ x ] 0 symbolic[ pi ] definite-integrate .
! => 2
symbolic[ x neg exp ] symbolic[ x ] 0 symbolic[ inf ] definite-integrate .
! => 1
symbolic[ 1 x / ] symbolic[ x ] 1 symbolic[ inf ] definite-integrate expr.
! => inf
```

The Gaussian integral has no elementary antiderivative, so it is a rule of
its own:

$ integral_(-infinity)^infinity e^(-(x - 5)^2 / 9) dif x = 3 sqrt(pi) $

```factor
symbolic[ x 5 - 2 ^ 9 / neg exp ] symbolic[ x ]
symbolic[ inf neg ] symbolic[ inf ] definite-integrate expr.
! => 3*sqrt(pi)
```

== Limits and Taylor polynomials

$ lim_(x -> 0) x log x = 0, quad lim_(x -> 0) (sin x) / x = 1 $

```factor
symbolic[ x x log * ] symbolic[ x ] 0 limit .
! => 0
symbolic[ x sin x / ] symbolic[ x ] 0 limit .
! => 1
symbolic[ x atan ] symbolic[ x ] symbolic[ inf ] limit expr.
! => pi/2
```

$ e^x approx 1 + x + x^2/2 + x^3/6 $

```factor
symbolic[ x exp ] symbolic[ x ] 3 maclaurin expr.
! => x^3/6 + x^2/2 + x + 1
symbolic[ x sin ] symbolic[ x ] 5 maclaurin expr.
! => x^5/120 - x^3/6 + x
```
