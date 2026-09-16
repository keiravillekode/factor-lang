#include "harness.hpp"

#include <cstring>

namespace factor {
namespace tests {

test_case*& registry() {
  static test_case* head = nullptr;
  return head;
}

void fail(const char* file, int line, const std::string& message) {
  std::ostringstream out;
  out << file << ":" << line << ": " << message;
  throw check_failure(out.str());
}

} // namespace tests
} // namespace factor

using namespace factor::tests;

static bool matches(const char* name, const char* filter) {
  return filter == nullptr || strstr(name, filter) != nullptr;
}

int main(int argc, char** argv) {
  const char* filter = nullptr;
  bool list = false;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--list") == 0)
      list = true;
    else if (strcmp(argv[i], "--filter") == 0 && i + 1 < argc)
      filter = argv[++i];
    else {
      std::cerr << "usage: " << argv[0] << " [--list] [--filter SUBSTRING]\n";
      return 2;
    }
  }

  // Registration prepends, so reverse to run in definition order.
  std::vector<test_case*> cases;
  for (test_case* t = registry(); t; t = t->next)
    cases.push_back(t);
  std::reverse(cases.begin(), cases.end());

  int passed = 0, failed = 0, skipped = 0;
  for (test_case* t : cases) {
    if (!matches(t->name, filter))
      continue;
    if (list) {
      std::cout << t->name << "\n";
      continue;
    }
    try {
      t->fn();
      passed++;
    } catch (const skip_test& s) {
      skipped++;
      std::cout << "SKIP " << t->name << ": " << s.what() << "\n";
    } catch (const check_failure& f) {
      failed++;
      std::cout << "FAIL " << t->name << "\n     " << f.what() << "\n";
    } catch (const std::exception& e) {
      failed++;
      std::cout << "FAIL " << t->name << "\n     unexpected exception: " << e.what() << "\n";
    }
  }
  if (list)
    return 0;

  std::cout << passed << " passed, " << failed << " failed, " << skipped
            << " skipped\n";
  return failed == 0 ? 0 : 1;
}
