/*
 * my-tm-launcher -- runs ONE program, fixed when this file is compiled, with
 * the arguments it was given, and nothing else.
 *
 * It exists to hold macOS Full Disk Access for my-tm's LaunchDaemons. macOS
 * grants that access per program; the jobs would otherwise run /bin/dash,
 * and a grant on /bin/dash would cover every dash script on the Mac.
 *
 * Built by `my-tm --install` when JOBS_RUN_WITH_FULL_DISK_ACCESS=1: compiled,
 * then ad-hoc signed. The program path and the hash of this source are
 * compiled in, never written here:
 *     -DMY_TM_PATH='"/path/to/my-tm"' -DLAUNCHER_SOURCE_HASH='"<md5>"'
 * macOS ties the grant to that exact build, so a rebuild needs granting again.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#ifndef MY_TM_PATH
#error "build with -DMY_TM_PATH='\"/path/to/my-tm\"'"
#endif
#ifndef LAUNCHER_SOURCE_HASH
#define LAUNCHER_SOURCE_HASH "unknown"
#endif

static void explain(FILE *out)
{
	fprintf(out,
	    "usage: my-tm-launcher [--help] [--version] <MY-TM-ARGUMENTS>\n"
	    "\n"
	    "Runs %s with the arguments given, and nothing else.\n"
	    "It holds Full Disk Access for the my-tm LaunchDaemons, so the jobs can\n"
	    "look inside network volumes and verify backups. That access is granted in\n"
	    "System Settings > Privacy & Security > Full Disk Access.\n"
	    "Built and installed by `my-tm --install` (JOBS_RUN_WITH_FULL_DISK_ACCESS=1).\n",
	    MY_TM_PATH);
}

int main(int argc, char *argv[])
{
	if (argc == 1) {
		explain(stderr);
		return 64;
	}
	if (argc == 2 && strcmp(argv[1], "--help") == 0) {
		explain(stdout);
		return 0;
	}
	if (argc == 2 && strcmp(argv[1], "--version") == 0) {
		printf("my-tm-launcher (runs %s, source %s)\n", MY_TM_PATH, LAUNCHER_SOURCE_HASH);
		return 0;
	}
	argv[0] = (char *)MY_TM_PATH;
	execv(MY_TM_PATH, argv);
	perror("my-tm-launcher: cannot run " MY_TM_PATH);
	return 126;
}
