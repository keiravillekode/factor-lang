! Copyright (C) 2008 Doug Coleman.
! See https://factorcode.org/license.txt for BSD license.
USING: alien.c-types alien.libraries alien.syntax classes.struct
kernel namespaces unix.stat unix.types ;
IN: unix.statfs.linux

STRUCT: statfs64
    { f_type __SWORD_TYPE }
    { f_bsize __SWORD_TYPE }
    { f_blocks __fsblkcnt64_t }
    { f_bfree __fsblkcnt64_t }
    { f_bavail __fsblkcnt64_t }
    { f_files __fsblkcnt64_t }
    { f_ffree __fsblkcnt64_t }
    { f_fsid __fsid_t }
    { f_namelen __SWORD_TYPE }
    { f_frsize __SWORD_TYPE }
    { f_spare __SWORD_TYPE[5] } ;

! musl does not export statfs64; its statfs is already the 64-bit
! call. glibc needs statfs64 on 32-bit, where they differ.
FUNCTION-ALIAS: statfs64-func int statfs64 ( c-string path, statfs64* buf )
FUNCTION-ALIAS: statfs-func   int statfs   ( c-string path, statfs64* buf )

SYMBOL: statfs64-available?

: detect-statfs64 ( -- )
    "statfs64" f dlsym? >boolean statfs64-available? set-global ;

STARTUP-HOOK: [ detect-statfs64 ]

: (statfs) ( path buf -- int )
    statfs64-available? get-global [ statfs64-func ] [ statfs-func ] if ;
