#include <stdio.h>
#include <sys/utsname.h>

int main(void) {
    printf("Hello from FreeBSD cross-compile!\n");

    struct utsname info;
    if (uname(&info) == 0) {
        printf("System: %s %s %s %s\n",
               info.sysname, info.nodename,
               info.release, info.machine);
    }
    return 0;
}