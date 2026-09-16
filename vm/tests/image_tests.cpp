// Tests for vm/image.cpp and vm/image.hpp: command-line parameters, the
// image header layout, embedded image footers and object sizing.
#include "test_vm.hpp"

#include <cstdio>
#include <cstring>
#include <unistd.h>

using namespace factor;
using namespace factor::tests;

namespace {

struct argv_builder {
  std::vector<std::string> storage;
  std::vector<vm_char*> argv;

  argv_builder(std::initializer_list<const char*> args) {
    storage.push_back("factor");
    for (const char* a : args)
      storage.push_back(a);
    for (std::string& s : storage)
      argv.push_back(&s[0]);
  }
  int argc() const { return (int)argv.size(); }
  vm_char** data() { return argv.data(); }
};

struct temp_file {
  std::string path;
  temp_file() {
    char buf[] = "/tmp/factor-image-test-XXXXXX";
    int fd = mkstemp(buf);
    if (fd < 0)
      throw std::runtime_error("mkstemp failed");
    close(fd);
    path = buf;
  }
  ~temp_file() { unlink(path.c_str()); }
  void write(const void* data, size_t n) {
    FILE* f = fopen(path.c_str(), "wb");
    CHECK(f != NULL);
    CHECK_EQ(n, fwrite(data, 1, n, f));
    fclose(f);
  }
};

} // namespace

FACTOR_TEST(vm_parameters_defaults) {
  vm_parameters p;
  CHECK(!p.embedded_image);
  CHECK(p.image_path == NULL);
  CHECK(p.executable_path == NULL);
  // Stack sizes are in kilobytes, heap sizes in megabytes at this point.
  CHECK_EQ((cell)(32 * sizeof(cell)), p.datastack_size);
  CHECK_EQ((cell)(32 * sizeof(cell)), p.retainstack_size);
  CHECK_EQ((cell)(128 * sizeof(cell)), p.callstack_size);
  CHECK_EQ((cell)96, p.code_size);
  CHECK_EQ((cell)(sizeof(cell) / 4), p.young_size);
  CHECK_EQ((cell)(sizeof(cell) / 2), p.aging_size);
  CHECK_EQ((cell)(24 * sizeof(cell)), p.tenured_size);
  CHECK_EQ((cell)3, p.max_pic_size);
  CHECK_EQ((cell)256, p.callback_size);
  CHECK(!p.fep);
  CHECK(p.signals);
  CHECK(p.console);
}

FACTOR_TEST(vm_parameters_parse_every_numeric_flag) {
  argv_builder args{"-datastack=100", "-retainstack=200", "-callstack=300", "-young=4",
                    "-aging=5", "-tenured=600", "-codeheap=70", "-pic=8", "-callbacks=9"};
  vm_parameters p;
  p.init_from_args(args.argc(), args.data());
  CHECK_EQ((cell)100, p.datastack_size);
  CHECK_EQ((cell)200, p.retainstack_size);
  CHECK_EQ((cell)300, p.callstack_size);
  CHECK_EQ((cell)4, p.young_size);
  CHECK_EQ((cell)5, p.aging_size);
  CHECK_EQ((cell)600, p.tenured_size);
  CHECK_EQ((cell)70, p.code_size);
  CHECK_EQ((cell)8, p.max_pic_size);
  CHECK_EQ((cell)9, p.callback_size);
  CHECK(p.image_path == NULL);
  CHECK(!p.fep);
  CHECK(p.signals);
}

FACTOR_TEST(vm_parameters_parse_image_path_fep_and_no_signals) {
  argv_builder args{"-i=first.image", "-fep", "-no-signals", "-i=second.image"};
  vm_parameters p;
  p.init_from_args(args.argc(), args.data());
  CHECK(p.image_path != NULL);
  CHECK_EQ(std::string("second.image"), std::string(p.image_path));
  CHECK(p.fep);
  CHECK(!p.signals);
  CHECK(!p.embedded_image); // only ever set by init_factor
}

FACTOR_TEST(vm_parameters_stop_at_double_dash_and_ignore_unknown_flags) {
  argv_builder args{"-e=USING: math ;", "-run=listener", "-bogus", "-young=abc", "-young",
                    "--", "-young=9", "-fep"};
  vm_parameters p;
  p.init_from_args(args.argc(), args.data());
  CHECK_EQ((cell)(sizeof(cell) / 4), p.young_size);
  CHECK(!p.fep);
  CHECK(p.image_path == NULL);

  // argv[0] is skipped even if it looks like a flag.
  std::string name = "-fep";
  vm_char* only[] = {&name[0]};
  vm_parameters q;
  q.init_from_args(1, only);
  CHECK(!q.fep);
}

FACTOR_TEST(vm_parameters_numeric_parsing_follows_sscanf) {
  // sscanf %d accepts a numeric prefix and negative numbers; the VM does
  // not validate further. Documenting the behaviour rather than a contract.
  argv_builder args{"-young=4m", "-aging=-1", "-tenured=0x10"};
  vm_parameters p;
  p.init_from_args(args.argc(), args.data());
  CHECK_EQ((cell)4, p.young_size);
  CHECK_EQ((cell)-1, p.aging_size);
  CHECK_EQ((cell)0, p.tenured_size);
}

FACTOR_TEST(image_header_layout_matches_the_bootstrap_image_writer) {
  // basis/bootstrap/image/image.factor: image-magic, image-version,
  // header-size 10 cells followed by special-object-count cells.
  CHECK_EQ((cell)0x0f0e0d0c, image_magic);
  CHECK_EQ((cell)4, image_version);
  CHECK_EQ((size_t)0, offsetof(image_header, magic));
  CHECK_EQ((size_t)1 * sizeof(cell), offsetof(image_header, version));
  CHECK_EQ((size_t)2 * sizeof(cell), offsetof(image_header, data_relocation_base));
  CHECK_EQ((size_t)3 * sizeof(cell), offsetof(image_header, data_size));
  CHECK_EQ((size_t)3 * sizeof(cell), offsetof(image_header, version4_escape));
  CHECK_EQ((size_t)4 * sizeof(cell), offsetof(image_header, code_relocation_base));
  CHECK_EQ((size_t)5 * sizeof(cell), offsetof(image_header, code_size));
  CHECK_EQ((size_t)6 * sizeof(cell), offsetof(image_header, escaped_data_size));
  CHECK_EQ((size_t)7 * sizeof(cell), offsetof(image_header, compressed_data_size));
  CHECK_EQ((size_t)8 * sizeof(cell), offsetof(image_header, compressed_code_size));
  CHECK_EQ((size_t)9 * sizeof(cell), offsetof(image_header, reserved_4));
  CHECK_EQ((size_t)10 * sizeof(cell), offsetof(image_header, special_objects));
  CHECK_EQ((size_t)(10 + special_object_count) * sizeof(cell), sizeof(image_header));

  CHECK_EQ((size_t)0, offsetof(embedded_image_footer, magic));
  CHECK_EQ(sizeof(cell), offsetof(embedded_image_footer, image_offset));
  CHECK_EQ(2 * sizeof(cell), sizeof(embedded_image_footer));
}

FACTOR_TEST(read_embedded_image_footer_recognises_the_trailing_magic) {
  test_vm t;
  temp_file file;

  std::vector<char> payload(1000, 'x');
  embedded_image_footer footer = {image_magic, 123};
  std::vector<char> bytes(payload);
  bytes.insert(bytes.end(), (char*)&footer, (char*)&footer + sizeof(footer));
  file.write(bytes.data(), bytes.size());

  FILE* f = fopen(file.path.c_str(), "rb");
  CHECK(f != NULL);
  embedded_image_footer read = {0, 0};
  CHECK(t.vm.read_embedded_image_footer(f, &read));
  CHECK_EQ(image_magic, read.magic);
  CHECK_EQ((cell)123, read.image_offset);
  fclose(f);

  // A footer-sized file with only the footer.
  file.write(&footer, sizeof(footer));
  f = fopen(file.path.c_str(), "rb");
  CHECK(t.vm.read_embedded_image_footer(f, &read));
  fclose(f);

  // Wrong magic at the end is not an embedded image.
  footer.magic = image_magic + 1;
  bytes.assign(payload.begin(), payload.end());
  bytes.insert(bytes.end(), (char*)&footer, (char*)&footer + sizeof(footer));
  file.write(bytes.data(), bytes.size());
  f = fopen(file.path.c_str(), "rb");
  CHECK(!t.vm.read_embedded_image_footer(f, &read));
  fclose(f);

  // The magic appearing before the end does not count either.
  footer.magic = image_magic;
  bytes.assign(payload.begin(), payload.end());
  bytes.insert(bytes.end(), (char*)&footer, (char*)&footer + sizeof(footer));
  bytes.insert(bytes.end(), 8, 'y');
  file.write(bytes.data(), bytes.size());
  f = fopen(file.path.c_str(), "rb");
  CHECK(!t.vm.read_embedded_image_footer(f, &read));
  fclose(f);
}

FACTOR_TEST(embedded_image_p_is_false_for_the_test_executable) {
  test_vm t;
  const vm_char* path = factor::vm_executable_path();
  CHECK(path != NULL);
  CHECK(strstr(path, "factor-test") != NULL);
  free((vm_char*)path);
  CHECK(!t.vm.embedded_image_p());
}

FACTOR_TEST(object_size_per_type_matches_the_layout_formulas) {
  test_vm t;

  factor::array* a = t.vm.allot_array(3, false_object);
  CHECK_EQ(align(sizeof(factor::array) + 3 * sizeof(cell), data_alignment), a->size());
  CHECK_EQ(a->size(), object_size(tag<factor::array>(a)));

  byte_array* ba = t.vm.allot_byte_array(5);
  CHECK_EQ(align(sizeof(byte_array) + 5, data_alignment), ba->size());

  factor::string* s = t.vm.allot_string(7, 'a');
  CHECK_EQ(align(sizeof(factor::string) + 7, data_alignment), s->size());

  bignum* bn = t.vm.allot<bignum>(sizeof(bignum) + 2 * sizeof(cell));
  bn->capacity = tag_fixnum(2);
  CHECK_EQ(align(sizeof(bignum) + 2 * sizeof(cell), data_alignment), bn->size());

  // A tuple's size comes from its layout.
  tuple_layout* layout = (tuple_layout*)t.vm.allot_array(5, false_object);
  layout->size = tag_fixnum(3);
  factor::tuple* tup = t.vm.allot<factor::tuple>(factor::tuple_size(layout));
  tup->layout = tag<tuple_layout>(layout);
  CHECK_EQ(align(sizeof(factor::tuple) + 3 * sizeof(cell), data_alignment), tup->size());

  CHECK_EQ(align(sizeof(quotation), data_alignment), t.vm.allot<quotation>(sizeof(quotation))->size());
  CHECK_EQ(align(sizeof(word), data_alignment), t.vm.allot<word>(sizeof(word))->size());
  CHECK_EQ(align(sizeof(boxed_float), data_alignment), t.vm.allot<boxed_float>(sizeof(boxed_float))->size());
  CHECK_EQ(align(sizeof(dll), data_alignment), t.vm.allot<dll>(sizeof(dll))->size());
  CHECK_EQ(align(sizeof(alien), data_alignment), t.vm.allot<alien>(sizeof(alien))->size());
  CHECK_EQ(align(sizeof(wrapper), data_alignment), t.vm.allot<wrapper>(sizeof(wrapper))->size());

  callstack* cs = t.vm.allot<callstack>(callstack_object_size(24));
  cs->length = tag_fixnum(24);
  CHECK_EQ(align(sizeof(callstack) + 24, data_alignment), cs->size());

  // Immediates have no heap size.
  CHECK_EQ((cell)0, object_size(tag_fixnum(5)));
  CHECK_EQ((cell)0, object_size(false_object));
}

namespace {

// A fixup that shifts every data pointer by a constant, standing in for the
// startup_fixup image.cpp uses (which is private to that file).
struct shifting_fixup {
  static const bool translated_code_block_map = false;
  cell data_offset;
  explicit shifting_fixup(cell data_offset) : data_offset(data_offset) {}
  object* fixup_data(object* obj) { return (object*)((cell)obj + data_offset); }
  code_block* fixup_code(code_block* compiled) { return compiled; }
  object* translate_data(const object* obj) { return fixup_data((object*)obj); }
  code_block* translate_code(const code_block* compiled) { return (code_block*)compiled; }
  cell size(object* obj) { return obj->size(*this); }
  cell size(code_block* compiled) { return compiled->size(); }
};

} // namespace

FACTOR_TEST(slot_visitor_rebases_heap_pointers_and_leaves_immediates_alone) {
  test_vm t;
  factor::array* target = t.vm.allot_array(1, false_object);
  factor::array* a = t.vm.allot_array(4, false_object);
  t.vm.set_array_nth(a, 0, tag<factor::array>(target));
  t.vm.set_array_nth(a, 1, tag_fixnum(42));
  t.vm.set_array_nth(a, 2, false_object);
  t.vm.set_array_nth(a, 3, tag<factor::array>(target));

  shifting_fixup fixup(0x1000);
  slot_visitor<shifting_fixup> visitor(&t.vm, fixup);
  visitor.visit_slots(a);

  CHECK_EQ(tag<factor::array>(target) + 0x1000, array_nth(a, 0));
  CHECK_EQ(tag_fixnum(42), array_nth(a, 1));
  CHECK_EQ(false_object, array_nth(a, 2));
  CHECK_EQ(tag<factor::array>(target) + 0x1000, array_nth(a, 3));
  // The tag survives the rebase.
  CHECK_EQ((cell)ARRAY_TYPE, TAG(array_nth(a, 0)));
}
