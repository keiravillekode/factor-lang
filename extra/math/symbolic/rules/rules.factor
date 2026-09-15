! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays assocs combinators kernel lexer math
math.symbolic parser quotations sequences ;
IN: math.symbolic.rules

! A rule rewrites expressions matching lhs to rhs. Pattern variables
! (?x in symbolic[ ] and rule[ ]) match any expression, the same
! expression wherever they repeat. rhs is an expression using the
! pattern variables, or a quotation ( bindings -- expr ). condition is
! f or a quotation ( bindings -- ? ).
TUPLE: rule lhs rhs condition ;

: <rule> ( lhs rhs -- rule ) f rule boa ;

: <conditional-rule> ( lhs rhs condition -- rule ) rule boa ;

! The expression bound to pattern variable name.
: binding ( bindings name -- expr ) <pvar> of ;

ERROR: bad-rule tokens ;

<PRIVATE

: parse-rule-side ( tokens -- expr )
    dup parse-symbolic-tokens dup length 1 =
    [ nip first ] [ drop bad-rule ] if ;

: split-rule ( tokens -- lhs rhs )
    dup "=>" swap index [ cut rest ] [ bad-rule ] if* ;

PRIVATE>

SYNTAX: rule[
    "]" parse-tokens split-rule [ parse-rule-side ] bi@ <rule> suffix! ;

<PRIVATE

DEFER: (match)

:: bind-pvar ( pvar expr bindings -- bindings/f )
    pvar bindings at* [ expr = bindings f ? ]
    [ drop bindings pvar expr 2array suffix ] if ;

! Match each pattern to a distinct expression, trying every
! assignment. Outputs the bindings and the unmatched expressions.
:: match-unordered ( patterns exprs bindings -- bindings/f rest/f )
    patterns empty? [ bindings exprs ] [
        patterns unclip :> ( others pattern )
        exprs length <iota> [| i |
            pattern i exprs nth bindings (match) [| b |
                others i exprs remove-nth b match-unordered
                over [ 2array ] [ 2drop f ] if
            ] [ f ] if*
        ] map-find drop [ first2 ] [ f f ] if*
    ] if ;

: patterns-first ( patterns -- patterns' )
    [ pvar? not ] partition append ;

:: match-all ( patterns exprs bindings -- bindings/f )
    patterns length exprs length = [
        patterns patterns-first exprs bindings match-unordered
        empty? [ drop f ] unless
    ] [ f ] if ;

:: (match) ( pattern expr bindings -- bindings/f )
    {
        { [ pattern pvar? ] [ pattern expr bindings bind-pvar ] }
        { [ pattern add? ] [
            expr add? [ pattern terms>> expr terms>> bindings match-all ] [ f ] if
        ] }
        { [ pattern mul? ] [
            expr mul? [ pattern factors>> expr factors>> bindings match-all ] [ f ] if
        ] }
        { [ pattern pow? ] [
            expr pow? [
                pattern base>> expr base>> bindings (match)
                [ [ pattern exponent>> expr exponent>> ] dip (match) ] [ f ] if*
            ] [ f ] if
        ] }
        { [ pattern fn? ] [
            expr fn? [ pattern name>> expr name>> = ] [ f ] if
            [ pattern arg>> expr arg>> bindings (match) ] [ f ] if
        ] }
        { [ pattern derivative? ] [
            expr derivative? [
                pattern expr>> expr expr>> bindings (match)
                [ [ pattern var>> expr var>> ] dip (match) ] [ f ] if*
            ] [ f ] if
        ] }
        [ pattern expr = bindings f ? ]
    } cond ;

! Like match, but a sum or product pattern may match some of the terms
! or factors of a sum or product; the rest are output too.
:: match-some ( pattern expr -- bindings/f rest )
    {
        { [ pattern add? expr add? and ] [
            pattern terms>> patterns-first expr terms>> { } match-unordered
        ] }
        { [ pattern mul? expr mul? and ] [
            pattern factors>> patterns-first expr factors>> { } match-unordered
        ] }
        [ pattern expr { } (match) { } ]
    } cond ;

:: instantiate ( rhs bindings -- expr )
    rhs callable?
    [ bindings rhs call( bindings -- expr ) ] [ rhs bindings subs ] if ;

PRIVATE>

! The bindings of pattern variables when pattern matches all of expr.
: match ( pattern expr -- bindings/f ) { } (match) ;

! The rewritten expression, or f when the rule does not apply.
:: apply-rule ( expr rule -- expr'/f )
    rule lhs>> expr match-some :> ( bindings rest )
    bindings [
        rule condition>> [ bindings swap call( bindings -- ? ) ] [ t ] if*
    ] [ f ] if [
        rule rhs>> bindings instantiate
        rest empty? [
            rest swap suffix expr add? [ >add ] [ >mul ] if
        ] unless
        dup expr = [ drop f ] when
    ] [ f ] if ;

<PRIVATE

CONSTANT: max-rewrite-passes 100

:: rewrite-node ( expr rules -- expr' )
    expr {
        { [ dup add? ] [ terms>> [ rules rewrite-node ] map >add ] }
        { [ dup mul? ] [ factors>> [ rules rewrite-node ] map >mul ] }
        { [ dup pow? ] [
            [ base>> rules rewrite-node ] [ exponent>> rules rewrite-node ] bi s^
        ] }
        { [ dup fn? ] [ [ arg>> rules rewrite-node ] [ name>> ] bi apply-fn ] }
        { [ dup derivative? ] [
            [ expr>> rules rewrite-node ] [ var>> ] bi <derivative>
        ] }
        [ ]
    } cond
    dup rules [ apply-rule ] with map-find drop [ nip ] when* ;

:: (rewrite) ( expr rules passes -- expr' )
    passes 0 = [ expr ] [
        expr rules rewrite-node :> next
        next expr = [ expr ] [ next rules passes 1 - (rewrite) ] if
    ] if ;

PRIVATE>

! Apply rules everywhere in expr, innermost first, until none applies.
: rewrite ( expr rules -- expr' )
    max-rewrite-passes (rewrite) ;

: pythagorean-rules ( -- rules )
    {
        [ symbolic[ ?x sin 2 ^ ?x cos 2 ^ + ] 1 <rule> ]
        [ symbolic[ ?a ?x sin 2 ^ * ?a ?x cos 2 ^ * + ] symbolic[ ?a ] <rule> ]
    } [ call( -- rule ) ] map ;

: trig-rules ( -- rules )
    pythagorean-rules
    {
        [ symbolic[ ?x tan ] symbolic[ ?x sin ?x cos / ] <rule> ]
        [ symbolic[ 2 ?x sin * ?x cos * ] symbolic[ 2 ?x * sin ] <rule> ]
    } [ call( -- rule ) ] map append ;

: hyperbolic-rules ( -- rules )
    {
        [ symbolic[ ?x cosh 2 ^ ?x sinh 2 ^ - ] 1 <rule> ]
        [
            symbolic[ ?a ?x cosh 2 ^ * ?b ?x sinh 2 ^ * + ] symbolic[ ?a ]
            [ [ "a" binding ] [ "b" binding ] bi s+ 0 number= ] <conditional-rule>
        ]
        [ symbolic[ ?x tanh ] symbolic[ ?x sinh ?x cosh / ] <rule> ]
    } [ call( -- rule ) ] map ;

: log-expand-rules ( -- rules )
    {
        [ symbolic[ ?a ?b * log ] symbolic[ ?a log ?b log + ] <rule> ]
        [ symbolic[ ?a ?n ^ log ] symbolic[ ?n ?a log * ] <rule> ]
    } [ call( -- rule ) ] map ;

: exp-rules ( -- rules )
    {
        [ symbolic[ ?a exp ?b exp * ] symbolic[ ?a ?b + exp ] <rule> ]
        [ symbolic[ ?a exp ?n ^ ] symbolic[ ?a ?n * exp ] <rule> ]
    } [ call( -- rule ) ] map ;
