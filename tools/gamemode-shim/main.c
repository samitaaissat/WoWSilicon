/*
 * wine-rosetta-shim — the X87_SIDECAR_PATH target that preserves macOS Game
 * Mode bundle identity across Wine's loader re-exec.
 *
 * Game Mode only recognises a process whose literal executable path is
 * <App>.app/Contents/MacOS/<file> (verified empirically on macOS 27: both the
 * exec path and its realpath must sit directly in Contents/MacOS). Wine's ntdll
 * re-execs every i386 image through $X87_SIDECAR_PATH as
 * [sidecar, --cooperative, <loader>, <args>...] with the loader set to its
 * ntdll-derived path in Contents/lib/wine/x86_64-unix/ — a path that destroys
 * that identity (dlls/ntdll/unix/loader.c, preloader_exec; runtime patch 0002).
 *
 * This shim sits at Contents/MacOS/wine-rosetta-shim, rewrites the loader
 * argument to the physical copy at Contents/MacOS/wine-gamemode beside it, and
 * execs the real x87sidecar (also beside it, shipped inside the runtime
 * tarball). The sidecar keeps this pid — it execs the target itself and
 * double-forks its JIT server away — so the final game process runs
 * wine-gamemode from Contents/MacOS and gamepolicyd identifies it as a game.
 *
 * The legacy shape [shim, <loader>, <args>...] (a runtime without patch 0002,
 * reached via ROSETTA_X87_PATH) still execs the old rosettax87 loader, so this
 * shim binary keeps working if it ever ends up beside an older runtime.
 *
 * wine-gamemode must be the lib/wine/x86_64-unix/wine binary (loader/main.c):
 * only it carries the WINE_RESERVE/WINE_TOP_DOWN address-space reservation
 * segments a Wine process needs. It finds ntdll.so in its own directory, hence
 * the Contents/MacOS/ntdll.so symlink staged by the Makefile.
 */
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    char self[PATH_MAX];
    uint32_t size = sizeof(self);
    if (_NSGetExecutablePath(self, &size) != 0) return 127;

    char real[PATH_MAX];
    if (!realpath(self, real)) return 127;
    char *dir = dirname(real);

    char sidecar[PATH_MAX], rosetta[PATH_MAX], loader[PATH_MAX];
    snprintf(sidecar, sizeof(sidecar), "%s/x87sidecar", dir);
    snprintf(rosetta, sizeof(rosetta), "%s/rosettax87", dir);
    snprintf(loader, sizeof(loader), "%s/wine-gamemode", dir);

    if (argc >= 3 && strcmp(argv[1], "--cooperative") == 0) {
        argv[2] = loader;
        argv[0] = sidecar;
        execv(sidecar, argv);
        perror("wine-rosetta-shim: execv x87sidecar");
        return 127;
    }

    if (argc >= 2) argv[1] = loader;
    argv[0] = rosetta;
    execv(rosetta, argv);
    perror("wine-rosetta-shim: execv rosettax87");
    return 127;
}
