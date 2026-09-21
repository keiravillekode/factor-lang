USING: alien.c-types alien.libraries alien.syntax classes.struct
kernel namespaces unix.time ;
IN: unix.stat

STRUCT: stat
    { st_dev ulong }
    { st_ino ulong }
    { st_mode uint }
    { st_nlink uint }
    { st_uid uint }
    { st_gid uint }
    { st_rdev ulong }
    { __pad1 ulong }
    { st_size long }
    { st_blksize int }
    { __pad2 int }
    { st_blocks long }
    { st_atimespec timespec }
    { st_mtimespec timespec }
    { st_ctimespec timespec }
    { __unused4 uint }
    { __unused5 uint } ;

! glibc only started exporting stat, lstat and fstat as real symbols
! in 2.33. Before that they were header inlines over the __xstat64
! family, which musl has never exported. Choose at run time: an image
! can be built against one libc and run against another.
FUNCTION-ALIAS: (stat)  int stat  ( c-string pathname, stat* buf )
FUNCTION-ALIAS: (lstat) int lstat ( c-string pathname, stat* buf )
FUNCTION-ALIAS: (fstat) int fstat ( int fd, stat* buf )

FUNCTION: int __xstat64  ( int ver, c-string pathname, stat* buf )
FUNCTION: int __lxstat64 ( int ver, c-string pathname, stat* buf )
FUNCTION: int __fxstat64 ( int ver, int fd, stat* buf )

CONSTANT: _STAT_VER 0

SYMBOL: xstat-abi?

: detect-stat-abi ( -- )
    "stat" f dlsym? not xstat-abi? set-global ;

STARTUP-HOOK: [ detect-stat-abi ]

:  stat-func ( pathname buf -- int )
    xstat-abi? get-global
    [ [ _STAT_VER ] 2dip __xstat64 ] [ (stat) ] if ;

: lstat ( pathname buf -- int )
    xstat-abi? get-global
    [ [ _STAT_VER ] 2dip __lxstat64 ] [ (lstat) ] if ;

: fstat ( fd buf -- int )
    xstat-abi? get-global
    [ [ _STAT_VER ] 2dip __fxstat64 ] [ (fstat) ] if ;
