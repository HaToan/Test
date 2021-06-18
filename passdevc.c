/*
 * passdev.c - waits for a given device to appear, mounts it and reads a
 *             key from it which is piped to stdout.
 *
 * Copyright (C) 2008   David Härdeman <david@hardeman.nu>
 *
 * This package is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This package is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this package; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
 */


#define _BSD_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mount.h>

static bool do_debug = false;

static void
debug(const char *fmt, ...)
{
	va_list ap;

	if (!do_debug)
		return;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
}

int
main(int argc, char **argv, char **envp)
{
	char *debugval;
	char *filepath;
	struct stat st;
	char *keypath;
	int fd;
	size_t toread;
	size_t bytesread;
	char *keybuffer;
	size_t towrite;
	size_t byteswritten;
	ssize_t bytes;
	char *to;
	int timeout = 0;
	bool do_timeout = false;

	/* We only take one argument */
	if (argc != 2) {
		fprintf(stderr, "Incorrect number of arguments\n");
		goto error;
	}

	/* If DEBUG=1 is in the environment, enable debug messages */
	debugval = getenv("DEBUG");
	if (debugval && atoi(debugval) > 0)
		do_debug = true;

	/* Split string into device and path (and timeout) */
	filepath = argv[1];
    if( access( filepath, F_OK ) != 0 ) {
		fprintf(stderr, "file doesn't exist\n");
		goto error;
	}

    /* Generate the full path to the keyfile */
	keypath = malloc( strlen(filepath) + 1);
	if (!keypath) {
		fprintf(stderr, "Failed to allocate memory\n");
		goto error;
	}
	sprintf(keypath, "%s", filepath);

    /* Get the size of the keyfile */
	if (stat(keypath, &st)) {
		fprintf(stderr, "Unable to stat file\n");
		goto error_free;
	}

    /* Check the size of the keyfile */
	if (st.st_size < 0) {
		fprintf(stderr, "Invalid keyfile size\n");
		goto error_free;
	}

    /* Open the keyfile */
	if ((fd = open(keypath, O_RDONLY)) < 0) {
		fprintf(stderr, "Failed to open keyfile\n");
		goto error_free;
	}

	toread = (size_t)st.st_size;

	/* Allocate a buffer for the keyfile contents */
	keybuffer = malloc(toread);
	if (!keybuffer) {
		fprintf(stderr, "Failed to allocate memory\n");
		goto error_close;
		exit(EXIT_FAILURE);
	}

	/* Read the keyfile */
	bytesread = 0;
	while (bytesread < toread) {
		bytes = read(fd, keybuffer + bytesread, toread - bytesread);
		if (bytes <= 0) {
			fprintf(stderr, "Failed to read entire key\n");
			goto error_keybuffer;
		}
		bytesread += bytes;
	}

	/* Clean up */
	close(fd);
	free(keypath);

    /* Decrypt */

	/* Write result */
	byteswritten = 0;
	towrite = toread;
	while (byteswritten < towrite) {
		bytes = write(STDOUT_FILENO, keybuffer + byteswritten,
			      towrite - byteswritten);
		if (bytes <= 0) {
			fprintf(stderr, "Failed to write entire key\n");
			memset(keybuffer, 0, toread);
			free(keybuffer);
			goto error;
		}
		byteswritten += bytes;
	}

	/* Clean up */
	memset(keybuffer, 0, toread);
	free(keybuffer);

	/* Done */
	exit(EXIT_SUCCESS);

	/* Error handling */
error_keybuffer:
	memset(keybuffer, 0, toread);
	free(keybuffer);
error_close:
	close(fd);
error_free:
	free(keypath);
error:
	exit(EXIT_FAILURE);
}
