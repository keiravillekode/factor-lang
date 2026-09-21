! Copyright (C) 2008 Doug Coleman.
! See https://factorcode.org/license.txt for BSD license.
USING: alien.c-types alien.libraries alien.syntax classes.struct
kernel namespaces unix.types ;
IN: unix.statvfs.linux

STRUCT: statvfs64
    { f_bsize ulong }
    { f_frsize ulong }
    { f_blocks __fsblkcnt64_t }
    { f_bfree __fsblkcnt64_t }
    { f_bavail __fsblkcnt64_t }
    { f_files __fsfilcnt64_t }
    { f_ffree __fsfilcnt64_t }
    { f_favail __fsfilcnt64_t }
    { f_fsid ulong }
    { f_flag ulong }
    { f_namemax ulong }
    { __f_spare int[6] } ;

! musl does not export statvfs64; its statvfs is already the 64-bit
! call. glibc needs statvfs64 on 32-bit, where they differ.
FUNCTION-ALIAS: statvfs64-func int statvfs64 ( c-string path, statvfs64* buf )
FUNCTION-ALIAS: statvfs-func   int statvfs   ( c-string path, statvfs64* buf )

SYMBOL: statvfs64-available?

: detect-statvfs64 ( -- )
    "statvfs64" f dlsym? >boolean statvfs64-available? set-global ;

STARTUP-HOOK: [ detect-statvfs64 ]

: (statvfs) ( path buf -- int )
    statvfs64-available? get-global [ statvfs64-func ] [ statvfs-func ] if ;

CONSTANT: ST_RDONLY 1        ! Mount read-only.
CONSTANT: ST_NOSUID 2        ! Ignore suid and sgid bits.
CONSTANT: ST_NODEV 4         ! Disallow access to device special files.
CONSTANT: ST_NOEXEC 8        ! Disallow program execution.
CONSTANT: ST_SYNCHRONOUS 16  ! Writes are synced at once.
CONSTANT: ST_MANDLOCK 64     ! Allow mandatory locks on an FS.
CONSTANT: ST_WRITE 128       ! Write on file/directory/symlink.
CONSTANT: ST_APPEND 256      ! Append-only file.
CONSTANT: ST_IMMUTABLE 512   ! Immutable file.
CONSTANT: ST_NOATIME 1024    ! Do not update access times.
