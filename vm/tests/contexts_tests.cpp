// Tests for vm/contexts.cpp: context construction, the data and retain
// stacks, context recycling and the context primitives.
#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

static const cell true_sentinel = tag_fixnum(0x74727565);

FACTOR_TEST(context_construction_resets_all_stacks) {
  test_vm t;
  context* c = t.vm.ctx;
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);
  CHECK_EQ(c->retainstack_seg->start - sizeof(cell), c->retainstack);
  CHECK_EQ((cell)CALLSTACK_BOTTOM(c), c->callstack_top);
  CHECK_EQ((cell)CALLSTACK_BOTTOM(c), c->callstack_bottom);
  CHECK_EQ((cell)0, c->callstack_save);
  for (cell i = 0; i < context_object_count; i++)
    CHECK_EQ(false_object, c->context_objects[i]);
  CHECK_EQ(t.vm.datastack_size, c->datastack_seg->size);
  CHECK_EQ(t.vm.retainstack_size, c->retainstack_seg->size);
  CHECK_EQ(t.vm.callstack_size, c->callstack_seg->size);
  CHECK_EQ(c->datastack_seg->start + c->datastack_seg->size,
           c->datastack_seg->end);
}

FACTOR_TEST(datastack_push_pop_peek_replace) {
  test_vm t;
  context* c = t.vm.ctx;
  c->push(tag_fixnum(1));
  c->push(tag_fixnum(2));
  CHECK_EQ(tag_fixnum(2), c->peek());
  CHECK_EQ((cell)2, t.datastack_depth());
  c->replace(tag_fixnum(3));
  CHECK_EQ(tag_fixnum(3), c->peek());
  CHECK_EQ((cell)2, t.datastack_depth());
  CHECK_EQ(tag_fixnum(3), c->pop());
  CHECK_EQ(tag_fixnum(1), c->pop());
  CHECK_EQ((cell)0, t.datastack_depth());
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);
}

FACTOR_TEST(context_reset_clears_stacks_and_objects) {
  test_vm t;
  context* c = t.vm.ctx;
  c->push(tag_fixnum(1));
  c->retainstack += sizeof(cell);
  c->context_objects[OBJ_NAMESTACK] = tag_fixnum(5);
  c->callstack_top = c->callstack_bottom - 64;
  c->reset();
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);
  CHECK_EQ(c->retainstack_seg->start - sizeof(cell), c->retainstack);
  CHECK_EQ((cell)CALLSTACK_BOTTOM(c), c->callstack_top);
  CHECK_EQ(false_object, c->context_objects[OBJ_NAMESTACK]);
}

FACTOR_TEST(fix_stacks_only_resets_out_of_bounds_stacks) {
  test_vm t;
  context* c = t.vm.ctx;
  c->push(tag_fixnum(1));
  c->push(tag_fixnum(2));
  c->retainstack += sizeof(cell);
  cell retain_before = c->retainstack;
  c->fix_stacks();
  CHECK_EQ((cell)2, t.datastack_depth());
  CHECK_EQ(retain_before, c->retainstack);

  // Underflow: pointer below the segment.
  c->datastack = c->datastack_seg->start - 2 * sizeof(cell);
  c->fix_stacks();
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);
  CHECK_EQ(retain_before, c->retainstack);

  // Overflow: less than stack_reserved bytes of headroom.
  c->datastack = c->datastack_seg->end - stack_reserved;
  c->fix_stacks();
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);

  // Exactly stack_reserved plus one cell of headroom is still fine.
  c->datastack = c->datastack_seg->end - stack_reserved - sizeof(cell);
  c->fix_stacks();
  CHECK_EQ(c->datastack_seg->end - stack_reserved - sizeof(cell),
           c->datastack);

  // The retain stack is checked independently.
  c->retainstack = c->retainstack_seg->end;
  c->fix_stacks();
  CHECK_EQ(c->retainstack_seg->start - sizeof(cell), c->retainstack);
}

FACTOR_TEST(address_to_error_maps_guard_pages) {
  test_vm t;
  context* c = t.vm.ctx;
  cell page = getpagesize();
  CHECK_EQ((int)ERROR_DATASTACK_UNDERFLOW,
           (int)c->address_to_error(c->datastack_seg->start - sizeof(cell)));
  CHECK_EQ((int)ERROR_DATASTACK_UNDERFLOW,
           (int)c->address_to_error(c->datastack_seg->start - page));
  CHECK_EQ((int)ERROR_DATASTACK_OVERFLOW,
           (int)c->address_to_error(c->datastack_seg->end));
  CHECK_EQ((int)ERROR_DATASTACK_OVERFLOW,
           (int)c->address_to_error(c->datastack_seg->end + page - 1));
  CHECK_EQ((int)ERROR_RETAINSTACK_UNDERFLOW,
           (int)c->address_to_error(c->retainstack_seg->start - 1));
  CHECK_EQ((int)ERROR_RETAINSTACK_OVERFLOW,
           (int)c->address_to_error(c->retainstack_seg->end + 8));
  // The callstack grows downwards, so the low guard page is an overflow.
  CHECK_EQ((int)ERROR_CALLSTACK_OVERFLOW,
           (int)c->address_to_error(c->callstack_seg->start - 16));
  CHECK_EQ((int)ERROR_CALLSTACK_UNDERFLOW,
           (int)c->address_to_error(c->callstack_seg->end + 16));
  // Inside a segment or anywhere else is a plain memory error.
  CHECK_EQ((int)ERROR_MEMORY,
           (int)c->address_to_error(c->datastack_seg->start));
  CHECK_EQ((int)ERROR_MEMORY, (int)c->address_to_error(16));
}

FACTOR_TEST(new_context_and_delete_context_recycle) {
  test_vm t;
  factor_vm& vm = t.vm;
  size_t active = vm.active_contexts.size();
  CHECK_EQ((size_t)2, active);
  CHECK(vm.unused_contexts.empty());

  context* c = vm.new_context();
  CHECK_EQ(active + 1, vm.active_contexts.size());
  CHECK_EQ((size_t)1, vm.active_contexts.count(c));

  // delete_context parks the current context on the unused list.
  context* saved = vm.ctx;
  vm.ctx = c;
  c->push(tag_fixnum(9));
  vm.delete_context();
  vm.ctx = saved;
  CHECK_EQ(active, vm.active_contexts.size());
  CHECK_EQ((size_t)0, vm.active_contexts.count(c));
  CHECK_EQ((size_t)1, vm.unused_contexts.size());
  CHECK_EQ(c, vm.unused_contexts.back());

  // The next new_context reuses it, reset.
  context* again = vm.new_context();
  CHECK_EQ(c, again);
  CHECK(vm.unused_contexts.empty());
  CHECK_EQ(c->datastack_seg->start - sizeof(cell), c->datastack);
}

FACTOR_TEST(delete_context_keeps_at_most_ten_unused) {
  test_vm t;
  factor_vm& vm = t.vm;
  context* saved = vm.ctx;
  std::vector<context*> made;
  for (int i = 0; i < 12; i++)
    made.push_back(vm.new_context());
  for (context* c : made) {
    vm.ctx = c;
    vm.delete_context();
  }
  vm.ctx = saved;
  CHECK_EQ((size_t)10, vm.unused_contexts.size());
  CHECK_EQ((size_t)2, vm.active_contexts.size());
  // The oldest two were freed; the newest ten remain, newest last.
  CHECK_EQ(made[11], vm.unused_contexts.back());
  CHECK_EQ(made[2], vm.unused_contexts.front());
}

FACTOR_TEST(init_context_stores_an_alien_to_itself) {
  test_vm t;
  context* c = t.vm.ctx;
  t.vm.init_context(c);
  cell a = c->context_objects[OBJ_CONTEXT];
  CHECK_EQ((cell)ALIEN_TYPE, TAG(a));
  CHECK_EQ((cell)c, untag<alien>(a)->address);
  CHECK_EQ(false_object, untag<alien>(a)->base);
  CHECK_EQ((char*)c, t.vm.pinned_alien_offset(a));
}

FACTOR_TEST(context_object_primitives) {
  test_vm t;
  factor_vm& vm = t.vm;
  cell depth = t.datastack_depth();

  t.push(tag_fixnum(77));
  t.push_fixnum(OBJ_CATCHSTACK);
  vm.primitive_set_context_object();
  CHECK_EQ(depth, t.datastack_depth());
  CHECK_EQ(tag_fixnum(77), vm.ctx->context_objects[OBJ_CATCHSTACK]);

  t.push_fixnum(OBJ_CATCHSTACK);
  vm.primitive_context_object();
  CHECK_EQ(depth + 1, t.datastack_depth());
  CHECK_EQ(tag_fixnum(77), t.pop());

  // context-object-for reads another context through its alien.
  vm.spare_ctx->context_objects[OBJ_NAMESTACK] = tag_fixnum(11);
  vm.init_context(vm.spare_ctx);
  t.push_fixnum(OBJ_NAMESTACK);
  t.push(vm.spare_ctx->context_objects[OBJ_CONTEXT]);
  vm.primitive_context_object_for();
  CHECK_EQ(depth + 1, t.datastack_depth());
  CHECK_EQ(tag_fixnum(11), t.pop());
}

FACTOR_TEST(datastack_to_array_copies_bottom_first) {
  test_vm t;
  factor_vm& vm = t.vm;
  t.push_fixnum(1);
  t.push_fixnum(2);
  t.push_fixnum(3);
  cell arr = vm.datastack_to_array(vm.ctx);
  factor::array* a = untag<factor::array>(arr);
  CHECK_EQ((cell)3, array_capacity(a));
  CHECK_EQ(tag_fixnum(1), array_nth(a, 0));
  CHECK_EQ(tag_fixnum(3), array_nth(a, 2));
  // The source stack is untouched.
  CHECK_EQ((cell)3, t.datastack_depth());

  factor::array* empty =
      untag<factor::array>(vm.datastack_to_array(vm.spare_ctx));
  CHECK_EQ((cell)0, array_capacity(empty));
}

FACTOR_TEST(datastack_for_and_retainstack_for_primitives) {
  test_vm t;
  factor_vm& vm = t.vm;
  context* other = vm.spare_ctx;
  vm.init_context(other);
  other->push(tag_fixnum(4));
  other->push(tag_fixnum(5));
  // Two retain stack entries.
  ((cell*)other->retainstack_seg->start)[0] = tag_fixnum(6);
  ((cell*)other->retainstack_seg->start)[1] = tag_fixnum(7);
  other->retainstack = other->retainstack_seg->start + sizeof(cell);

  cell depth = t.datastack_depth();
  t.push(other->context_objects[OBJ_CONTEXT]);
  vm.primitive_datastack_for();
  CHECK_EQ(depth + 1, t.datastack_depth());
  factor::array* ds = untag<factor::array>(t.pop());
  CHECK_EQ((cell)2, array_capacity(ds));
  CHECK_EQ(tag_fixnum(4), array_nth(ds, 0));
  CHECK_EQ(tag_fixnum(5), array_nth(ds, 1));

  t.push(other->context_objects[OBJ_CONTEXT]);
  vm.primitive_retainstack_for();
  CHECK_EQ(depth + 1, t.datastack_depth());
  factor::array* rs = untag<factor::array>(t.pop());
  CHECK_EQ((cell)2, array_capacity(rs));
  CHECK_EQ(tag_fixnum(6), array_nth(rs, 0));
  CHECK_EQ(tag_fixnum(7), array_nth(rs, 1));
}

FACTOR_TEST(set_datastack_and_set_retainstack_primitives) {
  test_vm t;
  factor_vm& vm = t.vm;
  factor::array* a = vm.allot_array(3, false_object);
  vm.set_array_nth(a, 0, tag_fixnum(10));
  vm.set_array_nth(a, 1, tag_fixnum(20));
  vm.set_array_nth(a, 2, tag_fixnum(30));

  t.push_fixnum(99);
  t.push(tag<factor::array>(a));
  vm.primitive_set_datastack();
  CHECK_EQ((cell)3, t.datastack_depth());
  CHECK_EQ(tag_fixnum(30), t.pop());
  CHECK_EQ(tag_fixnum(20), t.pop());
  CHECK_EQ(tag_fixnum(10), t.pop());

  t.push(tag<factor::array>(vm.allot_array(0, false_object)));
  vm.primitive_set_datastack();
  CHECK_EQ((cell)0, t.datastack_depth());

  t.push(tag<factor::array>(a));
  vm.primitive_set_retainstack();
  CHECK_EQ((cell)0, t.datastack_depth());
  CHECK_EQ(vm.ctx->retainstack_seg->start + 2 * sizeof(cell),
           vm.ctx->retainstack);
  CHECK_EQ(tag_fixnum(10), ((cell*)vm.ctx->retainstack_seg->start)[0]);
  CHECK_EQ(tag_fixnum(30), *(cell*)vm.ctx->retainstack);
}

FACTOR_TEST(check_datastack_primitive) {
  test_vm t;
  factor_vm& vm = t.vm;
  vm.special_objects[OBJ_CANONICAL_TRUE] = true_sentinel;

  t.push_fixnum(1);
  t.push_fixnum(2);
  cell saved = vm.datastack_to_array(vm.ctx);

  // A quotation with effect ( -- x ) pushed one value: heights agree.
  t.push_fixnum(3);
  t.push(saved);
  t.push_fixnum(0); // in
  t.push_fixnum(1); // out
  vm.primitive_check_datastack();
  CHECK_EQ(true_sentinel, t.pop());
  CHECK_EQ((cell)3, t.datastack_depth());

  // Claimed effect ( -- ) but the stack grew: height mismatch.
  t.push(saved);
  t.push_fixnum(0);
  t.push_fixnum(0);
  vm.primitive_check_datastack();
  CHECK_EQ(false_object, t.pop());
  CHECK_EQ((cell)3, t.datastack_depth());

  // Right height but an element below the inputs was changed.
  ((cell*)vm.ctx->datastack_seg->start)[0] = tag_fixnum(42);
  t.push(saved);
  t.push_fixnum(0);
  t.push_fixnum(1);
  vm.primitive_check_datastack();
  CHECK_EQ(false_object, t.pop());

  // Consumed inputs are not compared: ( x -- y ) with the input changed.
  ((cell*)vm.ctx->datastack_seg->start)[0] = tag_fixnum(1);
  ((cell*)vm.ctx->datastack_seg->start)[1] = tag_fixnum(99);
  t.push(saved);
  t.push_fixnum(1);
  t.push_fixnum(2);
  vm.primitive_check_datastack();
  CHECK_EQ(true_sentinel, t.pop());
  CHECK_EQ((cell)3, t.datastack_depth());
}

FACTOR_TEST(load_locals_moves_values_to_the_retain_stack) {
  test_vm t;
  factor_vm& vm = t.vm;
  context* c = vm.ctx;
  t.push_fixnum(1);
  t.push_fixnum(2);
  t.push_fixnum(3);
  t.push_fixnum(2); // count
  vm.primitive_load_locals();
  CHECK_EQ((cell)1, t.datastack_depth());
  CHECK_EQ(tag_fixnum(1), c->peek());
  CHECK_EQ(c->retainstack_seg->start + sizeof(cell), c->retainstack);
  CHECK_EQ(tag_fixnum(2), ((cell*)c->retainstack_seg->start)[0]);
  CHECK_EQ(tag_fixnum(3), ((cell*)c->retainstack_seg->start)[1]);

  // Zero locals is a no-op. The arithmetic is signed, so count - 1 == -1
  // is harmless here, unlike in the Zig port where it underflows.
  t.push_fixnum(0);
  vm.primitive_load_locals();
  CHECK_EQ((cell)1, t.datastack_depth());
  CHECK_EQ(c->retainstack_seg->start + sizeof(cell), c->retainstack);

  // One more local goes above the previous two.
  t.push_fixnum(1);
  vm.primitive_load_locals();
  CHECK_EQ((cell)0, t.datastack_depth());
  CHECK_EQ(c->retainstack_seg->start + 2 * sizeof(cell), c->retainstack);
  CHECK_EQ(tag_fixnum(1), *(cell*)c->retainstack);
}

FACTOR_TEST(begin_and_end_callback_bookkeeping) {
  test_vm t;
  factor_vm& vm = t.vm;
  context* original_spare = vm.spare_ctx;
  t.push_fixnum(1);

  cell quot = tag_fixnum(123);
  CHECK_EQ(quot, vm.begin_callback(quot));
  // The current context was reset and re-initialised, a fresh spare context
  // was created and a callback id recorded.
  CHECK_EQ((cell)0, t.datastack_depth());
  CHECK_EQ((cell)ALIEN_TYPE, TAG(vm.ctx->context_objects[OBJ_CONTEXT]));
  CHECK(vm.spare_ctx != original_spare);
  CHECK_EQ((size_t)1, vm.callback_ids.size());
  CHECK_EQ(0, vm.callback_ids.back());
  CHECK_EQ(1, vm.callback_id);

  vm.primitive_current_callback();
  CHECK_EQ(tag_fixnum(0), t.pop());

  // end_callback parks the current context; a real callback stub would
  // switch ctx back, so do it by hand before the fixture tears down.
  context* parked = vm.ctx;
  vm.end_callback();
  CHECK(vm.callback_ids.empty());
  CHECK_EQ(parked, vm.unused_contexts.back());
  vm.ctx = vm.new_context();
  CHECK_EQ(parked, vm.ctx);
  // The replacement spare context stays in active_contexts and is freed with
  // the VM, as is the original.
  vm.spare_ctx = original_spare;
}

FACTOR_TEST(reset_context_keeps_the_top_two_values) {
  test_vm t;
  factor_vm& vm = t.vm;
  t.push_fixnum(1);
  t.push_fixnum(2);
  t.push_fixnum(3);
  vm.ctx->context_objects[OBJ_NAMESTACK] = tag_fixnum(5);
  reset_context(&vm);
  CHECK_EQ((cell)2, t.datastack_depth());
  CHECK_EQ(tag_fixnum(3), t.pop());
  CHECK_EQ(tag_fixnum(2), t.pop());
  CHECK_EQ(false_object, vm.ctx->context_objects[OBJ_NAMESTACK]);
  CHECK_EQ((cell)ALIEN_TYPE, TAG(vm.ctx->context_objects[OBJ_CONTEXT]));
}
