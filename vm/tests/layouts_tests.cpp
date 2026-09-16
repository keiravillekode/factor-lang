#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

FACTOR_TEST(fixnum_tagging_round_trips) {
  fixnum values[] = {0, 1, -1, 42, fixnum_max, fixnum_min};
  for (fixnum n : values) {
    cell tagged = tag_fixnum(n);
    CHECK_EQ((cell)FIXNUM_TYPE, TAG(tagged));
    CHECK_EQ(n, untag_fixnum(tagged));
  }
}

FACTOR_TEST(from_signed_cell_promotes_out_of_range_values) {
  test_vm t;
  CHECK_EQ(tag_fixnum(fixnum_max), t.vm.from_signed_cell(fixnum_max));
  CHECK_EQ(tag_fixnum(fixnum_min), t.vm.from_signed_cell(fixnum_min));
  cell big = t.vm.from_signed_cell(fixnum_max + 1);
  CHECK_EQ((cell)BIGNUM_TYPE, TAG(big));
  CHECK_EQ((int64_t)fixnum_max + 1, bignum_to_int64(untag<bignum>(big)));
}

FACTOR_TEST(data_stack_push_pop) {
  test_vm t;
  cell depth = t.datastack_depth();
  t.push_fixnum(1);
  t.push_fixnum(2);
  CHECK_EQ(depth + 2, t.datastack_depth());
  CHECK_EQ((fixnum)2, t.pop_fixnum());
  CHECK_EQ((fixnum)1, t.pop_fixnum());
  CHECK_EQ(depth, t.datastack_depth());
}

FACTOR_TEST(allot_array_lives_in_the_nursery) {
  test_vm t;
  factor::array* a = t.vm.allot_array(3, tag_fixnum(7));
  CHECK_EQ((cell)3, array_capacity(a));
  CHECK_EQ(tag_fixnum(7), array_nth(a, 2));
  CHECK(t.vm.nursery.contains_p(a));
}
