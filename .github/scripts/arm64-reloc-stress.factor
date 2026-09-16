! Compile a word with N distinct double literals. With the input declared
! a float, each `+` is inlined and on arm64 every literal is loaded with a
! PC-relative LDR from the binary literal table at the end of the block,
! whose 19-bit field only reaches 1MB, so a large enough N exercises the
! VM's relocation range check.
USING: compiler.units io kernel kernel.private make math prettyprint sequences
tools.time words ;
IN: arm64-reloc-stress

: make-big-quot ( n -- quot )
    [ { float } , \ declare , [ 0.5 + , \ + , ] each-integer ] [ ] make ;

: define-big ( quot -- word )
    "big" <uninterned-word>
    [ swap ( x -- y ) define-declared ] keep ;

: report ( word quot -- )
    over "code size: " write word-code swap - .
    [ 0.0 swap execute( x -- y ) ] [ 0.0 swap call( x -- y ) ] bi*
    2dup = "correct: " write [ . drop ] [ [ . ] bi@ ] if ;

: run ( n -- )
    "n = " write dup .
    make-big-quot dup
    [ [ define-big ] with-compilation-unit ] time swap report flush ;
