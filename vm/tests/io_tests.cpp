// Tests for vm/io.cpp (the ANSI C file primitives), vm/utilities.cpp,
// vm/booleans.hpp and the small inline helpers in vm/layouts.hpp and
// vm/bitwise_hacks.hpp.
#include "test_vm.hpp"

#include <unistd.h>

using namespace factor;
using namespace factor::tests;

namespace {

const cell true_sentinel = tag_fixnum(0x74727565);

// A NUL-terminated C string in a byte array, as the Factor side hands to
// fopen and friends.
cell c_string(factor_vm& vm, const std::string& s) {
  byte_array* ba = vm.allot_byte_array(s.size() + 1);
  memcpy(ba->data<char>(), s.c_str(), s.size() + 1);
  return tag<byte_array>(ba);
}

struct temp_file {
  std::string path;
  temp_file() {
    char name[] = "/tmp/factor-io-test-XXXXXX";
    int fd = mkstemp(name);
    CHECK(fd >= 0);
    close(fd);
    path = name;
  }
  ~temp_file() { unlink(path.c_str()); }
};

// ( path mode -- alien )
cell open_file(test_vm& t, const std::string& path, const char* mode) {
  t.push(c_string(t.vm, path));
  t.push(c_string(t.vm, mode));
  t.vm.primitive_fopen();
  return t.pop();
}

// ( text length alien -- )
void write_bytes(test_vm& t, cell file, const std::string& text) {
  t.push(c_string(t.vm, text));
  t.push_fixnum(text.size());
  t.push(file);
  t.vm.primitive_fwrite();
}

// ( offset whence alien -- )
void seek(test_vm& t, cell file, fixnum offset, fixnum whence) {
  t.push_fixnum(offset);
  t.push_fixnum(whence);
  t.push(file);
  t.vm.primitive_fseek();
}

// ( alien -- offset )
fixnum tell(test_vm& t, cell file) {
  t.push(file);
  t.vm.primitive_ftell();
  return t.pop_fixnum();
}

// ( n buf alien -- count ), returns the bytes read into `out`.
std::string read_bytes(test_vm& t, cell file, cell n) {
  byte_array* buf = t.vm.allot_byte_array(n == 0 ? 1 : n);
  memset(buf->data<char>(), 0, n == 0 ? 1 : n);
  t.push_fixnum(n);
  t.push(tag<byte_array>(buf));
  t.push(file);
  t.vm.primitive_fread();
  fixnum count = t.pop_fixnum();
  return std::string(buf->data<char>(), count);
}

// ( alien -- ch/f )
cell getc_cell(test_vm& t, cell file) {
  t.push(file);
  t.vm.primitive_fgetc();
  return t.pop();
}

void close_file(test_vm& t, cell file) {
  t.push(file);
  t.vm.primitive_fclose();
}

} // namespace

FACTOR_TEST(file_primitives_write_seek_tell_read) {
  test_vm t;
  temp_file f;
  cell depth = t.datastack_depth();

  cell file = open_file(t, f.path, "w+");
  CHECK_EQ((cell)ALIEN_TYPE, TAG(file));
  CHECK(untag<alien>(file)->address != 0);
  CHECK_EQ(depth, t.datastack_depth());

  write_bytes(t, file, "hello, world");
  CHECK_EQ(depth, t.datastack_depth());
  t.push(file);
  t.vm.primitive_fflush();
  CHECK_EQ(depth, t.datastack_depth());
  CHECK_EQ((fixnum)12, tell(t, file));

  // A zero-length write is a no-op that still pops its operands.
  write_bytes(t, file, "");
  CHECK_EQ(depth, t.datastack_depth());
  CHECK_EQ((fixnum)12, tell(t, file));

  // whence 0 = start, 1 = current, 2 = end.
  seek(t, file, 7, 0);
  CHECK_EQ((fixnum)7, tell(t, file));
  CHECK_EQ("world", read_bytes(t, file, 5));
  seek(t, file, -5, 1);
  CHECK_EQ((fixnum)7, tell(t, file));
  seek(t, file, -12, 2);
  CHECK_EQ((fixnum)0, tell(t, file));
  CHECK_EQ("hello", read_bytes(t, file, 5));
  CHECK_EQ(depth, t.datastack_depth());

  // A zero-length read returns 0 without touching the file.
  CHECK_EQ("", read_bytes(t, file, 0));
  CHECK_EQ((fixnum)5, tell(t, file));

  close_file(t, file);
  CHECK_EQ(depth, t.datastack_depth());
}

FACTOR_TEST(fread_past_the_end_returns_a_short_count_and_clears_eof) {
  test_vm t;
  temp_file f;
  cell file = open_file(t, f.path, "w+");
  write_bytes(t, file, "abc");
  seek(t, file, 0, 0);
  CHECK_EQ("abc", read_bytes(t, file, 10));
  FILE* handle = (FILE*)untag<alien>(file)->address;
  CHECK(!feof(handle));
  // At the end, a read returns 0 and the EOF flag is cleared again.
  CHECK_EQ("", read_bytes(t, file, 4));
  CHECK(!feof(handle));
  close_file(t, file);
}

FACTOR_TEST(fgetc_and_fputc_primitives) {
  test_vm t;
  temp_file f;
  cell depth = t.datastack_depth();
  cell file = open_file(t, f.path, "w+");

  t.push_fixnum('x');
  t.push(file);
  t.vm.primitive_fputc();
  t.push_fixnum('y');
  t.push(file);
  t.vm.primitive_fputc();
  CHECK_EQ(depth, t.datastack_depth());
  seek(t, file, 0, 0);

  CHECK_EQ(tag_fixnum('x'), getc_cell(t, file));
  CHECK_EQ(tag_fixnum('y'), getc_cell(t, file));
  // End of file reads as f and clears the EOF flag so the file stays usable.
  CHECK_EQ(false_object, getc_cell(t, file));
  CHECK(!feof((FILE*)untag<alien>(file)->address));
  seek(t, file, 1, 0);
  CHECK_EQ(tag_fixnum('y'), getc_cell(t, file));
  CHECK_EQ(depth, t.datastack_depth());
  close_file(t, file);
}

FACTOR_TEST(fread_accepts_an_alien_buffer_and_a_bignum_count) {
  test_vm t;
  temp_file f;
  cell file = open_file(t, f.path, "w+");
  write_bytes(t, file, "0123456789");
  seek(t, file, 0, 0);

  char raw[16] = {0};
  t.push_fixnum(4);
  t.push(t.vm.allot_alien((cell)raw));
  t.push(file);
  t.vm.primitive_fread();
  CHECK_EQ(tag_fixnum(4), t.pop());
  CHECK_EQ(std::string("0123"), std::string(raw, 4));

  // The count is unboxed with unbox_array_size, so a bignum works too.
  t.push(tag<bignum>(t.vm.fixnum_to_bignum(6)));
  t.push(t.vm.allot_alien((cell)raw));
  t.push(file);
  t.vm.primitive_fread();
  CHECK_EQ(tag_fixnum(6), t.pop());
  CHECK_EQ(std::string("456789"), std::string(raw, 6));
  close_file(t, file);
}

FACTOR_TEST(fopen_result_can_be_closed_once) {
  test_vm t;
  temp_file f;
  cell file = open_file(t, f.path, "r");
  CHECK_EQ((cell)0, (cell)raw_fclose((FILE*)untag<alien>(file)->address));
}

FACTOR_TEST(existsp_primitive) {
  test_vm t;
  t.vm.special_objects[OBJ_CANONICAL_TRUE] = true_sentinel;
  temp_file f;
  cell depth = t.datastack_depth();
  t.push(c_string(t.vm, f.path));
  t.vm.primitive_existsp();
  CHECK_EQ(depth + 1, t.datastack_depth());
  CHECK_EQ(true_sentinel, t.pop());
  t.push(c_string(t.vm, f.path + ".does-not-exist"));
  t.vm.primitive_existsp();
  CHECK_EQ(false_object, t.pop());
}

FACTOR_TEST(raw_fread_partial_read_pointer_arithmetic) {
  // BUG (not fixed here): raw_fread and safe_fwrite continue a short
  // transfer at `(int*)ptr + items_done * size`, which advances four bytes
  // per byte when size == 1 (and 4*size otherwise). The retry only happens
  // when fread/fwrite return a short count without EOF, i.e. after EINTR,
  // so it cannot be reproduced deterministically here; the arithmetic should
  // be `(char*)ptr + items_done * size`.
  SKIP_TEST("documents the pointer arithmetic in raw_fread/safe_fwrite; needs EINTR to trigger");
}

FACTOR_TEST(err_no_round_trips_errno) {
  set_err_no(ENOENT);
  CHECK_EQ(ENOENT, err_no());
  set_err_no(0);
  CHECK_EQ(0, err_no());
}

FACTOR_TEST(safe_strdup_copies_the_string) {
  vm_char* copy = safe_strdup("factor");
  CHECK(copy != NULL);
  CHECK_EQ(std::string("factor"), std::string(copy));
  free(copy);
}

FACTOR_TEST(factor_memcpy_copies_bytes) {
  char src[] = "abcdef";
  char dst[8] = {0};
  CHECK_EQ((void*)dst, factor_memcpy(dst, src, 4));
  CHECK_EQ(std::string("abcd"), std::string(dst));
}

FACTOR_TEST(memset_helpers_fill_patterns) {
  cell cells[4];
  memset_cell(cells, 0xABCD, sizeof(cells));
  for (cell c : cells)
    CHECK_EQ((cell)0xABCD, c);
  memset_cell(cells, 0, sizeof(cells));
  for (cell c : cells)
    CHECK_EQ((cell)0, c);
  uint16_t halves[6];
  memset_2(halves, 0x1234, sizeof(halves));
  for (uint16_t h : halves)
    CHECK_EQ((unsigned)0x1234, (unsigned)h);
  memset_2(halves, 0, sizeof(halves));
  CHECK_EQ((unsigned)0, (unsigned)halves[5]);
}

FACTOR_TEST(booleans_to_and_from_cells) {
  test_vm t;
  t.vm.special_objects[OBJ_CANONICAL_TRUE] = true_sentinel;
  CHECK(!to_boolean(false_object));
  CHECK(to_boolean(tag_fixnum(0)));
  CHECK(to_boolean(true_sentinel));
  CHECK_EQ(true_sentinel, t.vm.tag_boolean(1));
  CHECK_EQ(true_sentinel, t.vm.tag_boolean(42));
  CHECK_EQ(false_object, t.vm.tag_boolean(0));
}

FACTOR_TEST(alignment_helpers) {
  CHECK_EQ((cell)0, align(0, 16));
  CHECK_EQ((cell)16, align(1, 16));
  CHECK_EQ((cell)16, align(16, 16));
  CHECK_EQ((cell)32, align(17, 16));
  CHECK_EQ((cell)15, alignment_for(1, 16));
  CHECK_EQ((cell)0, alignment_for(32, 16));
  cell page = getpagesize();
  CHECK_EQ(page, align_page(1));
  CHECK_EQ(2 * page, align_page(page + 1));
  CHECK_EQ((cell)0, align_page(0));
}

FACTOR_TEST(bit_helpers) {
  CHECK_EQ((cell)0, log2((cell)1));
  CHECK_EQ((cell)1, log2((cell)2));
  CHECK_EQ((cell)1, log2((cell)3));
  CHECK_EQ((cell)10, log2((cell)1024));
  CHECK_EQ((cell)63, log2((cell)1 << 63));
  CHECK_EQ((cell)0, rightmost_set_bit(1));
  CHECK_EQ((cell)3, rightmost_set_bit(8));
  CHECK_EQ((cell)3, rightmost_set_bit(0x78));
  CHECK_EQ((cell)0, rightmost_clear_bit(0));
  CHECK_EQ((cell)2, rightmost_clear_bit(3));
  CHECK_EQ((cell)4, rightmost_clear_bit(0xF));
  CHECK_EQ((cell)0, popcount(0));
  CHECK_EQ((cell)1, popcount(1));
  CHECK_EQ((cell)4, popcount(0xF0));
  CHECK_EQ((cell)64, popcount(~(cell)0));
}
