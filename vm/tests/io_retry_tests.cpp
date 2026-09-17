// raw_fread and safe_fwrite retry a transfer that libc returned short
// without hitting end of file (an EINTR-interrupted read or write). The
// retry must continue from the byte after the ones already transferred.
//
// glibc's fopencookie builds a FILE* over custom callbacks, which lets a
// test script exactly such a partial transfer without any real signal.
#include "test_vm.hpp"

#include <cstring>
#include <string>
#include <vector>

using namespace factor;
using namespace factor::tests;

#if defined(__GLIBC__)

// A read script: each step either delivers bytes, or fails once with EINTR.
// A step is handed out progressively, since libc may ask for fewer bytes
// than the step holds.
struct read_script {
  std::vector<std::string> steps;
  size_t next = 0;
  size_t offset = 0;
};

static ssize_t scripted_read(void* cookie, char* buf, size_t size) {
  read_script* script = (read_script*)cookie;
  if (script->next == script->steps.size())
    return 0; // end of file
  const std::string& step = script->steps[script->next];
  if (step == "<EINTR>") {
    script->next++;
    errno = EINTR;
    return -1;
  }
  size_t n = std::min(size, step.size() - script->offset);
  memcpy(buf, step.data() + script->offset, n);
  script->offset += n;
  if (script->offset == step.size()) {
    script->next++;
    script->offset = 0;
  }
  return (ssize_t)n;
}

// A write script: each step is a number of bytes to accept (handed out
// progressively), or -1 to fail once with EINTR. Once the steps are used
// up everything is accepted. Accepted bytes are appended to `written`.
// Note that glibc makes a single callback per fwrite, so a short step
// alone produces a short fwrite return.
struct write_script {
  std::vector<long> steps;
  size_t next = 0;
  size_t offset = 0;
  std::string written;
};

static ssize_t scripted_write(void* cookie, const char* buf, size_t size) {
  write_script* script = (write_script*)cookie;
  if (script->next == script->steps.size()) {
    script->written.append(buf, size);
    return (ssize_t)size;
  }
  long step = script->steps[script->next];
  if (step < 0) {
    script->next++;
    errno = EINTR;
    return -1;
  }
  size_t n = std::min(size, (size_t)step - script->offset);
  script->written.append(buf, n);
  script->offset += n;
  if (script->offset == (size_t)step) {
    script->next++;
    script->offset = 0;
  }
  return (ssize_t)n;
}

static FILE* open_scripted(void* cookie, const char* mode,
                           cookie_read_function_t* read,
                           cookie_write_function_t* write) {
  cookie_io_functions_t functions = {read, write, nullptr, nullptr};
  FILE* file = fopencookie(cookie, mode, functions);
  CHECK(file != nullptr);
  setvbuf(file, nullptr, _IONBF, 0);
  return file;
}

FACTOR_TEST(raw_fread_resumes_after_an_interrupted_partial_read) {
  read_script script;
  script.steps = {"ABCD", "<EINTR>", "EFGH"};
  FILE* file = open_scripted(&script, "r", scripted_read, nullptr);

  // Big enough that a retry at the wrong offset stays inside the buffer.
  char buffer[64];
  memset(buffer, 0, sizeof(buffer));
  size_t items = raw_fread(buffer, 1, 8, file);
  fclose(file);

  CHECK_EQ((size_t)8, items);
  CHECK_EQ(std::string("ABCDEFGH"), std::string(buffer, 8));
}

FACTOR_TEST(safe_fwrite_resumes_after_an_interrupted_partial_write) {
  test_vm t;
  write_script script;
  // Accept only 3 of the 8 bytes on the first call, then everything. libc
  // makes one callback per fwrite and reports the short count, which is
  // enough to make safe_fwrite retry the remaining bytes.
  script.steps = {3};
  FILE* file = open_scripted(&script, "w", nullptr, scripted_write);

  // The message is followed by padding so that a retry at the wrong offset
  // reads recognisable bytes instead of running off the end.
  char buffer[64];
  memset(buffer, 'x', sizeof(buffer));
  memcpy(buffer, "ABCDEFGH", 8);
  size_t items = t.vm.safe_fwrite(buffer, 1, 8, file);
  fclose(file);

  CHECK_EQ((size_t)8, items);
  CHECK_EQ(std::string("ABCDEFGH"), script.written);
}

#else

FACTOR_TEST(raw_fread_resumes_after_an_interrupted_partial_read) {
  SKIP_TEST("needs glibc's fopencookie to script a partial read");
}

FACTOR_TEST(safe_fwrite_resumes_after_an_interrupted_partial_write) {
  SKIP_TEST("needs glibc's fopencookie to script a partial write");
}

#endif
