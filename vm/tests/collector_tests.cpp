// Collections on a bare VM: nursery, aging, full and compacting GCs, and
// large object allocation.
#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

namespace {

// gc() visits the callback heap and the code heap's remembered sets, so a
// collecting VM needs both, even though they stay empty.
struct gc_vm : test_vm {
  gc_vm() : test_vm(256 * 1024, 256 * 1024, 4 * 1024 * 1024) {
    vm.code = new code_heap(1024 * 1024);
    vm.callbacks = new callback_heap(64 * 1024, &vm);
  }
};

// A tenured array with `capacity` cells. Capacities of 64 and up take the
// large-block path of the free list, which hands out ascending addresses.
factor::array* tenured_array(factor_vm& vm, cell capacity, cell fill) {
  cell size = align(sizeof(factor::array) + capacity * sizeof(cell), data_alignment);
  object* obj = vm.data->tenured->allot(size);
  CHECK(obj != NULL);
  obj->initialize(ARRAY_TYPE);
  factor::array* a = (factor::array*)obj;
  a->capacity = tag_fixnum(capacity);
  memset_cell(a->data(), fill, capacity * sizeof(cell));
  return a;
}

void push_retain(context* ctx, cell tagged) {
  ctx->retainstack += sizeof(cell);
  *(cell*)ctx->retainstack = tagged;
}

cell card_of(factor_vm& vm, cell addr) {
  return vm.data->cards[addr_to_card(addr - vm.data->start)];
}

} // namespace

FACTOR_TEST(nursery_collection_promotes_roots_and_drops_garbage) {
  gc_vm t;
  data_heap* heap = t.vm.data;

  factor::array* live = t.vm.allot_array(3, tag_fixnum(11));
  t.vm.set_array_nth(live, 1, tag_fixnum(22));
  cell live_tagged = tag<factor::array>(live);
  t.push(live_tagged);
  t.vm.allot_array(100, false_object); // garbage
  CHECK(heap->nursery->contains_p(live));
  CHECK_EQ((cell)0, heap->aging->occupied_space());

  t.vm.primitive_minor_gc();

  cell moved = t.pop();
  CHECK(moved != live_tagged);
  CHECK_EQ((cell)ARRAY_TYPE, TAG(moved));
  factor::array* copy = untag<factor::array>(moved);
  CHECK(heap->aging->contains_p(copy));
  CHECK_EQ((cell)3, array_capacity(copy));
  CHECK_EQ(tag_fixnum(11), array_nth(copy, 0));
  CHECK_EQ(tag_fixnum(22), array_nth(copy, 1));
  CHECK_EQ(tag_fixnum(11), array_nth(copy, 2));

  // Only the live object was copied; the nursery was emptied.
  CHECK_EQ(copy->size(), heap->aging->occupied_space());
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
  CHECK(!heap->nursery->contains_p(copy));
}

FACTOR_TEST(nursery_collection_visits_every_root_kind) {
  gc_vm t;
  data_heap* heap = t.vm.data;

  factor::array* from_retain = t.vm.allot_array(1, tag_fixnum(1));
  factor::array* from_special = t.vm.allot_array(1, tag_fixnum(2));
  factor::array* from_data_root = t.vm.allot_array(1, tag_fixnum(3));
  factor::array* from_context_object = t.vm.allot_array(1, tag_fixnum(4));
  factor::array* from_spare_ctx = t.vm.allot_array(1, tag_fixnum(5));

  push_retain(t.vm.ctx, tag<factor::array>(from_retain));
  t.vm.special_objects[OBJ_ARGS] = tag<factor::array>(from_special);
  data_root<factor::array> rooted(from_data_root, &t.vm);
  t.vm.ctx->context_objects[0] = tag<factor::array>(from_context_object);
  t.vm.spare_ctx->push(tag<factor::array>(from_spare_ctx));

  t.vm.primitive_minor_gc();

  cell retain_top = *(cell*)t.vm.ctx->retainstack;
  CHECK(heap->aging->contains_p(untag<factor::array>(retain_top)));
  CHECK_EQ(tag_fixnum(1), array_nth(untag<factor::array>(retain_top), 0));
  CHECK(heap->aging->contains_p(untag<factor::array>(t.vm.special_objects[OBJ_ARGS])));
  CHECK_EQ(tag_fixnum(2), array_nth(untag<factor::array>(t.vm.special_objects[OBJ_ARGS]), 0));
  CHECK(heap->aging->contains_p(rooted.untagged()));
  CHECK_EQ(tag_fixnum(3), array_nth(rooted.untagged(), 0));
  CHECK(heap->aging->contains_p(untag<factor::array>(t.vm.ctx->context_objects[0])));
  CHECK_EQ(tag_fixnum(4), array_nth(untag<factor::array>(t.vm.ctx->context_objects[0]), 0));
  CHECK(heap->aging->contains_p(untag<factor::array>(t.vm.spare_ctx->peek())));
  CHECK_EQ(tag_fixnum(5), array_nth(untag<factor::array>(t.vm.spare_ctx->peek()), 0));
  CHECK_EQ((cell)5 * 32, heap->aging->occupied_space());
}

FACTOR_TEST(nursery_collection_follows_pointers_between_young_objects) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  factor::array* inner = t.vm.allot_array(1, tag_fixnum(9));
  factor::array* outer = t.vm.allot_array(2, tag<factor::array>(inner));
  cell inner_size = inner->size();
  cell outer_size = outer->size();
  t.push(tag<factor::array>(outer));

  t.vm.primitive_minor_gc();

  factor::array* outer_copy = untag<factor::array>(t.pop());
  CHECK(heap->aging->contains_p(outer_copy));
  factor::array* inner_copy = untag<factor::array>(array_nth(outer_copy, 0));
  CHECK(heap->aging->contains_p(inner_copy));
  // Both slots referenced the same object and still do.
  CHECK_EQ(array_nth(outer_copy, 0), array_nth(outer_copy, 1));
  CHECK_EQ(tag_fixnum(9), array_nth(inner_copy, 0));
  CHECK_EQ(inner_size + outer_size, heap->aging->occupied_space());
}

FACTOR_TEST(nursery_collection_scans_only_marked_tenured_cards) {
  gc_vm t;
  data_heap* heap = t.vm.data;

  // Two tenured arrays far enough apart to live in different cards.
  factor::array* marked = tenured_array(t.vm, 64, false_object);
  factor::array* unmarked = tenured_array(t.vm, 64, false_object);
  CHECK(addr_to_card((cell)marked - heap->start) != addr_to_card((cell)unmarked - heap->start));
  heap->reset_tenured(); // drop any marks left by allocation

  factor::array* young_a = t.vm.allot_array(1, tag_fixnum(1));
  factor::array* young_b = t.vm.allot_array(1, tag_fixnum(2));
  cell young_a_size = young_a->size();
  cell young_a_tagged = tag<factor::array>(young_a);
  cell young_b_tagged = tag<factor::array>(young_b);

  marked->data()[0] = young_a_tagged;
  t.vm.write_barrier(&marked->data()[0]);
  unmarked->data()[0] = young_b_tagged; // no barrier: a bug in real code
  CHECK_EQ((cell)card_mark_mask, card_of(t.vm, (cell)&marked->data()[0]));
  CHECK_EQ((cell)0, card_of(t.vm, (cell)&unmarked->data()[0]));

  t.vm.primitive_minor_gc();

  // The barriered slot follows its object into aging.
  cell a_now = array_nth(marked, 0);
  CHECK(a_now != young_a_tagged);
  CHECK(heap->aging->contains_p(untag<factor::array>(a_now)));
  CHECK_EQ(tag_fixnum(1), array_nth(untag<factor::array>(a_now), 0));
  // The unbarriered slot was never visited and still holds the stale value.
  CHECK_EQ(young_b_tagged, array_nth(unmarked, 0));
  // Only young_a was promoted.
  CHECK_EQ(young_a_size, heap->aging->occupied_space());
  // Scanning clears the nursery bit but keeps the aging bit on the card.
  cell card = card_of(t.vm, (cell)&marked->data()[0]);
  CHECK_EQ((cell)0, card & card_points_to_nursery);
  CHECK_EQ((cell)card_points_to_aging, card & card_points_to_aging);
}

FACTOR_TEST(aging_collection_moves_survivors_to_the_other_semispace) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  factor::array* live = t.vm.allot_array(2, tag_fixnum(7));
  t.push(tag<factor::array>(live));
  t.vm.primitive_minor_gc();
  aging_space* first_aging = heap->aging;
  factor::array* in_aging = untag<factor::array>(t.vm.ctx->peek());
  CHECK(first_aging->contains_p(in_aging));
  t.vm.allot_array(50, false_object); // nursery garbage

  t.vm.gc(COLLECT_AGING_OP, 0);

  CHECK(heap->aging != first_aging);
  CHECK_EQ((cell)first_aging, (cell)heap->aging_semispace);
  factor::array* now = untag<factor::array>(t.pop());
  CHECK(heap->aging->contains_p(now));
  CHECK(!first_aging->contains_p(now));
  CHECK_EQ(tag_fixnum(7), array_nth(now, 1));
  CHECK_EQ(now->size(), heap->aging->occupied_space());
  // The old semispace is only reset when it becomes the aging space again.
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
}

FACTOR_TEST(to_tenured_collection_promotes_aging_objects_referenced_from_tenured) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  factor::array* holder = tenured_array(t.vm, 64, false_object);
  cell tenured_before = heap->tenured->occupied_space();
  factor::array* young = t.vm.allot_array(1, tag_fixnum(3));
  t.vm.set_array_nth(holder, 0, tag<factor::array>(young));
  t.vm.write_barrier(&holder->data()[0]);

  t.vm.gc(COLLECT_TO_TENURED_OP, 0);

  factor::array* promoted = untag<factor::array>(array_nth(holder, 0));
  CHECK(heap->tenured->contains_p(promoted));
  CHECK_EQ(tag_fixnum(3), array_nth(promoted, 0));
  CHECK_EQ(tenured_before + promoted->size(), heap->tenured->occupied_space());
  CHECK_EQ((cell)0, heap->aging->occupied_space());
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
}

FACTOR_TEST(full_collection_sweeps_tenured_garbage_into_the_free_list) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  factor::array* a = tenured_array(t.vm, 64, tag_fixnum(1));
  factor::array* garbage = tenured_array(t.vm, 64, tag_fixnum(2));
  factor::array* c = tenured_array(t.vm, 64, tag_fixnum(3));
  cell block_size = a->size();
  cell occupied_before = heap->tenured->occupied_space();
  t.push(tag<factor::array>(a));
  t.push(tag<factor::array>(c));
  factor::array* young = t.vm.allot_array(1, tag_fixnum(4));
  t.push(tag<factor::array>(young));

  t.vm.primitive_full_gc();

  // Tenured survivors stay put; garbage becomes a free block.
  CHECK_EQ(tag<factor::array>(a), *(cell*)(t.vm.ctx->datastack - 2 * sizeof(cell)));
  CHECK_EQ(tag<factor::array>(c), *(cell*)(t.vm.ctx->datastack - sizeof(cell)));
  CHECK(((object*)garbage)->free_p());
  CHECK_EQ(block_size, ((free_heap_block*)garbage)->size());
  CHECK_EQ(tag_fixnum(1), array_nth(a, 0));
  CHECK_EQ(tag_fixnum(3), array_nth(c, 0));
  // The young object was promoted straight to tenured.
  factor::array* promoted = untag<factor::array>(t.vm.ctx->peek());
  CHECK(heap->tenured->contains_p(promoted));
  CHECK_EQ(tag_fixnum(4), array_nth(promoted, 0));
  CHECK_EQ(occupied_before - block_size + promoted->size(),
           heap->tenured->occupied_space());
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
  CHECK_EQ((cell)0, heap->aging->occupied_space());
  // The hole is reusable.
  CHECK_EQ((cell)garbage, (cell)heap->tenured->allot(block_size));
}

FACTOR_TEST(compacting_collection_slides_live_objects_down_and_fixes_slots) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  factor::array* a = tenured_array(t.vm, 64, tag_fixnum(1));
  factor::array* garbage = tenured_array(t.vm, 64, tag_fixnum(2));
  factor::array* c = tenured_array(t.vm, 64, tag_fixnum(3));
  cell size = a->size();
  CHECK_EQ(heap->tenured->start, (cell)a);
  CHECK_EQ(heap->tenured->start + size, (cell)garbage);
  CHECK_EQ(heap->tenured->start + 2 * size, (cell)c);
  t.vm.set_array_nth(c, 0, tag<factor::array>(a));
  t.vm.set_array_nth(c, 1, tag<factor::array>(c)); // self reference
  t.push(tag<factor::array>(c));
  t.vm.special_objects[OBJ_ARGS] = tag<factor::array>(a);

  t.vm.primitive_compact_gc();

  factor::array* c_now = untag<factor::array>(t.pop());
  CHECK_EQ(heap->tenured->start + size, (cell)c_now);
  CHECK_EQ(tag<factor::array>(a), t.vm.special_objects[OBJ_ARGS]);
  CHECK_EQ(tag<factor::array>(a), array_nth(c_now, 0));
  CHECK_EQ(tag<factor::array>(c_now), array_nth(c_now, 1));
  CHECK_EQ(tag_fixnum(3), array_nth(c_now, 2));
  CHECK_EQ(tag_fixnum(1), array_nth(a, 63));
  CHECK_EQ((cell)64, array_capacity(c_now));
  // One trailing free block, and the object start map knows the new places.
  CHECK_EQ((cell)1, heap->tenured->free_block_count);
  CHECK_EQ(heap->tenured->size - 2 * size, heap->tenured->free_space);
  CHECK_EQ((cell)c_now, heap->tenured->next_object_after((cell)a));
  CHECK_EQ(heap->tenured->start + 2 * size, (cell)heap->tenured->allot(size));
}

FACTOR_TEST(large_objects_are_allotted_in_tenured_with_cards_marked) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  cell capacity = heap->nursery->size / sizeof(cell);
  factor::array* big = t.vm.allot_array(capacity, tag_fixnum(5));
  CHECK(heap->tenured->contains_p(big));
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
  CHECK_EQ(capacity, array_capacity(big));
  CHECK_EQ(tag_fixnum(5), array_nth(big, capacity - 1));

  cell first = addr_to_card((cell)big - heap->start);
  cell last = addr_to_card((cell)big + big->size() - 1 - heap->start);
  for (cell i = first; i <= last; i++)
    CHECK_EQ((cell)card_mark_mask, (cell)heap->cards[i]);
  CHECK_EQ((cell)0, (cell)heap->cards[last + 1]);

  // A small allocation still goes to the nursery.
  factor::array* small = t.vm.allot_array(1, false_object);
  CHECK(heap->nursery->contains_p(small));
}

FACTOR_TEST(collecting_with_nothing_live_empties_the_young_generations) {
  gc_vm t;
  data_heap* heap = t.vm.data;
  for (int i = 0; i < 100; i++)
    t.vm.allot_array(10, false_object);
  t.vm.primitive_minor_gc();
  CHECK_EQ((cell)0, heap->nursery->occupied_space());
  CHECK_EQ((cell)0, heap->aging->occupied_space());
  t.vm.primitive_full_gc();
  CHECK_EQ((cell)0, heap->tenured->occupied_space());
  CHECK_EQ((cell)1, heap->tenured->free_block_count);
}
