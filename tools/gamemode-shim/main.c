/*
 * wine-rosetta-shim — the ROSETTA_X87_PATH target that preserves macOS Game
 * Mode bundle identity across Wine's loader re-exec.
 *
 * Game Mode only recognises a process whose literal executable path is
 * <App>.app/Contents/MacOS/<file> (verified empirically on macOS 27: both the
 * exec path and its realpath must sit directly in Contents/MacOS). Wine's ntdll
 * re-execs every i386 image through $ROSETTA_X87_PATH with argv[1] set to its
 * ntdll-derived loader path in Contents/lib/wine/x86_64-unix/ — a path that
 * destroys that identity (dlls/ntdll/unix/loader.c, preloader_exec).
 *
 * This shim sits at Contents/MacOS/wine-rosetta-shim, rewrites argv[1] to the
 * physical loader copy at Contents/MacOS/wine-gamemode beside it, and execs the
 * real rosettax87 loader (also beside it). The final game process then runs
 * from Contents/MacOS and gamepolicyd identifies it as a game.
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

    char rosetta[PATH_MAX], loader[PATH_MAX];
    snprintf(rosetta, sizeof(rosetta), "%s/rosettax87", dir);
    snprintf(loader, sizeof(loader), "%s/wine-gamemode", dir);

    if (argc >= 2) argv[1] = loader;
    argv[0] = rosetta;
    execv(rosetta, argv);
    perror("wine-rosetta-shim: execv rosettax87");
    return 127;
}
