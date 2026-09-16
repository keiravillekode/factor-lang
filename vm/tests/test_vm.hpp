// A bare factor_vm with a data heap and two contexts but no image, no code
// heap and no signal handlers: enough to drive allocation, the data stack,
// bignum arithmetic and most primitives directly.
#ifndef FACTOR_TESTS_TEST_VM_HPP
#define FACTOR_TESTS_TEST_VM_HPP

#include "harness.hpp"

namespace factor {
namespace tests {

struct test_vm {
  factor_vm vm;

  explicit test_vm(cell young_size = 256 * 1024, cell aging_size = 256 * 1024,
                   cell tenured_size = 2 * 1024 * 1024)
      : vm(thread_id()) {
    for (cell i = 0; i < special_object_count; i++)
      vm.special_objects[i] = false_object;
    vm.datastack_size = 32 * 1024;
    vm.retainstack_size = 32 * 1024;
    vm.callstack_size = 128 * 1024;
    vm.set_data_heap(new data_heap(&vm.nursery, young_size, aging_size, tenured_size));
    vm.ctx = vm.new_context();
    vm.spare_ctx = vm.new_context();
  }

  ~test_vm() {
    // ~factor_vm deletes every context it knows about and asserts that
    // nothing is current any more.
    vm.ctx = NULL;
    vm.spare_ctx = NULL;
  }

  void push(cell tagged) { vm.ctx->push(tagged); }
  cell pop() { return vm.ctx->pop(); }
  void push_fixnum(fixnum n) { push(tag_fixnum(n)); }
  fixnum pop_fixnum() { return untag_fixnum(pop()); }

  // The stack pointer sits one cell below the segment start when empty and
  // points at the top element otherwise.
  cell datastack_depth() const {
    return (vm.ctx->datastack + sizeof(cell) - vm.ctx->datastack_seg->start) / sizeof(cell);
  }

  // Reset the nursery bump pointer so long loops do not run out of space
  // (there is no collector attached to this VM).
  void reset_nursery() { vm.nursery.flush(); }
};

} // namespace tests
} // namespace factor

#endif
