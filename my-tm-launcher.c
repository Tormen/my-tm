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
/*
 * The uid allowed to run my-tm through this launcher, compiled in like the
 * path -- 0 everywhere it is installed. my-tm's suite builds a launcher with
 * its own uid here, so it can still exercise the argument pass-through that
 * the guard protects; `my-tm --install` never passes it.
 */
#ifndef MY_TM_RUN_UID
#define MY_TM_RUN_UID 0
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
	    "Runs ONLY as root, started by launchd: it passes every argument on, and\n"
	    "my-tm reads the file named by --config as shell, so running it as anyone\n"
	    "else would hand that access to them. --help and --version are open to all.\n"
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
	/*
	 * ROOT ONLY, past this point. The two answers above run no my-tm and use
	 * no grant, so anyone who can read this file may ask them -- comparing a
	 * deployed --version against a source is the documented way to spot a
	 * stale launcher. Running my-tm is different: every argument and the
	 * whole environment go through, my-tm reads the file named by --config
	 * (and $MY_TM_CONFIG) AS SHELL, and a launchd-started launcher is the one
	 * case where this program's Full Disk Access counts. Without this check,
	 * anyone who may execute the file can have launchd run their own shell
	 * code with that access. The file is root:<group> 0750, so that is its
	 * group -- a capability the group does not otherwise hold.
	 */
	if (getuid() != (uid_t)MY_TM_RUN_UID) {
		fprintf(stderr,
		    " !!! my-tm-launcher: runs only as uid %d, started by launchd -- not as uid %d\n"
		    "     (it holds Full Disk Access, which --help explains cannot be shared)\n",
		    (int)MY_TM_RUN_UID, (int)getuid());
		return 77;
	}
	argv[0] = (char *)MY_TM_PATH;
	execv(MY_TM_PATH, argv);
	perror("my-tm-launcher: cannot run " MY_TM_PATH);
	return 126;
}
