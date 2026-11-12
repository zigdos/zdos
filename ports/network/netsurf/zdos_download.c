/* Downloads for the framebuffer frontend, which has none: a file
 * NetSurf can't show is fetched again by FETCH, in the background,
 * into %HOME%\Downloads (C:\TEMP without HOME). create returns NULL,
 * so NetSurf drops its own transfer. */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "zdos.h"

#include "utils/errors.h"
#include "utils/nsurl.h"
#include "desktop/download.h"
#include "desktop/gui_internal.h"
#include "netsurf/download.h"
#include "netsurf/window.h"

/* A name FETCH's arguments and FAT take: other bytes become _ */
static void clean_name(const char *from, char *to, size_t size)
{
	size_t n = 0;
	for (; from != NULL && *from != '\0' && n + 1 < size; from++) {
		char c = *from;
		bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
		to[n++] = ok ? c : '_';
	}
	to[n] = '\0';
	if (n == 0 || strcmp(to, ".") == 0 || strcmp(to, "..") == 0)
		snprintf(to, size, "download");
}

/* dir\name, or dir\stem-2.ext ... where that exists */
static void free_path(const char *dir, const char *name, char *out, size_t size)
{
	struct stat st;
	const char *dot = strrchr(name, '.');
	int stem = dot != NULL && dot != name ? (int)(dot - name) : (int)strlen(name);
	const char *ext = name + stem;
	snprintf(out, size, "%s\\%s", dir, name);
	for (int i = 2; i < 1000 && stat(out, &st) == 0; i++)
		snprintf(out, size, "%s\\%.*s-%d%s", dir, stem, name, i, ext);
}

static void status(struct gui_window *parent, const char *text)
{
	if (parent != NULL && guit->window->set_status != NULL)
		guit->window->set_status(parent, text);
}

static struct gui_download_window *
zdos_download_create(download_context *ctx, struct gui_window *parent)
{
	nsurl *url = download_context_get_url(ctx);
	enum nsurl_scheme_type scheme = nsurl_get_scheme_type(url);
	char dir[256], name[96], path[384], args[2048], msg[512];

	if (scheme != NSURL_SCHEME_HTTP && scheme != NSURL_SCHEME_HTTPS) {
		status(parent, "Download: only http and https links");
		return NULL;
	}
	const char *home = getenv("HOME");
	if (home != NULL && *home != '\0') {
		snprintf(dir, sizeof dir, "%s\\Downloads", home);
		mkdir(dir, 0755);
	} else {
		snprintf(dir, sizeof dir, "C:\\TEMP");
	}
	clean_name(download_context_get_filename(ctx), name, sizeof name);
	free_path(dir, name, path, sizeof path);

	const char *link = nsurl_access(url);
	int len = snprintf(args, sizeof args, "-o %s %s", path, link);
	if (len < 0 || (size_t)len >= sizeof args || strchr(link, ' ') != NULL) {
		status(parent, "Download: link too long");
		return NULL;
	}
	/* FETCH's messages would draw over the page: */
	zdos_spawn_options opt = {
		.size = sizeof opt, .priority = -1, .input = ZDOS_NO_STREAM,
		.output = ZDOS_NUL_STREAM, .err = ZDOS_NUL_STREAM, .term = -1,
	};
	if (zdos->tasks->spawn_ex("FETCH", 5, args, (size_t)len, &opt) < 0) {
		status(parent, "Download: FETCH not found");
		return NULL;
	}
	snprintf(msg, sizeof msg, "Downloading to %s", path);
	status(parent, msg);
	return NULL;
}

static nserror zdos_download_data(struct gui_download_window *dw,
				  const char *data, unsigned int size)
{
	return NSERROR_OK;
}

static void zdos_download_error(struct gui_download_window *dw,
				const char *error_msg)
{
}

static void zdos_download_done(struct gui_download_window *dw)
{
}

struct gui_download_table zdos_download_table = {
	.create = zdos_download_create,
	.data = zdos_download_data,
	.error = zdos_download_error,
	.done = zdos_download_done,
};
