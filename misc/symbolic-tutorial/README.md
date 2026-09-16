# Symbolic algebra tutorial

`tutorial.typ` is a Typst document introducing `math.symbolic` and its
companion vocabularies through worked problems. Build it with

    typst compile tutorial.typ

Every Factor block in the document is machine-checked. A line

    ! => text

says that the code above it prints `text`. `!` starts a Factor comment, so
the blocks run exactly as they appear. Check them with

    FACTOR=/path/to/factor misc/symbolic-tutorial/check.py

where `FACTOR` runs the Factor VM on a script, for example a wrapper
passing `-i=factor.image`. Each block runs as its own program, with a
`USING:` prelude covering the symbolic vocabularies, so blocks are
independent and can be read in any order. The checker exits non-zero if
any block's output differs.
