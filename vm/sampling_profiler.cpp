#include "master.hpp"

namespace factor {

// This is like the growable_array class, except the whole of it
// exists on the Factor heap. growarr = growable array.
static cell growarr_capacity(array *growarr) {
  return untag_fixnum(growarr->data()[0]);
}

static cell growarr_nth(array *growarr, cell slot) {
  return array_nth(untag<array>(growarr->data()[1]), slot);
}

// Hard cap on recorded callstack entries per profiling session. The
// contents array is allocated in full by start_sampling_profiler so that
// growarr_add never allocates: record_sample runs inside the safepoint
// handler, where a collection has to walk a callstack that was interrupted
// mid-instruction. On arm64 that walk is not sound - it can hand the
// collector a frame whose return address lies outside the code block it is
// attributed to - and the result is a crash or silently corrupted
// execution. No allocation means no collection there. Entries past the cap
// are dropped; the samples that lose them just have shorter callstacks.
static const cell max_sample_callstack_entries = 2 * 1024 * 1024;

static cell sample_callstack_capacity(fixnum samples_per_second) {
  // ~10 seconds of samples at ~64 frames each, clamped to the hard cap.
  cell want = 10 * (cell)samples_per_second * 64;
  return std::min(want, max_sample_callstack_entries);
}

// Allocates memory
array* factor_vm::allot_growarr(cell capacity) {
  data_root<array> contents(allot_array(capacity, false_object), this);
  array *growarr = allot_uninitialized_array<array>(2);
  set_array_nth(growarr, 0, tag_fixnum(0));
  set_array_nth(growarr, 1, contents.value());
  return growarr;
}

// Does not allocate, and must not: see max_sample_callstack_entries.
void factor_vm::growarr_add(array *growarr, cell elt) {
  array* contents = untag<array>(growarr->data()[1]);
  cell count = growarr_capacity(growarr);
  if (count == array_capacity(contents)) {
    dropped_callstack_entries++;
    return;
  }
  set_array_nth(contents, count, elt);
  set_array_nth(growarr, 0, tag_fixnum(count + 1));
}

profiling_sample profiling_sample::record_counts() volatile {
  atomic::fence();
  profiling_sample returned(sample_count, gc_sample_count,
                            jit_sample_count, foreign_sample_count,
                            foreign_thread_sample_count);
  atomic::fetch_subtract(&sample_count, returned.sample_count);
  atomic::fetch_subtract(&gc_sample_count, returned.gc_sample_count);
  atomic::fetch_subtract(&jit_sample_count, returned.jit_sample_count);
  atomic::fetch_subtract(&foreign_sample_count, returned.foreign_sample_count);
  atomic::fetch_subtract(&foreign_thread_sample_count,
                         returned.foreign_thread_sample_count);
  return returned;
}

void profiling_sample::clear_counts() volatile {
  sample_count = 0;
  gc_sample_count = 0;
  jit_sample_count = 0;
  foreign_sample_count = 0;
  foreign_thread_sample_count = 0;
  atomic::fence();
}

// Allocates memory
void factor_vm::record_sample(bool prolog_p) {
  profiling_sample result = current_sample.record_counts();
  if (result.empty()) {
    return;
  }
  // Appends the callstack, which is just a sequence of quotation or
  // word references, to sample_callstacks.
  cell callstacks_cell = special_objects[OBJ_SAMPLE_CALLSTACKS];
  data_root<array> callstacks = data_root<array>(callstacks_cell, this);
  cell begin = growarr_capacity(callstacks.untagged());

  bool skip_p = prolog_p;
  auto recorder = [&](cell frame_top, cell size, code_block* owner, cell addr) {
    (void)frame_top;
    (void)size;
    (void)addr;
    if (skip_p)
      skip_p = false;
    else {
      growarr_add(callstacks.untagged(), owner->owner);
    }
  };
  iterate_callstack(ctx, recorder);
  cell end = growarr_capacity(callstacks.untagged());

  // Add the sample.
  result.thread = special_objects[OBJ_CURRENT_THREAD];
  result.callstack_begin = begin;
  result.callstack_end = end;
  samples.push_back(result);
}

// Allocates memory
void factor_vm::set_profiling(fixnum rate) {
  bool running_p = atomic::load(&sampling_profiler_p);
  if (rate > 0 && !running_p)
    start_sampling_profiler(rate);
  else if (rate == 0 && running_p)
    end_sampling_profiler();
}

// Allocates memory
void factor_vm::start_sampling_profiler(fixnum rate) {
  special_objects[OBJ_SAMPLE_CALLSTACKS] =
      tag<array>(allot_growarr(sample_callstack_capacity(rate)));
  dropped_callstack_entries = 0;
  samples_per_second = rate;
  current_sample.clear_counts();
  // Release the memory consumed by collecting samples.
  samples.clear();
  samples.shrink_to_fit();
  samples.reserve(10 * rate);
  atomic::store(&sampling_profiler_p, true);
  start_sampling_profiler_timer();
}

void factor_vm::end_sampling_profiler() {
  atomic::store(&sampling_profiler_p, false);
  end_sampling_profiler_timer();
  record_sample(false);
}

// Allocates memory
void factor_vm::primitive_set_profiling() {
  set_profiling(to_fixnum(ctx->pop()));
}

// Allocates memory
void factor_vm::primitive_get_samples() {
  if (atomic::load(&sampling_profiler_p) || samples.empty()) {
    ctx->push(false_object);
    return;
  }
  data_root<array> samples_array(allot_array(samples.size(), false_object),
                                 this);
  std::vector<profiling_sample>::const_iterator from_iter = samples.begin();
  cell to_i = 0;

  cell callstacks_cell = special_objects[OBJ_SAMPLE_CALLSTACKS];
  data_root<array> callstacks = data_root<array>(callstacks_cell, this);

  for (; from_iter != samples.end(); ++from_iter, ++to_i) {
    data_root<array> sample(allot_array(7, false_object), this);

    set_array_nth(sample.untagged(), 0,
                  tag_fixnum(from_iter->sample_count));
    set_array_nth(sample.untagged(), 1,
                  tag_fixnum(from_iter->gc_sample_count));
    set_array_nth(sample.untagged(), 2,
                  tag_fixnum(from_iter->jit_sample_count));
    set_array_nth(sample.untagged(), 3,
                  tag_fixnum(from_iter->foreign_sample_count));
    set_array_nth(sample.untagged(), 4,
                  tag_fixnum(from_iter->foreign_thread_sample_count));

    set_array_nth(sample.untagged(), 5, from_iter->thread);

    cell callstack_size =
        from_iter->callstack_end - from_iter->callstack_begin;
    data_root<array> callstack(allot_array(callstack_size, false_object),
                               this);

    for (cell i = 0; i < callstack_size; i++) {
      cell block_owner = growarr_nth(callstacks.untagged(),
                                     from_iter->callstack_begin + i);
      set_array_nth(callstack.untagged(), i, block_owner);
    }
    set_array_nth(sample.untagged(), 6, callstack.value());
    set_array_nth(samples_array.untagged(), to_i, sample.value());
  }
  ctx->push(samples_array.value());
}

}
