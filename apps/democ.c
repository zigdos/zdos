/* DEMOC: the C side of the API, without a C library: each group
 * called at least once, its structs as zdos.h lays them out (DEMO API
 * tests the behaviour). Exit code: failures; works in DEMOC.TMP. */
#include "zdos.h"

/* A string literal as pointer and length */
#define S(x) (x), (sizeof(x) - 1)

static int failures;

static void put(const char *s, size_t len) {
    zdos->console->print(s, len);
}

static void put_num(uint64_t n) {
    char buf[20];
    int i = sizeof buf;
    do {
        buf[--i] = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    put(buf + i, sizeof buf - i);
}

static bool same(const char *a, size_t a_len, const char *b) {
    size_t b_len = zdos_strlen(b);
    if (a_len != b_len) return false;
    for (size_t i = 0; i < a_len; i++)
        if (a[i] != b[i]) return false;
    return true;
}

static bool ends_with(const char *a, size_t a_len, const char *suffix) {
    size_t n = zdos_strlen(suffix);
    return a_len >= n && same(a + a_len - n, n, suffix);
}

static void color(uint8_t fg) {
    zdos->console->set_color(fg, ZDOS_BLACK);
}

static void section(const char *name) {
    color(ZDOS_YELLOW);
    zdos_puts(name);
    color(ZDOS_LIGHT_GRAY);
    zdos_puts("\n");
}

/* "[ OK ] what" in green or "[FAIL] what" in red */
static void check(bool ok, const char *what) {
    color(ok ? ZDOS_LIGHT_GREEN : ZDOS_LIGHT_RED);
    zdos_puts(ok ? "  [ OK ] " : "  [FAIL] ");
    color(ZDOS_LIGHT_GRAY);
    zdos_puts(what);
    zdos_puts("\n");
    if (!ok) failures++;
}

/* True if all of it was written */
static bool write_file(const char *path, size_t path_len, const char *data, size_t len) {
    int32_t h = zdos->files->open(path, path_len, ZDOS_WRITE);
    if (h < 0) return false;
    bool ok = zdos->files->write(h, data, len) == (int64_t)len;
    zdos->files->close(h);
    return ok;
}

static void test_time(void) {
    section("Time");
    zdos_time t;
    zdos->time->get(&t);
    check(t.year >= 2000 && t.month >= 1 && t.month <= 12 && t.day >= 1, "get_time gives a valid date");
    uint64_t start = zdos->time->millis();
    zdos->time->sleep(200);
    uint64_t took = zdos->time->millis() - start;
    check(took >= 150 && took <= 400, "sleep(200) takes about 200 ms");
    zdos_time bad = t;
    bad.month = 2;
    bad.day = 30;
    check(!zdos->time->set(&bad), "set_time refuses February 30");
    bad.year = 2023;
    bad.day = 29;
    check(!zdos->time->set(&bad), "set_time refuses February 29 in 2023");
    /* Set the clock to what it says, so the tests don't change it: */
    zdos->time->get(&t);
    check(zdos->time->set(&t), "set_time accepts the current time");
}

static void test_memory(void) {
    section("Memory");
    unsigned char *p = zdos->memory->alloc(100000);
    check(p != 0 && ((uintptr_t)p & 15) == 0, "alloc(100000) succeeds, 16-byte aligned");
    if (!p) return;
    for (int i = 0; i < 100000; i++) p[i] = (unsigned char)i;
    uint64_t sum = 0;
    for (int i = 0; i < 100000; i++) sum += p[i];
    check(sum == 12742320, "the block can be written and read back");
    zdos->memory->free(p);
}

static void test_files(void) {
    section("Files and folders");
    char drives[26];
    size_t count = zdos->drives->letters(drives, sizeof drives);
    check(count > 0, "get_drives lists at least one drive");
    bool info_ok = true, has_c = false;
    for (size_t i = 0; i < count; i++) {
        zdos_drive_info info;
        if (!zdos->drives->info((uint8_t)drives[i], &info) || info.letter != (uint8_t)drives[i]) info_ok = false;
        else if (drives[i] == 'C' && info.size > 0) has_c = true;
    }
    zdos_drive_info none;
    check(info_ok && has_c && !zdos->drives->info('Y', &none), "drive_info for every drive; none for Y:");

    zdos->files->delete_tree(S("DEMOC.TMP")); /* leftovers of an interrupted run */
    check(zdos->files->make_dir(S("DEMOC.TMP")), "make_dir DEMOC.TMP");
    check(!zdos->files->make_dir(S("DEMOC.TMP")) && zdos->programs->last_error() == ZDOS_ERROR_ALREADY_EXISTS,
          "make_dir again: last_error is ZDOS_ERROR_ALREADY_EXISTS");
    check(zdos->files->open(S("DEMOC.TMP\\NONE.TXT"), ZDOS_READ) < 0 && zdos->programs->last_error() == ZDOS_ERROR_NOT_FOUND,
          "open a missing file: ZDOS_ERROR_NOT_FOUND");
    check(zdos->files->open(S("DEMOC.TMP\\NO_DIR\\X.TXT"), ZDOS_WRITE) < 0 && zdos->programs->last_error() == ZDOS_ERROR_PATH_NOT_FOUND,
          "create in a missing folder: ZDOS_ERROR_PATH_NOT_FOUND");

    check(write_file(S("DEMOC.TMP\\A.TXT"), S("Hello from C\n")), "create and write a file");
    int32_t h = zdos->files->open(S("DEMOC.TMP\\A.TXT"), ZDOS_UPDATE);
    check(h >= 0 && zdos->files->seek(h, ZDOS_SEEK_END) && zdos->files->write(h, S("more\n")) == 5, "append (update mode, seek to end)");
    if (h >= 0) zdos->files->close(h);

    char buf[64];
    h = zdos->files->open(S("DEMOC.TMP\\A.TXT"), ZDOS_READ);
    int64_t n = h >= 0 ? zdos->files->read(h, buf, sizeof buf) : -1;
    check(n == 18 && same(buf, 18, "Hello from C\nmore\n") && zdos->files->size(h) == 18, "read back the whole file, size 18");
    if (h >= 0) zdos->files->close(h);

    zdos_dir_entry e;
    /* As created: ext2 and Minix names are case-sensitive */
    check(zdos->files->stat(S("DEMOC.TMP\\A.TXT"), &e) && !e.is_dir && e.size == 18 && same(e.name, e.name_len, "A.TXT"),
          "stat gives name, size and type");

    check(zdos->files->move(S("DEMOC.TMP\\A.TXT"), S("DEMOC.TMP\\B.TXT")) && !zdos->files->stat(S("DEMOC.TMP\\A.TXT"), &e),
          "move (rename) A.TXT to B.TXT");

    bool listed = false;
    int32_t d = zdos->files->open_dir(S("DEMOC.TMP"));
    if (d >= 0) {
        while (zdos->files->read_dir(d, &e))
            if (same(e.name, e.name_len, "B.TXT")) listed = true;
        zdos->files->close(d);
    }
    check(listed, "open_dir / read_dir list B.TXT");

    check(zdos->files->copy(S("DEMOC.TMP\\B.TXT"), S("DEMOC.TMP\\C.TXT")) && zdos->files->stat(S("DEMOC.TMP\\C.TXT"), &e) && e.size == 18,
          "copy a file");
    check(!zdos->files->copy(S("DEMOC.TMP"), S("DEMOC.TMP\\INSIDE")), "copying a folder into itself fails");
    check(zdos->files->move(S("DEMOC.TMP\\C.TXT"), S("DEMOC.TMP\\D.TXT")) && !zdos->files->stat(S("DEMOC.TMP\\C.TXT"), &e),
          "move a file");
    check(zdos->files->delete_file(S("DEMOC.TMP\\D.TXT")) && !zdos->files->delete_file(S("DEMOC.TMP\\D.TXT")) &&
              zdos->programs->last_error() == ZDOS_ERROR_NOT_FOUND,
          "delete a file, then deleting it again fails with ZDOS_ERROR_NOT_FOUND");


    char cwd[300], saved[300];
    size_t saved_len = zdos->files->get_cwd(saved, sizeof saved);
    bool inside = zdos->files->set_cwd(S("DEMOC.TMP"));
    size_t len = zdos->files->get_cwd(cwd, sizeof cwd);
    check(inside && ends_with(cwd, len, "\\DEMOC.TMP") && zdos->files->set_cwd(saved, saved_len), "set_cwd into the folder and back");

    /* stat_ex: Unix's fields only where the file system has them */
    zdos_stat_ex x = {0};
    x.size = sizeof x;
    zdos_drive_info here;
    bool fat = zdos->drives->info((uint8_t)cwd[0], &here) && here.file_system >= ZDOS_FS_FAT12 && here.file_system <= ZDOS_FS_FAT32;
    check(zdos->files->stat_ex(S("DEMOC.TMP\\B.TXT"), &x) && x.file_size == 18 && !x.is_dir && x.drive == (uint8_t)cwd[0] &&
              x.size == sizeof x && (fat ? !(x.valid & ZDOS_STAT_MODE) : (x.valid & ZDOS_STAT_MODE) && (x.mode & 0170000) == 0100000),
          "stat_ex: size, type, drive; mode only where the file system has one");

    check(zdos->files->delete_tree(S("DEMOC.TMP")) && !zdos->files->stat(S("DEMOC.TMP"), &e), "delete_tree removes the folder with its file");
}

static void test_system(void) {
    section("System and variables");
    /* Guard bytes after it: the kernel's struct must be no larger */
    struct {
        zdos_system_info info;
        uint8_t guard[16];
    } out;
    for (size_t i = 0; i < sizeof out.guard; i++) out.guard[i] = 0xA5;
    zdos->programs->system_info(&out.info);
    zdos_system_info info = out.info;
    bool kept = true;
    for (size_t i = 0; i < sizeof out.guard; i++) kept = kept && out.guard[i] == 0xA5;
    check(kept && (info.os_version[0] | info.os_version[1] | info.os_version[2]) != 0, "system_info: the version, nothing written past it");
    check(info.total_memory > 0 && info.free_memory <= info.total_memory && info.cpu_name_len > 0 && info.cpu_name_len <= 128,
          "system_info: memory and the CPU's name");
    char buf[300];
    size_t n = zdos->programs->program_path(buf, sizeof buf);
    check(n > 3 && buf[1] == ':' && ends_with(buf, n, "DEMOC.APP"), "program_path ends in DEMOC.APP");
    check(zdos->programs->set_var(S("DEMOC_VAR"), S("7")) && zdos->programs->get_var(S("DEMOC_VAR"), buf, sizeof buf) == 1 && buf[0] == '7',
          "set_var / get_var");
    bool pushed = zdos->system->push_vars();
    zdos->programs->set_var(S("DEMOC_SCOPED"), S("1"));
    if (pushed) zdos->system->pop_vars();
    check(pushed && zdos->programs->get_var(S("DEMOC_SCOPED"), buf, sizeof buf) < 0, "push_vars, set_var, pop_vars: the variable is gone");
    zdos->programs->set_var(S("DEMOC_VAR"), S(""));
    zdos->system->catch_ctrl_c(true);
    check(!zdos->system->ctrl_c_pressed(true), "catch_ctrl_c: no Ctrl+C pressed");
    zdos->system->catch_ctrl_c(false);
    n = zdos->system->boot_file(buf, sizeof buf);
    check(n == 0 || (n <= sizeof buf && buf[0] == '\\'), "boot_file: none, or a path");
}

static void test_drives(void) {
    section("Drives and disks");
    char cwd[300];
    zdos->files->get_cwd(cwd, sizeof cwd);
    uint8_t letter = (uint8_t)cwd[0];
    uint64_t sectors = 0;
    check(zdos->drives->sectors(letter, &sectors) && sectors > 0, "sectors of the current drive");
    zdos_disk_location loc;
    if (zdos->drives->location(letter, &loc)) {
        zdos_disk_info disk;
        check(zdos->disks->info(loc.disk, &disk) && loc.sectors > 0 && loc.start + loc.sectors <= disk.sectors && disk.sector_size >= 512,
              "location, and disks->info of its disk");
    } else {
        check(zdos->programs->last_error() == ZDOS_ERROR_NOT_SUPPORTED, "location: not on this edition");
    }
    static uint8_t first[512];
    check(zdos->drives->read(letter, 0, first, sizeof first), "read the drive's first sector");
    zdos_disk_info none;
    uint32_t disks = zdos->disks->count();
    check(disks > 0 && !zdos->disks->info(disks, &none), "disks->count; info past the last fails");
}

static void test_keyb(void) {
    section("Keyboard layouts");
    char name[16];
    uint32_t n = zdos->keyb->count(), active = zdos->keyb->active();
    size_t len = zdos->keyb->name(active, name, sizeof name);
    check(n >= 1 && active < n && len > 0 && len <= sizeof name, "count, active, its name");
    char list[256];
    check(zdos->keyb->loaded(list, sizeof list) <= sizeof list, "loaded");
}

static void test_tasks(void) {
    section("Tasks and threads");
    int32_t id = zdos->tasks->spawn(S("DEMO"), S("task count C 2 10"));
    if (id < 0) {
        zdos_puts("  [skip] tasks: not on this edition\n");
    } else {
        check(zdos->tasks->wait((uint32_t)id) == 2, "spawn DEMO task count, wait: exit code 2");
    }
    check(zdos->tasks->priority(zdos->tasks->id()) >= 0, "id, priority");
    zdos_cpu_times t;
    zdos->tasks->times(&t);
    check(t.total_ms > 0 && t.idle_ms <= t.total_ms, "times");
    int32_t m = zdos->tasks->mutex_create();
    check(m >= 0 && zdos->tasks->mutex_lock(m) && zdos->tasks->mutex_unlock(m), "mutex: create, lock, unlock");
    if (m >= 0) zdos->tasks->mutex_destroy(m);
    int32_t sem = zdos->threads->sem_create(1);
    check(sem >= 0 && zdos->threads->sem_wait(sem, 0) && zdos->threads->sem_value(sem) == 0 && !zdos->threads->sem_wait(sem, 10) &&
              zdos->threads->sem_post(sem) && zdos->threads->sem_value(sem) == 1,
          "semaphore: wait, empty, post");
    if (sem >= 0) zdos->threads->sem_destroy(sem);
    int32_t cond = zdos->threads->cond_create();
    if (cond >= 0) {
        zdos->threads->cond_signal(cond); /* no one waits: nothing happens */
        zdos->threads->cond_destroy(cond);
    }
    check(cond >= 0 && zdos->threads->default_stack_size() > 0, "condition: create, signal, destroy; default stack size");
    check(zdos->signals->alarm(0) == 0 && (zdos->signals->pending() & 1) == 0, "signals: no alarm set, none pending");
}

static volatile uint32_t core_value;

static void ZDOS_CALL core_job(void *arg) {
    core_value = (uint32_t)(uintptr_t)arg;
}

static void test_cores(void) {
    section("Cores");
    uint32_t n = zdos->cores->count();
    if (n < 2) {
        check(n == 1, "count: 1");
        return;
    }
    core_value = 0;
    bool started = zdos->cores->start(1, core_job, (void *)(uintptr_t)1234);
    if (started) zdos->cores->wait(1);
    check(!started || (core_value == 1234 && !zdos->cores->busy(1)), "a job on core 1 (or it takes none: the network's own)");
}

static void test_net(void) {
    section("Network");
    zdos_net_info info;
    zdos->net->info(&info);
    check(!(info.flags & ZDOS_NET_STARTED) || info.address[0] != 0, "info");
    zdos_net_route r;
    uint32_t routes = 0;
    while (routes < 1000 && zdos->net->route(routes, &r)) routes++;
    check(routes < 1000, "route: the list ends");
    const uint8_t lo[4] = {127, 0, 0, 1};
    zdos_ping_reply reply;
    check(zdos->net->ping(lo, 1, 32, 64, 1000, &reply) && reply.result == ZDOS_PING_REPLY, "ping 127.0.0.1");
    int32_t u = zdos->net->socket(ZDOS_SOCKET_DATAGRAM);
    zdos_net_address me = {{127, 0, 0, 1}, 0, 0};
    char got[8] = {0};
    bool ok = u >= 0 && zdos->net->bind(u, &me) && zdos->net->address(u, false, &me) && me.port != 0 &&
              zdos->net->send_to(u, "hello", 5, 0, &me) == 5 && zdos->net->recv_from(u, got, sizeof got, 0, 0) == 5 &&
              same(got, 5, "hello");
    if (u >= 0) zdos->files->close(u);
    check(ok, "UDP: a datagram to its own address");
}

static void test_screen(void) {
    section("Screen");
    /* Redirected: cursor and colors are ignored: */
    if (zdos->console->output_redirected()) {
        zdos_puts("  [skip] output is redirected, nothing to test on the screen\n");
        return;
    }
    zdos_pos size = zdos->console->screen_size();
    check(size.col >= 40 && size.row >= 20, "screen_size");
    zdos_pos here = zdos->console->get_cursor();
    zdos->console->set_cursor(30, here.row);
    zdos_pos moved = zdos->console->get_cursor();
    zdos->console->set_cursor(0, here.row);
    check(moved.col == 30 && moved.row == here.row, "set_cursor / get_cursor");
    zdos_puts("  ");
    for (uint8_t c = 0; c < 16; c++) {
        zdos->console->set_color(c, ZDOS_BLACK);
        zdos_puts("#");
    }
    color(ZDOS_LIGHT_GRAY);
    zdos_puts(" set_color: the 16 colors\n");
}

static void test_programs(void) {
    section("Programs");
    check(zdos->programs->exec(S("DEMO"), S("child")) == 42, "exec DEMO child returns its exit code 42");
    check(zdos->programs->exec(S("NO_SUCH_PROGRAM"), S("")) == -1, "exec of a missing program fails");
}

ZDOS_CALL unsigned char zdos_entry(const zdos_start *start) {
    zdos_init(start);
    color(ZDOS_WHITE);
    zdos_puts("DEMOC - zdos API test in C");
    color(ZDOS_LIGHT_GRAY);
    if (start->args_len > 0) {
        zdos_puts(" (arguments: ");
        put(start->args, start->args_len);
        zdos_puts(")");
    }
    zdos_puts("\n");

    test_time();
    test_memory();
    test_files();
    test_screen();
    test_programs();
    test_system();
    test_drives();
    test_keyb();
    test_tasks();
    test_cores();
    test_net();

    zdos_puts("\n");
    if (failures == 0) {
        color(ZDOS_LIGHT_GREEN);
        zdos_puts("All tests passed.");
    } else {
        color(ZDOS_LIGHT_RED);
        put_num((uint64_t)failures);
        zdos_puts(" test(s) failed.");
    }
    color(ZDOS_LIGHT_GRAY);
    zdos_puts("\n");
    return (unsigned char)failures;
}
