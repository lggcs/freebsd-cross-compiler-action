#include <iostream>
#include <string>
#include <vector>

int main() {
    std::vector<std::string> features = {
        "C++ cross-compilation",
        "FreeBSD 15.1 target",
        "libc++ from sysroot",
        "LLVM/Clang + LLD"
    };

    std::cout << "FreeBSD C++ cross-compile test\n";
    std::cout << "==============================\n";
    for (const auto& f : features) {
        std::cout << "  - " << f << "\n";
    }
    std::cout << "==============================\n";
    std::cout << "Binary compiled on Linux, ready for FreeBSD.\n";
    return 0;
}