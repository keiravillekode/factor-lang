USING: arrays assocs byte-arrays calendar continuations io.streams.string
kernel kernel.private locals math math.parser math.private memory namespaces parser
quotations quotations.private random sequences splitting system threads
tools.profiler.sampling tools.profiler.sampling.private
tools.test ;
IN: tools.profiler.sampling.tests

CONSTANT: report-samples {
    { 60 0 0 0 0 "thread-a" { "expensive" "caller" } }
    { 10 0 0 0 0 "thread-a" { "cheap" "caller" } }
    { 30 0 0 0 0 "thread-b" { "other" } }
}

: report-percentages ( -- percentages )
    [ report-samples top-down* profile. ] with-string-writer
    split-lines rest [ empty? ] reject
    [ split-words harvest third string>number ] map ;

! All rows use total time across threads, even after root trimming (#385).
{ { 70.0 60.0 10.0 30.0 30.0 } } [ report-percentages ] unit-test

! The cutoff is inclusive and does not renormalize the remaining rows.
{ { 70.0 60.0 30.0 30.0 } } [
    30 profile-minimum-percent [ report-percentages ] with-variable
] unit-test

{ { } } [
    90 profile-minimum-percent [ report-percentages ] with-variable
] unit-test

! Empty and zero-time profiles still print without NaNs or division by zero.
{ 0.0 } [ 0 0 time-percentage ] unit-test
{ t } [
    [ H{ } profile. ] with-string-writer
    "time %" swap subseq?
] unit-test

! collect-tops: top is the last element in the array
{ 5 } [
    { { 1 2 3 4 5 6 { 3 4 5 } } } 1 2 collect-tops
    keys first
] unit-test

! Make sure the profiler doesn't blow up the VM

! Keep an array and an unboxed floating-point accumulator live across polls.
: sampled-sum ( array -- sum )
    0.0 swap [ { float } declare + ] each ;

{ } [
    [
        50 [ 100000 1.25 <array> sampled-sum 125000.0 assert= ] times
    ] profile
] unit-test

: frameless-increment ( n -- n' ) { fixnum } declare 1 fixnum+fast ;

: frameless-increments ( n -- ) [ frameless-increment drop ] each-integer ;

{ t } [
    [ 100,000,000 frameless-increments ] profile
    most-recent-profile-data [
        sample-callstack
        { leaf-signal-handler frameless-increment frameless-increments } head?
    ] any?
] unit-test

{ t } [
    1500000 [ 1 \ drop 2array ] replicate concat >quotation
    [ jit-compile ] [ 2drop ] recover
    [ 100,000,000 frameless-increments ] profile
    most-recent-profile-data
    [ [ jit-sample-count ] map-sum 2 * ] [ [ first ] map-sum ] bi <
] unit-test

{ } [ 10 [ [ ] profile ] times ] unit-test

! The VM records samples inside the safepoint signal handler, where it must
! not allocate (an allocation can start a GC, and a GC taken while compiled
! code is stopped at a safepoint is unsafe). So the callstack buffer,
! OBJ-SAMPLE-CALLSTACKS = { count contents }, is allocated in full when
! profiling starts, sized for ~10 seconds of samples at ~64 frames each,
! and entries are dropped once it is full. Both VMs size it the same way.
: with-sample-rate ( rate quot -- )
    samples-per-second get-global
    [ [ samples-per-second set-global ] dip ] dip
    [ samples-per-second set-global ] curry finally ; inline

: sample-callstacks ( -- count contents )
    OBJ-SAMPLE-CALLSTACKS special-object first2 ;

{ t t } [
    97 [ [ 100000 [ 64 f <array> drop ] times ] profile ] with-sample-rate
    sample-callstacks length
    [ nip 97 10 * 64 * = ] [ <= ] 2bi
] unit-test

! When the buffer fills, profiling keeps running, the count stops at the
! capacity, and every entry that was recorded belongs to exactly one sample
! (the samples that lost entries just have shorter callstacks). At 997
! samples/s the capacity is 638,080 entries; 4,000-frame samples fill it in
! well under a second.
: deep-frames ( n -- n ) dup 0 = [ drop 1 ] [ 1 - deep-frames 1 + ] if ;

:: run-for-nanos ( nanos quot -- )
    nano-count :> start
    [ quot call nano-count start - nanos < ] loop ; inline

{ t t } [
    997 [
        [ 1,500,000,000 [ 4000 deep-frames drop ] run-for-nanos ] profile
    ] with-sample-rate
    sample-callstacks length over =
    swap most-recent-profile-data [ sample-callstack length ] map-sum =
] unit-test
TUPLE: boom ;
[ 10 [ [ boom new throw ] profile ] times ] [ boom? ] must-fail-with

{ t t t t t t t t t t } [
    10 [
        [
            100 [ 1000 random (byte-array) >boolean t assert= ] times gc
        ] profile raw-profile-data get-global >boolean
    ] times
] unit-test

{ t t t t t t t t t t } [
    10 [
        [
            100 [ 1000 random (byte-array) >boolean t assert= ] times compact-gc
        ] profile raw-profile-data get-global >boolean
    ] times
] unit-test

{ t t } [
    2 [
        [ 1 seconds sleep ] profile
        raw-profile-data get-global >boolean
    ] times
] unit-test

{ t } [
    [ 1,000,000 <iota> [ sq sq sq ] map >boolean t assert= ] profile
    raw-profile-data get-global >boolean
] unit-test

f raw-profile-data set-global
gc

{ t t } [
    ! Seed the samples data
    [ "resource:basis/tools/memory/memory.factor" run-file ] profile
    get-samples length 0 >
    OBJ-SAMPLE-CALLSTACKS special-object first 0 >
] unit-test

{ t } [
    ! On x86.64, [ ] profile doesn't generate any samples at all
    ! because it runs so quickly. On x86.32, one spurious sample is
    ! sometimes generated for some unknown reason.
    gc [ ] profile get-samples length 1 <=
] unit-test

! On Unix this used to put 1,000,000 in tv_usec, silently disabling the timer.
{ t } [
    1 set-profiling
    [ 2 seconds sleep ] [ 0 set-profiling ] finally
    get-samples >boolean
] unit-test
