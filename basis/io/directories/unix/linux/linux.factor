! Copyright (C) 2009 Doug Coleman.
! See https://factorcode.org/license.txt for BSD license.
USING: fry io.directories io.directories.unix kernel libc math
sequences system unix.ffi ;
IN: io.directories.unix.linux

! readdir rather than readdir64_r: musl does not export the LFS64
! symbols, and on 64-bit Linux readdir is already large-file safe.
! readdir returns a pointer owned by the directory stream, which the
! next call invalidates, so produce converts each entry before asking
! for the next one. NULL means both end-of-stream and error, so errno
! has to be cleared first and checked afterwards.
: next-dirent ( DIR* -- dirent* ? )
    clear-errno readdir
    [ t ] [ errno [ (throw-errno) ] unless-zero f f ] if* ;

M: linux (directory-entries)
    [
        '[ _ next-dirent ] [ >directory-entry ] produce nip
    ] with-unix-directory ;
