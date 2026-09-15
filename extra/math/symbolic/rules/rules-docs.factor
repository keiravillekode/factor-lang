! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: assocs help.markup help.syntax kernel math.symbolic
quotations sequences strings ;
IN: math.symbolic.rules

HELP: rule
{ $class-description "A rewrite rule. " { $slot "lhs" } " is a pattern: an expression that may contain pattern variables, written " { $snippet "?x" } " in " { $link POSTPONE: symbolic[ } ". " { $slot "rhs" } " is an expression using those variables, or a quotation " { $snippet "( bindings -- expr )" } ". " { $slot "condition" } " is " { $link f } " or a quotation " { $snippet "( bindings -- ? )" } "." } ;

HELP: <rule>
{ $values { "lhs" "a pattern" } { "rhs" "an expression or a quotation" } { "rule" rule } }
{ $description "Creates a rule." } ;

HELP: <conditional-rule>
{ $values { "lhs" "a pattern" } { "rhs" "an expression or a quotation" } { "condition" quotation } { "rule" rule } }
{ $description "Creates a rule that applies only when " { $snippet "condition" } " returns true for the bindings." }
{ $examples { $example "USING: arrays kernel math math.symbolic math.symbolic.rules sequences ;" "symbolic[ x 2 ^ log x y ^ log + ]\nsymbolic[ ?a ?n ^ log ] symbolic[ ?n ?a log * ] [ \"n\" binding integer? ]\n<conditional-rule> 1array rewrite expr." "2*log(x) + log(x^y)" } } ;

HELP: binding
{ $values { "bindings" assoc } { "name" string } { "expr" "an expression" } }
{ $description "The expression bound to the pattern variable " { $snippet "?name" } ", for quotations in rules." } ;

HELP: bad-rule
{ $error-description "Thrown by " { $link POSTPONE: rule[ } " when there is no " { $snippet "=>" } " or a side does not give exactly one expression." } ;

HELP: rule[
{ $syntax "rule[ lhs-tokens => rhs-tokens ]" }
{ $description "A rule literal. Each side is read like " { $link POSTPONE: symbolic[ } " and must give one expression." }
{ $examples { $example "USING: arrays math.symbolic math.symbolic.rules sequences ;" "symbolic[ a b + c * ] rule[ ?x ?y + ?z * => ?x ?z * ?y ?z * + ] 1array rewrite expr." "a*c + b*c" } } ;

HELP: match
{ $values { "pattern" "a pattern" } { "expr" "an expression" } { "bindings/f" "an assoc or " { $link f } } }
{ $description "Matches all of " { $snippet "expr" } " against " { $snippet "pattern" } ", in any order of terms and factors. Outputs the bindings of the pattern variables, or " { $link f } ". A repeated pattern variable must match equal expressions." } ;

HELP: apply-rule
{ $values { "expr" "an expression" } { "rule" rule } { "expr'/f" "an expression or " { $link f } } }
{ $description "Rewrites " { $snippet "expr" } " once with " { $snippet "rule" } " at the top level, or outputs " { $link f } ". A sum or product pattern may match some of the terms or factors of a sum or product; the others are kept." } ;

HELP: rewrite
{ $values { "expr" "an expression" } { "rules" { $sequence rule } } { "expr'" "an expression" } }
{ $description "Applies the first matching rule at every subexpression, innermost first, repeatedly until no rule applies (at most 100 passes)." }
{ $examples { $example "USING: math.symbolic math.symbolic.rules ;" "symbolic[ x sin 2 ^ x cos 2 ^ + z + ] pythagorean-rules rewrite expr." "z + 1" } } ;

HELP: pythagorean-rules
{ $values { "rules" { $sequence rule } } }
{ $description "sin(x)^2 + cos(x)^2 = 1, also with a common coefficient." } ;

HELP: trig-rules
{ $values { "rules" { $sequence rule } } }
{ $description "The " { $link pythagorean-rules } ", tan(x) = sin(x)/cos(x) and 2*sin(x)*cos(x) = sin(2*x)." } ;

HELP: hyperbolic-rules
{ $values { "rules" { $sequence rule } } }
{ $description "cosh(x)^2 - sinh(x)^2 = 1, also with a common coefficient, and tanh(x) = sinh(x)/cosh(x)." } ;

HELP: log-expand-rules
{ $values { "rules" { $sequence rule } } }
{ $description "log(a*b) = log(a) + log(b) and log(a^n) = n*log(a), for positive a and b." } ;

HELP: exp-rules
{ $values { "rules" { $sequence rule } } }
{ $description "exp(a)*exp(b) = exp(a + b) and exp(a)^n = exp(a*n)." } ;

ARTICLE: "math.symbolic.rules" "Symbolic rewrite rules"
"The " { $vocab-link "math.symbolic.rules" } " vocabulary rewrites " { $vocab-link "math.symbolic" } " expressions with user-defined rules, which match sums and products in any order."
{ $subsections rule <rule> <conditional-rule> POSTPONE: rule[ binding }
"Using rules:"
{ $subsections match apply-rule rewrite }
"Rule sets:"
{ $subsections pythagorean-rules trig-rules hyperbolic-rules log-expand-rules exp-rules }
{ $subsections bad-rule } ;

ABOUT: "math.symbolic.rules"
