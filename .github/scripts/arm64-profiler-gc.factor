! Does a code-compacting collection inside the profiler's safepoint handler
! leave stale return addresses behind? Run with the VM's investigation hook
! FACTOR_PROFILER_COMPACT_EVERY=N, which compacts on every Nth sample.
!
! Each round fills the code heap with garbage code blocks, then compiles a
! fresh caller/callee pair ABOVE them, drops the garbage, and profiles the
! pair. The first compaction in the handler slides the pair down over the
! freed garbage. If the interrupted word's resume PC or the caller's return
! address is not fixed up, execution resumes in stale code: a crash, or a
! wrong sum.
USING: accessors compiler.units io kernel math namespaces prettyprint
sequences tools.profiler.sampling words ;
IN: arm64-profiler-gc

: garbage-word ( i -- word )
    '[ _ + 1 + ] "garbage" <uninterned-word>
    [ swap ( x -- y ) define-declared ] keep ;

: make-garbage ( n -- words )
    [ <iota> [ garbage-word ] map ] with-compilation-unit ;

: fresh-pair ( -- caller )
    [
        ! callee: tiny, frameless, with an entry safepoint
        [ 1 + ] "callee" <uninterned-word>
        [ swap ( x -- y ) define-declared ] keep
        ! caller: loops calling the callee through a real call
        '[ 0 swap [ _ execute( x -- y ) + ] each-integer ]
        "caller" <uninterned-word>
        [ swap ( n -- sum ) define-declared ] keep
    ] with-compilation-unit ;

: expected ( n -- sum ) dup 1 + * 2 /i ;

: code-start ( word -- addr ) word-code drop ;

: round ( n -- ok? )
    2000 make-garbage drop           ! garbage below the pair
    dup fresh-pair                   ! the pair, compiled above it
    dup code-start "before" set
    [ '[ _ _ execute( n -- sum ) "sum" set ] profile ] keep
    code-start "before" get = not
    "  caller code moved during the profile: " write dup pprint nl drop
    expected "sum" get
    "  sum " write dup pprint " expected " write over pprint nl
    = ;

: main ( rounds n -- )
    '[ _ round ] replicate
    [ [ ] count ] [ length ] bi
    "rounds ok: " write swap pprint " / " write pprint nl flush ;
