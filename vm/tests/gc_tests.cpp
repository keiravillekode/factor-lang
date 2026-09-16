// GC data structures: bump allocator, segments, mark bits, free list,
// object start map, card marking and data heap layout.
#include "test_vm.hpp"

using namespace factor;
using namespace factor::tests;

namespace {

// A page-aligned, guard-paged region for allocators that write headers
// into the memory they manage.
struct region {
  segment* seg;
  explicit region(cell size) : seg(new segment(align_page(size), false)) {}
  ~region() { delete seg; }
  cell start() const { return seg->start; }
};

// Give a block the shape of a byte array so object::size() reports
// exactly `block_size` bytes (sizeof(byte_array) == 16).
void shape_as_byte_array(object* obj, cell block_size) {
  obj->initialize(BYTE_ARRAY_TYPE);
  ((byte_array*)obj)->capacity = tag_fixnum(block_size - sizeof(byte_array));
}

} // namespace

// --- bump_allocator ---------------------------------------------------------

FACTOR_TEST(bump_allocator_allots_aligned_and_tracks_space) {
  region r(4096);
  bump_allocator b(4096, r.start());
  CHECK_EQ(r.start(), b.here);
  CHECK_EQ(r.start() + 4096, b.end);
  CHECK_EQ((cell)0, b.occupied_space());
  CHECK_EQ((cell)4096, b.free_space());

  object* a = b.allot(24);
  CHECK_EQ(r.start(), (cell)a);
  // 24 rounds up to the 16-byte data alignment.
  CHECK_EQ(r.start() + 32, b.here);
  object* c = b.allot(16);
  CHECK_EQ(r.start() + 32, (cell)c);
  CHECK_EQ((cell)48, b.occupied_space());
  CHECK_EQ((cell)4096 - 48, b.free_space());

  CHECK(b.contains_p(a));
  CHECK(b.contains_p((object*)(r.start() + 4095)));
  CHECK(!b.contains_p((object*)(r.start() + 4096)));
  CHECK(!b.contains_p((object*)(r.start() - 1)));

  b.flush();
  CHECK_EQ(r.start(), b.here);
  CHECK_EQ((cell)0, b.occupied_space());
}

// --- segment ----------------------------------------------------------------

FACTOR_TEST(segment_has_guard_pages_and_range_predicates) {
  cell page = getpagesize();
  segment seg(4 * page, false);
  CHECK_EQ(4 * page, seg.size);
  CHECK_EQ(seg.start + 4 * page, seg.end);
  CHECK_EQ((cell)0, seg.start % page);

  CHECK(seg.in_segment_p(seg.start));
  CHECK(seg.in_segment_p(seg.end - 1));
  CHECK(!seg.in_segment_p(seg.end));
  CHECK(!seg.in_segment_p(seg.start - 1));

  CHECK(seg.underflow_p(seg.start - 1));
  CHECK(seg.underflow_p(seg.start - page));
  CHECK(!seg.underflow_p(seg.start - page - 1));
  CHECK(!seg.underflow_p(seg.start));

  CHECK(seg.overflow_p(seg.end));
  CHECK(seg.overflow_p(seg.end + page - 1));
  CHECK(!seg.overflow_p(seg.end + page));
  CHECK(!seg.overflow_p(seg.end - 1));

  // The interior is writable end to end.
  *(cell*)seg.start = 1;
  *(cell*)(seg.end - sizeof(cell)) = 2;
  CHECK_EQ((cell)1, *(cell*)seg.start);
  CHECK_EQ((cell)2, *(cell*)(seg.end - sizeof(cell)));

  // Unlocking and relocking the borders must not fail.
  seg.set_border_locked(false);
  seg.set_border_locked(true);
}

FACTOR_TEST(executable_segment_is_writable) {
  cell page = getpagesize();
  segment seg(page, true);
  *(uint8_t*)seg.start = 0xc3;
  CHECK_EQ((unsigned)0xc3, (unsigned)*(uint8_t*)seg.start);
}

// --- mark_bits --------------------------------------------------------------
// mark_bits only touches its own bitmaps, so any base address will do.

FACTOR_TEST(mark_bits_marks_lines_and_finds_neighbours) {
  const cell base = 0x100000;
  const cell size = 64 * 1024;
  mark_bits m(size, base);
  CHECK_EQ(size / data_alignment / mark_bits_granularity, m.bits_size);
  CHECK(!m.marked_p(base));

  // 48 bytes = 3 lines starting at line 0.
  m.set_marked_p(base, 48);
  CHECK(m.marked_p(base));
  CHECK(m.marked_p(base + 16));
  CHECK(m.marked_p(base + 32));
  CHECK(!m.marked_p(base + 48));

  // A range spanning a bitmap word boundary (lines 62..66).
  m.set_marked_p(base + 62 * 16, 5 * 16);
  for (cell line = 62; line < 67; line++)
    CHECK(m.marked_p(base + line * 16));
  CHECK(!m.marked_p(base + 61 * 16));
  CHECK(!m.marked_p(base + 67 * 16));

  CHECK_EQ(base + 48, m.next_unmarked_block_after(base));
  CHECK_EQ(base + 62 * 16, m.next_marked_block_after(base + 48));
  CHECK_EQ((cell)(62 * 16 - 48), m.unmarked_block_size(base + 48));
  // Nothing marked after line 66: the end of the region is returned.
  CHECK_EQ(base + size, m.next_marked_block_after(base + 67 * 16));
  CHECK_EQ(base + 67 * 16, m.next_unmarked_block_after(base + 62 * 16));

  m.clear_mark_bits();
  CHECK(!m.marked_p(base));
  CHECK(!m.marked_p(base + 62 * 16));
  CHECK_EQ(base + size, m.next_marked_block_after(base));
}

FACTOR_TEST(mark_bits_forwarding_counts_marked_lines_before_a_block) {
  const cell base = 0x200000;
  mark_bits m(64 * 1024, base);
  // A: 48 bytes at line 0, hole of 64 bytes, B: 32 bytes at line 7,
  // then a hole crossing a word boundary and C at line 100.
  m.set_marked_p(base, 48);
  m.set_marked_p(base + 112, 32);
  m.set_marked_p(base + 100 * 16, 16);
  m.compute_forwarding();

  CHECK_EQ(base, m.forward_block(base));
  CHECK_EQ(base + 16, m.forward_block(base + 16));
  // B slides down over the 64-byte hole.
  CHECK_EQ(base + 48, m.forward_block(base + 112));
  CHECK_EQ(base + 64, m.forward_block(base + 128));
  // Offsets within a line are preserved.
  CHECK_EQ(base + 48 + 8, m.forward_block(base + 112 + 8));
  // C lands right after B's new position: 3 + 2 marked lines before it.
  CHECK_EQ(base + 5 * 16, m.forward_block(base + 100 * 16));

  m.clear_forwarding();
  CHECK_EQ((cell)0, m.forwarding[m.bits_size - 1]);
}

// --- free_list_allocator ----------------------------------------------------

FACTOR_TEST(free_list_starts_as_one_block_and_promotes_pages_for_small_blocks) {
  region r(64 * 1024);
  const cell size = 64 * 1024;
  free_list_allocator<object> fl(size, r.start());
  CHECK_EQ(r.start(), fl.start);
  CHECK_EQ(size, fl.free_space);
  CHECK_EQ((cell)1, fl.free_block_count);
  CHECK_EQ(size, fl.largest_free_block());
  CHECK_EQ((cell)0, fl.occupied_space());
  CHECK(fl.can_allot_p(1024));
  CHECK(!fl.can_allot_p(size + 16));

  // 24 rounds up to 32. The first small allocation carves an
  // allocation_page_size chunk into 32 pieces and hands out the last one.
  object* a = fl.allot(24);
  CHECK(a != NULL);
  CHECK_EQ(r.start() + allocation_page_size - 32, (cell)a);
  CHECK_EQ(size - 32, fl.free_space);
  CHECK_EQ((cell)32, fl.occupied_space());
  CHECK_EQ((cell)(1 + 31), fl.free_block_count);
  CHECK_EQ(size - allocation_page_size, fl.largest_free_block());

  object* b = fl.allot(32);
  CHECK_EQ(r.start() + allocation_page_size - 64, (cell)b);
  CHECK(fl.contains_p(a));
  CHECK(!fl.contains_p((object*)(r.start() + size)));

  // Freeing returns the bytes and the block is reused first (LIFO).
  shape_as_byte_array(a, 32);
  fl.free(a);
  CHECK(a->free_p());
  CHECK_EQ((cell)32, ((free_heap_block*)a)->size());
  CHECK_EQ(size - 32, fl.free_space);
  CHECK_EQ((cell)a, (cell)fl.allot(32));
}

FACTOR_TEST(free_list_large_blocks_split_from_the_start) {
  region r(64 * 1024);
  const cell size = 64 * 1024;
  free_list_allocator<object> fl(size, r.start());

  // >= free_list_count * 16 bytes goes through the large-block path and
  // splits the single free block from its start.
  object* a = fl.allot(2048);
  CHECK_EQ(r.start(), (cell)a);
  object* b = fl.allot(4096);
  CHECK_EQ(r.start() + 2048, (cell)b);
  CHECK_EQ(size - 2048 - 4096, fl.free_space);
  CHECK_EQ((cell)1, fl.free_block_count);
  CHECK_EQ(size - 2048 - 4096, fl.largest_free_block());

  // Exhaust it: the remainder can be taken exactly, then nothing is left.
  object* c = fl.allot(size - 2048 - 4096);
  CHECK_EQ(r.start() + 2048 + 4096, (cell)c);
  CHECK_EQ((cell)0, fl.free_space);
  CHECK_EQ((cell)0, fl.free_block_count);
  CHECK_EQ((cell)0, fl.largest_free_block());
  CHECK(fl.allot(16) == NULL);
  CHECK(!fl.can_allot_p(16));

  allocator_room room = fl.as_allocator_room();
  CHECK_EQ(size, room.size);
  CHECK_EQ(size, room.occupied_space);
  CHECK_EQ((cell)0, room.total_free);
  CHECK_EQ((cell)0, room.contiguous_free);
  CHECK_EQ((cell)0, room.free_block_count);
}

FACTOR_TEST(free_list_initial_free_list_resets_to_the_tail) {
  region r(16 * 1024);
  free_list_allocator<object> fl(16 * 1024, r.start());
  fl.allot(2048);
  fl.initial_free_list(4096);
  CHECK_EQ((cell)16 * 1024 - 4096, fl.free_space);
  CHECK_EQ((cell)1, fl.free_block_count);
  free_heap_block* tail = (free_heap_block*)(r.start() + 4096);
  CHECK(tail->free_p());
  CHECK_EQ((cell)16 * 1024 - 4096, tail->size());
  CHECK_EQ(r.start() + 4096, (cell)fl.allot(512));

  // Fully occupied: no free block at all.
  fl.initial_free_list(16 * 1024);
  CHECK_EQ((cell)0, fl.free_space);
  CHECK_EQ((cell)0, fl.free_block_count);
}

FACTOR_TEST(free_list_sweep_rebuilds_free_blocks_from_marks_and_coalesces) {
  region r(64 * 1024);
  const cell size = 64 * 1024;
  free_list_allocator<object> fl(size, r.start());
  cell base = r.start();

  // Live objects at base (64 bytes) and base+256 (32 bytes); everything
  // else is garbage, including two separate "objects" that must coalesce.
  fl.state.clear_mark_bits();
  fl.state.set_marked_p(base, 64);
  fl.state.set_marked_p(base + 256, 32);

  std::vector<std::pair<cell, cell> > freed;
  auto record = [&](object* block, cell block_size) {
    freed.push_back(std::make_pair((cell)block, block_size));
  };
  fl.sweep(record);

  CHECK_EQ((size_t)2, freed.size());
  CHECK_EQ(base + 64, freed[0].first);
  CHECK_EQ((cell)(256 - 64), freed[0].second);
  CHECK_EQ(base + 288, freed[1].first);
  CHECK_EQ(size - 288, freed[1].second);
  CHECK_EQ((cell)2, fl.free_block_count);
  CHECK_EQ(size - 96, fl.free_space);
  CHECK(((free_heap_block*)(base + 64))->free_p());
  CHECK_EQ((cell)192, ((free_heap_block*)(base + 64))->size());
  CHECK_EQ(size - 288, fl.largest_free_block());

  // The hole is reused by a later allocation of its exact size.
  CHECK_EQ(base + 64, (cell)fl.allot(192));
}

// --- object_start_map -------------------------------------------------------

FACTOR_TEST(object_start_map_finds_the_object_containing_a_card) {
  const cell base = 0x300000;
  const cell size = 16 * card_size;
  object_start_map m(size, base);

  // Cleared: every card starts inside an object, and card 0 is the start.
  CHECK_EQ(base, m.find_object_containing_card(0));

  m.record_object_start_offset((object*)base);
  m.record_object_start_offset((object*)(base + 3 * card_size + 48));
  // A later object in the same card does not move the recorded start.
  m.record_object_start_offset((object*)(base + 3 * card_size + 96));
  CHECK_EQ((unsigned)0, (unsigned)m.object_start_offsets[0]);
  CHECK_EQ((unsigned)48, (unsigned)m.object_start_offsets[3]);
  CHECK_EQ((unsigned)card_starts_inside_object, (unsigned)m.object_start_offsets[1]);

  // Cards 1..3 are covered by the object starting at base; card 4 (and
  // later ones) by the one starting at card 3 offset 48.
  CHECK_EQ(base, m.find_object_containing_card(1));
  CHECK_EQ(base, m.find_object_containing_card(2));
  CHECK_EQ(base, m.find_object_containing_card(3));
  CHECK_EQ(base + 3 * card_size + 48, m.find_object_containing_card(4));
  CHECK_EQ(base + 3 * card_size + 48, m.find_object_containing_card(9));

  m.clear_object_start_offsets();
  CHECK_EQ((unsigned)card_starts_inside_object, (unsigned)m.object_start_offsets[3]);
}

FACTOR_TEST(object_start_map_update_for_sweep_moves_starts_to_marked_lines) {
  const cell base = 0x400000;
  const cell size = 16 * card_size;
  object_start_map m(size, base);
  mark_bits state(size, base);

  m.record_object_start_offset((object*)base);
  m.record_object_start_offset((object*)(base + 3 * card_size + 48));
  m.record_object_start_offset((object*)(base + 5 * card_size + 16));

  // Only a block at card 3 offset 64 and the object in card 5 survive.
  state.set_marked_p(base + 3 * card_size + 64, 16);
  state.set_marked_p(base + 5 * card_size + 16, 32);
  m.update_for_sweep(&state);

  // Card 0: nothing marked after the old start, so it now starts inside.
  CHECK_EQ((unsigned)card_starts_inside_object, (unsigned)m.object_start_offsets[0]);
  // Card 3: the start moves forward to the first marked line.
  CHECK_EQ((unsigned)64, (unsigned)m.object_start_offsets[3]);
  // Card 5: the recorded start is itself marked, so it stays.
  CHECK_EQ((unsigned)16, (unsigned)m.object_start_offsets[5]);
}

// --- cards and decks --------------------------------------------------------

FACTOR_TEST(card_and_deck_arithmetic) {
  CHECK_EQ((cell)256, card_size);
  CHECK_EQ((cell)(256 * 1024), deck_size);
  CHECK_EQ((cell)1024, cards_per_deck);
  CHECK_EQ((cell)0xc0, card_mark_mask);
  CHECK_EQ((cell)3, addr_to_card(3 * card_size + 5));
  CHECK_EQ((cell)2, addr_to_deck(2 * deck_size + card_size));
}

FACTOR_TEST(write_barrier_marks_the_card_and_deck_of_a_slot) {
  test_vm t;
  data_heap* heap = t.vm.data;
  cell slot = heap->tenured->start + 5 * card_size + 24;
  cell card_index = addr_to_card(slot - heap->start);
  cell deck_index = addr_to_deck(slot - heap->start);
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[card_index]);
  CHECK_EQ((unsigned)0, (unsigned)heap->decks[deck_index]);

  t.vm.write_barrier((cell*)slot);
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)heap->cards[card_index]);
  CHECK_EQ((unsigned)card_mark_mask, (unsigned)heap->decks[deck_index]);
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[card_index + 1]);
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[card_index - 1]);

  // The offsets used by compiled code agree with the table indices.
  CHECK_EQ((cell)&heap->cards[card_index], t.vm.cards_offset + (slot >> card_bits));
  CHECK_EQ((cell)&heap->decks[deck_index], t.vm.decks_offset + (slot >> deck_bits));

  heap->reset_tenured();
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[card_index]);
  CHECK_EQ((unsigned)0, (unsigned)heap->decks[deck_index]);
}

FACTOR_TEST(write_barrier_over_a_range_marks_every_card_it_touches) {
  test_vm t;
  data_heap* heap = t.vm.data;
  // Starts 16 bytes into card 8 and ends 16 bytes into card 11: 4 cards.
  cell addr = heap->tenured->start + 8 * card_size + 16;
  t.vm.write_barrier((object*)addr, 3 * card_size);
  cell first = addr_to_card(addr - heap->start);
  for (cell i = 0; i < 4; i++)
    CHECK_EQ((unsigned)card_mark_mask, (unsigned)heap->cards[first + i]);
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[first - 1]);
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[first + 4]);

  heap->mark_all_cards();
  CHECK_EQ((unsigned)0xff, (unsigned)heap->cards[0]);
  CHECK_EQ((unsigned)0xff, (unsigned)heap->decks[0]);
  heap->reset_tenured();
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[first]);
  // reset_tenured only clears the tenured range.
  cell aging_card = addr_to_card(heap->aging->start - heap->start);
  CHECK_EQ((unsigned)0xff, (unsigned)heap->cards[aging_card]);
}

// --- data_heap --------------------------------------------------------------

FACTOR_TEST(data_heap_rounds_sizes_to_decks_and_lays_out_generations) {
  test_vm t(64 * 1024, 64 * 1024, 1024 * 1024);
  data_heap* heap = t.vm.data;
  CHECK_EQ(deck_size, heap->young_size);
  CHECK_EQ(deck_size, heap->aging_size);
  CHECK_EQ(4 * deck_size, heap->tenured_size);
  CHECK_EQ((cell)0, heap->start % deck_size);

  CHECK_EQ(heap->start, heap->tenured->start);
  CHECK_EQ(heap->tenured->end, heap->aging->start);
  CHECK_EQ(heap->aging->end, heap->aging_semispace->start);
  CHECK_EQ(heap->aging_semispace->end, heap->nursery->start);
  CHECK_EQ(heap->young_size, heap->nursery->size);
  CHECK_EQ((cell)&t.vm.nursery, (cell)heap->nursery);
  CHECK(heap->seg->end - heap->nursery->end <= deck_size);

  cell total = heap->young_size + 2 * heap->aging_size + heap->tenured_size + deck_size;
  CHECK_EQ(total / card_size, (cell)(heap->cards_end - heap->cards));
  CHECK_EQ(total / deck_size, (cell)(heap->decks_end - heap->decks));

  CHECK_EQ(heap->young_size + heap->aging_size, heap->high_water_mark());
  CHECK(!heap->high_fragmentation_p());
  CHECK(!heap->low_memory_p());
}

FACTOR_TEST(data_room_reports_the_generations) {
  test_vm t;
  data_heap_room room = t.vm.data_room();
  data_heap* heap = t.vm.data;
  CHECK_EQ(heap->nursery->size, room.nursery_size);
  CHECK_EQ((cell)0, room.nursery_occupied);
  CHECK_EQ(heap->nursery->size, room.nursery_free);
  CHECK_EQ(heap->aging->size, room.aging_size);
  CHECK_EQ((cell)0, room.aging_occupied);
  CHECK_EQ(heap->tenured->size, room.tenured_size);
  CHECK_EQ((cell)0, room.tenured_occupied);
  CHECK_EQ(heap->tenured->size, room.tenured_total_free);
  CHECK_EQ(heap->tenured->size, room.tenured_contiguous_free);
  CHECK_EQ((cell)1, room.tenured_free_block_count);
  CHECK_EQ((cell)(heap->cards_end - heap->cards), room.cards);

  t.vm.allot_array(10, false_object);
  room = t.vm.data_room();
  CHECK_EQ((cell)96, room.nursery_occupied);
  CHECK_EQ(heap->nursery->size - 96, room.nursery_free);
}

FACTOR_TEST(data_heap_reset_nursery_and_aging) {
  test_vm t;
  data_heap* heap = t.vm.data;
  t.vm.allot_array(2, false_object);
  CHECK(heap->nursery->occupied_space() > 0);
  heap->reset_nursery();
  CHECK_EQ((cell)0, heap->nursery->occupied_space());

  object* obj = heap->aging->allot(32);
  CHECK(obj != NULL);
  cell card = addr_to_card((cell)obj - heap->start);
  heap->cards[card] = card_mark_mask;
  CHECK_EQ((unsigned)0, (unsigned)heap->aging->starts.object_start_offsets[0]);
  heap->reset_aging();
  CHECK_EQ((cell)0, heap->aging->occupied_space());
  CHECK_EQ((unsigned)0, (unsigned)heap->cards[card]);
  CHECK_EQ((unsigned)card_starts_inside_object,
           (unsigned)heap->aging->starts.object_start_offsets[0]);
}

// --- aging_space and tenured_space ------------------------------------------

FACTOR_TEST(aging_space_allots_until_full_and_records_starts) {
  region r(8 * 1024);
  aging_space aging(8 * 1024, r.start());
  CHECK_EQ((cell)0, aging.first_object());

  object* a = aging.allot(48);
  object* b = aging.allot(4096);
  CHECK_EQ(r.start(), (cell)a);
  CHECK_EQ(r.start() + 48, (cell)b);
  CHECK(aging.allot(8 * 1024) == NULL);
  CHECK_EQ(r.start() + 48 + 4096, aging.here);

  CHECK_EQ((unsigned)0, (unsigned)aging.starts.object_start_offsets[0]);
  CHECK_EQ((unsigned)card_starts_inside_object, (unsigned)aging.starts.object_start_offsets[1]);
  CHECK_EQ(r.start(), aging.first_object());

  shape_as_byte_array(a, 48);
  shape_as_byte_array(b, 4096);
  CHECK_EQ((cell)b, aging.next_object_after((cell)a));
  CHECK_EQ((cell)0, aging.next_object_after((cell)b));
}

FACTOR_TEST(tenured_space_iteration_skips_free_blocks) {
  region r(64 * 1024);
  tenured_space tenured(64 * 1024, r.start());
  CHECK_EQ((cell)0, tenured.first_object());

  object* a = tenured.allot(1024);
  object* b = tenured.allot(1024);
  object* c = tenured.allot(1024);
  CHECK_EQ(r.start(), (cell)a);
  CHECK_EQ(r.start() + 1024, (cell)b);
  CHECK_EQ(r.start() + 2048, (cell)c);
  shape_as_byte_array(a, 1024);
  shape_as_byte_array(b, 1024);
  shape_as_byte_array(c, 1024);
  CHECK_EQ((unsigned)0, (unsigned)tenured.starts.object_start_offsets[4]);

  CHECK_EQ((cell)a, tenured.first_object());
  CHECK_EQ((cell)b, tenured.next_object_after((cell)a));
  CHECK_EQ((cell)c, tenured.next_object_after((cell)b));
  // After c comes the trailing free block, so iteration ends.
  CHECK_EQ((cell)0, tenured.next_object_after((cell)c));

  tenured.free(b);
  CHECK_EQ((cell)c, tenured.next_object_after((cell)a));
  tenured.free(a);
  CHECK_EQ((cell)c, tenured.first_object());
}
