/*
 * THIS FILE IS A TEMPLATE — the factory generates sapi/cli/tebako_php_main.c
 * from it with @MOUNT_ROOT@ substituted (PhpBuild#write_fs_tu).
 *
 * The tebako php fs TU (translation unit): the runtime exe's real main(),
 * linked INTO the php cli binary (the ruby/python pattern — README's
 * LINKED-driver decision). php's own entry point (sapi/cli/php_cli.c's
 * main) is renamed php_cli_main at COMPILE time (the generated Makefile's
 * php_cli.lo rule gains -Dmain=php_cli_main — a build-file substitution,
 * never a source patch; "main" occurs in php_cli.c exactly once as the
 * function definition, everywhere else only inside a string literal or an
 * include filename, where a macro never expands). This TU provides main
 * and forwards to php_cli_main after the boot.
 *
 * The interpreter is UNPATCHED (no tamatebako php source factory exists,
 * so this factory fetches pristine php.net tarballs): php's own libc file
 * IO cannot see the driver's mounts. The visibility story is spec 22's
 * tier-1 preload interposition, composed in two process incarnations
 * (tebako-runtime-python's exact model):
 *
 *   1. the FIRST incarnation boots the driver in-process
 *      (tebako_driver_boot — mounts the env image from
 *      TEBAKO_RUNTIME_IMAGE and every --tebako-image payload triple,
 *      verifies the layout card, applies the jail, rewrites argv to the
 *      resolved entry, and arms the preload-shim injection env from the
 *      image's layout grant). A preload library binds only at exec, so —
 *   2. when the boot mounted anything, main re-execs ITSELF with the
 *      rewritten argv and the driver-armed env (LD_PRELOAD +
 *      TEBAKO_PRELOAD_SHIM + TEBAKO_TFS_MOUNTS). The shim's constructor
 *      re-mounts the serialized mount table in the child; the child
 *      (sentinel set) skips the boot and runs php_cli_main, whose libc IO
 *      the shim now serves from the VFS.
 *
 * Boot contract (exit codes are the driver's, surfaced unmodified — the
 * same named errors the ruby/python runtimes produce): TEBAKO_MOUNT_ROOT
 * malformed -> 65 (driver-validated pre-mount); ungranted override -> 78
 * (the layout pair check); a mounted image with no preload_shim grant ->
 * 78 (below: the interpreter would boot blind).
 *
 * Scope: the POSIX legs (linux ELF + macOS — the preload-shim tier 1
 * platforms). Windows (the spec 17 §7 materialize tier — there is no
 * preload tier on windows) arrives with its leg; this TU is written to
 * grow that branch the way tebako-runtime-python's tebako_python_main.c
 * carries it.
 */

/* glibc AND musl under -std=c11 (php's default cflags) hide
 * readlink/setenv behind feature-test macros; _GNU_SOURCE exposes them.
 * Must precede every system include. */
#if defined(__linux__)
#define _GNU_SOURCE
#endif

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h> /* _NSGetExecutablePath */
#endif

/* The spec-17 driver ABI (tamatebako/tebako crates/tebako-driver ffi.rs). */
extern int tebako_driver_boot(int *argc, char ***argv, const char *runtime_root);
extern const char *tebako_mount_point(void);
extern unsigned int tebako_driver_contract_version(void);

/* php's cli entry: sapi/cli/php_cli.c's main, renamed at compile time
 * (the header comment). */
extern int php_cli_main(int argc, char **argv);

/* The mount root this runtime was compiled against. OWNER: this factory
 * (php-src carries no patch literals to flow it from); the env image's
 * layout card declares the same value, emitted from the same constant in
 * the same build. */
static const char tebako_php_mount_root[] = "@MOUNT_ROOT@";

/* The re-exec sentinel (the header comment). */
#define TEBAKO_PHP_BOOTED "TEBAKO_PHP_BOOTED"

/* The running executable's own path for the re-exec: /proc on linux,
 * _NSGetExecutablePath on macOS. argv[0] as the last resort elsewhere
 * when it carries a path separator. A failure is a named error, never a
 * PATH guess. */
static int self_executable_path(char *buf, size_t cap, const char *argv0) {
#if defined(__linux__)
    ssize_t n = readlink("/proc/self/exe", buf, cap - 1);
    if (n <= 0 || (size_t)n >= cap - 1)
        return -1;
    buf[n] = '\0';
    return 0;
#elif defined(__APPLE__)
    /* _NSGetExecutablePath may return a symlink-laden spelling;
     * realpath resolves it (and normalizes into buf). */
    {
        char raw[PATH_MAX];
        uint32_t size = (uint32_t)sizeof raw;
        if (_NSGetExecutablePath(raw, &size) != 0)
            return -1;
        return realpath(raw, buf) != NULL ? 0 : -1;
    }
#else
    (void)cap;
    if (strchr(argv0, '/') != NULL && realpath(argv0, buf) != NULL)
        return 0;
    return -1;
#endif
}

int main(int argc, char **argv) {
    int rc;
    char version[16];

    /* The re-exec'd child: the preload shim is armed and its constructor
     * has re-mounted the mount table — straight to the interpreter. */
    if (getenv(TEBAKO_PHP_BOOTED) != NULL)
        return php_cli_main(argc, argv);

    rc = tebako_driver_boot(&argc, &argv, tebako_php_mount_root);
    if (rc != 0)
        return rc; /* the named loader error is already on stderr; nothing mounted */

    /* The runtime is authoritative for the contract it speaks (the ruby
     * driver's tebako_main behavior — the generic tebako_driver_boot
     * entry leaves the export to the caller); an inherited value is
     * always overwritten. */
    snprintf(version, sizeof version, "%u", tebako_driver_contract_version());
    setenv("TEBAKO_CONTRACT_VERSION", version, 1);

    /* php needs no analog of PYTHONHOME: the interpreter's compiled-in
     * paths (the include_path default, extension_dir) spell the baked
     * mount root, and the shim serves the VFS at that path in the child.
     * TEBAKO_MOUNT_ROOT's validated override is the driver's own affair —
     * the mounts, not php's configuration, move. */

    if (getenv("TEBAKO_TFS_MOUNTS") == NULL)
        return php_cli_main(argc, argv); /* bare boot — nothing mounted */

    if (getenv("TEBAKO_PRELOAD_SHIM") == NULL) {
        fputs("tebako-php: the env image declares no preload shim (lib/tebako/layout.yaml) — "
              "an unpatched php cannot read the mounted filesystem without it; rebuild the "
              "runtime with a link unit that ships libtfs_preload\n", stderr);
        return 78;
    }

    {
        char self[PATH_MAX];
        if (self_executable_path(self, sizeof self, argv[0]) != 0) {
            fputs("tebako-php: cannot resolve the interpreter's own path for the "
                  "preload-shim re-exec\n", stderr);
            return 74;
        }
        setenv(TEBAKO_PHP_BOOTED, "1", 1);
        execv(self, argv);
        perror("tebako-php: re-exec under the preload shim failed");
        return 74;
    }
}
