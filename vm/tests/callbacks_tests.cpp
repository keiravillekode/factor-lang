// Tests for vm/callbacks.cpp: the callback heap's allocation bookkeeping,
// and stub creation with a synthetic CALLBACK_STUB template on x86-64.
#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

namespace {

const cell heap_size = 64 * 1024;

// Install a callback heap on the VM; ~factor_vm deletes it.
callback_heap* install_callback_heap(factor_vm& vm) {
  vm.callbacks = new callback_heap(heap_size, &vm);
  return vm.callbacks;
}

} // namespace

FACTOR_TEST(callback_heap_starts_empty) {
  test_vm t;
  callback_heap* heap = install_callback_heap(t.vm);
  CHECK_EQ(heap_size, heap->seg->size);
  CHECK_EQ(&t.vm, heap->parent);
  allocator_room room = heap->allocator->as_allocator_room();
  CHECK_EQ(heap_size, room.size);
  CHECK_EQ((cell)0, room.occupied_space);
  CHECK_EQ(heap_size, room.total_free);
  CHECK_EQ(heap_size, room.contiguous_free);
  CHECK_EQ((cell)1, room.free_block_count);
}

FACTOR_TEST(callback_heap_allot_and_free_reuse_blocks) {
  test_vm t;
  callback_heap* heap = install_callback_heap(t.vm);
  free_list_allocator<code_block>* a = heap->allocator;

  code_block* first = a->allot(64);
  CHECK(first != NULL);
  CHECK(a->contains_p(first));
  CHECK(heap->seg->in_segment_p((cell)first));
  code_block* second = a->allot(64);
  CHECK(second != NULL);
  CHECK(second != first);
  CHECK_EQ((cell)128, a->occupied_space());

  a->free(first);
  CHECK_EQ((cell)64, a->occupied_space());
  // The freed block is handed out again.
  code_block* third = a->allot(64);
  CHECK_EQ(first, third);
  CHECK_EQ((cell)128, a->occupied_space());
}

FACTOR_TEST(callback_room_primitive_reports_the_allocator) {
  test_vm t;
  callback_heap* heap = install_callback_heap(t.vm);
  heap->allocator->allot(256);
  cell depth = t.datastack_depth();
  t.vm.primitive_callback_room();
  CHECK_EQ(depth + 1, t.datastack_depth());
  cell ba = t.pop();
  CHECK_EQ((cell)BYTE_ARRAY_TYPE, TAG(ba));
  CHECK_EQ(sizeof(allocator_room), array_capacity(untag<byte_array>(ba)));
  allocator_room* room = untag<byte_array>(ba)->data<allocator_room>();
  CHECK_EQ(heap_size, room->size);
  CHECK_EQ((cell)256, room->occupied_space);
  CHECK_EQ(heap_size - 256, room->total_free);
}

#if defined(FACTOR_AMD64)

namespace {

// A CALLBACK_STUB template: 32 bytes of "code" holding four absolute cells,
// one per relocation the x86-64 stub expects (vm, entry point, vm, return
// rewind). Each relocation's offset is the end of its cell.
void install_stub_template(factor_vm& vm) {
  byte_array* relocs = vm.allot_byte_array(4 * sizeof(relocation_entry));
  relocation_entry* r = relocs->data<relocation_entry>();
  r[0] = relocation_entry(RT_VM, RC_ABSOLUTE_CELL, 8);
  r[1] = relocation_entry(RT_ENTRY_POINT, RC_ABSOLUTE_CELL, 16);
  r[2] = relocation_entry(RT_VM, RC_ABSOLUTE_CELL, 24);
  r[3] = relocation_entry(RT_UNTAGGED, RC_ABSOLUTE_CELL, 32);
  byte_array* code = vm.allot_byte_array(32);
  memset(code->data<char>(), 0, 32);
  factor::array* tmpl = vm.allot_array(2, false_object);
  vm.set_array_nth(tmpl, 0, tag<byte_array>(relocs));
  vm.set_array_nth(tmpl, 1, tag<byte_array>(code));
  vm.special_objects[CALLBACK_STUB] = tag<factor::array>(tmpl);
}

cell make_owner_word(factor_vm& vm, cell entry_point) {
  word* w = vm.allot<word>(sizeof(word));
  w->hashcode = tag_fixnum(0);
  w->name = false_object;
  w->vocabulary = false_object;
  w->def = false_object;
  w->props = false_object;
  w->pic_def = false_object;
  w->pic_tail_def = false_object;
  w->subprimitive = false_object;
  w->entry_point = entry_point;
  return tag<word>(w);
}

} // namespace

FACTOR_TEST(callback_heap_add_fills_the_stub_operands) {
  test_vm t;
  factor_vm& vm = t.vm;
  callback_heap* heap = install_callback_heap(vm);
  install_stub_template(vm);
  cell owner = make_owner_word(vm, 0x1234);

  code_block* stub = heap->add(owner, 16);
  CHECK(heap->allocator->contains_p(stub));
  CHECK_EQ(owner, stub->owner);
  CHECK_EQ(false_object, stub->parameters);
  CHECK_EQ(false_object, stub->relocation);
  cell* cells = (cell*)stub->entry_point();
  CHECK_EQ((cell)&vm, cells[0]);
  CHECK_EQ((cell)0x1234, cells[1]);
  CHECK_EQ((cell)&vm, cells[2]);
  CHECK_EQ((cell)16, cells[3]);

  // update() re-patches the entry point when the owner is recompiled.
  untag<word>(owner)->entry_point = 0x5678;
  heap->update(stub);
  CHECK_EQ((cell)0x5678, cells[1]);
  CHECK_EQ((cell)&vm, cells[0]);
}

FACTOR_TEST(callback_and_free_callback_primitives) {
  test_vm t;
  factor_vm& vm = t.vm;
  callback_heap* heap = install_callback_heap(vm);
  install_stub_template(vm);
  cell owner = make_owner_word(vm, 0x1234);

  cell depth = t.datastack_depth();
  t.push(owner);
  t.push_fixnum(8);
  vm.primitive_callback();
  CHECK_EQ(depth + 1, t.datastack_depth());
  cell func = t.pop();
  CHECK_EQ((cell)ALIEN_TYPE, TAG(func));
  cell entry = untag<alien>(func)->address;
  CHECK(heap->seg->in_segment_p(entry));
  code_block* stub = (code_block*)entry - 1;
  CHECK_EQ(owner, stub->owner);
  CHECK_EQ((cell)8, ((cell*)entry)[3]);
  cell occupied = heap->allocator->occupied_space();
  CHECK(occupied > 0);

  t.push(func);
  vm.primitive_free_callback();
  CHECK_EQ(depth, t.datastack_depth());
  CHECK_EQ((cell)0, heap->allocator->occupied_space());
  CHECK((cell)occupied > 0);
}

#endif
