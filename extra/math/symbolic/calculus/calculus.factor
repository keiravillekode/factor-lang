! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays assocs combinators
combinators.short-circuit continuations kernel math
math.combinatorics math.numerical-integration math.symbolic
math.symbolic.compile namespaces sequences words ;
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

DEFER: limit

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

! 1/(u^2 + c) integrates to atan(u/sqrt(c))/(a*sqrt(c))
:: integrate-reciprocal-quadratic ( b x -- F/f )
    b terms>> :> terms
    terms length 2 = [
        terms [ x free-of? ] partition :> ( constants squares )
        constants length 1 = squares length 1 = and [
            constants first :> c
            squares first :> square
            square pow? [ square exponent>> 2 number= ] [ f ] if [
                square base>> :> u
                u x linear-coefficients drop :> a
                a c number? and [ c 0 > ] [ f ] if [
                    c ssqrt :> root
                    u root s/ satan root s/ a s/
                ] [ f ] if
            ] [ f ] if
        ] [ f ] if
    ] [ f ] if ;

:: integrate-pow ( expr x -- F/f )
    expr base>> :> b
    expr exponent>> :> n
    n -1 number= b add? and
    [ b x integrate-reciprocal-quadratic ] [ f ] if :> arc-tangent-form
    {
        { [ arc-tangent-form ] [ arc-tangent-form ] }
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

: +infinity? ( v -- ? ) infinity-expr = ;

: -infinity? ( v -- ? )
    dup mul? [ factors>> first2 infinity-expr = swap 0 < and ] [ drop f ] if ;

: infinite-sign ( v -- 1/-1 ) -infinity? -1 1 ? ;

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

! expr as constant * exp(q), where the constant is free of x
:: gaussian-form ( expr x -- constant/f q/f )
    {
        { [ expr "exp" fn-named? ] [ 1 expr arg>> ] }
        { [ expr mul? ] [
            expr factors>> [ "exp" fn-named? ] partition :> ( exponentials rest )
            exponentials length 1 = rest [ x free-of? ] all? and
            [ rest >mul exponentials first arg>> ] [ f f ] if
        ] }
        [ f f ]
    } cond ;

! The integral of k*exp(-a*x^2 + b*x + c) over the whole line is
! k*sqrt(pi/a)*exp(b^2/(4*a) + c); over a half line it is half that,
! but only when b is 0, since otherwise it needs the error function.
:: gaussian-integral ( expr x from to -- v/f )
    from infinite? to infinite? or [
        expr x gaussian-form :> ( k q )
        q [
            q x differentiate x differentiate :> second
            second number? [ second 0 < ] [ f ] if [
                second -2 / :> a
                q x differentiate x 0 at-bound :> b
                q x 0 at-bound :> c
                k pi-expr a s/ ssqrt s* b b s* 4 a s* s/ c s+ sexp s* :> whole
                {
                    { [ from infinite? to infinite? and ] [
                        from infinite-sign to infinite-sign = [ f ] [ whole ] if
                    ] }
                    { [ b 0 number= not ] [ f ] }
                    { [ from 0 number= to infinite? and ] [ whole 2 s/ ] }
                    { [ to 0 number= from infinite? and ] [ whole 2 s/ ] }
                    [ f ]
                } cond
            ] [ f ] if
        ] [ f ] if
    ] [ f ] if ;

! The antiderivative at a limit of integration, as a limit when the
! bound is infinite or the value is undefined there
:: bound-value ( F x bound -- v/f )
    bound infinite? [ f ] [ F x bound at-bound ] if
    dup { [ ] [ defined? ] } 1&& [
        drop F x bound limit dup limit-expr? [ drop f ] when
    ] unless ;

PRIVATE>

: integrate ( expr x -- expr' )
    2dup antiderivative [ 2nip ] [ <integral> ] if* ;

:: definite-integrate ( expr x from to -- expr' )
    expr x antiderivative [| F |
        F x to bound-value
        F x from bound-value
        2dup and [ s- ] [ 2drop expr x from to <definite-integral> ] if
    ] [
        expr x from to gaussian-integral [ ] [
            expr x from to symmetry-constant-exact
            [ from to symmetry-value ]
            [ expr x from to <definite-integral> ] if*
        ] if*
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


<PRIVATE

CONSTANT: max-lhopital-steps 8

! Extended arithmetic on limit values, outputting f when indeterminate
:: ext+ ( a b -- v/f )
    {
        { [ a not b not or ] [ f ] }
        { [ a infinite? b infinite? and ] [
            a infinite-sign b infinite-sign = [ a ] [ f ] if
        ] }
        { [ a infinite? ] [ a ] }
        { [ b infinite? ] [ b ] }
        [ a b s+ ]
    } cond ;

:: ext* ( a b -- v/f )
    {
        { [ a not b not or ] [ f ] }
        { [ a infinite? b infinite? or not ] [ a b s* ] }
        { [ a 0 number= b 0 number= or ] [ f ] }
        [
            a infinite? [ a infinite-sign ] [ a ] if
            b infinite? [ b infinite-sign ] [ b ] if
            s* dup number? [ 0 < [ infinity-expr sneg ] [ infinity-expr ] if ]
            [ drop f ] if
        ]
    } cond ;

DEFER: (limit)

! numerator and denominator, splitting factors with negative exponents
:: split-quotient ( expr -- num den )
    expr mul? [
        expr factors>> [
            { [ pow? ] [ exponent>> number? ] [ exponent>> 0 < ] } 1&&
        ] partition :> ( negatives rest )
        rest >mul
        negatives [ [ base>> ] [ exponent>> neg ] bi s^ ] map >mul
    ] [ expr 1 ] if ;

:: lhopital ( num den x point steps -- v/f )
    steps 0 <= [ f ] [
        num x differentiate :> n'
        den x differentiate :> d'
        d' 0 number= [ f ] [ n' d' s/ x point steps 1 - (limit) ] if
    ] if ;

! 0 * infinity as a quotient, so l'Hopital applies
:: indeterminate-product ( expr x point steps -- v/f )
    expr factors>> [ x free-of? ] partition :> ( constants deps )
    deps length 2 = [
        deps first2 :> ( a b )
        ! 0*infinity as b/(1/a) or a/(1/b), whichever l'Hopital settles
        b a -1 s^ x point steps lhopital
        [ ] [ a b -1 s^ x point steps lhopital ] if*
        dup [ constants >mul swap ext* ] when
    ] [ f ] if ;

:: fn-limit ( expr x point steps -- v/f )
    expr arg>> x point steps (limit) :> u
    u [
        u infinite? [
            u infinite-sign :> sign
            expr name>> {
                { "exp" [ sign 1 = [ infinity-expr ] [ 0 ] if ] }
                { "log" [ sign 1 = [ infinity-expr ] [ f ] if ] }
                { "atan" [ pi-expr 2 s/ sign s* ] }
                { "tanh" [ sign ] }
                { "sinh" [ u ] }
                { "cosh" [ infinity-expr ] }
                { "asinh" [ u ] }
                { "acosh" [ sign 1 = [ infinity-expr ] [ f ] if ] }
                [ drop f ]
            } case
        ] [
            u 0 number= expr name>> "log" = and
            [ infinity-expr sneg ]
            [ u expr name>> apply-fn dup defined? [ ] [ drop f ] if ] if
        ] if
    ] [ f ] if ;

:: quotient-limit ( num den x point steps -- v/f )
    num x point steps (limit) :> n
    den x point steps (limit) :> d
    {
        { [ n not d not or ] [ f ] }
        { [ d 0 number= n 0 number= and ] [ num den x point steps lhopital ] }
        { [ n infinite? d infinite? and ] [ num den x point steps lhopital ] }
        { [ d 0 number= ] [ f ] }
        { [ d infinite? ] [ n infinite? [ f ] [ 0 ] if ] }
        { [ n infinite? ] [ n ] }
        [ n d s/ dup defined? [ ] [ drop f ] if ]
    } cond ;

:: mul-limit ( expr x point steps -- v/f )
    expr split-quotient :> ( num den )
    den 1 number= [
        expr factors>> [ x point steps (limit) ] map
        dup [ ] all?
        [ 1 [ over [ ext* ] [ 2drop f ] if ] reduce ] [ drop f ] if
        [ ] [ expr x point steps indeterminate-product ] if*
    ] [ num den x point steps quotient-limit ] if ;

:: pow-limit ( expr x point steps -- v/f )
    expr base>> x point steps (limit) :> b
    expr exponent>> x point steps (limit) :> n
    b n and [
        {
            { [ b infinite? n number? and ] [
                n 0 > [
                    b infinite-sign -1 = n integer? and n odd? and
                    [ infinity-expr sneg ] [ infinity-expr ] if
                ] [ n 0 < [ 0 ] [ f ] if ] if
            ] }
            { [ b infinite? n infinite? or ] [ f ] }
            [ b n s^ dup defined? [ ] [ drop f ] if ]
        } cond
    ] [ f ] if ;

:: (limit) ( expr x point steps -- v/f )
    {
        { [ expr x free-of? ] [ expr ] }
        { [ expr x = ] [ point ] }
        { [ expr add? ] [
            expr terms>> [ x point steps (limit) ] map
            dup [ ] all?
            [ 0 [ over [ ext+ ] [ 2drop f ] if ] reduce ] [ drop f ] if
        ] }
        { [ expr fn? ] [ expr x point steps fn-limit ] }
        { [ expr mul? ] [ expr x point steps mul-limit ] }
        { [ expr pow? ] [ expr x point steps pow-limit ] }
        [ expr x point at-bound dup defined? [ ] [ drop f ] if ]
    } cond ;

PRIVATE>

! The limit of expr as x approaches point, which may be infinity-expr or
! its negative. Uses substitution, l'Hopital's rule for 0/0 and
! infinity/infinity, and rewrites 0*infinity as a quotient. Outputs an
! unevaluated limit-expr when it finds no value.
:: limit ( expr x point -- expr' )
    expr x point max-lhopital-steps (limit)
    [ ] [ expr x point <limit> ] if* ;

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

! Integration by the substitution u = g(x): the integrand divided by
! u' must be free of x once occurrences of g(x) are written as u.
:: substitution-integrand ( expr x u -- integrand/f t/f )
    "%s" <sym> :> t
    expr u x differentiate s/ u t 2array 1array subs :> integrand
    integrand x free-of? [ integrand t ] [ f f ] if ;

:: by-substitution ( expr x u -- expr' )
    expr x u substitution-integrand :> ( integrand t )
    integrand [
        integrand t antiderivative
        [ t u 2array 1array subs ] [ expr x <integral> ] if*
    ] [ expr x <integral> ] if ;

:: definite-by-substitution ( expr x from to u -- expr' )
    expr x u substitution-integrand :> ( integrand t )
    integrand [
        integrand t u x from at-bound u x to at-bound definite-integrate
    ] [ expr x from to <definite-integral> ] if ;

ERROR: undefined-at-point expr var point ;

! The Taylor polynomial of expr about point, up to the term in
! (x - point)^n: the sum of f(k)(point)*(x - point)^k/k!
:: taylor ( expr x point n -- expr' )
    V{ } clone :> terms
    expr :> derivative!
    n 1 + <iota> [| k |
        derivative x point at-bound :> value
        value defined? [ expr x point undefined-at-point ] unless
        value x point s- k s^ s* k factorial s/ terms push
        derivative x differentiate derivative!
    ] each
    terms >array >add ;

: maclaurin ( expr x n -- expr' ) [ 0 ] dip taylor ;

GENERIC: doit ( expr -- expr' )

M: object doit ;

M: add doit terms>> [ doit ] map >add ;

M: mul doit factors>> [ doit ] map >mul ;

M: pow doit [ base>> doit ] [ exponent>> doit ] bi s^ ;

M: fn doit [ arg>> doit ] [ name>> ] bi apply-fn ;

M: derivative doit [ expr>> doit ] [ var>> ] bi differentiate ;

M: limit-expr doit
    [ expr>> doit ] [ var>> ] [ point>> doit ] tri limit ;

M: integral doit
    dup from>> [
        { [ expr>> doit ] [ var>> ] [ from>> doit ] [ to>> doit ] } cleave
        definite-integrate
    ] [ [ expr>> doit ] [ var>> ] bi integrate ] if ;
