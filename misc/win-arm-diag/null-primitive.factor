! Diagnostic for the windows-11-arm CI crash: read address 0 through a
! quotation built at run time, which the base JIT compiles to a call of
! the alien-unsigned-1 primitive (the fault is inside VM C++ code).
! Expected: the error is caught and "after" is printed.
USING: alien.accessors arrays continuations io kernel prettyprint
quotations ;
IN: win-arm-diag.primitive

"[diag] primitive: before" print flush
[ f 0 \ alien-unsigned-1 3array >quotation call( -- n ) drop
  "[diag] primitive: no error?!" print ]
[ "[diag] primitive: caught " write . ] recover
"[diag] primitive: after" print flush
