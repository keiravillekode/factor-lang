# Symbolic algebra in Factor: an experiment

The `symbolic-algebra` branch adds a computer algebra system to `extra/`, in
the spirit of Julia's Symbolics or a small Mathematica: symbolic expressions,
simplification, derivatives, integrals, limits, user-defined rewrite rules,
and compilation of an expression back into a Factor quotation.

This is an experiment rather than a proposal. The vocabulary names, the
syntax and the word set may all change, and nothing here is offered for the
main repository yet.

**[The branch](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra)**

## The vocabularies

| Vocabulary | What it holds |
| --- | --- |
| [`math.symbolic`](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra/extra/math/symbolic) | expressions, the `symbolic[ ]` syntax, simplification, substitution, numeric evaluation, printing |
| [`math.symbolic.calculus`](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra/extra/math/symbolic/calculus) | derivatives, gradients, Jacobians, Hessians, antiderivatives, definite and improper integrals, limits, Taylor polynomials |
| [`math.symbolic.rules`](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra/extra/math/symbolic/rules) | pattern matching and user-defined rewrite rules |
| [`math.symbolic.compile`](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra/extra/math/symbolic/compile) | compiling an expression to a quotation or to a word |

Roughly 1800 lines of implementation, 500 of help, and 640 of tests.

## Expressions

Expressions are written in postfix inside `symbolic[ ]`, so they read like the
rest of Factor, and they print in ordinary infix notation.

```factor
USING: math.symbolic math.symbolic.calculus ;

symbolic[ 3 x sin * 4 y exp * + ] expr.
```

Polynomials, `sin cos tan`, the inverse trigonometric functions, the
hyperbolic functions and their inverses, `exp`, `log`, `sqrt` and `gamma` are
all expressible, along with unevaluated derivatives and definite integrals.
Simplification is canonical: like terms collect, constant factors fold, and
exact values are kept exact, so `sin(pi/3)` is `sqrt(3)/2` rather than a
float.

## Calculus

```factor
symbolic[ x x sin * ] symbolic[ x ] differentiate expr.
! x*cos(x) + sin(x)

symbolic[ x x exp * ] symbolic[ x ] integrate expr.
! x*exp(x) - exp(x)

symbolic[ x sin ] symbolic[ x ] 0 symbolic[ pi ] definite-integrate .
! 2
```

Improper integrals work, because a bound where the antiderivative is undefined
is evaluated as a limit. The Gaussian integral is recognized directly:

```factor
symbolic[ x 5 - 2 ^ 9 / neg exp ] symbolic[ x ]
symbolic[ inf neg ] symbolic[ inf ] definite-integrate expr.
! 3*sqrt(pi)
```

Integration by parts and integration by substitution can be driven by hand
when the automatic rules do not find a form, with the user choosing either
part or the substitution. There is a rule for definite integrals that follow
from the symmetry `f(x) + f(from + to - x) = c`, and one for Feynman's trick
of differentiating under the integral sign.

Limits use substitution, l'Hopital's rule, and rewriting of `0*infinity` and
`1^infinity`:

```factor
symbolic[ 1 x + 1 x / ^ ] symbolic[ x ] 0 limit expr.
! e

symbolic[ 1 x tan + log ] symbolic[ x ] 0 symbolic[ pi 4 / ]
definite-by-symmetry expr.
! log(2)*pi/8
```

## The tutorial

Forty-five worked problems in eight sections, from simplification through
differentiation and integration to limits, series and numerics. Every Factor
block in it is machine-checked: a script extracts the blocks, runs each one,
and compares what Factor prints against the expected output recorded in the
document, so the printed answers cannot drift away from what the code
actually does.

**[Read the tutorial (PDF)](symbolic-tutorial.pdf)**

The [Typst source and the checker](https://github.com/keiravillekode/factor-lang/tree/symbolic-algebra/misc/symbolic-tutorial)
are on the branch.

## Trying it

```
git remote add keira https://github.com/keiravillekode/factor-lang.git
git fetch keira symbolic-algebra
git checkout keira/symbolic-algebra
```

The vocabularies live in `extra/`, so they load from the source tree with
`USING: math.symbolic math.symbolic.calculus ;`.

## Testing

306 unit tests across the four vocabularies, run on both the C++ VM and the
Zig VM in ReleaseSafe, with `help-lint` clean and all 49 tutorial blocks
passing.

## What it does not do

The honest boundaries of the experiment:

- Integration is a set of rules, not a decision procedure. Integrands outside
  those rules come back as an unevaluated integral rather than a wrong answer.
- `definite-by-symmetry` checks a sum that is not symbolically constant by
  sampling twelve points, so its result is a strong hint and not a proof.
  `definite-integrate` uses the rule only in the symbolically exact case.
- `nintegrate` is Simpson's rule with a fixed step count, 180 by default. A
  violently oscillatory integrand needs far more steps, and gives a quietly
  inaccurate answer until it gets them.
- Singularities strictly inside the interval of integration are not detected.
- One-sided limits are not distinguished.
- There is no equation solving, no complex analysis, and no series beyond
  Taylor polynomials.
