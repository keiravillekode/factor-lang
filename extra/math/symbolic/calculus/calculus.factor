! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays assocs combinators
combinators.short-circuit kernel math math.numerical-integration
math.symbolic namespaces sequences ;
IN: math.symbolic.calculus

DEFER: doit
DEFER: integrate
DEFER: definite-integrate

GENERIC#: differentiate 1 ( expr var -- expr' )

M: number differentiate 2drop 0 ;

M: sym differentiate = 1 0 ? ;

M: const differentiate 2drop 0 ;

M: add differentiate [ terms>> ] dip '[ _ differentiate ] map >add ;

M:: mul differentiate ( expr var -- expr' )
    expr factors>> :> factors
    factors length <iota> [| i |
        i factors nth var differentiate
        i factors remove-nth >mul s*
    ] map >add ;

M:: pow differentiate ( expr var -- expr' )
    expr base>> :> b
    expr exponent>> :> n
    {
        { [ n var free-of? ] [ n b n 1 s- s^ s* b var differentiate s* ] }
        { [ b var free-of? ] [ expr b slog s* n var differentiate s* ] }
        [
            expr
            n var differentiate b slog s*
            n b var differentiate s* b s/ s+
            s*
        ]
    } cond ;

M:: fn differentiate ( expr var -- expr' )
    expr arg>> :> u
    u var differentiate
    u expr name>> {
        { "sin" [ scos ] }
        { "cos" [ ssin sneg ] }
        { "tan" [ scos -2 s^ ] }
        { "exp" [ sexp ] }
        { "log" [ -1 s^ ] }
    } case s* ;

M: derivative differentiate [ doit ] dip differentiate ;

! Leibniz integral rule; the integration variable is bound.
M:: integral differentiate ( expr var -- expr' )
    expr var>> :> x
    {
        { [ x var = ] [ expr from>> [ 0 ] [ expr expr>> ] if ] }
        { [ expr from>> not ] [ expr expr>> var differentiate x integrate ] }
        [
            expr expr>> x expr to>> 2array 1array subs
            expr to>> var differentiate s*
            expr expr>> x expr from>> 2array 1array subs
            expr from>> var differentiate s* s-
            expr expr>> var differentiate x expr from>> expr to>>
            definite-integrate s+
        ]
    } cond ;

<PRIVATE

SYMBOL: integration-depth

CONSTANT: max-integration-depth 24

DEFER: (integrate)

! a and b when expr = a*x + b, with a nonzero and free of x
:: linear-coefficients ( expr x -- a/f b/f )
    expr x differentiate :> a
    a x free-of? a 0 number= not and
    [ a expr x 0 2array 1array subs ] [ f f ] if ;

:: polynomial? ( expr x -- ? )
    {
        { [ expr x free-of? ] [ t ] }
        { [ expr x = ] [ t ] }
        { [ expr add? ] [ expr terms>> [ x polynomial? ] all? ] }
        { [ expr mul? ] [ expr factors>> [ x polynomial? ] all? ] }
        { [ expr pow? ] [
            expr exponent>> { [ integer? ] [ 0 > ] } 1&&
            expr base>> x polynomial? and
        ] }
        [ f ]
    } cond ;

: fn-named? ( expr name -- ? )
    over fn? [ [ name>> ] dip = ] [ 2drop f ] if ;

:: integrate-fn ( expr x -- F/f )
    expr arg>> :> u
    u x linear-coefficients drop :> a
    a [
        u expr name>> {
            { "sin" [ scos sneg ] }
            { "cos" [ ssin ] }
            { "tan" [ scos slog sneg ] }
            { "exp" [ sexp ] }
            { "log" [ dup slog s* u s- ] }
        } case a s/
    ] [ f ] if ;

:: integrate-pow ( expr x -- F/f )
    expr base>> :> b
    expr exponent>> :> n
    {
        { [ n 2 number= b "sin" fn-named? and ] [
            1 2 b arg>> s* scos s- 2 s/ x (integrate)
        ] }
        { [ n 2 number= b "cos" fn-named? and ] [
            1 2 b arg>> s* scos s+ 2 s/ x (integrate)
        ] }
        { [ n x free-of? ] [
            b x linear-coefficients drop :> a
            a [
                n -1 number=
                [ b slog a s/ ]
                [ b n 1 s+ s^ n 1 s+ a s* s/ ] if
            ] [ f ] if
        ] }
        { [ b x free-of? ] [
            n x linear-coefficients drop :> a
            a [ expr a b slog s* s/ ] [ f ] if
        ] }
        [ f ]
    } cond ;

! exp(u)*sin(v) and exp(u)*cos(v) with u, v linear
:: integrate-exp-trig ( factors x -- F/f )
    factors length 2 = [
        factors [ "exp" fn-named? ] find nip :> ex
        factors [ { [ "sin" fn-named? ] [ "cos" fn-named? ] } 1|| ] find nip :> tr
        ex tr and [
            ex arg>> x linear-coefficients drop :> a
            tr arg>> x linear-coefficients drop :> b
            a b and [
                tr arg>> :> v
                a tr s*
                b v tr "sin" fn-named? [ scos sneg ] [ ssin ] if s* s+
                ex s* a a s* b b s* s+ s/
            ] [ f ] if
        ] [ f ] if
    ] [ f ] if ;

! p*log(u): P*log(u) - integral(P*u'/u) where P = integral(p)
:: integrate-log-by-parts ( factors x -- F/f )
    factors [ "log" fn-named? ] partition :> ( logs others )
    logs length 1 = others >mul x polynomial? and [
        logs first :> g
        others >mul x (integrate) :> P
        P [
            P g s*
            P g arg>> x differentiate s* g arg>> s/ x (integrate)
            dup [ s- ] [ 2drop f ] if
        ] [ f ] if
    ] [ f ] if ;

! p*g: p*G - integral(p'*G) where G = integral(g), for polynomial p
:: integrate-by-parts ( factors x -- F/f )
    factors [ x polynomial? ] partition :> ( ps gs )
    ps empty? not gs length 1 = and [
        ps >mul :> p
        gs first x (integrate) :> G
        G [
            p G s*
            p x differentiate G s* x (integrate)
            dup [ s- ] [ 2drop f ] if
        ] [ f ] if
    ] [ f ] if ;

! Ways to write a factor as outer(u): { u outer(t) } pairs
:: substitution-candidates ( factor t x -- pairs )
    factor {
        { [ dup fn? ] [
            [ [ arg>> ] [ name>> t swap apply-fn ] bi 2array ]
            [ t 2array ] bi 2array
        ] }
        { [ dup pow? ] [
            dup exponent>> x free-of?
            [ [ base>> ] [ exponent>> t swap s^ ] bi 2array 1array ]
            [ drop { } ] if
        ] }
        [ drop { } ]
    } cond ;

! outer(u)*rest where rest is c*u' for a constant c
:: integrate-substitution ( factors x -- F/f )
    "%u" <sym> :> t
    factors length <iota> [| i |
        i factors nth t x substitution-candidates
        i factors remove-nth >mul :> rest
        [
            first2 :> ( u outer )
            rest u x differentiate s/ :> ratio
            ratio x free-of? [
                outer t (integrate)
                [ t u 2array 1array subs ratio s* ] [ f ] if*
            ] [ f ] if
        ] map-find drop
    ] map-find drop ;

:: integrate-mul ( expr x -- F/f )
    expr factors>> [ x free-of? ] partition :> ( consts deps )
    consts empty? [
        {
            [ integrate-exp-trig ]
            [ integrate-log-by-parts ]
            [ integrate-by-parts ]
            [ integrate-substitution ]
        } [ deps x rot call( factors x -- F/f ) ] map-find drop
    ] [
        consts >mul deps >mul x (integrate) dup [ s* ] [ 2drop f ] if
    ] if ;

:: (integrate-expr) ( expr x -- F/f )
    {
        { [ expr x free-of? ] [ expr x s* ] }
        { [ expr x = ] [ x 2 s^ 2 s/ ] }
        { [ expr add? ] [
            expr terms>> [ x (integrate) ] map
            dup [ ] all? [ >add ] [ drop f ] if
        ] }
        { [ expr mul? ] [ expr x integrate-mul ] }
        { [ expr pow? ] [ expr x integrate-pow ] }
        { [ expr fn? ] [ expr x integrate-fn ] }
        [ f ]
    } cond ;

: (integrate) ( expr x -- F/f )
    integration-depth get max-integration-depth >= [ 2drop f ] [
        integration-depth get 1 + integration-depth
        [ (integrate-expr) ] with-variable
    ] if ;

: antiderivative ( expr x -- F/f )
    0 integration-depth [ (integrate) ] with-variable ;

PRIVATE>

: integrate ( expr x -- expr' )
    2dup antiderivative [ 2nip ] [ <integral> ] if* ;

:: definite-integrate ( expr x from to -- expr' )
    expr x antiderivative [| F |
        F x to 2array 1array subs
        F x from 2array 1array subs s-
    ] [ expr x from to <definite-integral> ] if* ;

:: nintegrate ( expr x from to -- value )
    from evalf to evalf
    [ x swap 2array 1array expr swap subs evalf ] integrate-simpson ;

GENERIC: doit ( expr -- expr' )

M: object doit ;

M: add doit terms>> [ doit ] map >add ;

M: mul doit factors>> [ doit ] map >mul ;

M: pow doit [ base>> doit ] [ exponent>> doit ] bi s^ ;

M: fn doit [ arg>> doit ] [ name>> ] bi apply-fn ;

M: derivative doit [ expr>> doit ] [ var>> ] bi differentiate ;

M: integral doit
    dup from>> [
        { [ expr>> doit ] [ var>> ] [ from>> doit ] [ to>> doit ] } cleave
        definite-integrate
    ] [ [ expr>> doit ] [ var>> ] bi integrate ] if ;
