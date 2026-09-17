! Compile a word whose code block is larger than 1MB and whose first
! instructions load a double literal. `>float 0.5 +` inlines the addition,
! so on arm64 the literal is loaded with a PC-relative LDR from the binary
! literal table at the end of the block, whose 19-bit field only reaches
! 1MB. The type is then erased by a call to a non-inlined word, so the
! remaining N additions are generic calls, which compile in linear time
! and just make the block long. (More than one inlined float addition
! makes the compile time quadratic in N, so exactly one is used.)
USING: compiler.units io kernel make math prettyprint sequences
tools.time words ;
IN: arm64-reloc-stress

: opaque ( x -- x ) ;

: make-big-quot ( n -- quot )
    [
        \ >float , 0.5 , \ + , \ opaque ,
        [ 1000000.5 + , \ + , ] each-integer
    ] [ ] make ;

: define-big ( quot -- word )
    "big" <uninterned-word>
    [ swap ( x -- y ) define-declared ] keep ;

: exact-sum ( n -- float )
    0 swap [ 2000001/2 + + ] each-integer 1/2 + >float ;

: report ( n word quot -- )
    over "code size: " write word-code swap - .
    [ 0.0 swap execute( x -- y ) ] [ 0.0 swap call( x -- y ) ] bi*
    pick exact-sum
    "compiled:    " write pick .
    "interpreted: " write over .
    "exact:       " write dup .
    dup [ = ] curry bi@ and "correct: " write . 2drop ;

: run ( n -- )
    "n = " write dup . flush
    dup make-big-quot dup
    [ [ define-big ] with-compilation-unit ] time swap report flush ;
