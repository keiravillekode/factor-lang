! Copyright (C) 2013 Björn Lindqvist, Doug Coleman.
! See https://factorcode.org/license.txt for BSD license
USING: accessors alien.libraries.finder arrays ascii assocs
combinators.short-circuit environment io io.directories
io.encodings.utf8 io.files io.launcher io.pathnames kernel make
math.parser sequences sets sorting splitting system unicode ;
IN: alien.libraries.finder.linux

<PRIVATE

CONSTANT: mach-map {
    { ppc.64 { "libc6" "64bit" } }
    { x86.32 { "libc6" "x32" } }
    { x86.64 { "libc6" "x86-64" } }
    { arm.64 { "libc6" "AArch64" } }
}

CONSTANT: emulation-map {
    { x86.32 "elf_i386" }
    { x86.64 "elf_x86_64" }
    { arm.64 "aarch64linux" }
}

! What may follow "lib<name>" in a file the dynamic linker would
! accept for that name: ".so", a version like ".1" or a libc variant
! like ".musl-x86_64", or a "-1.2" style version before the ".so".
! Anything else belongs to a different library: "libcairo.so.2" is
! not a match for "c".
: version-suffix? ( string -- ? )
    {
        [ ".so" subseq-of? ]
        [
            {
                [ "." head? ]
                [
                    {
                        [ "-" head? ]
                        [ ?second [ ascii:digit? ] [ f ] if* ]
                    } 1&&
                ]
            } 1||
        ]
    } 1&& ;

: library-file-matches? ( prefix file -- ? )
    swap ?head [ version-suffix? ] [ drop f ] if ;

: parse-ldconfig-lines ( string -- triple )
    [
        "=>" split1 [ [ unicode:blank? ] trim ] bi@
        [
            " " split1 [ "()" in? ] trim "," split
            [ [ unicode:blank? ] trim ] map
            [ ": Linux" subseq-of? ] reject
        ] dip 3array
    ] map ;

: load-ldconfig-cache ( -- seq )
    ! musl ships an ldconfig that does not understand -p, so keep its
    ! complaint off the console.
    <process>
        { "/sbin/ldconfig" "-p" } >>command
        +closed+ >>stderr
    utf8 [ read-lines ] with-process-reader*
    2drop [ f ] [ rest parse-ldconfig-lines ] if-empty ;

: ldconfig-arch ( -- str )
    mach-map cpu of { "libc6" } or ;

: name-matches? ( lib triple -- ? )
    first library-file-matches? ;

: arch-matches? ( lib triple -- ? )
    [ drop ldconfig-arch ] [ second swap subset? ] bi* ;

: ldconfig-matches? ( lib triple -- ? )
    { [ name-matches? ] [ arch-matches? ] } 2&& ;

: find-ldconfig ( name -- path/f )
    load-ldconfig-cache [ ldconfig-matches? ] with find nip ?last ;

:: find-ld ( name -- path/f )
    name <process>
        [
            "ld" , "-t" ,
            "LD_LIBRARY_PATH" os-env ":" split [ "-L" , , ] each
            "-m" emulation-map cpu of append ,
            "-o" , "/dev/null" , "-l" name append ,
        ] { } make >>command
        +closed+ >>stderr
    utf8 [ read-lines ] with-process-reader* 2drop
    [ subseq? ] with find nip ;

! musl has no ldconfig cache and Alpine-style systems have no ld
! either, so fall back to looking through the search path itself.
CONSTANT: default-library-paths { "/lib" "/usr/local/lib" "/usr/lib" }

CONSTANT: multiarch-map {
    { x86.32 "i386-linux-gnu" }
    { x86.64 "x86_64-linux-gnu" }
    { arm.64 "aarch64-linux-gnu" }
    { ppc.64 "powerpc64-linux-gnu" }
}

: multiarch-library-paths ( -- seq )
    multiarch-map cpu of
    [ { "/lib" "/usr/lib" } swap '[ _ append-path ] map ] [ { } ] if* ;

CONSTANT: musl-arch-map {
    { x86.32 "i386" }
    { x86.64 "x86_64" }
    { arm.64 "aarch64" }
}

: musl-path-file ( -- path/f )
    musl-arch-map cpu of
    [ "/etc/ld-musl-" ".path" surround ] [ f ] if* ;

: musl-library-paths ( -- seq )
    musl-path-file [
        dup file-exists? [
            utf8 file-lines [ [ unicode:blank? ] trim ] map harvest
        ] [ drop { } ] if
    ] [ { } ] if* ;

: library-search-paths ( -- seq )
    [
        "LD_LIBRARY_PATH" os-env [ ":" split harvest % ] when*
        musl-library-paths %
        default-library-paths %
        multiarch-library-paths %
    ] { } make members ;

: so-version ( file -- seq )
    ".so." split1 nip
    [ "." split [ string>number 0 or ] map ] [ { } ] if* ;

: best-library ( prefix paths -- path )
    ! Prefer the unversioned name, which is usually a symlink to the
    ! newest library, then the soname, which is the next shortest and
    ! the one other programs link against, then the highest version.
    [ swap ".so" append '[ file-name _ = ] find nip ] keep
    swap [ nip ] [
        [ file-name so-version ] inv-sort-by
        [ file-name so-version length ] sort-by first
    ] if* ;

:: find-library-directory ( name -- path/f )
    "lib" name append :> prefix
    [
        library-search-paths [| dir |
            dir file-exists? [
                dir directory-files
                [ prefix swap library-file-matches? ] filter
                [ dir prepend-path , ] each
            ] when
        ] each
    ] { } make
    [ f ] [ prefix swap best-library ] if-empty ;

PRIVATE>

M: linux find-library*
    dup [ "lib" prepend ] keep 2array [
        { [ find-ldconfig ] [ find-ld ] } 1||
    ] map-find drop
    [ nip ] [ find-library-directory ] if* ;
