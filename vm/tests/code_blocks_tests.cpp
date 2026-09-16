// Tests for vm/code_blocks.cpp: header accessors, relocation table walks,
// label fixups and dlsym resolution over blocks that are never executed.
#include "test_vm.hpp"

#include <cstdlib>
#include <cstring>

using namespace factor;
using namespace factor::tests;

namespace {

struct fake_code_block {
  cell* buf;
  cell total;

  explicit fake_code_block(cell code_bytes = 64, code_block_type type = CODE_BLOCK_OPTIMIZED)
      : buf(nullptr), total(sizeof(code_block) + code_bytes) {
    void* mem = nullptr;
    if (posix_memalign(&mem, data_alignment, total) != 0)
      throw std::runtime_error("posix_memalign failed");
    buf = (cell*)mem;
    memset(buf, 0, total);
    block()->header = (total & 0xFFFFF8) | ((cell)type << 1);
    block()->owner = false_object;
    block()->parameters = false_object;
    block()->relocation = false_object;
  }
  ~fake_code_block() { free(buf); }
  code_block* block() const { return (code_block*)buf; }
};

byte_array* relocation_table(test_vm& t, const std::vector<relocation_entry>& entries) {
  byte_array* rels = t.vm.allot_byte_array(entries.size() * sizeof(relocation_entry));
  for (size_t i = 0; i < entries.size(); i++)
    rels->data<relocation_entry>()[i] = entries[i];
  return rels;
}

byte_array* c_string(test_vm& t, const char* s) {
  byte_array* ba = t.vm.allot_byte_array(strlen(s) + 1);
  memcpy(ba->data<char>(), s, strlen(s) + 1);
  return ba;
}

} // namespace

FACTOR_TEST(code_block_header_encodes_size_type_and_frame) {
  fake_code_block fcb(64, CODE_BLOCK_UNOPTIMIZED);
  code_block* blk = fcb.block();
  CHECK(!blk->free_p());
  CHECK_EQ((int)CODE_BLOCK_UNOPTIMIZED, (int)blk->type());
  CHECK_EQ(fcb.total, blk->size());
  CHECK_EQ((cell)0, blk->stack_frame_size());
  CHECK(!blk->pic_p());

  blk->set_type(CODE_BLOCK_PIC);
  CHECK(blk->pic_p());
  CHECK_EQ(fcb.total, blk->size());

  blk->set_type(CODE_BLOCK_OPTIMIZED);
  blk->set_stack_frame_size(0x40);
  CHECK_EQ((cell)0x40, blk->stack_frame_size());
  CHECK_EQ(fcb.total, blk->size());
  blk->set_stack_frame_size(0xFF0);
  CHECK_EQ((cell)0xFF0, blk->stack_frame_size());
  blk->set_stack_frame_size(0);
  CHECK_EQ((cell)0, blk->stack_frame_size());

  // Entry point and offsets.
  CHECK_EQ((cell)(blk + 1), blk->entry_point());
  CHECK_EQ((cell)24, blk->offset(blk->entry_point() + 24));
  CHECK_EQ(blk->entry_point() + 24, blk->address_for_offset(24));
  CHECK_EQ((cell)((uint8_t*)blk + fcb.total - sizeof(gc_info)), (cell)blk->block_gc_info());
}

FACTOR_TEST(stack_frame_size_for_address_treats_entry_and_leaves_as_leaf_frames) {
  fake_code_block fcb;
  code_block* blk = fcb.block();
  blk->set_stack_frame_size(0x30);
  CHECK_EQ((cell)LEAF_FRAME_SIZE, blk->stack_frame_size_for_address(blk->entry_point()));
  CHECK_EQ((cell)0x30, blk->stack_frame_size_for_address(blk->entry_point() + 8));
  blk->set_stack_frame_size(0);
  CHECK_EQ((cell)LEAF_FRAME_SIZE, blk->stack_frame_size_for_address(blk->entry_point() + 8));
}

FACTOR_TEST(free_code_block_header_uses_the_whole_size_field) {
  fake_code_block fcb;
  code_block* blk = fcb.block();
  blk->header = ((cell)0x1234560 & ~(cell)7) | 1;
  CHECK(blk->free_p());
  CHECK_EQ((cell)0x1234560, blk->size());
  CHECK_EQ((cell)0, blk->stack_frame_size());
}

FACTOR_TEST(each_instruction_operand_walks_the_table_and_counts_parameters) {
  test_vm t;
  fake_code_block fcb;
  std::vector<relocation_entry> entries = {
      relocation_entry(RT_DLSYM, RC_ABSOLUTE_CELL, 8),   // two parameters
      relocation_entry(RT_LITERAL, RC_ABSOLUTE_CELL, 16), // none
      relocation_entry(RT_VM, RC_ABSOLUTE_CELL, 24),      // one
      relocation_entry(RT_HERE, RC_RELATIVE, 32),         // none
  };
  fcb.block()->relocation = tag<byte_array>(relocation_table(t, entries));

  std::vector<instruction_operand> seen;
  auto collect = [&](instruction_operand op) { seen.push_back(op); };
  fcb.block()->each_instruction_operand(collect);

  CHECK_EQ((size_t)4, seen.size());
  cell expected_index[] = {0, 2, 2, 3};
  for (size_t i = 0; i < seen.size(); i++) {
    CHECK_EQ(entries[i].value, seen[i].rel.value);
    CHECK_EQ(expected_index[i], seen[i].index);
    CHECK_EQ(fcb.block()->entry_point() + entries[i].offset(), seen[i].pointer);
    CHECK_EQ(fcb.block(), seen[i].compiled);
  }

  // No relocation table: nothing is visited.
  fcb.block()->relocation = false_object;
  seen.clear();
  fcb.block()->each_instruction_operand(collect);
  CHECK_EQ((size_t)0, seen.size());
}

FACTOR_TEST(fixup_labels_stores_targets_relative_to_the_entry_point) {
  test_vm t;
  fake_code_block fcb(128);
  code_block* blk = fcb.block();
  cell entry = blk->entry_point();

  // Triples of (class, operand offset, target offset), all tagged fixnums.
  factor::array* labels = t.vm.allot_array(9, false_object);
  cell triples[][3] = {
      {RC_RELATIVE, 16, 64},
      {RC_ABSOLUTE_CELL, 40, 8},
      {RC_RELATIVE, 56, 0},
  };
  for (int i = 0; i < 3; i++)
    for (int j = 0; j < 3; j++)
      t.vm.set_array_nth(labels, i * 3 + j, tag_fixnum(triples[i][j]));

  t.vm.fixup_labels(labels, blk);

  CHECK_EQ((int32_t)(64 - 16), *(int32_t*)(entry + 16 - 4));
  CHECK_EQ(entry + 8, *(cell*)(entry + 40 - 8));
  CHECK_EQ((int32_t)(0 - 56), *(int32_t*)(entry + 56 - 4));

  // Reading them back through instruction operands gives absolute targets.
  instruction_operand rel(relocation_entry(RT_HERE, RC_RELATIVE, 16), blk, 0);
  CHECK_EQ((fixnum)(entry + 64), rel.load_value(rel.pointer));
  instruction_operand abs(relocation_entry(RT_HERE, RC_ABSOLUTE_CELL, 40), blk, 0);
  CHECK_EQ((fixnum)(entry + 8), abs.load_value(0));

  // An empty labels array is a no-op.
  factor::array* none = t.vm.allot_array(0, false_object);
  t.vm.fixup_labels(none, blk);
  CHECK_EQ((int32_t)(64 - 16), *(int32_t*)(entry + 16 - 4));
}

FACTOR_TEST(owner_quot_unwraps_words_for_unoptimized_blocks_only) {
  test_vm t;
  fake_code_block unopt(64, CODE_BLOCK_UNOPTIMIZED);
  fake_code_block opt(64, CODE_BLOCK_OPTIMIZED);
  fake_code_block pic(64, CODE_BLOCK_PIC);

  // A word whose definition is a distinguishable fixnum-tagged sentinel.
  word* w = t.vm.allot<word>(sizeof(word));
  memset((void*)((cell*)w + 1), 0, sizeof(word) - sizeof(cell));
  w->def = tag_fixnum(77);
  cell tagged_word = tag<word>(w);

  unopt.block()->owner = tagged_word;
  CHECK_EQ(tag_fixnum(77), unopt.block()->owner_quot());
  pic.block()->owner = tagged_word;
  CHECK_EQ(tag_fixnum(77), pic.block()->owner_quot());
  opt.block()->owner = tagged_word;
  CHECK_EQ(tagged_word, opt.block()->owner_quot());

  unopt.block()->owner = tag_fixnum(5);
  CHECK_EQ(tag_fixnum(5), unopt.block()->owner_quot());
  unopt.block()->owner = false_object;
  CHECK_EQ(false_object, unopt.block()->owner_quot());
}

FACTOR_TEST(scan_is_minus_one_unless_the_owner_is_an_unoptimized_quotation) {
  test_vm t;
  fake_code_block opt(64, CODE_BLOCK_OPTIMIZED);
  CHECK_EQ(tag_fixnum(-1), opt.block()->scan(&t.vm, opt.block()->entry_point()));

  fake_code_block unopt(64, CODE_BLOCK_UNOPTIMIZED);
  unopt.block()->owner = tag_fixnum(3);
  CHECK_EQ(tag_fixnum(-1), unopt.block()->scan(&t.vm, unopt.block()->entry_point()));
  unopt.block()->owner = false_object;
  CHECK_EQ(tag_fixnum(-1), unopt.block()->scan(&t.vm, unopt.block()->entry_point()));
}

FACTOR_TEST(compute_dlsym_address_resolves_libc_symbols_and_caches_them) {
  test_vm t;
  factor::array* params = t.vm.allot_array(2, false_object);
  t.vm.set_array_nth(params, 0, tag<byte_array>(c_string(t, "strlen")));
  t.vm.set_array_nth(params, 1, false_object); // f = the global namespace

  cell addr = t.vm.compute_dlsym_address(params, 0, false);
  CHECK(addr != 0);
  CHECK(addr != (cell)factor::undefined_symbol);
  typedef size_t (*strlen_fn)(const char*);
  CHECK_EQ((size_t)5, ((strlen_fn)addr)("hello"));

  // Second lookup is served from the cache with the same answer.
  CHECK_EQ((size_t)1, t.vm.dlsym_cache.size());
  CHECK_EQ(addr, t.vm.compute_dlsym_address(params, 0, false));
  CHECK_EQ((size_t)1, t.vm.dlsym_cache.size());

  // An unknown symbol resolves to the undefined_symbol trampoline and is
  // not cached.
  t.vm.set_array_nth(params, 0, tag<byte_array>(c_string(t, "factor_no_such_symbol_xyz")));
  CHECK_EQ((cell)factor::undefined_symbol, t.vm.compute_dlsym_address(params, 0, false));
  CHECK_EQ((size_t)1, t.vm.dlsym_cache.size());

  // A library that failed to open also yields undefined_symbol.
  dll* d = t.vm.allot<dll>(sizeof(dll));
  d->path = false_object;
  d->handle = NULL;
  t.vm.set_array_nth(params, 0, tag<byte_array>(c_string(t, "strlen")));
  t.vm.set_array_nth(params, 1, tag<dll>(d));
  CHECK_EQ((cell)factor::undefined_symbol, t.vm.compute_dlsym_address(params, 0, false));
}
