! Diagnostic: call address 0 through alien-indirect with 9 arguments, so
! the call goes through trampoline2 and faults at pc 0 with the return
! address inside trampoline2.
! Expected: the error is caught and "after" is printed.
USING: alien alien.c-types continuations io kernel prettyprint ;
IN: win-arm-diag.ffi-null-indirect-trampoline2

: call-null ( -- n )
    1 2 3 4 5 6 7 8 9 0 <alien>
    uintptr_t
    { uintptr_t uintptr_t uintptr_t uintptr_t uintptr_t uintptr_t uintptr_t uintptr_t uintptr_t }
    cdecl alien-indirect ;

"[diag] null indirect trampoline2: before" print flush
[ call-null drop "[diag] null indirect trampoline2: no error?!" print ]
[ "[diag] null indirect trampoline2: caught " write . ] recover
"[diag] null indirect trampoline2: after" print flush
