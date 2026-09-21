! Copyright (C) 2005, 2008 Slava Pestov.
! See https://factorcode.org/license.txt for BSD license.
USING: alien.libraries kernel namespaces system unix unix.ffi
unix.ffi.linux ;
IN: unix.linux

! open64 is needed on 32-bit glibc, where plain open is not
! large-file safe. musl is large-file safe everywhere and does not
! export the LFS64 aliases at all, so fall back to open there.
SYMBOL: open64-available?

: detect-open64 ( -- )
    "open64" f dlsym? >boolean open64-available? set-global ;

STARTUP-HOOK: [ detect-open64 ]

: open-func ( path flags mode -- fd )
    open64-available? get-global [ open64 ] [ open ] if ;

M: linux open-file [ open-func ] unix-system-call ;
