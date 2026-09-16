// Tests for vm/instruction_operands.cpp: relocation entry encoding and the
// per-class load/store of instruction operands over a code block laid out in
// ordinary aligned memory (nothing is ever executed).
#include "test_vm.hpp"

#include <cstdlib>
#include <cstring>

using namespace factor;
using namespace factor::tests;

namespace {

// A code block header followed by `code_cells` cells of zeroed "code".
struct fake_code_block {
  cell* buf;
  cell code_bytes;

  explicit fake_code_block(cell code_cells = 8, code_block_type type = CODE_BLOCK_OPTIMIZED)
      : buf(nullptr), code_bytes(code_cells * sizeof(cell)) {
    cell total = sizeof(code_block) + code_bytes;
    void* mem = nullptr;
    if (posix_memalign(&mem, data_alignment, total) != 0)
      throw std::runtime_error("posix_memalign failed");
    buf = (cell*)mem;
    memset(buf, 0, total);
    code_block* blk = block();
    // bits 3-23: size, bits 1-2: type, bit 0: free
    blk->header = (total & 0xFFFFF8) | ((cell)type << 1);
    blk->owner = false_object;
    blk->parameters = false_object;
    blk->relocation = false_object;
  }

  ~fake_code_block() { free(buf); }

  code_block* block() const { return (code_block*)buf; }
  cell entry_point() const { return block()->entry_point(); }

  // The instruction word that an operand at code offset `offset` patches.
  uint32_t& word_at(cell offset) const {
    return *(uint32_t*)(entry_point() + offset - sizeof(uint32_t));
  }
};

instruction_operand operand(const fake_code_block& fcb, relocation_class klass, cell offset,
                            relocation_type type = RT_HERE) {
  return instruction_operand(relocation_entry(type, klass, offset), fcb.block(), 0);
}

} // namespace

FACTOR_TEST(relocation_entry_packs_type_class_and_offset) {
  relocation_type types[] = {RT_DLSYM, RT_ENTRY_POINT, RT_ENTRY_POINT_PIC, RT_ENTRY_POINT_PIC_TAIL,
                             RT_HERE, RT_THIS, RT_LITERAL, RT_UNTAGGED, RT_MEGAMORPHIC_CACHE_HITS,
                             RT_VM, RT_CARDS_OFFSET, RT_DECKS_OFFSET, RT_TRAMPOLINE, RT_TRAMPOLINE2,
                             RT_INLINE_CACHE_MISS, RT_SAFEPOINT};
  relocation_class classes[] = {RC_ABSOLUTE_CELL, RC_ABSOLUTE, RC_RELATIVE, RC_RELATIVE_ARM_B,
                                RC_RELATIVE_ARM_B_COND_LDR, RC_ABSOLUTE_ARM_LDUR, RC_ABSOLUTE_ARM_CMP,
                                RC_ABSOLUTE_2, RC_ABSOLUTE_1};
  cell offsets[] = {0, 1, 8, 0x1234, 0x00ffffff};
  for (relocation_type t : types)
    for (relocation_class k : classes)
      for (cell o : offsets) {
        relocation_entry e(t, k, o);
        CHECK_EQ((int)t, (int)e.type());
        CHECK_EQ((int)k, (int)e.klass());
        CHECK_EQ(o, e.offset());
        // Round trip through the raw 32-bit value too.
        relocation_entry raw(e.value);
        CHECK_EQ(e.value, raw.value);
        CHECK_EQ((int)t, (int)raw.type());
      }
  // The enumerators must fit their 4-bit fields.
  CHECK(RT_SAFEPOINT <= 15);
  CHECK(RC_ABSOLUTE_1 <= 15);
  CHECK_EQ(10, (int)RC_ABSOLUTE_2);
  CHECK_EQ(11, (int)RC_ABSOLUTE_1);
}

FACTOR_TEST(relocation_entry_number_of_parameters) {
  CHECK_EQ(2, relocation_entry(RT_DLSYM, RC_ABSOLUTE_CELL, 0).number_of_parameters());
  CHECK_EQ(1, relocation_entry(RT_VM, RC_ABSOLUTE_CELL, 0).number_of_parameters());
  relocation_type zero[] = {RT_ENTRY_POINT, RT_ENTRY_POINT_PIC, RT_ENTRY_POINT_PIC_TAIL, RT_HERE,
                            RT_THIS, RT_LITERAL, RT_UNTAGGED, RT_MEGAMORPHIC_CACHE_HITS,
                            RT_CARDS_OFFSET, RT_DECKS_OFFSET, RT_TRAMPOLINE, RT_TRAMPOLINE2,
                            RT_INLINE_CACHE_MISS, RT_SAFEPOINT};
  for (relocation_type t : zero)
    CHECK_EQ(0, relocation_entry(t, RC_ABSOLUTE_CELL, 0).number_of_parameters());
}

FACTOR_TEST(instruction_operand_pointer_is_entry_point_plus_offset) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_ABSOLUTE_CELL, 24, RT_LITERAL);
  CHECK_EQ(fcb.entry_point() + 24, op.pointer);
  CHECK_EQ((cell)0, op.index);
  CHECK_EQ(fcb.block(), op.compiled);
  CHECK_EQ((int)RT_LITERAL, (int)op.rel.type());
}

FACTOR_TEST(absolute_cell_operand_round_trips_a_full_cell) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_ABSOLUTE_CELL, 16);
  cell values[] = {0, 1, 0x123456789abcdef0ULL, (cell)-1, (cell)-0x10};
  for (cell v : values) {
    op.store_value((fixnum)v);
    CHECK_EQ((fixnum)v, op.load_value(0));
    CHECK_EQ(v, *(cell*)(fcb.entry_point() + 16 - sizeof(cell)));
  }
}

FACTOR_TEST(absolute_operands_truncate_to_their_width) {
  fake_code_block fcb;
  // Poison the surrounding bytes so we can see nothing else is touched.
  memset((void*)fcb.entry_point(), 0xAB, fcb.code_bytes);

  instruction_operand op4 = operand(fcb, RC_ABSOLUTE, 16);
  op4.store_value((fixnum)0x1122334455667788ULL);
  CHECK_EQ((fixnum)0x55667788, op4.load_value(0));
  CHECK_EQ((cell)0xABABABAB, (cell)*(uint32_t*)(fcb.entry_point() + 8));
  CHECK_EQ((cell)0xABABABAB, (cell)*(uint32_t*)(fcb.entry_point() + 16));

  instruction_operand op2 = operand(fcb, RC_ABSOLUTE_2, 32);
  op2.store_value((fixnum)0x12345678);
  CHECK_EQ((fixnum)0x5678, op2.load_value(0));
  CHECK_EQ((cell)0xABAB, (cell)*(uint16_t*)(fcb.entry_point() + 28));

  instruction_operand op1 = operand(fcb, RC_ABSOLUTE_1, 40);
  op1.store_value((fixnum)0x1234);
  CHECK_EQ((fixnum)0x34, op1.load_value(0));
  CHECK_EQ((cell)0xAB, (cell)*(uint8_t*)(fcb.entry_point() + 38));
  // Loads are zero-extended, never sign-extended.
  op1.store_value((fixnum)0xFF);
  CHECK_EQ((fixnum)0xFF, op1.load_value(0));
}

FACTOR_TEST(relative_operand_stores_displacement_from_the_operand_end) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_RELATIVE, 16);
  cell pointer = op.pointer;
  fixnum displacements[] = {0, 4, -4, 0x100, -0x100, 0x7fffffff, -0x80000000LL};
  for (fixnum d : displacements) {
    fixnum target = (fixnum)pointer + d;
    op.store_value(target);
    CHECK_EQ((fixnum)(int32_t)d, (fixnum)*(int32_t*)(pointer - 4));
    // Loading relative to the same pointer gives the target back.
    CHECK_EQ(target, op.load_value(pointer));
    // Relative to another base, the displacement is re-applied there.
    CHECK_EQ((fixnum)0x1000 + d, op.load_value(0x1000));
  }
}

FACTOR_TEST(load_code_block_recovers_the_block_before_an_entry_point) {
  fake_code_block fcb;
  fake_code_block target;
  instruction_operand op = operand(fcb, RC_ABSOLUTE_CELL, 16, RT_ENTRY_POINT);
  op.store_value((fixnum)target.entry_point());
  CHECK_EQ(target.block(), op.load_code_block());

  instruction_operand rel = operand(fcb, RC_RELATIVE, 32, RT_ENTRY_POINT);
  rel.store_value((fixnum)target.entry_point());
  CHECK_EQ(target.block(), rel.load_code_block());
}

FACTOR_TEST(masked_load_and_store_sign_extend_and_scale) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_ABSOLUTE_CELL, 8);
  uint32_t& word = fcb.word_at(8);

  // A 19-bit field at bits 5..23 (the B.cond/LDR imm19), scaled by 4.
  word = 0xFF00001F; // opcode bits outside the field
  op.store_value_masked(4 * 3, rel_arm_b_cond_ldr_mask, 5, 2);
  CHECK_EQ((cell)(0xFF00001F | (3u << 5)), (cell)word);
  CHECK_EQ((fixnum)12, op.load_value_masked(23, 5, 2));

  op.store_value_masked(-4, rel_arm_b_cond_ldr_mask, 5, 2);
  CHECK_EQ((cell)(0xFF00001F | rel_arm_b_cond_ldr_mask), (cell)word);
  CHECK_EQ((fixnum)-4, op.load_value_masked(23, 5, 2));

  // Extremes of the field: (2^18 - 1) * 4 and -2^18 * 4.
  op.store_value_masked(0x3FFFF * 4, rel_arm_b_cond_ldr_mask, 5, 2);
  CHECK_EQ((fixnum)(0x3FFFF * 4), op.load_value_masked(23, 5, 2));
  op.store_value_masked(-0x40000 * 4, rel_arm_b_cond_ldr_mask, 5, 2);
  CHECK_EQ((fixnum)(-0x40000 * 4), op.load_value_masked(23, 5, 2));
  CHECK_EQ((cell)0xFF00001F, (cell)(word & ~rel_arm_b_cond_ldr_mask));

  // Scaling drops low bits on store (the caller asserts alignment).
  op.store_value_masked(4 * 5 + 3, rel_arm_b_cond_ldr_mask, 5, 2);
  CHECK_EQ((fixnum)20, op.load_value_masked(23, 5, 2));

  // A 9-bit unscaled field at bits 12..20 (LDUR imm9).
  word = 0;
  op.store_value_masked(-256, rel_arm_ldur_mask, 12, 0);
  CHECK_EQ((fixnum)-256, op.load_value_masked(20, 12, 0));
  CHECK_EQ((cell)(0x100u << 12), (cell)word);
  op.store_value_masked(255, rel_arm_ldur_mask, 12, 0);
  CHECK_EQ((fixnum)255, op.load_value_masked(20, 12, 0));
}

FACTOR_TEST(arm_b_operand_round_trips_imm26_at_its_limits) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_RELATIVE_ARM_B, 8, RT_ENTRY_POINT);
  uint32_t& word = fcb.word_at(8);
  cell pointer = op.pointer;
  // The displacement is measured from the instruction start (pointer - 4);
  // the field holds (target - pointer + 4) / 4 and spans +-128MB.
  fixnum displacements[] = {0, 4, -4, 0x1000, -0x1000, 0x7FFFFF8, -0x8000004};
  for (fixnum d : displacements) {
    word = 0x94000000; // BL with a zero immediate
    fixnum target = (fixnum)pointer + d;
    op.store_value(target);
    CHECK_EQ((cell)0x94000000, (cell)(word & ~rel_arm_b_mask));
    CHECK_EQ((cell)(((d + 4) >> 2) & rel_arm_b_mask), (cell)(word & rel_arm_b_mask));
    CHECK_EQ(target, op.load_value(pointer));
    CHECK_EQ(target - 0x40, op.load_value(pointer - 0x40));
  }
}

FACTOR_TEST(arm_b_cond_ldr_operand_round_trips_imm19_at_its_limits) {
  fake_code_block fcb;
  instruction_operand op = operand(fcb, RC_RELATIVE_ARM_B_COND_LDR, 8);
  uint32_t& word = fcb.word_at(8);
  cell pointer = op.pointer;
  // imm19 << 2 spans -0x100000 .. 0xFFFFC from the instruction start.
  fixnum displacements[] = {0, 4, -4, 0x1000, -0x1000, 0xFFFF8, -0x100004};
  for (fixnum d : displacements) {
    word = 0x54000001; // B.NE with a zero immediate
    fixnum target = (fixnum)pointer + d;
    op.store_value(target);
    CHECK_EQ((cell)0x54000001, (cell)(word & ~rel_arm_b_cond_ldr_mask));
    CHECK_EQ((cell)((((d + 4) >> 2) << 5) & rel_arm_b_cond_ldr_mask),
             (cell)(word & rel_arm_b_cond_ldr_mask));
    CHECK_EQ(target, op.load_value(pointer));
  }
}

FACTOR_TEST(arm_ldur_and_cmp_operands_round_trip_their_immediates) {
  fake_code_block fcb;
  uint32_t& word = fcb.word_at(8);

  instruction_operand ldur = operand(fcb, RC_ABSOLUTE_ARM_LDUR, 8, RT_UNTAGGED);
  fixnum imm9[] = {0, 1, -1, 100, 255, -256};
  for (fixnum imm : imm9) {
    word = 0xF840001F; // LDUR x31, [x0, #0]
    ldur.store_value(imm);
    CHECK_EQ((cell)0xF840001F, (cell)(word & ~rel_arm_ldur_mask));
    CHECK_EQ(imm, ldur.load_value(0));
  }

  instruction_operand cmp = operand(fcb, RC_ABSOLUTE_ARM_CMP, 8, RT_UNTAGGED);
  fixnum imm12[] = {0, 1, 2047};
  for (fixnum imm : imm12) {
    word = 0xF100001F; // CMP x0, #0
    cmp.store_value(imm);
    CHECK_EQ((cell)0xF100001F, (cell)(word & ~rel_arm_cmp_mask));
    CHECK_EQ(imm, cmp.load_value(0));
  }
  // The field is unsigned imm12 but load_value_masked sign-extends from bit
  // 21, so values with bit 11 set read back negative. Documenting, not
  // asserting a fix: nothing stores such a CMP immediate today.
  word = 0xF100001F;
  cmp.store_value(4095);
  CHECK_EQ((cell)(4095u << 10), (cell)(word & rel_arm_cmp_mask));
  CHECK_EQ((fixnum)-1, cmp.load_value(0));
}
