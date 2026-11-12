/* EXAMPLE_SDK: a tour of the C library in a program with main.
 * Build: SDK/bin/zdos-cc example_sdk.c -o EXAMPLE.APP
 * Try: EXAMPLE one "two words" three */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    printf("Hello from %s\n", argv[0]);
    for (int i = 1; i < argc; i++) {
        printf("  argument %d: %s\n", i, argv[i]);
    }

    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    printf("It is %04d-%02d-%02d %02d:%02d\n", t->tm_year + 1900, t->tm_mon + 1, t->tm_mday, t->tm_hour, t->tm_min);

    /* A file: write it, look at it, read it back, delete it: */
    const char *name = "HELLO.TMP";
    char text[64];
    int len = snprintf(text, sizeof(text), "pi is about %.5f\n", 3.14159265);
    int fd = open(name, O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0) {
        perror(name);
        return 1;
    }
    write(fd, text, (size_t)len);
    close(fd);

    struct stat st;
    if (stat(name, &st) == 0) {
        printf("%s has %lld bytes\n", name, (long long)st.st_size);
    }
    char back[64];
    fd = open(name, O_RDONLY);
    ssize_t n = fd >= 0 ? read(fd, back, sizeof(back) - 1) : -1;
    close(fd);
    back[n > 0 ? n : 0] = '\0';
    printf("Read back: %s", back);
    unlink(name);

    /* Errors arrive as errno, with the cause ZDOS reported: */
    if (open("NO_SUCH.FIL", O_RDONLY) < 0) {
        printf("Opening NO_SUCH.FIL: %s\n", strerror(errno));
    }

    /* The first few entries of the current directory: */
    DIR *dir = opendir("");
    if (dir != NULL) {
        struct dirent *e;
        int shown = 0;
        printf("In this directory:");
        while ((e = readdir(dir)) != NULL && shown < 5) {
            if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
                continue;
            }
            printf(" %s%s", e->d_name, e->d_type == DT_DIR ? "\\" : "");
            shown++;
        }
        printf("\n");
        closedir(dir);
    }
    return argc - 1; /* the exit code: how many arguments were given */
}
