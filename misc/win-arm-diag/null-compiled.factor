! Diagnostic for the windows-11-arm CI crash: read address 0 from
! optimized code (alien-unsigned-1 is an intrinsic, so the fault is in
! the code heap). Expected: the error is caught and "after" is printed.
USING: alien.accessors continuations io kernel prettyprint ;
IN: win-arm-diag.compiled

: read-null ( -- n ) f 0 alien-unsigned-1 ;

"[diag] compiled: before" print flush
[ read-null drop "[diag] compiled: no error?!" print ]
[ "[diag] compiled: caught " write . ] recover
"[diag] compiled: after" print flush
