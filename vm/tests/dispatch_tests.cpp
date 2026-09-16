// Tests for vm/dispatch.cpp and the bookkeeping parts of
// vm/inline_cache.cpp: class lookup, method dispatch through tuple layouts,
// the megamorphic cache and PIC transition counters.
#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

namespace {

// A word object with every slot set to f; only its identity matters.
cell make_word(factor_vm& vm) {
  word* w = vm.allot<word>(sizeof(word));
  w->hashcode = tag_fixnum(0);
  w->name = false_object;
  w->vocabulary = false_object;
  w->def = false_object;
  w->props = false_object;
  w->pic_def = false_object;
  w->pic_tail_def = false_object;
  w->subprimitive = false_object;
  w->entry_point = 0;
  return tag<word>(w);
}

cell make_array(factor_vm& vm, std::initializer_list<cell> items) {
  factor::array* a = vm.allot_array(items.size(), false_object);
  cell i = 0;
  for (cell item : items)
    vm.set_array_nth(a, i++, item);
  return tag<factor::array>(a);
}

// A tuple layout for a class at the given echelon. superclasses[e] and
// hashcodes[e] describe the class at echelon e, e == 0 being the root.
cell make_layout(factor_vm& vm, cell klass,
                 std::initializer_list<cell> superclasses,
                 std::initializer_list<fixnum> hashcodes,
                 fixnum size = 2) {
  cell echelons = superclasses.size();
  factor::array* a = vm.allot_array(3 + 2 * echelons, false_object);
  tuple_layout* layout = (tuple_layout*)a;
  layout->klass = klass;
  layout->size = tag_fixnum(size);
  layout->echelon = tag_fixnum(echelons - 1);
  cell i = 0;
  auto h = hashcodes.begin();
  for (cell superclass : superclasses) {
    vm.set_array_nth(a, 3 + 2 * i, superclass);
    vm.set_array_nth(a, 3 + 2 * i + 1, tag_fixnum(*h++));
    i++;
  }
  return tag<factor::array>(a);
}

cell make_tuple(factor_vm& vm, cell layout) {
  tuple_layout* l = untag<tuple_layout>(layout);
  cell slots = untag_fixnum(l->size);
  factor::tuple* t = vm.allot<factor::tuple>(sizeof(factor::tuple) + slots * sizeof(cell));
  t->layout = layout;
  for (cell i = 0; i < slots; i++)
    t->data()[i] = false_object;
  return tag<factor::tuple>(t);
}

// A method table for lookup_method: one entry per type tag.
cell make_methods(factor_vm& vm) {
  return tag<factor::array>(vm.allot_array(TYPE_COUNT, false_object));
}

} // namespace

FACTOR_TEST(object_class_of_immediates_and_tuples) {
  test_vm t;
  factor_vm& vm = t.vm;
  CHECK_EQ(tag_fixnum(FIXNUM_TYPE), vm.object_class(tag_fixnum(5)));
  CHECK_EQ(tag_fixnum(F_TYPE), vm.object_class(false_object));
  cell arr = make_array(vm, {});
  CHECK_EQ(tag_fixnum(ARRAY_TYPE), vm.object_class(arr));
  cell klass = make_word(vm);
  cell layout = make_layout(vm, klass, {klass}, {1});
  cell tup = make_tuple(vm, layout);
  CHECK_EQ(layout, vm.object_class(tup));
}

FACTOR_TEST(lookup_method_by_tag) {
  test_vm t;
  factor_vm& vm = t.vm;
  cell methods = make_methods(vm);
  cell fixnum_method = make_word(vm);
  cell f_method = make_word(vm);
  vm.set_array_nth(untag<factor::array>(methods), FIXNUM_TYPE, fixnum_method);
  vm.set_array_nth(untag<factor::array>(methods), F_TYPE, f_method);
  CHECK_EQ(fixnum_method, vm.lookup_method(tag_fixnum(3), methods));
  CHECK_EQ(f_method, vm.lookup_method(false_object, methods));
  // Types without a method give whatever the table holds, here f.
  CHECK_EQ(false_object, vm.lookup_method(make_array(vm, {}), methods));

  cell depth = t.datastack_depth();
  t.push(tag_fixnum(3));
  t.push(methods);
  vm.primitive_lookup_method();
  CHECK_EQ(depth + 1, t.datastack_depth());
  CHECK_EQ(fixnum_method, t.pop());
}

FACTOR_TEST(lookup_method_for_tuples_walks_echelons) {
  test_vm t;
  factor_vm& vm = t.vm;
  cell root = make_word(vm);
  cell parent = make_word(vm);
  cell child = make_word(vm);
  cell sibling = make_word(vm);
  // Child is at echelon 2; its hashcode 2 lands in bucket 2 of a 4-bucket
  // table, parent's hashcode 1 in bucket 1.
  cell child_layout = make_layout(vm, child, {root, parent, child}, {0, 1, 2});
  cell child_tuple = make_tuple(vm, child_layout);

  cell root_method = make_word(vm);
  cell parent_method = make_word(vm);
  cell child_method = make_word(vm);
  cell sibling_method = make_word(vm);

  // Echelon 2 table: bucket 2 is an alist holding sibling and child.
  cell echelon2 = make_array(
      vm, {false_object, false_object,
           make_array(vm, {sibling, sibling_method, child, child_method}),
           false_object});
  // Echelon 1 table: bucket 1 holds the method directly.
  cell echelon1 = make_array(vm, {false_object, parent_method, false_object,
                                  false_object});
  // Echelon 0: a word applies to every tuple.
  cell echelons = make_array(vm, {root_method, echelon1, echelon2});

  cell methods = make_methods(vm);
  vm.set_array_nth(untag<factor::array>(methods), TUPLE_TYPE, echelons);

  CHECK_EQ(child_method, vm.lookup_method(child_tuple, methods));

  // Without a child entry the lookup falls back to the parent's method.
  vm.set_array_nth(untag<factor::array>(echelon2), 2, false_object);
  CHECK_EQ(parent_method, vm.lookup_method(child_tuple, methods));

  // And then to the root's word.
  vm.set_array_nth(untag<factor::array>(echelon1), 1, false_object);
  CHECK_EQ(root_method, vm.lookup_method(child_tuple, methods));

  // A class deeper than the method table starts at the table's last echelon.
  cell deep_layout =
      make_layout(vm, child, {root, parent, child, child, child}, {0, 1, 2, 2, 2});
  cell deep_tuple = make_tuple(vm, deep_layout);
  vm.set_array_nth(untag<factor::array>(echelon2), 2,
                   make_array(vm, {child, child_method}));
  CHECK_EQ(child_method, vm.lookup_method(deep_tuple, methods));

  // A plain word in the tuple slot is the method for every tuple.
  vm.set_array_nth(untag<factor::array>(methods), TUPLE_TYPE, sibling_method);
  CHECK_EQ(sibling_method, vm.lookup_method(child_tuple, methods));
}

FACTOR_TEST(mega_cache_miss_fills_the_cache_and_counts) {
  test_vm t;
  factor_vm& vm = t.vm;
  vm.primitive_reset_dispatch_stats();
  cell methods = make_methods(vm);
  cell fixnum_method = make_word(vm);
  cell array_method = make_word(vm);
  vm.set_array_nth(untag<factor::array>(methods), FIXNUM_TYPE, fixnum_method);
  vm.set_array_nth(untag<factor::array>(methods), ARRAY_TYPE, array_method);
  // Four class/method pairs.
  cell cache = tag<factor::array>(vm.allot_array(8, false_object));

  // Index 0: the receiver is on top of the stack.
  cell depth = t.datastack_depth();
  t.push(tag_fixnum(5));
  t.push(methods);
  t.push_fixnum(0);
  t.push(cache);
  vm.primitive_mega_cache_miss();
  CHECK_EQ(depth + 2, t.datastack_depth());
  CHECK_EQ(fixnum_method, t.pop());
  CHECK_EQ(tag_fixnum(5), t.pop());
  CHECK_EQ((cell)1, vm.dispatch_stats.megamorphic_cache_misses);
  // klass tag_fixnum(0) hashes to slot 0.
  factor::array* c = untag<factor::array>(cache);
  CHECK_EQ(tag_fixnum(FIXNUM_TYPE), array_nth(c, 0));
  CHECK_EQ(fixnum_method, array_nth(c, 1));

  // Index 1: the receiver is one below the top.
  cell arr = make_array(vm, {});
  t.push(arr);
  t.push(tag_fixnum(7));
  t.push(methods);
  t.push_fixnum(1);
  t.push(cache);
  vm.primitive_mega_cache_miss();
  CHECK_EQ(array_method, t.pop());
  CHECK_EQ(tag_fixnum(7), t.pop());
  CHECK_EQ(arr, t.pop());
  CHECK_EQ((cell)2, vm.dispatch_stats.megamorphic_cache_misses);
  // klass tag_fixnum(ARRAY_TYPE): (ARRAY_TYPE & 3) << 1.
  cell slot = ((ARRAY_TYPE) & 3) << 1;
  CHECK_EQ(tag_fixnum(ARRAY_TYPE), array_nth(c, slot));
  CHECK_EQ(array_method, array_nth(c, slot + 1));
}

FACTOR_TEST(update_method_cache_hashes_by_class) {
  test_vm t;
  factor_vm& vm = t.vm;
  cell cache = tag<factor::array>(vm.allot_array(8, false_object));
  cell m = make_word(vm);
  // A tuple layout class is hashed by its untagged address.
  cell klass = make_word(vm);
  cell layout = make_layout(vm, klass, {klass}, {0});
  vm.update_method_cache(cache, layout, m);
  cell slot = ((layout >> TAG_BITS) & 3) << 1;
  factor::array* c = untag<factor::array>(cache);
  CHECK_EQ(layout, array_nth(c, slot));
  CHECK_EQ(m, array_nth(c, slot + 1));
}

FACTOR_TEST(update_pic_transitions_counts_by_size) {
  test_vm t;
  factor_vm& vm = t.vm;
  vm.max_pic_size = 3;
  vm.primitive_reset_dispatch_stats();
  vm.update_pic_transitions(0);
  vm.update_pic_transitions(1);
  vm.update_pic_transitions(2);
  vm.update_pic_transitions(3);
  CHECK_EQ((cell)1, vm.dispatch_stats.cold_call_to_ic_transitions);
  CHECK_EQ((cell)1, vm.dispatch_stats.ic_to_pic_transitions);
  CHECK_EQ((cell)1, vm.dispatch_stats.pic_to_mega_transitions);
  vm.update_pic_count(PIC_TAG);
  vm.update_pic_count(PIC_TUPLE);
  vm.update_pic_count(PIC_TUPLE);
  CHECK_EQ((cell)1, vm.dispatch_stats.pic_tag_count);
  CHECK_EQ((cell)2, vm.dispatch_stats.pic_tuple_count);
}

FACTOR_TEST(add_inline_cache_entry_grows_replaces_and_dedupes) {
  test_vm t;
  factor_vm& vm = t.vm;
  cell k1 = tag_fixnum(FIXNUM_TYPE);
  cell k2 = tag_fixnum(ARRAY_TYPE);
  cell m1 = make_word(vm);
  cell m2 = make_word(vm);
  cell m3 = make_word(vm);
  cell entries = tag<factor::array>(vm.allot_array(0, false_object));

  cell one = vm.add_inline_cache_entry(entries, k1, m1);
  CHECK_EQ((cell)2, array_capacity(untag<factor::array>(one)));
  CHECK_EQ(k1, array_nth(untag<factor::array>(one), 0));
  CHECK_EQ(m1, array_nth(untag<factor::array>(one), 1));

  // The same pair again cannot help: f.
  CHECK_EQ(false_object, vm.add_inline_cache_entry(one, k1, m1));

  // A new method for a cached class is patched in place.
  CHECK_EQ(one, vm.add_inline_cache_entry(one, k1, m2));
  CHECK_EQ(m2, array_nth(untag<factor::array>(one), 1));

  cell two = vm.add_inline_cache_entry(one, k2, m3);
  CHECK_EQ((cell)4, array_capacity(untag<factor::array>(two)));
  CHECK_EQ(k2, array_nth(untag<factor::array>(two), 2));
  CHECK_EQ(m3, array_nth(untag<factor::array>(two), 3));
}

FACTOR_TEST(dispatch_stats_primitive_copies_the_counters) {
  test_vm t;
  factor_vm& vm = t.vm;
  vm.primitive_reset_dispatch_stats();
  vm.dispatch_stats.megamorphic_cache_hits = 5;
  vm.dispatch_stats.pic_tuple_count = 9;
  cell depth = t.datastack_depth();
  vm.primitive_dispatch_stats();
  CHECK_EQ(depth + 1, t.datastack_depth());
  cell ba = t.pop();
  CHECK_EQ((cell)BYTE_ARRAY_TYPE, TAG(ba));
  CHECK_EQ(sizeof(dispatch_statistics),
           array_capacity(untag<byte_array>(ba)));
  dispatch_statistics* stats = untag<byte_array>(ba)->data<dispatch_statistics>();
  CHECK_EQ((cell)5, stats->megamorphic_cache_hits);
  CHECK_EQ((cell)9, stats->pic_tuple_count);
  CHECK_EQ((cell)0, stats->megamorphic_cache_misses);
}
