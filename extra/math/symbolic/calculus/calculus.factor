! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays assocs combinators
combinators.short-circuit continuations kernel math
math.numerical-integration math.symbolic math.symbolic.compile
namespaces sequences words ;
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
        { "asin" [ 2 s^ 1 swap s- ssqrt -1 s^ ] }
        { "acos" [ 2 s^ 1 swap s- ssqrt -1 s^ sneg ] }
        { "atan" [ 2 s^ 1 s+ -1 s^ ] }
        { "sinh" [ scosh ] }
        { "cosh" [ ssinh ] }
        { "tanh" [ scosh -2 s^ ] }
        { "asinh" [ 2 s^ 1 s+ ssqrt -1 s^ ] }
        { "acosh" [ 2 s^ 1 s- ssqrt -1 s^ ] }
        { "atanh" [ 2 s^ 1 swap s- -1 s^ ] }
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
            { "sinh" [ scosh ] }
            { "cosh" [ ssinh ] }
            { "tanh" [ scosh slog ] }
            { "asin" [ [ dup sasin s* ] [ 2 s^ 1 swap s- ssqrt ] bi s+ ] }
            { "acos" [ [ dup sacos s* ] [ 2 s^ 1 swap s- ssqrt ] bi s- ] }
            { "atan" [ [ dup satan s* ] [ 2 s^ 1 s+ slog 2 s/ ] bi s- ] }
            { "asinh" [ [ dup sasinh s* ] [ 2 s^ 1 s+ ssqrt ] bi s- ] }
            { "acosh" [ [ dup sacosh s* ] [ 2 s^ 1 s- ssqrt ] bi s- ] }
            { "atanh" [ [ dup satanh s* ] [ 2 s^ 1 swap s- slog 2 s/ ] bi s+ ] }
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

: at-bound ( expr x bound -- expr' ) 2array 1array subs ;

! f(x) + f(a + b - x), which is constant when the graph is symmetric
! about the midpoint of the interval
:: symmetry-sum ( expr x from to -- g )
    expr x from to s+ x s- at-bound expr s+ ;

CONSTANT: symmetry-sample-fractions { 1/8 1/4 3/8 1/2 5/8 3/4 7/8 }

:: constant-between? ( g c x from to -- ? )
    [
        c evalf :> cv
        from evalf :> a
        to evalf :> b
        symmetry-sample-fractions [| fraction |
            g x b a - fraction * a + at-bound evalf cv - abs 1e-9 <
        ] all?
    ] [ drop f ] recover ;

:: symmetry-constant-exact ( expr x from to -- c/f )
    expr x from to symmetry-sum :> g
    g x free-of? [ g ] [ f ] if ;

! Verified numerically when the sum is not symbolically constant
:: symmetry-constant ( expr x from to -- c/f )
    expr x from to symmetry-sum :> g
    g x free-of? [ g ] [
        g x from at-bound :> c
        g c x from to constant-between? [ c ] [ f ] if
    ] if ;

: symmetry-value ( c from to -- expr ) swap s- swap s* 2 s/ ;

PRIVATE>

: integrate ( expr x -- expr' )
    2dup antiderivative [ 2nip ] [ <integral> ] if* ;

:: definite-integrate ( expr x from to -- expr' )
    expr x antiderivative [| F |
        F x to 2array 1array subs
        F x from 2array 1array subs s-
    ] [
        expr x from to symmetry-constant-exact
        [ from to symmetry-value ]
        [ expr x from to <definite-integral> ] if*
    ] if* ;

! The definite integral from the symmetry f(x) + f(a + b - x) = c, which
! gives (b - a)*c/2. The sum is checked numerically when it is not
! symbolically constant.
:: definite-by-symmetry ( expr x from to -- expr' )
    expr x from to symmetry-constant
    [ from to symmetry-value ]
    [ expr x from to <definite-integral> ] if* ;

! Compiling costs a few milliseconds, which pays off only for many
! evaluation points.
CONSTANT: compile-nintegrate-steps 1000

:: nintegrate ( expr x from to -- value )
    num-steps get compile-nintegrate-steps >= [
        expr x 1array expr>word '[ _ execute( x -- value ) ]
    ] [
        [ x swap 2array 1array expr swap subs evalf ]
    ] if :> f
    from evalf to evalf [ f call( x -- value ) ] integrate-simpson ;

: gradient ( expr vars -- exprs )
    [ differentiate ] with map ;

: jacobian ( exprs vars -- matrix )
    '[ _ gradient ] map ;

ERROR: no-antiderivative expr var ;

<PRIVATE

! u*v and v*u' for integration by parts, where v is an antiderivative of dv
:: parts ( u dv x -- uv rest )
    dv x antiderivative [ dv x no-antiderivative ] unless* :> v
    u v s*
    v u x differentiate s* ;


PRIVATE>

! Integration by parts: integral(u*dv) = u*v - integral(v*u'), with the
! remaining integral left unevaluated (doit evaluates it).
:: by-parts ( x u dv -- expr' )
    u dv x parts :> ( uv rest )
    rest 0 number= [ uv ] [ uv rest x <integral> s- ] if ;

:: by-parts-u ( expr x u -- expr' )
    x u expr u s/ by-parts ;

:: by-parts-dv ( expr x dv -- expr' )
    x expr dv s/ dv by-parts ;

:: definite-by-parts ( x from to u dv -- expr' )
    u dv x parts :> ( uv rest )
    uv x to at-bound uv x from at-bound s-
    rest 0 number= [ rest x from to <definite-integral> s- ] unless ;

:: definite-by-parts-u ( expr x from to u -- expr' )
    x from to u expr u s/ definite-by-parts ;

:: definite-by-parts-dv ( expr x from to dv -- expr' )
    x from to expr dv s/ dv definite-by-parts ;

! Differentiation under the integral sign: F'(t), where F(t) is the
! definite integral of expr with respect to x.
:: feynman-derivative ( expr x from to t -- expr' )
    expr t differentiate x from to definite-integrate ;

! F(t) recovered from F'(t) and the known value F(t0): the antiderivative
! G of F'(t), as G(t) - G(t0) + F(t0). Outputs the unevaluated integral
! when a step has no closed form.
:: feynman-solve ( expr x from to t t0 -- expr' )
    expr x from to t feynman-derivative :> Fp
    Fp integral? [ expr x from to <definite-integral> ] [
        Fp t antiderivative [| G |
            G G t t0 at-bound s-
            expr t t0 at-bound x from to definite-integrate s+
        ] [ expr x from to <definite-integral> ] if*
    ] if ;

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
