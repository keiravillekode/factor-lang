// Object layouts, arrays, byte arrays, strings, tuples, clone, hashcodes,
// slots and the write barrier, special objects, and become.
#include "test_vm.hpp"

#include <dlfcn.h>

using namespace factor;
using namespace factor::tests;

namespace {

// Card and deck bytes covering the address of `slot`.
card* card_for(factor_vm& vm, void* slot) {
  return vm.data->cards + (addr_to_card((cell)slot) - addr_to_card(vm.data->start));
}

card_deck* deck_for(factor_vm& vm, void* slot) {
  return vm.data->decks + (addr_to_deck((cell)slot) - addr_to_deck(vm.data->start));
}

bool in_tenured(factor_vm& vm, void* obj) {
  return (cell)obj >= vm.data->tenured->start && (cell)obj < vm.data->tenured->end;
}

// An array big enough to bypass the nursery: allot_object sends anything at
// least as large as the nursery to tenured space.
factor::array* allot_tenured_array(factor_vm& vm) {
  cell capacity = vm.data->nursery->size / sizeof(cell);
  factor::array* a = vm.allot_uninitialized_array<factor::array>(capacity);
  memset_cell(a->data(), false_object, capacity * sizeof(cell));
  return a;
}

// A tuple layout with `slots` slots: an array whose first three elements are
// the class, the tagged slot count and the tagged echelon.
tuple_layout* make_layout(factor_vm& vm, cell slots) {
  factor::array* a = vm.allot_array(3, false_object);
  tuple_layout* layout = (tuple_layout*)a;
  layout->klass = false_object;
  layout->size = tag_fixnum(slots);
  layout->echelon = tag_fixnum(1);
  return layout;
}

byte_array* c_string(factor_vm& vm, const char* s) {
  cell len = strlen(s);
  byte_array* ba = vm.allot_byte_array(len + 1);
  memcpy(ba->data<char>(), s, len);
  return ba;
}

} // namespace

// --- layouts.hpp ---------------------------------------------------------

FACTOR_TEST(tag_macros_and_alignment) {
  cell addr = 0x1230;
  CHECK_EQ((cell)ARRAY_TYPE, TAG(addr | ARRAY_TYPE));
  CHECK_EQ(addr, UNTAG(addr | STRING_TYPE));
  CHECK_EQ(addr | TUPLE_TYPE, RETAG(addr | ARRAY_TYPE, TUPLE_TYPE));
  CHECK(immediate_p(tag_fixnum(5)));
  CHECK(immediate_p(false_object));
  CHECK(!immediate_p(addr | ARRAY_TYPE));
  CHECK_EQ((cell)F_TYPE, false_object);
  CHECK_EQ((cell)14, (cell)TYPE_COUNT);

  CHECK_EQ((cell)16, align(1, 16));
  CHECK_EQ((cell)16, align(16, 16));
  CHECK_EQ((cell)32, align(17, 16));
  CHECK_EQ((cell)0, align(0, 16));
  CHECK_EQ((cell)15, alignment_for(1, 16));
  CHECK_EQ((cell)0, alignment_for(32, 16));
  CHECK_EQ((cell)16, data_alignment);
}

FACTOR_TEST(object_header_type_hashcode_and_forwarding) {
  alignas(16) cell buf[4] = {0, 0, 0, 0};
  object* obj = (object*)buf;

  obj->initialize(STRING_TYPE);
  CHECK_EQ((cell)STRING_TYPE, obj->type());
  CHECK_EQ((cell)0, obj->hashcode());
  CHECK(!obj->free_p());
  CHECK(!obj->forwarding_pointer_p());

  obj->set_hashcode(0x1234);
  CHECK_EQ((cell)0x1234, obj->hashcode());
  CHECK_EQ((cell)STRING_TYPE, obj->type());

  // The hashcode occupies bits 6.. of the header; the largest value fits.
  cell max_hash = ((cell)1 << (WORD_SIZE - 6)) - 1;
  obj->set_hashcode(max_hash);
  CHECK_EQ(max_hash, obj->hashcode());
  CHECK_EQ((cell)STRING_TYPE, obj->type());

  alignas(16) cell target[2] = {0, 0};
  obj->forward_to((object*)target);
  CHECK(obj->forwarding_pointer_p());
  CHECK_EQ((cell)target, (cell)obj->forwarding_pointer());

  buf[0] = 1; // free block marker
  CHECK(obj->free_p());
}

FACTOR_TEST(tagged_pointer_helpers) {
  test_vm t;
  factor::array* a = t.vm.allot_array(2, false_object);
  cell tagged = tag<factor::array>(a);
  CHECK_EQ((cell)ARRAY_TYPE, TAG(tagged));
  CHECK_EQ((cell)a, UNTAG(tagged));
  CHECK_EQ((cell)a, (cell)untag<factor::array>(tagged));
  CHECK_EQ(tagged, tag_dynamic(a));
  factor::tagged<factor::array> wrapped(tagged);
  CHECK(wrapped.type_p());
  CHECK_EQ(tagged, wrapped.value());
  CHECK_EQ((cell)a, (cell)wrapped.untagged());
}

FACTOR_TEST(string_and_tuple_size_helpers) {
  test_vm t;
  CHECK_EQ(sizeof(factor::string) + 7, string_size(7));
  factor::string* s = t.vm.allot_string(7, 'a');
  CHECK_EQ((cell)7, string_capacity(s));

  tuple_layout* layout = make_layout(t.vm, 3);
  CHECK_EQ((cell)3, tuple_capacity(layout));
  CHECK_EQ(sizeof(factor::tuple) + 3 * sizeof(cell), factor::tuple_size(layout));
  CHECK_EQ(sizeof(factor::array) + 5 * sizeof(cell), array_size<factor::array>(5));
  CHECK_EQ(sizeof(byte_array) + 5, array_size<byte_array>(5));
}

// --- arrays.cpp ----------------------------------------------------------

FACTOR_TEST(allot_array_fills_every_slot) {
  test_vm t;
  factor::array* a = t.vm.allot_array(5, tag_fixnum(9));
  CHECK_EQ((cell)ARRAY_TYPE, a->type());
  CHECK_EQ((cell)5, array_capacity(a));
  for (cell i = 0; i < 5; i++)
    CHECK_EQ(tag_fixnum(9), array_nth(a, i));
  CHECK(t.vm.nursery.contains_p(a));

  t.vm.set_array_nth(a, 2, tag_fixnum(-1));
  CHECK_EQ(tag_fixnum(-1), array_nth(a, 2));
  CHECK_EQ(tag_fixnum(9), array_nth(a, 1));
}

FACTOR_TEST(array_primitive_takes_capacity_and_fill) {
  test_vm t;
  t.push_fixnum(3);
  t.push(tag_fixnum(42));
  t.vm.primitive_array();
  cell result = t.pop();
  CHECK_EQ((cell)ARRAY_TYPE, TAG(result));
  factor::array* a = untag<factor::array>(result);
  CHECK_EQ((cell)3, array_capacity(a));
  CHECK_EQ(tag_fixnum(42), array_nth(a, 0));
  CHECK_EQ(tag_fixnum(42), array_nth(a, 2));
  CHECK_EQ((cell)0, t.datastack_depth());

  t.push_fixnum(0);
  t.push(false_object);
  t.vm.primitive_array();
  CHECK_EQ((cell)0, array_capacity(untag<factor::array>(t.pop())));
}

FACTOR_TEST(reallot_array_grows_by_copying_and_zero_filling) {
  test_vm t;
  factor::array* a = t.vm.allot_array(2, tag_fixnum(7));
  factor::array* b = t.vm.reallot_array(a, 4);
  CHECK((cell)a != (cell)b);
  CHECK_EQ((cell)4, array_capacity(b));
  CHECK_EQ(tag_fixnum(7), array_nth(b, 0));
  CHECK_EQ(tag_fixnum(7), array_nth(b, 1));
  // New slots are zero-filled, i.e. fixnum 0, not f.
  CHECK_EQ(tag_fixnum(0), array_nth(b, 2));
  CHECK_EQ(tag_fixnum(0), array_nth(b, 3));
  // The original is untouched.
  CHECK_EQ((cell)2, array_capacity(a));
}

FACTOR_TEST(reallot_array_shrinks_nursery_arrays_in_place) {
  test_vm t;
  factor::array* a = t.vm.allot_array(4, tag_fixnum(1));
  CHECK_EQ((cell)a, (cell)t.vm.reallot_array(a, 4));
  factor::array* b = t.vm.reallot_array(a, 2);
  CHECK_EQ((cell)a, (cell)b);
  CHECK_EQ((cell)2, array_capacity(b));
}

FACTOR_TEST(reallot_array_copies_when_shrinking_outside_the_nursery) {
  test_vm t;
  factor::array* big = allot_tenured_array(t.vm);
  CHECK(in_tenured(t.vm, big));
  t.vm.set_array_nth(big, 0, tag_fixnum(5));
  factor::array* small = t.vm.reallot_array(big, 3);
  CHECK((cell)big != (cell)small);
  CHECK(t.vm.nursery.contains_p(small));
  CHECK_EQ((cell)3, array_capacity(small));
  CHECK_EQ(tag_fixnum(5), array_nth(small, 0));
  CHECK_EQ(false_object, array_nth(small, 1));
}

FACTOR_TEST(resize_array_primitive) {
  test_vm t;
  factor::array* a = t.vm.allot_array(1, tag_fixnum(3));
  t.push_fixnum(3);
  t.push(tag<factor::array>(a));
  t.vm.primitive_resize_array();
  factor::array* b = untag<factor::array>(t.pop());
  CHECK_EQ((cell)3, array_capacity(b));
  CHECK_EQ(tag_fixnum(3), array_nth(b, 0));
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(large_arrays_go_to_tenured_space_with_cards_marked) {
  test_vm t;
  factor::array* big = allot_tenured_array(t.vm);
  CHECK(in_tenured(t.vm, big));
  CHECK(!t.vm.nursery.contains_p(big));
  CHECK_EQ((cell)ARRAY_TYPE, big->type());
  // allot_large_object marks every card the object spans so that
  // initialization code may store young pointers without a barrier.
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)*card_for(t.vm, big->data()));
  CHECK_EQ((unsigned)card_mark_mask,
           (unsigned)*card_for(t.vm, big->data() + array_capacity(big) - 1));
}

FACTOR_TEST(growable_array_appends_and_trims) {
  test_vm t;
  growable_array g(&t.vm, 2);
  for (cell i = 0; i < 5; i++)
    g.add(tag_fixnum(i));
  CHECK_EQ((cell)5, g.count);
  CHECK(array_capacity(g.elements.untagged()) >= 5);
  factor::array* more = t.vm.allot_array(2, tag_fixnum(100));
  g.append(more);
  CHECK_EQ((cell)7, g.count);
  g.trim();
  CHECK_EQ((cell)7, array_capacity(g.elements.untagged()));
  CHECK_EQ(tag_fixnum(4), array_nth(g.elements.untagged(), 4));
  CHECK_EQ(tag_fixnum(100), array_nth(g.elements.untagged(), 6));
}

// --- byte_arrays.cpp -----------------------------------------------------

FACTOR_TEST(allot_byte_array_is_zeroed) {
  test_vm t;
  byte_array* ba = t.vm.allot_byte_array(10);
  CHECK_EQ((cell)BYTE_ARRAY_TYPE, ba->type());
  CHECK_EQ((cell)10, array_capacity(ba));
  for (cell i = 0; i < 10; i++)
    CHECK_EQ(0u, (unsigned)ba->data<uint8_t>()[i]);
  CHECK_EQ((cell)ba + sizeof(byte_array), (cell)ba->data<uint8_t>());
}

FACTOR_TEST(byte_array_primitives) {
  test_vm t;
  t.push_fixnum(4);
  t.vm.primitive_byte_array();
  byte_array* ba = untag<byte_array>(t.pop());
  CHECK_EQ((cell)4, array_capacity(ba));
  CHECK_EQ(0u, (unsigned)ba->data<uint8_t>()[3]);

  t.push_fixnum(8);
  t.vm.primitive_uninitialized_byte_array();
  byte_array* u = untag<byte_array>(t.pop());
  CHECK_EQ((cell)8, array_capacity(u));

  memset(ba->data<uint8_t>(), 0xab, 4);
  t.push_fixnum(6);
  t.push(tag<byte_array>(ba));
  t.vm.primitive_resize_byte_array();
  byte_array* grown = untag<byte_array>(t.pop());
  CHECK_EQ((cell)6, array_capacity(grown));
  CHECK_EQ(0xabu, (unsigned)grown->data<uint8_t>()[3]);
  CHECK_EQ(0u, (unsigned)grown->data<uint8_t>()[4]);
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(growable_byte_array_appends) {
  test_vm t;
  growable_byte_array g(&t.vm, 4);
  const char* text = "hello, world";
  g.append_bytes((void*)text, 5);
  g.append_bytes((void*)(text + 5), 7);
  CHECK_EQ((cell)12, g.count);
  byte_array* other = c_string(t.vm, "!!");
  g.append_byte_array(tag<byte_array>(other));
  CHECK_EQ((cell)15, g.count);
  g.trim();
  CHECK_EQ((cell)15, array_capacity(g.elements.untagged()));
  CHECK_EQ(0, memcmp(g.elements->data<char>(), "hello, world!!", 14));
}

// --- strings.cpp ---------------------------------------------------------

FACTOR_TEST(allot_string_with_ascii_fill) {
  test_vm t;
  factor::string* s = t.vm.allot_string(4, 'x');
  CHECK_EQ((cell)STRING_TYPE, s->type());
  CHECK_EQ(tag_fixnum(4), s->length);
  CHECK_EQ(false_object, s->aux);
  CHECK_EQ(false_object, s->hashcode);
  for (cell i = 0; i < 4; i++)
    CHECK_EQ((unsigned)'x', (unsigned)s->data()[i]);
}

FACTOR_TEST(allot_string_with_wide_fill_uses_aux_storage) {
  test_vm t;
  cell ch = 0x3b1; // greek alpha
  factor::string* s = t.vm.allot_string(3, ch);
  CHECK(to_boolean(s->aux));
  byte_array* aux = untag<byte_array>(s->aux);
  CHECK_EQ((cell)6, array_capacity(aux));
  // Low byte: low 7 bits with the high bit set; aux: remaining bits ^ 1.
  CHECK_EQ((unsigned)((ch & 0x7f) | 0x80), (unsigned)s->data()[0]);
  CHECK_EQ((unsigned)((ch >> 7) ^ 1), (unsigned)aux->data<uint16_t>()[0]);
  CHECK_EQ((unsigned)((ch >> 7) ^ 1), (unsigned)aux->data<uint16_t>()[2]);
}

FACTOR_TEST(string_primitive) {
  test_vm t;
  t.push_fixnum(3);
  t.push_fixnum('q');
  t.vm.primitive_string();
  factor::string* s = untag<factor::string>(t.pop());
  CHECK_EQ((cell)3, string_capacity(s));
  CHECK_EQ((unsigned)'q', (unsigned)s->data()[2]);
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(set_string_nth_fast_writes_a_byte) {
  test_vm t;
  factor::string* s = t.vm.allot_string(3, 'a');
  t.push_fixnum('z');
  t.push_fixnum(1);
  t.push(tag<factor::string>(s));
  t.vm.primitive_set_string_nth_fast();
  CHECK_EQ((unsigned)'z', (unsigned)s->data()[1]);
  CHECK_EQ((unsigned)'a', (unsigned)s->data()[0]);
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(reallot_string_shrinks_in_place_and_grows_by_copying) {
  test_vm t;
  factor::string* s = t.vm.allot_string(5, 'b');
  CHECK_EQ((cell)s, (cell)t.vm.reallot_string(s, 3));
  CHECK_EQ((cell)3, string_capacity(s));

  factor::string* grown = t.vm.reallot_string(s, 6);
  CHECK((cell)grown != (cell)s);
  CHECK_EQ((cell)6, string_capacity(grown));
  CHECK_EQ((unsigned)'b', (unsigned)grown->data()[2]);
  CHECK_EQ(0u, (unsigned)grown->data()[3]);
  CHECK_EQ(0u, (unsigned)grown->data()[5]);
  CHECK_EQ(false_object, grown->aux);
}

FACTOR_TEST(reallot_string_carries_aux_storage) {
  test_vm t;
  cell ch = 0x100;
  factor::string* s = t.vm.allot_string(2, ch);
  factor::string* grown = t.vm.reallot_string(s, 4);
  CHECK(to_boolean(grown->aux));
  byte_array* aux = untag<byte_array>(grown->aux);
  CHECK_EQ((cell)8, array_capacity(aux));
  CHECK_EQ((unsigned)((ch >> 7) ^ 1), (unsigned)aux->data<uint16_t>()[1]);
  CHECK_EQ((unsigned)((ch & 0x7f) | 0x80), (unsigned)grown->data()[1]);
  // The new tail is NUL in both planes.
  CHECK_EQ(0u, (unsigned)grown->data()[3]);

  // Shrinking in place trims the aux capacity too.
  factor::string* shrunk = t.vm.reallot_string(grown, 1);
  CHECK_EQ((cell)grown, (cell)shrunk);
  CHECK_EQ((cell)2, array_capacity(untag<byte_array>(shrunk->aux)));
}

FACTOR_TEST(resize_string_primitive) {
  test_vm t;
  factor::string* s = t.vm.allot_string(2, 'c');
  t.push_fixnum(4);
  t.push(tag<factor::string>(s));
  t.vm.primitive_resize_string();
  factor::string* r = untag<factor::string>(t.pop());
  CHECK_EQ((cell)4, string_capacity(r));
  CHECK_EQ((unsigned)'c', (unsigned)r->data()[1]);
  CHECK_EQ((cell)0, t.datastack_depth());
}

// --- tuples.cpp ----------------------------------------------------------

FACTOR_TEST(tuple_primitive_fills_slots_with_f) {
  test_vm t;
  tuple_layout* layout = make_layout(t.vm, 3);
  t.push(tag<factor::array>((factor::array*)layout));
  t.vm.primitive_tuple();
  cell result = t.pop();
  CHECK_EQ((cell)TUPLE_TYPE, TAG(result));
  factor::tuple* tup = untag<factor::tuple>(result);
  CHECK_EQ(tag<factor::array>((factor::array*)layout), tup->layout);
  for (cell i = 0; i < 3; i++)
    CHECK_EQ(false_object, tup->data()[i]);
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(tuple_boa_primitive_takes_slots_from_the_stack) {
  test_vm t;
  tuple_layout* layout = make_layout(t.vm, 2);
  t.push_fixnum(10);
  t.push_fixnum(20);
  t.push(tag<factor::array>((factor::array*)layout));
  t.vm.primitive_tuple_boa();
  factor::tuple* tup = untag<factor::tuple>(t.pop());
  CHECK_EQ(tag_fixnum(10), tup->data()[0]);
  CHECK_EQ(tag_fixnum(20), tup->data()[1]);
  CHECK_EQ((cell)0, t.datastack_depth());

  tuple_layout* empty = make_layout(t.vm, 0);
  t.push(tag<factor::array>((factor::array*)empty));
  t.vm.primitive_tuple_boa();
  CHECK_EQ(sizeof(factor::tuple), untag<factor::tuple>(t.pop())->size());
}

// --- objects.cpp ---------------------------------------------------------

FACTOR_TEST(clone_copies_arrays_independently) {
  test_vm t;
  factor::array* a = t.vm.allot_array(2, tag_fixnum(1));
  a->set_hashcode(77);
  t.push(tag<factor::array>(a));
  t.vm.primitive_clone();
  factor::array* b = untag<factor::array>(t.pop());
  CHECK((cell)a != (cell)b);
  CHECK_EQ((cell)2, array_capacity(b));
  CHECK_EQ(tag_fixnum(1), array_nth(b, 1));
  CHECK_EQ((cell)0, b->hashcode());
  CHECK_EQ((cell)77, a->hashcode());
  t.vm.set_array_nth(b, 0, tag_fixnum(2));
  CHECK_EQ(tag_fixnum(1), array_nth(a, 0));
}

FACTOR_TEST(clone_preserves_type_for_tuples_and_byte_arrays) {
  test_vm t;
  tuple_layout* layout = make_layout(t.vm, 1);
  t.push(tag<factor::array>((factor::array*)layout));
  t.vm.primitive_tuple();
  cell original = t.pop();
  untag<factor::tuple>(original)->data()[0] = tag_fixnum(5);
  t.push(original);
  t.vm.primitive_clone();
  cell copy = t.pop();
  CHECK((cell)copy != (cell)original);
  CHECK_EQ((cell)TUPLE_TYPE, TAG(copy));
  CHECK_EQ(untag<factor::tuple>(original)->layout, untag<factor::tuple>(copy)->layout);
  CHECK_EQ(tag_fixnum(5), untag<factor::tuple>(copy)->data()[0]);

  byte_array* ba = t.vm.allot_byte_array(3);
  ba->data<uint8_t>()[1] = 0x5c;
  t.push(tag<byte_array>(ba));
  t.vm.primitive_clone();
  byte_array* bc = untag<byte_array>(t.pop());
  CHECK_EQ((cell)BYTE_ARRAY_TYPE, bc->type());
  CHECK_EQ(0x5cu, (unsigned)bc->data<uint8_t>()[1]);
}

FACTOR_TEST(clone_leaves_immediates_alone) {
  test_vm t;
  t.push(tag_fixnum(3));
  t.vm.primitive_clone();
  CHECK_EQ(tag_fixnum(3), t.pop());
  t.push(false_object);
  t.vm.primitive_clone();
  CHECK_EQ(false_object, t.pop());
}

FACTOR_TEST(identity_hashcode_is_assigned_once_and_distinct) {
  test_vm t;
  factor::array* a = t.vm.allot_array(1, false_object);
  factor::array* b = t.vm.allot_array(1, false_object);

  t.push(tag<factor::array>(a));
  t.vm.primitive_identity_hashcode();
  CHECK_EQ(tag_fixnum(0), t.pop());

  cell counter = t.vm.object_counter;
  t.push(tag<factor::array>(a));
  t.vm.primitive_compute_identity_hashcode();
  CHECK_EQ(counter + 1, t.vm.object_counter);
  t.push(tag<factor::array>(b));
  t.vm.primitive_compute_identity_hashcode();

  t.push(tag<factor::array>(a));
  t.vm.primitive_identity_hashcode();
  fixnum ha = t.pop_fixnum();
  t.push(tag<factor::array>(a));
  t.vm.primitive_identity_hashcode();
  CHECK_EQ(ha, t.pop_fixnum());
  t.push(tag<factor::array>(b));
  t.vm.primitive_identity_hashcode();
  CHECK(ha != t.pop_fixnum());
  CHECK(ha != 0);
  CHECK_EQ((cell)ARRAY_TYPE, a->type());
}

FACTOR_TEST(size_primitive_matches_object_sizes) {
  test_vm t;
  t.push(tag_fixnum(1));
  t.vm.primitive_size();
  CHECK_EQ(tag_fixnum(0), t.pop());

  factor::array* a = t.vm.allot_array(3, false_object);
  t.push(tag<factor::array>(a));
  t.vm.primitive_size();
  CHECK_EQ(tag_fixnum(align(sizeof(factor::array) + 3 * sizeof(cell), data_alignment)), t.pop());
  CHECK_EQ(align(sizeof(factor::array) + 3 * sizeof(cell), data_alignment), object_size(tag<factor::array>(a)));

  factor::string* s = t.vm.allot_string(5, 'a');
  CHECK_EQ(align(sizeof(factor::string) + 5, data_alignment), s->size());
  byte_array* ba = t.vm.allot_byte_array(1);
  CHECK_EQ(align(sizeof(byte_array) + 1, data_alignment), ba->size());
}

FACTOR_TEST(slots_are_numbered_from_the_header) {
  test_vm t;
  factor::array* a = t.vm.allot_array(2, tag_fixnum(0));
  // slot 0 is the header, slot 1 the capacity, slot 2 the first element.
  CHECK_EQ(a->header, a->slots()[0]);
  CHECK_EQ(tag_fixnum(2), a->slots()[1]);
  t.push(tag_fixnum(99));
  t.push(tag<factor::array>(a));
  t.push_fixnum(3);
  t.vm.primitive_set_slot();
  CHECK_EQ(tag_fixnum(99), array_nth(a, 1));
  CHECK_EQ(tag_fixnum(0), array_nth(a, 0));
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(set_slot_marks_the_card_and_deck) {
  test_vm t;
  factor::array* old = allot_tenured_array(t.vm);
  cell* slot = &old->data()[0];
  *card_for(t.vm, slot) = 0;
  *deck_for(t.vm, slot) = 0;

  factor::array* young = t.vm.allot_array(1, false_object);
  CHECK(t.vm.nursery.contains_p(young));
  t.push(tag<factor::array>(young));
  t.push(tag<factor::array>(old));
  t.push_fixnum(2);
  t.vm.primitive_set_slot();

  CHECK_EQ(tag<factor::array>(young), *slot);
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)*card_for(t.vm, slot));
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)*deck_for(t.vm, slot));
  // A neighbouring card that was never written stays clear.
  cell* far = &old->data()[card_size / sizeof(cell) * 2];
  *card_for(t.vm, far) = 0;
  t.vm.set_array_nth(old, 1, tag_fixnum(4));
  CHECK_EQ(0u, (unsigned)*card_for(t.vm, far));
}

FACTOR_TEST(special_object_primitives_round_trip) {
  test_vm t;
  t.push(tag_fixnum(55));
  t.push_fixnum(OBJ_GLOBAL);
  t.vm.primitive_set_special_object();
  CHECK_EQ(tag_fixnum(55), t.vm.special_objects[OBJ_GLOBAL]);
  t.push_fixnum(OBJ_GLOBAL);
  t.vm.primitive_special_object();
  CHECK_EQ(tag_fixnum(55), t.pop());
  CHECK_EQ((cell)0, t.datastack_depth());
}

FACTOR_TEST(special_object_indices_match_kernel_factor) {
  // Values hard-coded in core/kernel/kernel.factor and used by
  // basis/bootstrap/image/image.factor.
  CHECK_EQ((cell)85, special_object_count);
  CHECK_EQ(3, (int)OBJ_WALKER_HOOK);
  CHECK_EQ(7, (int)OBJ_CELL_SIZE);
  CHECK_EQ(10, (int)OBJ_ARGS);
  CHECK_EQ(11, (int)OBJ_STDIN);
  CHECK_EQ(12, (int)OBJ_STDOUT);
  CHECK_EQ(20, (int)OBJ_STARTUP_QUOT);
  CHECK_EQ(21, (int)OBJ_GLOBAL);
  CHECK_EQ(23, (int)JIT_PROLOG);
  CHECK_EQ(42, (int)JIT_DECLARE_WORD);
  CHECK_EQ(43, (int)C_TO_FACTOR_WORD);
  CHECK_EQ(51, (int)OBJ_SAMPLE_CALLSTACKS);
  CHECK_EQ(52, (int)REDEFINITION_COUNTER);
  CHECK_EQ(53, (int)CALLBACK_STUB);
  CHECK_EQ(54, (int)PIC_LOAD);
  CHECK_EQ(61, (int)PIC_MISS_TAIL_WORD);
  CHECK_EQ(62, (int)MEGA_LOOKUP);
  CHECK_EQ(63, (int)MEGA_LOOKUP_WORD);
  CHECK_EQ(64, (int)MEGA_MISS_WORD);
  CHECK_EQ(65, (int)OBJ_UNDEFINED);
  CHECK_EQ(66, (int)OBJ_STDERR);
  CHECK_EQ(67, (int)OBJ_STAGE2);
  CHECK_EQ(68, (int)OBJ_CURRENT_THREAD);
  CHECK_EQ(72, (int)OBJ_VM_COMPILER);
  CHECK_EQ(73, (int)OBJ_WAITING_CALLBACKS);
  CHECK_EQ(78, (int)OBJ_CANONICAL_TRUE);
  CHECK_EQ(79, (int)OBJ_BIGNUM_ZERO);
  CHECK_EQ(80, (int)OBJ_BIGNUM_POS_ONE);
  CHECK_EQ(81, (int)OBJ_BIGNUM_NEG_ONE);

  // save_special_p keeps the ranges the image needs and drops the ones
  // init_factor fills in at startup.
  CHECK(!save_special_p(OBJ_STDIN));
  CHECK(!save_special_p(OBJ_ARGS));
  CHECK(save_special_p(OBJ_STARTUP_QUOT));
  CHECK(save_special_p(JIT_PROLOG));
  CHECK(save_special_p(LEAF_SIGNAL_HANDLER_WORD));
  CHECK(!save_special_p(WIN_EXCEPTION_HANDLER));
  CHECK(save_special_p(REDEFINITION_COUNTER));
  CHECK(save_special_p(OBJ_UNDEFINED));
  CHECK(!save_special_p(OBJ_STDERR));
  CHECK(save_special_p(OBJ_STAGE2));
  CHECK(!save_special_p(OBJ_CURRENT_THREAD));
  CHECK(save_special_p(OBJ_CANONICAL_TRUE));
  CHECK(save_special_p(OBJ_BIGNUM_NEG_ONE));
  CHECK(!save_special_p(OBJ_BIGNUM_NEG_ONE + 1));
}

FACTOR_TEST(become_rewrites_every_reference) {
  // become runs a minor collection and walks the code and callback heaps,
  // so give the bare VM empty ones.
  test_vm t;
  t.vm.code = new code_heap(1 << 20);
  t.vm.callbacks = new callback_heap(64 * 1024, &t.vm);

  factor::array* old_obj = t.vm.allot_array(1, tag_fixnum(1));
  factor::array* new_obj = t.vm.allot_array(1, tag_fixnum(2));
  factor::array* holder = t.vm.allot_array(1, tag<factor::array>(old_obj));
  t.vm.special_objects[OBJ_GLOBAL] = tag<factor::array>(holder);
  data_root<factor::array> rooted(old_obj, &t.vm);

  t.push(tag<factor::array>(old_obj)); // stays on the stack across become
  factor::array* olds = t.vm.allot_array(1, tag<factor::array>(old_obj));
  factor::array* news = t.vm.allot_array(1, tag<factor::array>(new_obj));
  t.push(tag<factor::array>(olds));
  t.push(tag<factor::array>(news));
  t.vm.primitive_become();

  cell replacement = t.pop();
  CHECK_EQ((cell)0, t.datastack_depth());
  CHECK_EQ((cell)ARRAY_TYPE, TAG(replacement));
  CHECK_EQ(tag_fixnum(2), array_nth(untag<factor::array>(replacement), 0));
  // The collection moved everything out of the nursery.
  CHECK(!t.vm.nursery.contains_p(untag<factor::array>(replacement)));
  factor::array* moved_holder = untag<factor::array>(t.vm.special_objects[OBJ_GLOBAL]);
  CHECK_EQ(replacement, array_nth(moved_holder, 0));
  CHECK_EQ(replacement, rooted.value());
  // Every card is dirty afterwards so the next minor GC revisits old->new links.
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)(*card_for(t.vm, moved_holder->data()) & card_mark_mask));
}
