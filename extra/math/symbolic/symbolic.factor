! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays assocs combinators
combinators.short-circuit generalizations io kernel lexer
linked-assocs make math math.constants math.functions math.order
math.parser prettyprint.backend prettyprint.custom sequences
sorting strings vectors ;
IN: math.symbolic

! Expressions are numbers or these tuples. Build them with the
! words below, which keep them in a canonical, simplified form.

TUPLE: sym name ;
TUPLE: const name ;
TUPLE: add terms ;
TUPLE: mul factors ;
TUPLE: pow base exponent ;
TUPLE: fn name arg ;
TUPLE: derivative expr var ;
TUPLE: integral expr var from to ;
TUPLE: pvar name ;

UNION: symbolic sym const add mul pow fn derivative integral pvar ;

: <sym> ( name -- sym ) sym boa ;

: <pvar> ( name -- pvar ) pvar boa ;

CONSTANT: pi-expr T{ const f "pi" }

CONSTANT: e-expr T{ const f "e" }

: <derivative> ( expr var -- derivative ) derivative boa ;

: <integral> ( expr var -- integral ) f f integral boa ;

: <definite-integral> ( expr var from to -- integral ) integral boa ;

ERROR: unbound-symbol name ;

ERROR: unevaluated-expression expr ;

! Printing

<PRIVATE

GENERIC: unparse-expr ( expr -- string precedence )

: ?parens ( string precedence min -- string' )
    < [ "(" ")" surround ] when ;

: unparse-at-least ( expr min -- string )
    [ unparse-expr ] dip ?parens ;

PRIVATE>

: expr>string ( expr -- string ) unparse-expr drop ;

: expr. ( expr -- ) expr>string print ;

<PRIVATE

M: integer unparse-expr [ number>string ] [ 0 < 2 4 ? ] bi ;

M: ratio unparse-expr number>string 2 ;

M: float unparse-expr [ number>string ] [ 0 < 2 4 ? ] bi ;

M: sym unparse-expr name>> 4 ;

M: const unparse-expr name>> 4 ;

M: pvar unparse-expr name>> "?" prepend 4 ;

M: fn unparse-expr
    [ name>> ] [ arg>> expr>string ] bi "(" ")" surround append 4 ;

M: derivative unparse-expr
    [ expr>> ] [ var>> ] bi [ expr>string ] bi@ ", " glue
    "D(" ")" surround 4 ;

M: integral unparse-expr
    { [ expr>> ] [ var>> ] [ from>> ] [ to>> ] } cleave 4array sift
    [ expr>string ] map ", " join "integrate(" ")" surround 4 ;

: power-string ( base exponent -- string )
    dup 1 number= [ drop 4 unparse-at-least ] [
        [ 4 unparse-at-least ] [ 4 unparse-at-least ] bi* "^" glue
    ] if ;

: negative-exponent? ( expr -- ? )
    { [ pow? ] [ exponent>> number? ] [ exponent>> 0 < ] } 1&& ;

M: pow unparse-expr
    {
        { [ dup exponent>> 1/2 = ] [ base>> expr>string "sqrt(" ")" surround 4 ] }
        { [ dup negative-exponent? ] [
            [ base>> ] [ exponent>> neg ] bi power-string
            "1/" prepend 2
        ] }
        [ [ base>> ] [ exponent>> ] bi power-string 3 ]
    } cond ;

: split-coefficient ( mul -- coefficient factors )
    factors>> dup first number? [ unclip swap ] [ 1 swap ] if ;

: factor-strings ( factors -- strings )
    [
        dup negative-exponent?
        [ [ base>> ] [ exponent>> neg ] bi power-string ]
        [ 3 unparse-at-least ] if
    ] map ;

M:: mul unparse-expr ( expr -- string precedence )
    expr split-coefficient [ negative-exponent? ] partition :> ( den num )
    dup 0 < "-" "" ? :> sign
    abs dup rational? [ >fraction ] [ 1 ] if :> ( c-num c-den )
    c-num 1 number= [ { } ] [ c-num number>string 1array ] if
    num factor-strings append
    [ "1" ] [ "*" join ] if-empty :> numerator
    c-den 1 = [ { } ] [ c-den number>string 1array ] if
    den factor-strings append :> denominators
    denominators empty? [ numerator ] [
        numerator "/" append
        denominators length 1 = [
            den length 1 = [
                den first [ base>> ] [ exponent>> neg ] bi
                dup 1 number= [ drop 3 unparse-at-least ] [ power-string ] if
            ] [ denominators first ] if
        ] [ denominators "*" join "(" ")" surround ] if append
    ] if sign prepend 2 ;

PRIVATE>

: negative-term? ( expr -- ? )
    {
        { [ dup number? ] [ 0 < ] }
        { [ dup mul? ] [ factors>> first { [ number? ] [ 0 < ] } 1&& ] }
        [ drop f ]
    } cond ;

: negate-term ( expr -- expr' )
    dup number? [ neg ] [
        factors>> unclip neg
        dup 1 number= [ drop dup length 1 = [ first ] [ mul boa ] if ]
        [ prefix mul boa ] if
    ] if ;

<PRIVATE

M: add unparse-expr
    terms>> unclip expr>string swap [
        dup negative-term?
        [ negate-term expr>string " - " prepend ]
        [ expr>string " + " prepend ] if
    ] map concat append 1 ;

PRIVATE>

! Canonical order: in sums, higher degree first and numbers last; in
! products, the number first, then variables and their powers by name.

GENERIC: degree ( expr -- n )

M: object degree drop 0 ;

M: sym degree drop 1 ;

M: pow degree
    dup base>> sym? [
        exponent>> dup integer? [ drop 0 ] unless
    ] [ drop 0 ] if ;

M: mul degree factors>> [ degree ] map-sum ;

<PRIVATE

: term-key ( expr -- key )
    [ number? 1 0 ? ]
    [ degree neg ]
    [ dup negative-term? [ negate-term ] when expr>string ] tri 3array ;

: factor-key ( expr -- key )
    {
        { [ dup number? ] [ drop 0 "" ] }
        { [ dup sym? ] [ name>> 1 swap ] }
        { [ dup pow? ] [
            base>> dup sym? [ name>> 1 swap ] [ expr>string 2 swap ] if
        ] }
        [ expr>string 2 swap ]
    } cond 2array ;

PRIVATE>

DEFER: s*
DEFER: s^
DEFER: sexp

<PRIVATE

: split-term ( expr -- coefficient rest )
    dup mul? [
        factors>> dup first number? [
            unclip swap dup length 1 = [ first ] [ mul boa ] if
        ] [ mul boa 1 swap ] if
    ] [ 1 swap ] if ;

: split-power ( expr -- base exponent )
    dup pow? [ [ base>> ] [ exponent>> ] bi ] [ 1 ] if ;

: flatten-as ( seq quot: ( expr -- ? ) slot: ( expr -- seq ) -- seq' )
    '[ dup @ [ @ ] [ 1array ] if ] map concat ; inline

PRIVATE>

DEFER: s+

:: >add ( seq -- expr )
    seq [ add? ] [ terms>> ] flatten-as [ number? ] partition :> ( numbers others )
    <linked-hash> :> coefficients
    others [ split-term coefficients at+ ] each
    coefficients >alist [ nip 0 number= ] assoc-reject
    [ swap s* ] { } assoc>map
    numbers sum dup 0 number= [ drop ] [ suffix ] if
    [ term-key ] sort-by
    dup length { { 0 [ drop 0 ] } { 1 [ first ] } [ drop add boa ] } case ;

:: >mul ( seq -- expr )
    seq [ mul? ] [ factors>> ] flatten-as [ number? ] partition :> ( numbers others )
    numbers product :> c
    c 0 number= [ c ] [
        <linked-hash> :> exponents
        others [
            split-power :> ( b n )
            b exponents at 0 or n s+ b exponents set-at
        ] each
        exponents >alist [ s^ ] { } assoc>map [ 1 number= ] reject
        dup [ { [ number? ] [ mul? ] } 1|| ] any? [
            c prefix >mul
        ] [
            [ factor-key ] sort-by
            c 1 number= [ c prefix ] unless
            dup length { { 0 [ drop 1 ] } { 1 [ first ] } [ drop mul boa ] } case
        ] if
    ] if ;

: s+ ( a b -- a+b ) 2array >add ;

: s* ( a b -- a*b ) 2array >mul ;

:: s^ ( base exponent -- base^exponent )
    {
        { [ exponent 0 number= ] [ 1 ] }
        { [ exponent 1 number= ] [ base ] }
        { [ base 1 number= ] [ 1 ] }
        { [ base number? exponent integer? and ] [
            base 0 number= exponent 0 < and
            [ base exponent pow boa ] [ base exponent ^ ] if
        ] }
        { [ base float? exponent number? and ] [ base exponent ^ ] }
        { [ base number? exponent float? and ] [ base exponent ^ ] }
        { [ base e-expr = ] [ exponent sexp ] }
        { [ base pow? exponent integer? and ] [
            base base>> base exponent>> exponent s* s^
        ] }
        { [ base mul? exponent integer? and ] [
            base factors>> [ exponent s^ ] map >mul
        ] }
        [ base exponent pow boa ]
    } cond ;

: sneg ( a -- -a ) -1 s* ;

: s- ( a b -- a-b ) sneg s+ ;

: s/ ( a b -- a/b ) -1 s^ s* ;

: ssqrt ( a -- sqrt[a] ) 1/2 s^ ;

<PRIVATE

! k when expr is k*pi for a rational k
: pi-multiple ( expr -- k/f )
    {
        { [ dup pi-expr = ] [ drop 1 ] }
        { [ dup mul? ] [
            factors>> dup length 2 = [
                first2 pi-expr = [ dup rational? [ drop f ] unless ] [ drop f ] if
            ] [ drop f ] if
        ] }
        [ drop f ]
    } cond ;

: half-odd? ( k -- ? ) { [ ratio? ] [ denominator 2 = ] } 1&& ;

PRIVATE>

:: ssin ( u -- sin[u] )
    u pi-multiple :> k
    {
        { [ u float? ] [ u sin ] }
        { [ u 0 number= ] [ 0 ] }
        { [ k integer? ] [ 0 ] }
        { [ k half-odd? ] [ k numerator 4 rem 1 = 1 -1 ? ] }
        { [ u negative-term? ] [ u negate-term ssin sneg ] }
        [ "sin" u fn boa ]
    } cond ;

:: scos ( u -- cos[u] )
    u pi-multiple :> k
    {
        { [ u float? ] [ u cos ] }
        { [ u 0 number= ] [ 1 ] }
        { [ k integer? ] [ k even? 1 -1 ? ] }
        { [ k half-odd? ] [ 0 ] }
        { [ u negative-term? ] [ u negate-term scos ] }
        [ "cos" u fn boa ]
    } cond ;

:: stan ( u -- tan[u] )
    {
        { [ u float? ] [ u tan ] }
        { [ u 0 number= ] [ 0 ] }
        { [ u pi-multiple integer? ] [ 0 ] }
        { [ u negative-term? ] [ u negate-term stan sneg ] }
        [ "tan" u fn boa ]
    } cond ;

:: sexp ( u -- exp[u] )
    {
        { [ u float? ] [ u e^ ] }
        { [ u 0 number= ] [ 1 ] }
        { [ u 1 number= ] [ e-expr ] }
        { [ u { [ fn? ] [ name>> "log" = ] } 1&& ] [ u arg>> ] }
        [ "exp" u fn boa ]
    } cond ;

:: slog ( u -- log[u] )
    {
        { [ u { [ float? ] [ 0 > ] } 1&& ] [ u log ] }
        { [ u 1 number= ] [ 0 ] }
        { [ u e-expr = ] [ 1 ] }
        { [ u { [ fn? ] [ name>> "exp" = ] } 1&& ] [ u arg>> ] }
        [ "log" u fn boa ]
    } cond ;

ERROR: unknown-function name ;

: apply-fn ( arg name -- expr )
    {
        { "sin" [ ssin ] }
        { "cos" [ scos ] }
        { "tan" [ stan ] }
        { "exp" [ sexp ] }
        { "log" [ slog ] }
        [ unknown-function ]
    } case ;

! Substitution, free variables, evaluation, expansion

DEFER: subs

<PRIVATE

GENERIC#: (subs) 1 ( expr assoc -- expr' )

M: object (subs) drop ;

M: add (subs) [ terms>> ] dip '[ _ subs ] map >add ;

M: mul (subs) [ factors>> ] dip '[ _ subs ] map >mul ;

M: pow (subs) [ [ base>> ] [ exponent>> ] bi ] dip '[ _ subs ] bi@ s^ ;

M: fn (subs) [ [ arg>> ] dip subs ] [ drop name>> ] 2bi apply-fn ;

M: derivative (subs) [ [ expr>> ] dip subs ] [ drop var>> ] 2bi <derivative> ;

M: integral (subs)
    {
        [ [ expr>> ] dip subs ]
        [ drop var>> ]
        [ [ from>> ] dip over [ subs ] [ drop ] if ]
        [ [ to>> ] dip over [ subs ] [ drop ] if ]
    } 2cleave integral boa ;

PRIVATE>

: subs ( expr assoc -- expr' )
    2dup at* [ 2nip ] [ drop (subs) ] if ;

: simplify ( expr -- expr' ) { } subs ;

GENERIC#: free-of? 1 ( expr var -- ? )

M: object free-of? = not ;

M: add free-of? [ terms>> ] dip '[ _ free-of? ] all? ;

M: mul free-of? [ factors>> ] dip '[ _ free-of? ] all? ;

M: pow free-of? [ [ base>> ] [ exponent>> ] bi ] dip '[ _ free-of? ] bi@ and ;

M: fn free-of? [ arg>> ] dip free-of? ;

M: derivative free-of? [ expr>> ] dip free-of? ;

M: integral free-of?
    [ [ expr>> ] [ from>> ] [ to>> ] tri 3array sift ] dip '[ _ free-of? ] all? ;

GENERIC: evalf ( expr -- number )

M: number evalf >float ;

M: sym evalf name>> unbound-symbol ;

M: pvar evalf name>> "?" prepend unbound-symbol ;

M: const evalf name>> "pi" = pi e ? ;

M: add evalf terms>> [ evalf ] map-sum ;

M: mul evalf factors>> [ evalf ] map product ;

M: pow evalf [ base>> evalf ] [ exponent>> evalf ] bi ^ ;

M: fn evalf [ arg>> evalf ] [ name>> ] bi apply-fn ;

M: derivative evalf unevaluated-expression ;

M: integral evalf unevaluated-expression ;

<PRIVATE

:: distribute ( seqs -- combinations )
    seqs { { } } [| combinations terms |
        combinations [| combination | terms [ combination swap suffix ] map ] map concat
    ] reduce ;

PRIVATE>

GENERIC: expand ( expr -- expr' )

M: object expand ;

M: add expand terms>> [ expand ] map >add ;

M: mul expand
    factors>> [ expand dup add? [ terms>> ] [ 1array ] if ] map
    distribute [ >mul ] map >add ;

M: pow expand
    [ base>> expand ] [ exponent>> ] bi
    over add? over { [ integer? ] [ 1 > ] } 1&& and
    [ swap <repetition> >array mul boa expand ] [ s^ ] if ;

M: fn expand [ arg>> expand ] [ name>> ] bi apply-fn ;

! symbolic[ ... ] literals

<PRIVATE

ERROR: symbolic-stack-underflow token ;

CONSTANT: symbolic-words H{
    { "+" { 2 [ first2 s+ ] } }
    { "-" { 2 [ first2 s- ] } }
    { "*" { 2 [ first2 s* ] } }
    { "/" { 2 [ first2 s/ ] } }
    { "^" { 2 [ first2 s^ ] } }
    { "neg" { 1 [ first sneg ] } }
    { "sqrt" { 1 [ first ssqrt ] } }
    { "sin" { 1 [ first ssin ] } }
    { "cos" { 1 [ first scos ] } }
    { "tan" { 1 [ first stan ] } }
    { "exp" { 1 [ first sexp ] } }
    { "log" { 1 [ first slog ] } }
    { "pi" { 0 [ drop pi-expr ] } }
    { "e" { 0 [ drop e-expr ] } }
    { "D" { 2 [ first2 <derivative> ] } }
    { "integral" { 2 [ first2 <integral> ] } }
    { "definite-integral" { 4 [ first4 <definite-integral> ] } }
}

:: parse-symbolic-token ( stack token -- )
    token string>number [ stack push ] [
        token symbolic-words at [
            first2 :> ( arity quot )
            stack length arity - :> i
            i 0 < [ token symbolic-stack-underflow ] when
            stack i tail >array quot call( args -- expr )
            i stack shorten
            stack push
        ] [
            token { [ "?" head? ] [ length 1 > ] } 1&&
            [ token rest <pvar> ] [ token <sym> ] if
            stack push
        ] if*
    ] if* ;

PRIVATE>

: parse-symbolic-tokens ( tokens -- exprs )
    V{ } clone [ '[ _ swap parse-symbolic-token ] each ] keep >array ;

SYNTAX: symbolic[
    V{ } clone "]" over '[ _ swap parse-symbolic-token ] each-token
    [ suffix! ] each ;

<PRIVATE

GENERIC: (postfix) ( expr -- )

M: number (postfix) number>string , ;

M: sym (postfix) name>> , ;

M: const (postfix) name>> , ;

M: pvar (postfix) name>> "?" prepend , ;

M: add (postfix) terms>> unclip (postfix) [ (postfix) "+" , ] each ;

M: mul (postfix) factors>> unclip (postfix) [ (postfix) "*" , ] each ;

M: pow (postfix) [ base>> (postfix) ] [ exponent>> (postfix) ] bi "^" , ;

M: fn (postfix) [ arg>> (postfix) ] [ name>> , ] bi ;

M: derivative (postfix) [ expr>> (postfix) ] [ var>> (postfix) ] bi "D" , ;

M: integral (postfix)
    dup from>> [
        { [ expr>> ] [ var>> ] [ from>> ] [ to>> ] } cleave
        [ (postfix) ] 4 napply "definite-integral" ,
    ] [
        [ expr>> (postfix) ] [ var>> (postfix) ] bi "integral" ,
    ] if ;

PRIVATE>

: expr>postfix ( expr -- string )
    [ (postfix) ] { } make " " join ;

M: symbolic pprint*
    dup expr>postfix "symbolic[ " " ]" pprint-string ;
