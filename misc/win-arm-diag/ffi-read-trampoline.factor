! Diagnostic: fault inside a C function called through trampoline
! (1 argument, all in registers). win_arm_diag_read1 reads address 0.
! Expected: the error is caught and "after" is printed.
USING: alien.c-types alien.syntax continuations io kernel prettyprint ;
IN: win-arm-diag.ffi-trampoline

FUNCTION: uintptr_t win_arm_diag_read1 ( uintptr_t p )

: read-null ( -- n ) 0 win_arm_diag_read1 ;

"[diag] ffi trampoline: before" print flush
[ read-null drop "[diag] ffi trampoline: no error?!" print ]
[ "[diag] ffi trampoline: caught " write . ] recover
"[diag] ffi trampoline: after" print flush
