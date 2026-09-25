// SPDX-License-Identifier: CDDL-1.0
/*
 * This file and its contents are supplied under the terms of the
 * Common Development and Distribution License ("CDDL"), version 1.0.
 * You may only use this file in accordance with the terms of version
 * 1.0 of the CDDL.
 *
 * A full copy of the text of the CDDL should have accompanied this
 * source.  A copy of the CDDL is also available via the Internet at
 * https://opensource.org/license/CDDL-1.0.
 */

/*
 * Copyright (c) 2026 by the OpenZFS project.  All rights reserved.
 */

/*
 * Check that syncfs(2) reports a failed fsync(2).
 *
 * fsync_writeback_error <datafile> <fail-sentinel> <heal-sentinel>
 *
 * The program writes to datafile, creates fail-sentinel and waits
 * for the caller to remove it after breaking the device.  fsync
 * must then fail.  The program creates heal-sentinel, waits for the
 * caller to remove it after repairing the device and calls syncfs
 * twice.  The first call must report the error and the second must
 * not.
 *
 * Both sentinels must live outside the filesystem under test.
 * Exit 0 on success, 1 if syncfs misreports and 2 on any other
 * failure.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>

#define	BUFSZ	(128 * 1024)

static int
wait_gone(const char *path)
{
	int fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0644);

	if (fd < 0) {
		perror("open sentinel");
		return (-1);
	}
	(void) close(fd);
	while (access(path, F_OK) == 0)
		(void) usleep(100000);
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc != 4) {
		(void) fprintf(stderr,
		    "usage: %s <datafile> <fail-sentinel> <heal-sentinel>\n",
		    argv[0]);
		return (2);
	}

	const char *datafile = argv[1];
	const char *failsent = argv[2];
	const char *healsent = argv[3];

	int fd = open(datafile, O_RDWR | O_CREAT, 0644);
	if (fd < 0) {
		perror("open");
		return (2);
	}

	char *buf = malloc(BUFSZ);
	if (buf == NULL) {
		perror("malloc");
		(void) close(fd);
		return (2);
	}
	memset(buf, 0xab, BUFSZ);
	if (write(fd, buf, BUFSZ) != BUFSZ) {
		perror("write");
		free(buf);
		(void) close(fd);
		return (2);
	}
	free(buf);

	if (wait_gone(failsent) != 0) {
		(void) close(fd);
		return (2);
	}

	if (fsync(fd) == 0) {
		(void) fprintf(stderr, "fsync succeeded, nothing failed\n");
		(void) close(fd);
		return (2);
	}
	(void) fprintf(stderr, "fsync: %s\n", strerror(errno));

	if (wait_gone(healsent) != 0) {
		(void) close(fd);
		return (2);
	}

	/*
	 * errseq reports an error once per open file, so only the
	 * first syncfs returns it.
	 */
	int first = syncfs(fd);
	int firsterr = errno;
	int second = syncfs(fd);
	int seconderr = errno;

	(void) close(fd);

	if (first == 0) {
		(void) fprintf(stderr,
		    "syncfs reported success after a failed writeback\n");
		return (1);
	}
	(void) fprintf(stderr, "first syncfs: %s\n", strerror(firsterr));

	if (second != 0) {
		(void) fprintf(stderr,
		    "second syncfs also reported an error, %s\n",
		    strerror(seconderr));
		return (1);
	}

	(void) fprintf(stderr, "second syncfs clean, as errseq requires\n");
	return (0);
}
