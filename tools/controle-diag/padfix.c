/*
 * padfix - corrige controles Xbox que o Android mapeia com Generic.kl.
 *
 * Roda como usuario "shell" (via adb, sem root). Captura com exclusividade
 * (EVIOCGRAB) o controle original e cria, via /dev/uinput, um clone identico
 * mas com vendor/product de um controle Xbox oficial. O Android entao aplica
 * o keylayout correto (analogico direito em Z/RZ, gatilhos em LTRIGGER/RTRIGGER).
 *
 * Uso: padfix <vid_origem_hex> <pid_origem_hex> <vid_clone_hex> <pid_clone_hex>
 * Fica rodando; se o controle for desconectado, espera ele voltar.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS_LONG (8 * sizeof(unsigned long))
#define NLONGS(n) (((n) + BITS_LONG - 1) / BITS_LONG)
#define TEST(b, arr) (((arr)[(b) / BITS_LONG] >> ((b) % BITS_LONG)) & 1UL)

static volatile sig_atomic_t stop_flag = 0;
static void on_sig(int s) { (void)s; stop_flag = 1; }

static int find_source(unsigned vid, unsigned pid, char *path, size_t len) {
    DIR *d = opendir("/dev/input");
    struct dirent *e;
    if (!d) return -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5)) continue;
        snprintf(path, len, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        struct input_id id;
        unsigned long keys[NLONGS(KEY_CNT)] = {0};
        if (ioctl(fd, EVIOCGID, &id) == 0 && id.vendor == vid && id.product == pid &&
            id.bustype != BUS_VIRTUAL &&
            ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys) >= 0 && TEST(BTN_GAMEPAD, keys)) {
            closedir(d);
            return fd;
        }
        close(fd);
    }
    closedir(d);
    return -1;
}

static int make_clone(int src, unsigned cvid, unsigned cpid) {
    unsigned long keys[NLONGS(KEY_CNT)] = {0}, abs[NLONGS(ABS_CNT)] = {0};
    int ui = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (ui < 0) { perror("padfix: abrir /dev/uinput"); return -1; }
    ioctl(src, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
    ioctl(src, EVIOCGBIT(EV_ABS, sizeof(abs)), abs);
    ioctl(ui, UI_SET_EVBIT, EV_KEY);
    ioctl(ui, UI_SET_EVBIT, EV_ABS);
    for (int i = 0; i < KEY_CNT; i++)
        if (TEST(i, keys)) ioctl(ui, UI_SET_KEYBIT, i);
    for (int i = 0; i < ABS_CNT; i++) {
        if (!TEST(i, abs)) continue;
        struct uinput_abs_setup as;
        memset(&as, 0, sizeof(as));
        as.code = i;
        if (ioctl(src, EVIOCGABS(i), &as.absinfo) < 0) continue;
        ioctl(ui, UI_SET_ABSBIT, i);
        if (ioctl(ui, UI_ABS_SETUP, &as) < 0) perror("padfix: UI_ABS_SETUP");
    }
    struct uinput_setup us;
    memset(&us, 0, sizeof(us));
    us.id.bustype = BUS_USB;
    us.id.vendor = cvid;
    us.id.product = cpid;
    us.id.version = 0x0408;
    snprintf(us.name, sizeof(us.name), "Xbox Controller (padfix)");
    if (ioctl(ui, UI_DEV_SETUP, &us) < 0 || ioctl(ui, UI_DEV_CREATE) < 0) {
        perror("padfix: criar dispositivo uinput");
        close(ui);
        return -1;
    }
    return ui;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "uso: %s vid pid vid_clone pid_clone (hex)\n", argv[0]);
        return 2;
    }
    unsigned vid = strtoul(argv[1], 0, 16), pid = strtoul(argv[2], 0, 16);
    unsigned cvid = strtoul(argv[3], 0, 16), cpid = strtoul(argv[4], 0, 16);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sig;
    sigaction(SIGINT, &sa, 0);
    sigaction(SIGTERM, &sa, 0);
    signal(SIGHUP, SIG_IGN);
    setvbuf(stdout, 0, _IOLBF, 0);

    int waiting_msg = 0;
    while (!stop_flag) {
        char path[300];
        int src = find_source(vid, pid, path, sizeof(path));
        if (src < 0) {
            if (!waiting_msg) { printf("padfix: aguardando controle %04x:%04x...\n", vid, pid); waiting_msg = 1; }
            sleep(1);
            continue;
        }
        waiting_msg = 0;
        fcntl(src, F_SETFL, fcntl(src, F_GETFL) & ~O_NONBLOCK);
        int ui = make_clone(src, cvid, cpid);
        if (ui < 0) { close(src); return 1; }
        if (ioctl(src, EVIOCGRAB, 1) < 0) {
            perror("padfix: EVIOCGRAB (captura exclusiva)");
            ioctl(ui, UI_DEV_DESTROY);
            return 1;
        }
        printf("padfix: ATIVO %s (%04x:%04x) -> clone %04x:%04x\n", path, vid, pid, cvid, cpid);
        struct input_event ev;
        while (!stop_flag) {
            ssize_t n = read(src, &ev, sizeof(ev));
            if (n != sizeof(ev)) {
                if (n < 0 && errno == EINTR) continue;
                break; /* controle desconectado */
            }
            if (ev.type == EV_KEY || ev.type == EV_ABS || ev.type == EV_SYN)
                if (write(ui, &ev, sizeof(ev)) < 0 && errno != EAGAIN) break;
        }
        ioctl(src, EVIOCGRAB, 0);
        ioctl(ui, UI_DEV_DESTROY);
        close(ui);
        close(src);
        printf("padfix: controle desconectado.\n");
    }
    printf("padfix: encerrado.\n");
    return 0;
}
