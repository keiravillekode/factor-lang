! Copyright (C) 2026 Eric Willigers.
! See https://factorcode.org/license.txt for BSD license.
USING: accessors arrays combinators compiler.units effects kernel
make math math.constants math.functions math.symbolic sequences
words ;
IN: math.symbolic.compile

ERROR: not-compilable expr ;

<PRIVATE

! Code for an expression has stack effect ( values -- values result ),
! where values holds the variables' values in order.
GENERIC#: (compile) 1 ( expr vars -- )

M: object (compile) drop not-compilable ;

M: number (compile) drop , ;

M: const (compile) drop name>> "pi" = pi e ? , ;

M: sym (compile)
    dupd index [ nip \ dup , , \ swap , \ nth , ] [ name>> unbound-symbol ] if* ;

:: compile-fold ( exprs vars op -- )
    exprs unclip vars (compile)
    [ \ swap , vars (compile) \ rot , op % ] each ;

M: add (compile) [ terms>> ] dip { + } compile-fold ;

M: mul (compile) [ factors>> ] dip { * } compile-fold ;

M: pow (compile)
    [ [ base>> ] [ exponent>> ] bi 2array ] dip { swap ^ } compile-fold ;

M:: fn (compile) ( expr vars -- )
    expr arg>> vars (compile)
    expr name>> {
        { "sin" [ \ sin ] }
        { "cos" [ \ cos ] }
        { "tan" [ \ tan ] }
        { "exp" [ \ e^ ] }
        { "log" [ \ log ] }
    } case , ;

PRIVATE>

! A quotation ( value1 ... valuen -- result ) evaluating expr with
! the values of vars.
:: expr>quot ( expr vars -- quot )
    [
        vars length :> n
        n , f , \ <array> ,
        n <iota> <reversed> [ \ swap , \ over , , \ swap , \ set-nth , ] each
        expr vars (compile)
        \ nip ,
    ] [ ] make ;

! A compiled word ( value1 ... valuen -- result ) evaluating expr.
: expr>word ( expr vars -- word )
    [ expr>quot ] [ [ name>> ] map { "result" } <effect> ] bi
    [ define-temp ] with-compilation-unit ;
