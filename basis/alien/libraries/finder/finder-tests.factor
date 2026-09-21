USING: alien alien.libraries.finder tools.test ;
IN: alien.libraries.finder

{ f } [ "dont-exist" find-library* ] unit-test
{ "dont-exist" } [ "dont-exist" find-library ] unit-test

{ "gtk-3" } [ "libgtk-3.so" library-path>name ] unit-test
{ "foo" } [ "libfoo.so.1" library-path>name ] unit-test
{ "foo" } [ "libfoo.dylib" library-path>name ] unit-test
{ "foo" } [ "foo.dll" library-path>name ] unit-test

! Only plain library names are looked up again; a path is taken as is.
{ f } [ "/usr/lib/libdont-exist.so" resolve-library-path ] unit-test
{ f } [ "libdont-exist.so" resolve-library-path ] unit-test
