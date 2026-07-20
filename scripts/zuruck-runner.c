/*
 * zuruck-runner — dedicated launcher for scheduled restic backups (macOS).
 *
 * WHY THIS EXISTS
 *   A launchd backup job needs Full Disk Access to read protected folders
 *   (Desktop/Documents/Downloads/Pictures/…). macOS attributes a file-access
 *   request to the job's *responsible process* — i.e. ProgramArguments[0].
 *   If that were /bin/bash, we'd have to grant FDA to system-wide bash, which
 *   would then bless EVERY bash script any launchd job runs. Instead we grant
 *   FDA to this one dedicated binary.
 *
 * WHY fork()+exec() AND NOT execv()
 *   TCC evaluates the code signature of the process that stays resident as the
 *   responsible process. If we execv()'d into bash, this process image would
 *   BECOME bash and TCC would judge bash's identity — back to square one. By
 *   forking the interpreter as a child and remaining alive as its parent, THIS
 *   binary stays the responsible process, so the FDA grant applies to it alone.
 *
 * WHY IT'S SAFE TO GRANT
 *   The backup script path (BACKUP_SH) and interpreter (INTERP) are baked in at
 *   compile time. This binary can only ever run the zuruck backup; it is not a
 *   general "run anything with FDA" tool. It forwards its own argv to the script
 *   (e.g. --forget --tag scheduled --dry-run), nothing more.
 *
 * NOTE ON REBUILDS
 *   FDA is keyed on the binary's code hash. Rebuilding this file changes the
 *   hash and INVALIDATES the grant (you'd re-add it). That's rare: all the
 *   backup logic lives in backup.sh (a script), so this binary almost never
 *   needs recompiling.
 *
 * Build (see scripts/install-schedule.sh --build-runner):
 *   clang -O2 -Wall -Wextra -o zuruck-runner zuruck-runner.c \
 *       -DBACKUP_SH="\"/abs/path/backup.sh\"" -DINTERP="\"/bin/bash\""
 *   codesign -s - -i com.zuruck.runner -f zuruck-runner
 */
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/wait.h>

#ifndef INTERP
#define INTERP "/bin/bash"
#endif
#ifndef BACKUP_SH
#define BACKUP_SH "/nonexistent/backup.sh" /* must be overridden at build time */
#endif

int main(int argc, char **argv) {
	/* argv for the child: INTERP BACKUP_SH <forwarded args...> NULL */
	char **args = calloc((size_t)argc + 3, sizeof(char *));
	if (!args) { perror("zuruck-runner: calloc"); return 127; }
	int i = 0;
	args[i++] = (char *)INTERP;
	args[i++] = (char *)BACKUP_SH;
	for (int j = 1; j < argc; j++) args[i++] = argv[j];
	args[i] = NULL;

	pid_t pid = fork();
	if (pid < 0) { perror("zuruck-runner: fork"); return 127; }
	if (pid == 0) {
		execv(INTERP, args);
		perror("zuruck-runner: execv");
		_exit(127);
	}

	int status = 0;
	if (waitpid(pid, &status, 0) < 0) { perror("zuruck-runner: waitpid"); return 127; }
	if (WIFEXITED(status))   return WEXITSTATUS(status);
	if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
	return 1;
}
