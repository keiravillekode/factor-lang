; Windows ARM64 trampolines.
;
; Preprocessed with cl /EP before armasm64 (see Nmakefile) so the kxarm64.h
; prologue/epilogue macros can emit unwind data (.pdata/.xdata). Without it,
; Windows cannot unwind from a faulting VM primitive (called through
; trampoline) back to the Factor frame whose registered exception handler
; turns the fault into a vm-error, and the process dies with 0xC0000005.

#include "ksarm64.h"

; X16 = IP0
; X17 = IP1
; X20 = CTX

	TEXTAREA

	NESTED_ENTRY trampoline
	PROLOG_SAVE_REG_PAIR fp, lr, #-16!
	PROLOG_NOP mov fp, sp
	str	fp, [x20]	; ctx.callstack_top
	blr	x16
	EPILOG_RESTORE_REG_PAIR fp, lr, #16!
	EPILOG_RETURN
	NESTED_END trampoline

; trampoline2 saves fp/lr at [x17] (a slot in the outgoing-argument area of the
; caller) rather than below sp, which the standard prologue macros cannot
; describe, so it is left without unwind data. It is only used for FFI calls
; that pass arguments on the stack.

	EXPORT	trampoline2
	ALIGN	4
trampoline2
	stp	fp, lr, [x17]
	mov	fp, x17
	str	fp, [x20]
	blr	x16
	ldp	fp, lr, [fp]
	ret

	END
