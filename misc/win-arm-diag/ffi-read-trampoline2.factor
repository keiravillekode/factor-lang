! Diagnostic: fault inside a C function called through trampoline2
! (9 arguments; the 9th is passed on the stack, so the compiler uses
! %c-invoke-tramp2). win_arm_diag_read9 reads address 0.
! Expected: the error is caught and "after" is printed.
USING: alien.c-types alien.syntax continuations io kernel prettyprint ;
IN: win-arm-diag.ffi-trampoline2

FUNCTION: uintptr_t win_arm_diag_read9 ( uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6, uintptr_t a7, uintptr_t a8, uintptr_t p )

: read-null ( -- n ) 1 2 3 4 5 6 7 8 0 win_arm_diag_read9 ;

"[diag] ffi trampoline2: before" print flush
[ read-null drop "[diag] ffi trampoline2: no error?!" print ]
[ "[diag] ffi trampoline2: caught " write . ] recover
"[diag] ffi trampoline2: after" print flush
