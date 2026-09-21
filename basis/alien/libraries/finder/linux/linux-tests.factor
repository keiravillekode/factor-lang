USING: alien.libraries.finder alien.libraries.finder.linux.private
sequences tools.test ;

{ t } [ "c" find-library "libc" subseq-of? ] unit-test

! Matching is by name, not by prefix: "c" must not pick up libcairo.
{ t } [ "libc" "libc.so.6" library-file-matches? ] unit-test
{ t } [ "libc" "libc.musl-x86_64.so.1" library-file-matches? ] unit-test
{ t } [ "libgtk-3" "libgtk-3.so.0.2420.32" library-file-matches? ] unit-test
{ t } [ "libSDL" "libSDL-1.2.so.0" library-file-matches? ] unit-test
{ f } [ "libc" "libcairo.so.2" library-file-matches? ] unit-test
{ f } [ "libc" "libcap.so.2.78" library-file-matches? ] unit-test
{ f } [ "libGL" "libGLU.so.1" library-file-matches? ] unit-test
{ f } [ "libfoo" "libfoo-bar.so" library-file-matches? ] unit-test
{ f } [ "libfoo" "libfoo.a" library-file-matches? ] unit-test

{ { 0 2420 32 } } [ "libgtk-3.so.0.2420.32" so-version ] unit-test
{ { } } [ "libgtk-3.so" so-version ] unit-test

! The unversioned name wins, then the soname, then the newest.
{ "/usr/lib/libgtk-3.so" } [
    "libgtk-3" {
        "/usr/lib/libgtk-3.so.0.2420.32"
        "/usr/lib/libgtk-3.so"
        "/usr/lib/libgtk-3.so.0"
    } best-library
] unit-test

{ "/usr/lib/libgtk-3.so.0" } [
    "libgtk-3" {
        "/usr/lib/libgtk-3.so.0.2420.32"
        "/usr/lib/libgtk-3.so.0"
    } best-library
] unit-test
