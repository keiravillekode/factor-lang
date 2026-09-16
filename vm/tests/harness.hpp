// Minimal unit test harness for the Factor VM. No external dependencies.
//
// Each test is a function registered with FACTOR_TEST(name) { ... }.
// Use CHECK(expr) and CHECK_EQ(expected, actual); a failing check throws,
// so the rest of that test is skipped and the runner moves on.
#ifndef FACTOR_TESTS_HARNESS_HPP
#define FACTOR_TESTS_HARNESS_HPP

#include "../master.hpp"

#include <functional>
#include <sstream>
#include <stdexcept>
#include <string>

namespace factor {
namespace tests {

struct test_case {
  const char* name;
  const char* file;
  void (*fn)();
  test_case* next;
};

test_case*& registry();

struct registrar {
  registrar(test_case* t) {
    t->next = registry();
    registry() = t;
  }
};

struct check_failure : std::runtime_error {
  explicit check_failure(const std::string& what) : std::runtime_error(what) {}
};

struct skip_test : std::runtime_error {
  explicit skip_test(const std::string& why) : std::runtime_error(why) {}
};

[[noreturn]] void fail(const char* file, int line, const std::string& message);

template <typename T> std::string show(const T& v) {
  std::ostringstream out;
  out << v;
  return out.str();
}

inline std::string show(unsigned char v) { return show((unsigned)v); }
inline std::string show(signed char v) { return show((int)v); }

template <typename A, typename B>
void check_eq(const char* file, int line, const char* expr_a, const char* expr_b,
              const A& a, const B& b) {
  if (!(a == b)) {
    fail(file, line, std::string("expected ") + expr_a + " == " + expr_b +
                         ", got " + show(a) + " vs " + show(b));
  }
}

} // namespace tests
} // namespace factor

#define FACTOR_TEST(name)                                                      \
  static void name();                                                          \
  static factor::tests::test_case name##_case = {#name, __FILE__, name,        \
                                                 nullptr};                     \
  static factor::tests::registrar name##_registrar(&name##_case);              \
  static void name()

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond))                                                               \
      factor::tests::fail(__FILE__, __LINE__, "check failed: " #cond);         \
  } while (0)

#define CHECK_EQ(expected, actual)                                             \
  factor::tests::check_eq(__FILE__, __LINE__, #expected, #actual, (expected),  \
                          (actual))

#define SKIP_TEST(why) throw factor::tests::skip_test(why)

#endif
