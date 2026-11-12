// CXXTEST: tests libc++, a TAP line per check.
// Build: SDK/bin/zdos-c++ -O2 cxxtest.cpp -o CXXTEST.APP
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <typeinfo>
#include <unordered_map>
#include <vector>

static int test_number = 0;
static int failures = 0;

static void check(bool ok, const std::string &what) {
    ++test_number;
    if (!ok) ++failures;
    std::cout << (ok ? "ok " : "not ok ") << test_number << " - " << what << "\n";
}

struct Base {
    virtual ~Base() = default;
    virtual int value() const { return 1; }
};
struct Derived : Base {
    int value() const override { return 2; }
};

static int destroyed = 0;
struct Guard {
    ~Guard() { ++destroyed; }
};

static int thrower(int depth) {
    Guard g;
    if (depth == 0) throw std::runtime_error("deep");
    return thrower(depth - 1) + 1;
}

static void throw_int() { throw 42; }

static std::atomic<int> tl_made{0}, tl_gone{0};
struct PerThread {
    int id;
    PerThread() : id(++tl_made) {}
    ~PerThread() { ++tl_gone; }
};
static thread_local PerThread per_thread;

int main() {
    std::cout << "1..17" << std::endl;

    std::string s = "Hello";
    s += ", ZDOS";
    check(s == "Hello, ZDOS" && s.size() == 11 && s.find("ZDOS") == 7, "std::string");

    std::vector<int> v = {5, 3, 9, 1, 7};
    std::sort(v.begin(), v.end());
    check(v == std::vector<int>({1, 3, 5, 7, 9}), "std::vector and std::sort");

    std::map<std::string, int> m = {{"b", 2}, {"a", 1}, {"c", 3}};
    std::string keys;
    for (auto &kv : m) keys += kv.first;
    check(keys == "abc" && m["b"] == 2, "std::map");

    std::unordered_map<int, std::string> um;
    for (int i = 0; i < 100; i++) um[i] = std::to_string(i * i);
    check(um.size() == 100 && um[12] == "144", "std::unordered_map");

    std::ostringstream os;
    os << 42 << ' ' << 3.25 << ' ' << std::hex << 255 << ' ' << std::boolalpha << true;
    check(os.str() == "42 3.25 ff true", "std::ostringstream: " + os.str());
    std::cout << "# std::cout: " << 12345 << " " << 2.5 << " " << -7L << std::endl;

    std::istringstream is("17 2.5 word");
    int n = 0;
    double d = 0;
    std::string w;
    is >> n >> d >> w;
    check(n == 17 && d == 2.5 && w == "word", "std::istringstream");

    int caught = 0;
    try {
        throw_int();
    } catch (int e) {
        caught = e;
    }
    check(caught == 42, "throw and catch an int");

    destroyed = 0;
    std::string what;
    try {
        thrower(5);
    } catch (const std::exception &e) {
        what = e.what();
    }
    check(what == "deep" && destroyed == 6, "std::runtime_error across functions, destructors run");

    bool rethrown = false;
    try {
        try {
            throw std::logic_error("again");
        } catch (...) {
            throw;
        }
    } catch (const std::logic_error &e) {
        rethrown = std::string(e.what()) == "again";
    }
    check(rethrown, "catch (...) and rethrow");

    std::unique_ptr<Base> b = std::make_unique<Derived>();
    std::unique_ptr<Base> plain = std::make_unique<Base>();
    Derived *dp = dynamic_cast<Derived *>(b.get());
    const Base &rb = *b;
    check(dp != nullptr && dp->value() == 2 && typeid(rb) == typeid(Derived) &&
              dynamic_cast<Derived *>(plain.get()) == nullptr,
          std::string("dynamic_cast and typeid: ") + typeid(rb).name());

    bool bad_cast = false;
    try {
        Base &ref = *plain;
        (void)dynamic_cast<Derived &>(ref);
    } catch (const std::bad_cast &) {
        bad_cast = true;
    }
    check(bad_cast, "std::bad_cast");

    std::function<int(int)> twice = [](int x) { return 2 * x; };
    std::function<int(int)> composed = [&](int x) { return twice(x) + 1; };
    check(composed(20) == 41, "std::function");

    auto shared = std::make_shared<std::string>("shared");
    std::weak_ptr<std::string> weak = shared;
    {
        auto copy = shared;
        check(shared.use_count() == 2 && *weak.lock() == "shared", "std::shared_ptr and std::weak_ptr");
    }

    auto t0 = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    check(ms >= 40 && ms < 1000, "std::chrono::steady_clock and sleep_for: " + std::to_string(ms) + " ms");

    std::mutex mu;
    std::condition_variable cv;
    int counter = 0, ready = 0;
    std::vector<std::thread> threads;
    for (int t = 0; t < 4; t++) {
        threads.emplace_back([&] {
            for (int i = 0; i < 1000; i++) {
                std::lock_guard<std::mutex> lock(mu);
                ++counter;
            }
            std::lock_guard<std::mutex> lock(mu);
            ++ready;
            cv.notify_one();
        });
    }
    {
        std::unique_lock<std::mutex> lock(mu);
        cv.wait(lock, [&] { return ready == 4; });
    }
    for (auto &t : threads) t.join();
    check(counter == 4000, "std::thread, std::mutex, std::condition_variable");

    int main_id = per_thread.id;
    int other_id = 0;
    std::thread([&] { other_id = per_thread.id; }).join();
    check(main_id != other_id && other_id != 0 && tl_gone == 1,
          "thread_local with a constructor and destructor: made " + std::to_string(tl_made.load()) +
              ", ended " + std::to_string(tl_gone.load()));

    bool caught_in_thread = false;
    std::thread([&] {
        try {
            throw std::out_of_range("thread");
        } catch (const std::out_of_range &) {
            caught_in_thread = true;
        }
    }).join();
    check(caught_in_thread, "exception inside a thread");

    std::cout << (failures == 0 ? "# all passed" : "# FAILED") << std::endl;
    return failures == 0 ? 0 : 1;
}
