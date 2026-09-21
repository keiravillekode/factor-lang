#include "master.hpp"

namespace factor {

// Sample callstacks are kept in one Factor heap object, reachable from
// special_objects[OBJ_SAMPLE_CALLSTACKS], so that the GC keeps the words and
// quotations they refer to alive and so that Factor code can read them with
// get-samples. The object is a "growarr": a 2-element array
//
//   { count contents }
//
// where contents is an array of code block owners (words or quotations) and
// count is how many of its slots are in use. Every sample appends the
// owners of its callstack frames, outermost last, and remembers the range
// [callstack_begin, callstack_end) it occupies (see profiling_sample).
//
// The Zig VM keeps the same layout; see sampleCallstacksAdd and friends in
// src/safepoints.zig.

static cell growarr_count(array *growarr) {
  return untag_fixnum(growarr->data()[0]);
}

static cell growarr_nth(array *growarr, cell slot) {
  return array_nth(untag<array>(growarr->data()[1]), slot);
}

// record_sample runs inside the safepoint signal handler, which has
// interrupted compiled code at a safepoint. Nothing that runs there may
// allocate on the Factor heap: an allocation can start a collection, and a
// collection taken while a context is stopped at a safepoint walks a
// callstack that is not in a walkable state (on arm64 the walk attributes a
// frame to the wrong code block and the collector crashes or corrupts the
// heap; see factor/factor#3223). So the contents array is allocated in full
// when profiling starts, sized from the sample rate, and when it is full
// further entries are dropped rather than the array grown. A sample that
// loses entries just has a shorter callstack. The Zig VM does the same:
// MAX_SAMPLE_CALLSTACK_ENTRIES and sampleCallstackCapacity in
// src/safepoints.zig.
static const cell max_sample_callstack_entries = 2 * 1024 * 1024;

static cell sample_callstack_capacity(fixnum samples_per_second) {
  // ~10 seconds of samples at ~64 frames each, clamped to the hard cap.
  cell want = 10 * (cell)samples_per_second * 64;
  return std::min(want, max_sample_callstack_entries);
}

// Allocates memory. Only called from start_sampling_profiler, outside the
// signal handler.
array* factor_vm::allot_growarr(cell capacity) {
  data_root<array> contents(allot_array(capacity, false_object), this);
  array *growarr = allot_uninitialized_array<array>(2);
  set_array_nth(growarr, 0, tag_fixnum(0));
  set_array_nth(growarr, 1, contents.value());
  return growarr;
}

// Does not allocate, and must not: it runs inside the signal handler (see
// above). When the contents array is full the entry is dropped and counted.
void factor_vm::growarr_add(array *growarr, cell elt) {
  array* contents = untag<array>(growarr->data()[1]);
  cell count = growarr_count(growarr);
  if (count == array_capacity(contents)) {
    dropped_callstack_entries++;
    return;
  }
  set_array_nth(contents, count, elt);
  set_array_nth(growarr, 0, tag_fixnum(count + 1));
}

profiling_sample profiling_sample::record_counts() volatile {
  profiling_sample returned(atomic::load(&sample_count),
                            atomic::load(&gc_sample_count),
                            atomic::load(&jit_sample_count),
                            atomic::load(&foreign_sample_count),
                            atomic::load(&foreign_thread_sample_count));
  atomic::fetch_subtract(&sample_count, returned.sample_count);
  atomic::fetch_subtract(&gc_sample_count, returned.gc_sample_count);
  atomic::fetch_subtract(&jit_sample_count, returned.jit_sample_count);
  atomic::fetch_subtract(&foreign_sample_count, returned.foreign_sample_count);
  atomic::fetch_subtract(&foreign_thread_sample_count,
                         returned.foreign_thread_sample_count);
  return returned;
}

void profiling_sample::clear_counts() volatile {
  atomic::store(&sample_count, fixnum(0));
  atomic::store(&gc_sample_count, fixnum(0));
  atomic::store(&jit_sample_count, fixnum(0));
  atomic::store(&foreign_sample_count, fixnum(0));
  atomic::store(&foreign_thread_sample_count, fixnum(0));
}

// Runs inside the safepoint signal handler (handle_safepoint in
// safepoints.cpp). Does not allocate: see growarr_add.
void factor_vm::record_sample(bool prolog_p) {
  profiling_sample result = current_sample.record_counts();
  if (result.empty()) {
    return;
  }
  // Appends the callstack, which is just a sequence of quotation or
  // word references, to sample_callstacks.
  array* callstacks = untag<array>(special_objects[OBJ_SAMPLE_CALLSTACKS]);
  cell begin = growarr_count(callstacks);

  bool skip_p = prolog_p;
  auto recorder = [&](cell frame_top, cell size, code_block* owner, cell addr) {
    (void)frame_top;
    (void)size;
    (void)addr;
    if (skip_p)
      skip_p = false;
    else {
      growarr_add(callstacks, owner->owner);
    }
  };
  iterate_callstack(ctx, recorder);
  cell end = growarr_count(callstacks);

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
  // The whole sample buffer is allocated here, before the timer starts, so
  // that recording a sample never has to (see growarr_add).
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

    cell frame_count =
        from_iter->callstack_end - from_iter->callstack_begin;
    data_root<array> callstack(allot_array(frame_count, false_object),
                               this);

    for (cell i = 0; i < frame_count; i++) {
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
