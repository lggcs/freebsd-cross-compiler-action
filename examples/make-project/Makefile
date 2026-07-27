CC ?= freebsd-cc
CXX ?= freebsd-c++
CFLAGS ?= -O2 -Wall
CXXFLAGS ?= -O2 -Wall

hello-make: hello.c
	$(CC) $(CFLAGS) -o hello-make hello.c

hello-make-cpp: hello.cpp
	$(CXX) $(CXXFLAGS) -o hello-make-cpp hello.cpp

all: hello-make hello-make-cpp

clean:
	rm -f hello-make hello-make-cpp

.PHONY: all clean