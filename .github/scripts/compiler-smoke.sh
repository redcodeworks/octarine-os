#!/usr/bin/env bash
# Runs INSIDE the built image (mounted at /compiler-smoke.sh by the image workflows): the compilers and the linker that the image ships
# (gcc, gcc-c++, make, binutils) must really work, not only be installed. Compiles, links and runs a C and a C++ program, links one with
# `ld` through gcc -fuse-ld=bfd, runs make on a tiny Makefile and calls ld, ar and as. Exit 0 only when everything works.
set -euo pipefail
d=$(mktemp -d)
trap 'rm -rf -- "${d}"' EXIT
cd "${d}"

cat >hello.c <<'C'
#include <stdio.h>
#include <math.h>
int main(void) { printf("c-ok %d\n", (int)sqrt(49.0)); return 0; }
C
cat >hello.cpp <<'C'
#include <iostream>
#include <string>
#include <vector>
int main() { std::vector<std::string> v{"cpp", "ok"}; std::cout << v[0] << "-" << v[1] << std::endl; return 0; }
C
cat >Makefile <<'M'
out.txt: hello-c
	./hello-c > out.txt
M

gcc --version | head -n1
g++ --version | head -n1
make --version | head -n1
ld --version | head -n1

gcc -O2 -Wall -o hello-c hello.c -lm
[[ "$(./hello-c)" == "c-ok 7" ]]
echo "PASS C program compiles, links and runs"

g++ -O2 -Wall -o hello-cpp hello.cpp
[[ "$(./hello-cpp)" == "cpp-ok" ]]
echo "PASS C++ program compiles, links and runs"

gcc -fuse-ld=bfd -o hello-bfd hello.c -lm
[[ "$(./hello-bfd)" == "c-ok 7" ]]
echo "PASS gcc links through ld (bfd)"

make
[[ "$(cat out.txt)" == "c-ok 7" ]]
echo "PASS make builds from a Makefile"

printf '.globl _start\n_start: mov $60, %%eax\n xor %%edi, %%edi\n syscall\n' >a.s
as -o a.o a.s
ld -o a-static a.o
./a-static
ar rcs libx.a a.o
ar t libx.a | grep -qx a.o
echo "PASS as, ld and ar run (a hand-assembled program was linked and exited 0)"
