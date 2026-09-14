#!/usr/bin/env python3
"""Seeded random Factor program generator for GC-stress differential fuzzing.

Each program is a fixed prelude plus a list of independent "ops" (Factor
snippets with stack effect ( -- ) that type-guard everything they touch), so
any subset of ops is still a valid program -- that is what reduce.py relies on.

Usage:
  gen.py --seed N [-o prog.factor] [--ops-out ops.json] [--nops K]
  gen.py --ops ops.json -o prog.factor        # render an explicit op list
  gen.py --seed N --extended ...              # add the extended op families
"""
import argparse
import json
import random

NSLOTS = 16

PRELUDE = r"""USING: accessors alien alien.accessors arrays assocs byte-arrays
classes classes.tuple combinators compiler.units continuations hashtables
io kernel kernel.private math math.functions math.order math.parser memory namespaces quotations
sbufs sequences sorting strings threads vectors words ;
IN: fuzzprog

TUPLE: t1 a b c ;
TUPLE: t2 < t1 d ;
TUPLE: t3 x ;

SYMBOL: pool
SYMBOL: pending
SYMBOL: checkpoints

: slot@ ( i -- obj ) pool get-global nth ;
: slot! ( obj i -- ) pool get-global set-nth ;

: first-n ( seq n -- seq' ) index-or-length head ;

DEFER: summ

: summ-elts ( seq d -- str ) [ 6 first-n ] dip [ summ ] curry map "," join ;

: summ-string ( str -- str' )
    [ length number>string ] [ 40 first-n >array [ number>string ] map "." join ] bi
    ":" glue ;

: summ-hashtable ( h d -- str )
    [ [ assoc-size number>string ] [ keys ] bi ] dip
    [ summ ] curry map sort 6 first-n "," join ":" glue ;

: summ ( obj d -- str )
    dup 0 <= [ 2drop "~" ] [
        1 - swap {
            { [ dup not ] [ 2drop "f" ] }
            { [ dup t eq? ] [ 2drop "t" ] }
            { [ dup number? ] [ nip number>string ] }
            { [ dup string? ] [ nip summ-string "s" prepend ] }
            { [ dup sbuf? ] [ nip >string summ-string "sb" prepend ] }
            { [ dup byte-array? ] [ nip [ length number>string ] [ sum number>string ] bi ":" glue "b" prepend ] }
            { [ dup array? ] [ [ length number>string ] [ rot summ-elts ] bi "[" glue "a" prepend "]" append ] }
            { [ dup vector? ] [ [ length number>string ] [ rot summ-elts ] bi "[" glue "v" prepend "]" append ] }
            { [ dup hashtable? ] [ swap summ-hashtable "h" prepend ] }
            { [ dup t1? ] [ [ class-of name>> ] [ tuple-slots rot summ-elts ] bi "{" glue "}" append ] }
            { [ dup t3? ] [ [ class-of name>> ] [ tuple-slots rot summ-elts ] bi "{" glue "}" append ] }
            { [ dup quotation? ] [ nip length number>string "q" prepend ] }
            { [ dup word? ] [ nip name>> "w" prepend ] }
            { [ dup callstack? ] [ 2drop "cs" ] }
            { [ dup alien? ] [ nip 0 alien-unsigned-1 number>string "al" prepend ] }
            [ nip class-of name>> ]
        } cond
    ] if ;

: become-ok? ( a b -- ? )
    {
        { [ 2dup eq? ] [ 2drop f ] }
        { [ 2dup [ array? ] both? ] [ [ length ] bi@ = ] }
        { [ 2dup [ t1? ] both? ] [ [ class-of ] bi@ = ] }
        { [ 2dup [ t3? ] both? ] [ 2drop t ] }
        [ 2drop f ]
    } cond ;

: safe-become ( a b -- )
    2dup become-ok? [ [ 1array ] bi@ become ] [ 2drop ] if ;

: deep ( n -- obj )
    dup 0 > [ dup 1array swap 1 - deep 2array ] [ drop minor-gc { } ] if ;

: deep-compact ( n -- obj )
    dup 0 > [ dup number>string swap 1 - deep-compact 2array ] [ drop compact-gc { } ] if ;

: dyn ( quot name -- word )
    [ [ "fuzzprog" create-word swap ( -- x ) define-declared ] 2curry with-compilation-unit ] keep
    "fuzzprog" lookup-word ;

: checkpoint ( -- )
    pool get-global [ 2 summ ] map "|" join checkpoints get-global push ;

: wait-threads ( -- )
    [ pending get-global 0 > ] [ yield ] while ;

: dump ( -- )
    checkpoints get-global [ "C: " prepend print ] each
    pool get-global [ [ 4 summ ] dip number>string swap ": " glue "D:" prepend print ] each-index
    "FUZZ-DONE" print ;
"""


# --- Extended mode (--extended): opt-in op families; default output unchanged ---
#   1. tuple redefinition with live instances (update-tuples -> become)
#   2. generic dispatch through IC/PIC/megamorphic caches + method redefinition
#   3. save-image + reload (run.py --save-image-every; main saves if FUZZ_SAVE_IMAGE is set)
#   4. alien callbacks: libc qsort with allocating / GCing / nested Factor comparators
#   5. sampling profiler around allocation-heavy work
# All extended prelude words are prefixed xf- so render() can auto-detect them.

EXT_USING_OLD = "sbufs sequences sorting strings threads vectors words ;"
EXT_USING_NEW = ("sbufs sequences sorting strings threads vectors words\n"
                 "alien.c-types alien.syntax environment eval libc math.order tools.profiler.sampling ;")

EXT_TUPLE_ANCHOR = "TUPLE: t3 x ;\n"
EXT_TUPLE_DEFS = "TUPLE: xf-rt k a b ;\nGENERIC: xf-g ( obj -- n )\n"

EXT_SUMM_ANCHOR = "            { [ dup quotation? ]"
EXT_SUMM_CLAUSE = '            { [ dup xf-rt? ] [ k>> swap summ "rt" prepend ] }\n'

EXT_WORDS = r"""
! Slot k is present in every redefinition of xf-rt; only k is ever read.
:: xf-make ( k fill -- tuple )
    xf-rt all-slots length fill <array> xf-rt slots>tuple :> tup
    k tup k<< tup ;

M: object xf-g drop 0 ;
M: fixnum xf-g 1 + ;
M: string xf-g length ;
M: array xf-g length 3 * ;
M: t1 xf-g drop 11 ;

: xf-recv ( i -- obj )
    dup 9 mod {
        [ ]
        [ number>string ]
        [ 1array ]
        [ dup dup t1 boa ]
        [ t3 boa ]
        [ >float ]
        [ 3 mod <byte-array> ]
        [ dup H{ } clone [ set-at ] keep ]
        [ f xf-make ]
    } nth call( i -- obj ) ;

: xf-churn ( seq -- n ) [ xf-g ] map sum ;

FUNCTION-ALIAS: xf-qsort void qsort ( void* base, size_t nmemb, size_t size, void* compar )
CALLBACK: int xf-cmp-cb ( void* a, void* b )

: xf-icmp ( a b -- n ) 2dup < [ 2drop -1 ] [ > 1 0 ? ] if ;

! Sorts in malloc'd memory: byte arrays may move under a GC inside the callback.
:: xf-sort-ints ( seq cb -- seq' )
    seq length :> n
    n 4 * 4 max malloc :> mem
    seq [ mem swap 4 * set-alien-signed-4 ] each-index
    mem n 4 cb xf-qsort
    n <iota> [ 4 * mem swap alien-signed-4 ] map
    mem free ;

: xf-plain ( -- alien ) [ [ 0 alien-signed-4 ] bi@ xf-icmp ] xf-cmp-cb ;
: xf-alloc ( -- alien ) [ [ 0 alien-signed-4 ] bi@ 2dup 2array 50 <iota> [ 1array ] map 2drop xf-icmp ] xf-cmp-cb ;
: xf-gc ( -- alien ) [ [ 0 alien-signed-4 ] bi@ minor-gc xf-icmp ] xf-cmp-cb ;
: xf-big ( -- alien ) [ [ 0 alien-signed-4 ] bi@ 20000 f <array> drop 3000 <byte-array> drop xf-icmp ] xf-cmp-cb ;
: xf-nested ( -- alien ) [ [ 0 alien-signed-4 ] bi@ { 5 3 9 1 7 } xf-alloc xf-sort-ints drop 10 f <array> drop xf-icmp ] xf-cmp-cb ;
: xf-nested2 ( -- alien ) [ [ 0 alien-signed-4 ] bi@ { 2 1 3 } xf-nested xf-sort-ints drop gc xf-icmp ] xf-cmp-cb ;

: xf-profile ( quot rate -- ) samples-per-second set-global profile ; inline
"""

EXT_RATIO = 0.4
EXT_SLOTS = ["a", "b", "c", "d", "e"]
EXT_GC = ["", "minor-gc", "gc", "compact-gc"]
EXT_FILLS = ["f", "0", '"z"']
EXT_METHODS = {
    "fixnum": ["1 +", "2 *", "drop 5", "7 -"],
    "bignum": ["drop 15", "1000 mod"],
    "string": ["length", "length 2 *", "drop 1"],
    "array": ["length", "length 3 *", "drop 2"],
    "float": [">integer", "drop 9"],
    "byte-array": ["length", "drop 3"],
    "hashtable": ["assoc-size", "drop 4"],
    "t1": ["drop 11", "drop 12"],
    "t3": ["drop 13"],
    "xf-rt": ["k>> dup fixnum? [ ] [ drop 6 ] if", "drop 14"],
    "callstack": ["drop 16"],
}
EXT_METHOD_USING = "USING: accessors arrays assocs byte-arrays hashtables kernel math sequences strings fuzzprog ;"
# comparator -> max elements sorted (nested comparators do a sort per comparison)
EXT_CALLBACKS = {"xf-plain": 400, "xf-alloc": 300, "xf-gc": 150, "xf-big": 80, "xf-nested": 60, "xf-nested2": 25}
EXT_RATES = ["7", "97", "499", "1000", "3001"]


def ext_prelude():
    s = PRELUDE
    for old, new in ((EXT_USING_OLD, EXT_USING_NEW),
                     (EXT_TUPLE_ANCHOR, EXT_TUPLE_ANCHOR + EXT_TUPLE_DEFS),
                     (EXT_SUMM_ANCHOR, EXT_SUMM_CLAUSE + EXT_SUMM_ANCHOR)):
        assert s.count(old) == 1, old
        s = s.replace(old, new)
    return s + EXT_WORDS


class Gen:
    def __init__(self, rng):
        self.r = rng
        self.uid = 0

    def slot(self):
        return self.r.randrange(NSLOTS)

    def n(self, lo, hi):
        return self.r.randint(lo, hi)

    def fresh(self):
        self.uid += 1
        return self.uid

    # --- value expressions ( -- obj ) ---
    def val(self, depth=2):
        r = self.r
        choices = [
            (6, lambda: f"{self.n(0, 3000)} <iota> [ 1array ] map"),
            (4, lambda: f"{self.n(0, 5000)} <iota> >array"),
            (3, lambda: f"{self.n(0, 20000)} f <array>"),
            (4, lambda: f"\"h\\u{{e9}}llo w\\u{{3bb}}rld {self.n(0, 999)}\" clone"),
            (3, lambda: f"{self.n(0, 5000)} CHAR: a <string>"),
            (3, lambda: f"{{ 955 97 8364 {self.n(0, 0x10ffff)} }} >string"),
            (3, lambda: f"{self.n(0, 4000)} <iota> [ number>string ] map concat"),
            (3, lambda: f"{self.n(0, 20000)} <byte-array>"),
            (3, lambda: f"V{{ }} clone {self.n(0, 3000)} <iota> [ over push ] each"),
            (3, lambda: f"H{{ }} clone {self.n(0, 500)} <iota> [ dup number>string pick set-at ] each"),
            (2, lambda: f"SBUF\" \" clone {self.n(0, 2000)} <iota> [ 7 * 900 + over push ] each"),
            (3, lambda: f"2 {self.n(60, 3000)} ^ 3 {self.n(40, 1500)} ^ *"),
            (2, lambda: f"{self.n(0, 10**6)} >float {r.choice(['3.25', '0.5', '1024.0'])} *"),
            (4, lambda: f"{self.slot()} slot@"),
            (2, lambda: "get-callstack"),
            (2, lambda: f"{self.n(1, 3000)} deep"),
            (1, lambda: f"{self.n(1, 400)} deep-compact"),
            (2, lambda: f"[ {self.val(0)} swap continue-with ] callcc1"),
            (1, lambda: f"[ gc {self.val(0)} swap continue-with ] callcc1"),
            (2, lambda: f"[ {self.val(0)} \"boom\" 2array throw ] [ ] recover"),
            (1, lambda: f"[ {self.val(0)} \"x\" 2array throw ] [ minor-gc ] recover"),
            (1, lambda: r.choice(["300000 f <array>", "3000000 <byte-array>", "400000 CHAR: z <string>"])),
        ]
        if depth > 0:
            choices += [
                (4, lambda: f"{self.val(depth-1)} {self.val(depth-1)} {self.val(depth-1)} t1 boa"),
                (2, lambda: f"{self.val(depth-1)} {self.val(depth-1)} {self.val(depth-1)} {self.val(depth-1)} t2 boa"),
                (2, lambda: f"{self.val(depth-1)} t3 boa"),
                (3, lambda: f"{self.val(depth-1)} {self.val(depth-1)} 2array"),
                (2, lambda: f"{self.val(depth-1)} 1array"),
                (2, lambda: f"{self.val(depth-1)} clone"),
            ]
        total = sum(w for w, _ in choices)
        x = r.uniform(0, total)
        for w, f in choices:
            x -= w
            if x <= 0:
                return f()
        return choices[-1][1]()

    # --- ops ( -- ) ---
    def op(self):
        r = self.r
        s, t, u = self.slot(), self.slot(), self.slot()
        i = self.fresh()
        ops = [
            (10, lambda: f"{self.val()} {s} slot!"),
            (4, lambda: "minor-gc"),
            (4, lambda: "gc"),
            (3, lambda: "compact-gc"),
            (4, lambda: f"{self.val()} {s} slot@ dup array? [ dup empty? [ 2drop ] [ [ length 2/ ] keep set-nth ] if ] [ 2drop ] if"),
            (3, lambda: f"{self.val()} {s} slot@ dup t1? [ {r.choice(['a<<', 'b<<', 'c<<'])} ] [ 2drop ] if"),
            (2, lambda: f"{self.val()} {s} slot@ dup t3? [ x<< ] [ 2drop ] if"),
            (3, lambda: f"{self.val()} {s} slot@ dup vector? [ push ] [ 2drop ] if"),
            (3, lambda: f"{s} slot@ dup string? [ dup empty? [ drop ] [ [ {self.n(128, 0x10ffff)} 0 ] dip set-nth ] if ] [ drop ] if"),
            (2, lambda: f"{s} slot@ dup byte-array? [ dup empty? [ drop ] [ [ 255 0 ] dip set-nth ] if ] [ drop ] if"),
            # The C++ oracle (factor.bak) fills grown slots with fixnum 0 although
            # the docs (and the Zig VM) say f; normalize so this doesn't mask real diffs.
            # Resize a clone: both VMs shrink a *nursery* array in place, so resizing
            # the pooled object makes the digest depend on GC timing (aliasing).
            (3, lambda: f"{s} slot@ dup array? [ clone {self.n(0, 6000)} swap resize-array [ dup 0 eq? [ drop f ] when ] map! ] when {t} slot!"),
            (3, lambda: f"{s} slot@ clone {t} slot!"),
            (2, lambda: f"{s} slot@ {t} slot!"),
            (3, lambda: f"{self.val()} {self.n(0, 500)} number>string {s} slot@ dup hashtable? [ set-at ] [ 3drop ] if"),
            (3, lambda: f"{self.n(0, 5000)} <iota> [ {self.n(2, 97)} * {self.n(3, 1009)} mod ] map {r.choice(['sort', '[ swap <=> ] sort-with', '[ 7 mod ] sort-by', '[ [ 1array ] bi@ [ first ] bi@ <=> ] sort-with'])} {s} slot!"),
            (3, lambda: f"{self.n(1, 20000)} [ {self.n(1, 8)} f <array> drop ] times"),
            (3, lambda: f"{s} slot@ {t} slot@ safe-become"),
            (2, lambda: f"{self.val()} {self.val()} 2dup become-ok? [ [ {s} slot! ] [ {t} slot! ] bi* ] [ 2drop ] if {s} slot@ {t} slot@ safe-become"),
            (3, lambda: f"[ {self.val()} ] \"dyn{i}\" dyn execute( -- x ) {s} slot!"),
            (3, lambda: f"{s} slot@ 1quotation \"dyn{i}\" dyn minor-gc gc execute( -- x ) {t} slot!"),
            (2, lambda: f"{self.n(2, 5)} [ drop [ {self.val(1)} ] \"dyn{i}\" dyn drop {r.choice(['', 'gc', 'compact-gc'])} ] each-integer \"dyn{i}\" \"fuzzprog\" lookup-word execute( -- x ) {s} slot!"),
            (3, lambda: f"{s} slot@ [ 3 summ ] curry call( -- x ) {t} slot!"),
            (2, lambda: f"{s} slot@ {t} slot@ [ 2array ] 2curry call( -- x ) {u} slot!"),
            (2, lambda: f"{s} slot@ 1quotation [ 1array ] compose call( -- x ) {t} slot!"),
            (2, lambda: f"[ {self.val(1)} {s} slot! gc yield {self.val(1)} {t} slot! pending [ 1 - ] change-global ] \"fz\" spawn drop pending [ 1 + ] change-global"),
            (2, lambda: "yield"),
            (2, lambda: f"{s} slot@ dup byte-array? [ dup length 2 > [ 1 swap <displaced-alien> ] [ drop f ] if ] [ drop f ] if {t} slot!"),
            (2, lambda: f"{s} slot@ dup string? [ reverse ] when {t} slot!"),
            (2, lambda: f"{s} slot@ {t} slot@ 2dup [ string? ] both? [ append ] [ drop ] if {u} slot!"),
            (1, lambda: f"{s} slot@ dup sequence? [ dup length 100000 < [ >array ] when ] when {t} slot!"),
            (2, lambda: "checkpoint"),
            (2, lambda: f"[ {self.val(1)} {s} slot! compact-gc {self.val(1)} swap continue-with ] callcc1 {t} slot!"),
            (1, lambda: f"[ {self.val(1)} {s} slot! return ] with-return"),
        ]
        total = sum(w for w, _ in ops)
        x = r.uniform(0, total)
        for w, f in ops:
            x -= w
            if x <= 0:
                return f()
        return ops[-1][1]()


    # --- extended ops ( -- ) ---
    def ext_op(self):
        r = self.r
        s, t = self.slot(), self.slot()
        i = self.fresh()

        def redefine():
            slots = ["k"] + r.sample(EXT_SLOTS, r.randint(0, len(EXT_SLOTS)))
            r.shuffle(slots)
            return f'"IN: fuzzprog TUPLE: xf-rt {" ".join(slots)} ;" eval( -- ) {r.choice(EXT_GC)}'

        def method():
            cls = r.choice(sorted(EXT_METHODS))
            return (f'"{EXT_METHOD_USING} IN: fuzzprog M: {cls} xf-g {r.choice(EXT_METHODS[cls])} ;" '
                    f'eval( -- ) {r.choice(EXT_GC)}')

        def qsort_fresh():
            cb = r.choice(sorted(EXT_CALLBACKS))
            return (f"{self.n(0, EXT_CALLBACKS[cb])} <iota> [ {self.n(2, 97)} * {self.n(3, 1009)} mod ] map "
                    f"{cb} xf-sort-ints {s} slot!")

        def qsort_pool():
            cb = r.choice(sorted(EXT_CALLBACKS))
            return (f"{s} slot@ dup array? [ dup length {EXT_CALLBACKS[cb]} < [ dup [ integer? ] all? "
                    f"[ [ 1000000 mod ] map {cb} xf-sort-ints ] when ] when ] when {t} slot!")

        ops = [
            # 1. tuple redefinition with live instances
            (4, lambda: f"{self.val(1)} {r.choice(EXT_FILLS)} xf-make {s} slot!"),
            (3, lambda: f"{self.n(0, 3000)} <iota> [ {r.choice(EXT_FILLS)} xf-make ] map {s} slot!"),
            (2, lambda: f"H{{ }} clone {self.n(0, 800)} <iota> [ dup {r.choice(EXT_FILLS)} xf-make swap pick set-at ] each {s} slot!"),
            (3, lambda: f"{self.val(1)} {s} slot@ dup xf-rt? [ k<< ] [ 2drop ] if"),
            (2, lambda: f"{s} slot@ dup xf-rt? [ k>> ] when {t} slot!"),
            (4, redefine),
            # 2. generic dispatch (IC -> PIC -> megamorphic) + method redefinition
            (4, lambda: f"{self.n(0, 3000)} <iota> [ {self.n(0, 50)} + xf-recv ] map xf-churn {s} slot!"),
            (3, lambda: f"{self.n(0, 2000)} <iota> [ xf-recv ] map [ [ xf-g ] map sum ] curry call( -- x ) {s} slot!"),
            (2, lambda: f"{s} slot@ xf-g {t} slot!"),
            (2, lambda: f'[ {self.n(0, 500)} <iota> [ xf-recv xf-g ] map sum ] "dyn{i}" dyn execute( -- x ) {s} slot!'),
            (4, method),
            # 4. libc qsort with Factor comparator callbacks
            (3, qsort_fresh),
            (2, qsort_pool),
            # 5. sampling profiler
            (3, lambda: f"[ {self.val(1)} {s} slot! {r.choice(EXT_GC)} {self.val(1)} {t} slot! ] {r.choice(EXT_RATES)} xf-profile"),
            (1, lambda: f"[ {self.n(1, 20000)} [ {self.n(1, 8)} f <array> drop ] times yield ] {r.choice(EXT_RATES)} xf-profile"),
            (1, lambda: "[ most-recent-profile-data length drop ] [ drop ] recover"),
        ]
        total = sum(w for w, _ in ops)
        x = r.uniform(0, total)
        for w, f in ops:
            x -= w
            if x <= 0:
                return f()
        return ops[-1][1]()


def generate_ops(seed, nops=None, extended=False):
    rng = random.Random(seed)
    g = Gen(rng)
    if nops is None:
        nops = rng.randint(10, 60)
    ops = []
    large = 0
    while len(ops) < nops:
        o = g.ext_op() if extended and rng.random() < EXT_RATIO else g.op()
        k = o.count("300000 f <array>") + o.count("3000000 <byte-array>") + o.count("400000 CHAR: z")
        if large + k > 4:
            continue
        large += k
        ops.append(o)
    return ops


def render(ops, extended=None):
    """extended=None auto-detects extended ops by their xf- words."""
    if extended is None:
        extended = any("xf-" in o for o in ops)
    out = [ext_prelude() if extended else PRELUDE]
    for idx, body in enumerate(ops):
        out.append(f": op{idx} ( -- ) {body} ;\n")
    calls = " ".join(f"op{idx}" for idx in range(len(ops)))
    out.append(
        ": main ( -- )\n"
        f"    {NSLOTS} f <array> pool set-global 0 pending set-global V{{ }} clone checkpoints set-global\n"
        f"    {calls}\n" +
        ("    wait-threads dump \"FUZZ_SAVE_IMAGE\" os-env [ save-image ] when* ;\n\nMAIN: main\n" if extended
         else "    wait-threads dump ;\n\nMAIN: main\n")
    )
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int)
    ap.add_argument("--ops", help="render from explicit op list (json)")
    ap.add_argument("--nops", type=int)
    ap.add_argument("-o", "--out")
    ap.add_argument("--ops-out")
    ap.add_argument("--extended", action="store_true", help="enable extended op families")
    a = ap.parse_args()
    if a.ops:
        with open(a.ops) as f:
            ops = json.load(f)
    else:
        ops = generate_ops(a.seed, a.nops, a.extended)
    src = render(ops, True if a.extended else None)
    if a.ops_out:
        with open(a.ops_out, "w") as f:
            json.dump(ops, f, indent=1)
    if a.out:
        with open(a.out, "w") as f:
            f.write(src)
    else:
        print(src)


if __name__ == "__main__":
    main()
