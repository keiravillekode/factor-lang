USING: accessors alien.libraries io.pathnames kernel namespaces
sequences splitting system vocabs ;
IN: alien.libraries.finder

HOOK: find-library* os ( name -- path/f )

: find-library ( name -- path/library-not-found )
    [ find-library* ] transmute ;

: ?update-library ( name path abi -- )
    pick lookup-library [ dll>> dll-valid? ] [ f ] if* [
        3drop
    ] [
        [ find-library ] [ update-library ] bi*
    ] if ;

! "libgtk-3.so" -> "gtk-3", "libfoo.dylib" -> "foo", "foo.dll" -> "foo"
: library-path>name ( path -- name )
    file-name "lib" ?head drop
    { ".so" ".dylib" ".dll" } [ dupd subseq-index ] map-find drop
    [ head ] when* ;

! Used by alien.libraries when a library named without a version
! cannot be opened. Only plain names are retried; a path that names a
! directory is taken at face value.
: resolve-library-path ( path -- path'/f )
    dup file-name over = [ library-path>name find-library* ] [ drop f ] if ;

STARTUP-HOOK: [ [ resolve-library-path ] dll-path-resolver set-global ]

! Try to find the library from a list, but if it's not found,
! try to open a library that is the first name in that list anyway
! or "library_not_found" as a last resort for better debugging.
: find-library-from-list ( seq -- path/f )
    [ [ find-library* ] map-find drop ]
    [ ?first "library_not_found" or ] ?unless ;

"alien.libraries.finder." os name>> append require
