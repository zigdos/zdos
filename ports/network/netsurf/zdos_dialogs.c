/* Downloads and file uploads for the framebuffer frontend, which has
 * neither of them: small windows in its look (frame grey, outlined
 * text, text buttons) over the page.
 * DOWNLOAD: NetSurf's own transfer into %HOME%\Downloads (without
 * HOME C:\TEMP), with the name, bytes, a bar and Cancel.
 * UPLOAD: a file chooser for <input type=file>: folders and files of a
 * folder, a path to type, OK and Cancel. */
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include <libnsfb.h>
#include <libnsfb_event.h>
#include <libnsfb_plot.h>
#include <nsutils/time.h>

#include "utils/errors.h"
#include "utils/nsoption.h"
#include "utils/nsurl.h"
#include "desktop/download.h"
#include "desktop/gui_internal.h"
#include "netsurf/browser_window.h"
#include "netsurf/download.h"
#include "netsurf/layout.h"
#include "netsurf/plotters.h"
#include "netsurf/misc.h"
#include "netsurf/window.h"

#include "framebuffer/gui.h"
#include "framebuffer/fbtk.h"
#include "framebuffer/framebuffer.h"
#include "framebuffer/image_data.h"
#include "framebuffer/fbtk/widget.h"

#include "zdos.h"

extern fbtk_widget_t *fbtk; /* gui.c: the root */

/* The version for ZDOS: NetSurf's, read by Makefile.config from
 * desktop/version.c and expanded before ZDOS_FILE_VERSION's # */
#define NS_FILE_VERSION(major, minor) ZDOS_FILE_VERSION(major, minor, 0, 0)
#define NS_FILE_VERSION_OF(major, minor) NS_FILE_VERSION(major, minor)
NS_FILE_VERSION_OF(ZDOS_NS_MAJOR, ZDOS_NS_MINOR);

/* For gui.c (dialogs-zdos.patch): */
void zdos_dialogs_keep_on_top(void);
void zdos_file_gadget_open(struct gui_window *gw, struct hlcache_handle *hl,
			   struct form_control *gadget);

#define SELECTED_COLOUR 0xFFFED5B4 /* light blue: 0xAABBGGRR */
#define BAR_COLOUR 0xFFC07830
#define LIGHT_EDGE FB_COLOUR_WHITE
#define DARK_EDGE 0xFF808080
#define MAX_OPEN 8

/* COMMON */

/* Open windows: drawn again after the page (keep_on_top) */
static fbtk_widget_t *open_windows[MAX_OPEN];

/* A row's height: the toolbar's, less its padding */
static int row_height(void)
{
	int h = nsoption_int(fb_toolbar_size) - 6;
	return h < 20 ? 20 : h;
}

static bool inside(fbtk_widget_t *w, fbtk_widget_t *win)
{
	for (; w != NULL; w = w->parent)
		if (w == win)
			return true;
	return false;
}

/* The arrow over the dialog's parts, not the page's last pointer */
static void arrow_over(fbtk_widget_t *w)
{
	fbtk_set_handler(w, FBTK_CBT_POINTERENTER, fbtk_set_ptr, &pointer_image);
}

static fbtk_widget_t *open_window(int w, int h)
{
	int rw = fbtk_get_width(fbtk), rh = fbtk_get_height(fbtk);
	int n = 0, x, y;
	fbtk_widget_t *win;

	if (w > rw - 8)
		w = rw - 8;
	if (h > rh - 8)
		h = rh - 8;
	for (int i = 0; i < MAX_OPEN; i++)
		if (open_windows[i] != NULL)
			n++;
	/* each further one a step down and right */
	x = (rw - w) / 2 + n * row_height();
	y = (rh - h) / 2 + n * row_height();
	if (x + w > rw)
		x = rw - w;
	if (y + h > rh)
		y = rh - h;

	win = fbtk_create_window(fbtk, x, y, w, h, FB_FRAME_COLOUR);
	if (win == NULL)
		return NULL;
	/* fbtk's windows start hidden */
	fbtk_set_mapping(win, true);
	arrow_over(win);
	/* a black edge */
	arrow_over(fbtk_create_fill(win, 0, 0, w, 1, FB_COLOUR_BLACK));
	arrow_over(fbtk_create_fill(win, 0, h - 1, w, 1, FB_COLOUR_BLACK));
	arrow_over(fbtk_create_fill(win, 0, 0, 1, h, FB_COLOUR_BLACK));
	arrow_over(fbtk_create_fill(win, w - 1, 0, 1, h, FB_COLOUR_BLACK));
	for (int i = 0; i < MAX_OPEN; i++) {
		if (open_windows[i] == NULL) {
			open_windows[i] = win;
			break;
		}
	}
	fbtk_request_redraw(win);
	return win;
}

static void close_window(fbtk_widget_t *win)
{
	fbtk_widget_t *root = fbtk_get_root_widget(fbtk);

	for (int i = 0; i < MAX_OPEN; i++)
		if (open_windows[i] == win)
			open_windows[i] = NULL;
	/* Nothing of fbtk's may point into it once gone */
	if (inside(root->u.root.input, win) && window_list != NULL)
		fbtk_set_focus(window_list->browser);
	if (inside(root->u.root.input, win))
		root->u.root.input = NULL;
	if (inside(root->u.root.caret.owner, win))
		fbtk_set_caret(root->u.root.caret.owner, false, 0, 0, 0, NULL);
	if (inside(root->u.root.prev, win))
		root->u.root.prev = NULL;
	if (inside(root->u.root.grabbed, win))
		root->u.root.grabbed = NULL;
	fbtk_destroy_widget(win);
	fbtk_request_redraw(fbtk);
}

/* gui.c, before each redraw: a page drawn again would cover them */
void zdos_dialogs_keep_on_top(void)
{
	if (!fbtk_get_redraw_pending(fbtk))
		return;
	for (int i = MAX_OPEN - 1; i >= 0; i--)
		if (open_windows[i] != NULL)
			fbtk_request_redraw(open_windows[i]);
}

static fbtk_widget_t *label(fbtk_widget_t *win, int x, int y, int w, int h,
			    const char *text)
{
	fbtk_widget_t *t = fbtk_create_text(win, x, y, w, h, FB_FRAME_COLOUR,
					    FB_COLOUR_BLACK, false);
	fbtk_set_text(t, text);
	arrow_over(t);
	return t;
}

/* A button as the page's: white top and left edges, grey bottom and
 * right ones, the text in the middle, the page's size (fbtk's own has
 * edges of the window's grey and smaller text at the left) */
static int button_redraw(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	fbtk_widget_t *root = fbtk_get_root_widget(widget);
	nsfb_t *fb = root->u.root.fb;
	nsfb_bbox_t bbox, edge;
	plot_font_style_t style = {
		.family = PLOT_FONT_FAMILY_SANS_SERIF,
		.weight = 400,
		.flags = FONTF_NONE,
		.background = widget->bg,
		.foreground = widget->fg,
	};
	struct redraw_context ctx = {
		.interactive = true,
		.background_images = true,
		.plot = &fb_plotters,
	};
	int fh = widget->height * 2 / 3, tw = 0;

	(void)cbi;
	fbtk_get_bbox(widget, &bbox);
	nsfb_claim(fb, &bbox);
	nsfb_plot_rectangle_fill(fb, &bbox, widget->bg);
	edge = (nsfb_bbox_t){ bbox.x0, bbox.y0, bbox.x1, bbox.y0 + 1 };
	nsfb_plot_rectangle_fill(fb, &edge, LIGHT_EDGE);
	edge = (nsfb_bbox_t){ bbox.x0, bbox.y0, bbox.x0 + 1, bbox.y1 };
	nsfb_plot_rectangle_fill(fb, &edge, LIGHT_EDGE);
	edge = (nsfb_bbox_t){ bbox.x0, bbox.y1 - 1, bbox.x1, bbox.y1 };
	nsfb_plot_rectangle_fill(fb, &edge, DARK_EDGE);
	edge = (nsfb_bbox_t){ bbox.x1 - 1, bbox.y0, bbox.x1, bbox.y1 };
	nsfb_plot_rectangle_fill(fb, &edge, DARK_EDGE);

	if (widget->u.text.text != NULL) {
		/* points from pixels, as fbtk's text: 72 per FBTK_DPI */
		style.size = fh * PLOT_STYLE_SCALE * 72 / FBTK_DPI;
		guit->layout->width(&style, widget->u.text.text,
				    widget->u.text.len, &tw);
		/* baseline 3/4 down the font, the font in the middle */
		ctx.plot->text(&ctx, &style,
			       bbox.x0 + (widget->width - tw) / 2,
			       bbox.y0 + (widget->height - fh) / 2 + fh * 3 / 4 + 1,
			       widget->u.text.text, widget->u.text.len);
	}
	nsfb_update(fb, &bbox);
	return 0;
}

static fbtk_widget_t *button(fbtk_widget_t *win, int x, int y, int w, int h,
			     const char *text, fbtk_callback click, void *pw)
{
	fbtk_widget_t *b = fbtk_create_text_button(win, x, y, w, h, FB_FRAME_COLOUR,
						   FB_COLOUR_BLACK, click, pw);
	fbtk_set_handler(b, FBTK_CBT_REDRAW, button_redraw, NULL);
	fbtk_set_text(b, text);
	return b;
}

/* A mouse button let go: a button's click */
static bool released(fbtk_callback_info *cbi)
{
	return cbi->event != NULL && cbi->event->type == NSFB_EVENT_KEY_UP &&
		cbi->event->value.keycode == NSFB_KEY_MOUSE_1;
}

static void status(struct gui_window *gw, const char *text)
{
	if (gw == NULL)
		gw = window_list;
	if (gw != NULL && guit->window->set_status != NULL)
		guit->window->set_status(gw, text);
}

static void size_text(unsigned long long n, char *out, size_t size)
{
	if (n < 1024)
		snprintf(out, size, "%llu bytes", n);
	else if (n < 1024 * 1024)
		snprintf(out, size, "%.1f KB", n / 1024.0);
	else if (n < 1024ull * 1024 * 1024)
		snprintf(out, size, "%.1f MB", n / (1024.0 * 1024));
	else
		snprintf(out, size, "%.2f GB", n / (1024.0 * 1024 * 1024));
}

/* DOWNLOAD */

struct gui_download_window {
	download_context *ctx;
	struct gui_window *parent;
	fbtk_widget_t *window, *progress, *bar;
	int bar_x, bar_y, bar_w, bar_h;
	FILE *file;
	char path[384];
	unsigned long long got, total, shown;
	bool closing;
};

/* A name FAT takes: other bytes become _ */
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

static void show_progress(struct gui_download_window *dw)
{
	char got[32], total[32], text[96];
	int w = 0;

	size_text(dw->got, got, sizeof got);
	if (dw->total > 0) {
		size_text(dw->total, total, sizeof total);
		snprintf(text, sizeof text, "%s of %s", got, total);
		w = (int)((dw->got > dw->total ? dw->total : dw->got) *
			  (unsigned long long)dw->bar_w / dw->total);
	} else {
		snprintf(text, sizeof text, "%s", got);
	}
	fbtk_set_text(dw->progress, text);
	/* the bar: hidden while empty (a width of 0 is the parent's) */
	fbtk_set_mapping(dw->bar, w > 0);
	if (w > 0) {
		fbtk_set_pos_and_size(dw->bar, dw->bar_x, dw->bar_y, w, dw->bar_h);
		fbtk_request_redraw(dw->bar);
	}
	dw->shown = dw->got;
}

/* Later, from the scheduler: not inside NetSurf's own callbacks */
static void download_finish(void *p)
{
	struct gui_download_window *dw = p;
	close_window(dw->window);
	download_context_destroy(dw->ctx);
	free(dw);
}

static void download_end(struct gui_download_window *dw, bool keep, const char *msg)
{
	if (dw->closing)
		return;
	dw->closing = true;
	if (dw->file != NULL) {
		if (fclose(dw->file) != 0)
			keep = false;
		dw->file = NULL;
	}
	if (!keep)
		remove(dw->path);
	status(dw->parent, msg);
	guit->misc->schedule(0, download_finish, dw);
}

static int download_cancel(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct gui_download_window *dw = cbi->context;
	if (!released(cbi) || dw->closing)
		return 0;
	download_context_abort(dw->ctx);
	download_end(dw, false, "Download cancelled");
	return 0;
}

static struct gui_download_window *
zdos_download_create(download_context *ctx, struct gui_window *parent)
{
	struct gui_download_window *dw;
	char dir[256], name[96], text[160];
	int h = row_height(), pad = h / 2, w, y;

	const char *home = getenv("HOME");
	if (home != NULL && *home != '\0') {
		snprintf(dir, sizeof dir, "%s\\Downloads", home);
		mkdir(dir, 0755);
	} else {
		snprintf(dir, sizeof dir, "C:\\TEMP");
	}

	dw = calloc(1, sizeof *dw);
	if (dw == NULL)
		return NULL;
	dw->ctx = ctx;
	dw->parent = parent;
	dw->total = download_context_get_total_length(ctx);
	clean_name(download_context_get_filename(ctx), name, sizeof name);
	free_path(dir, name, dw->path, sizeof dw->path);
	dw->file = fopen(dw->path, "wb");
	if (dw->file == NULL) {
		snprintf(text, sizeof text, "Download: cannot write %s", dw->path);
		status(parent, text);
		free(dw);
		return NULL;
	}

	w = h * 18;
	dw->window = open_window(w, h * 4 + pad * 4);
	if (dw->window == NULL) {
		fclose(dw->file);
		remove(dw->path);
		free(dw);
		return NULL;
	}
	w = fbtk_get_width(dw->window);
	y = pad;
	snprintf(text, sizeof text, "Downloading %s", dw->path);
	label(dw->window, pad, y, w - pad * 2, h, text);
	y += h + pad / 2;
	dw->progress = label(dw->window, pad, y, w - pad * 2, h, "");
	y += h + pad / 2;
	/* the bar: a white outlined field, filled from the left */
	arrow_over(fbtk_create_text(dw->window, pad, y, w - pad * 2, h,
				    FB_COLOUR_WHITE, FB_COLOUR_BLACK, true));
	dw->bar_x = pad + 1;
	dw->bar_y = y + 1;
	dw->bar_w = w - pad * 2 - 2;
	dw->bar_h = h - 2;
	dw->bar = fbtk_create_fill(dw->window, dw->bar_x, dw->bar_y, 1,
				   dw->bar_h, BAR_COLOUR);
	arrow_over(dw->bar);
	y += h + pad;
	button(dw->window, w - pad - h * 4, y, h * 4, h, "Cancel",
	       download_cancel, dw);
	show_progress(dw);
	return dw;
}

static nserror zdos_download_data(struct gui_download_window *dw,
				  const char *data, unsigned int size)
{
	if (dw->closing)
		return NSERROR_OK;
	if (fwrite(data, 1, size, dw->file) != size) {
		char text[448];
		snprintf(text, sizeof text, "Download: cannot write %s", dw->path);
		download_end(dw, false, text);
		return NSERROR_SAVE_FAILED;
	}
	dw->got += size;
	/* the numbers: every 32 KB */
	if (dw->got - dw->shown >= 32768)
		show_progress(dw);
	return NSERROR_OK;
}

static void zdos_download_error(struct gui_download_window *dw,
				const char *error_msg)
{
	char text[256];
	snprintf(text, sizeof text, "Download failed: %s",
		 error_msg != NULL ? error_msg : "error");
	download_end(dw, false, text);
}

static void zdos_download_done(struct gui_download_window *dw)
{
	char text[448];
	snprintf(text, sizeof text, "Saved to %s", dw->path);
	download_end(dw, true, text);
}

struct gui_download_table zdos_download_table = {
	.create = zdos_download_create,
	.data = zdos_download_data,
	.error = zdos_download_error,
	.done = zdos_download_done,
};

/* UPLOAD */

#define MAX_ROWS 16

struct entry {
	char *name;
	bool is_dir;
};

static struct upload {
	struct browser_window *bw;
	struct hlcache_handle *hl;
	struct form_control *gadget;
	fbtk_widget_t *window, *path, *vscroll;
	fbtk_widget_t *rows[MAX_ROWS];
	int nrows;
	char dir[512]; /* C:/A/B; a drive's top: C:/ */
	struct entry *entries;
	int count, top, selected;
	uint64_t last_click;
	int last_row;
	bool closing;
} *upload;

static void free_entries(struct upload *u)
{
	for (int i = 0; i < u->count; i++)
		free(u->entries[i].name);
	free(u->entries);
	u->entries = NULL;
	u->count = 0;
}

static int entry_order(const void *a, const void *b)
{
	const struct entry *x = a, *y = b;
	if (strcmp(x->name, "..") == 0)
		return -1;
	if (strcmp(y->name, "..") == 0)
		return 1;
	if (x->is_dir != y->is_dir)
		return x->is_dir ? -1 : 1;
	return strcasecmp(x->name, y->name);
}

static bool is_drive_top(const char *dir)
{
	return dir[0] != '\0' && dir[1] == ':' && (dir[2] == '\0' ||
		(dir[2] == '/' && dir[3] == '\0'));
}

static void join(const char *dir, const char *name, char *out, size_t size)
{
	size_t n = strlen(dir);
	snprintf(out, size, "%s%s%s", dir, n > 0 && dir[n - 1] == '/' ? "" : "/", name);
}

/* Slashes forward, none at the end but a drive's: C:/ */
static void normalise(const char *in, char *out, size_t size)
{
	size_t n = 0;
	for (; *in != '\0' && n + 1 < size; in++)
		out[n++] = *in == '\\' ? '/' : *in;
	out[n] = '\0';
	while (n > 1 && out[n - 1] == '/' && !(n == 3 && out[1] == ':'))
		out[--n] = '\0';
	if (n == 2 && out[1] == ':' && n + 1 < size) {
		out[2] = '/';
		out[3] = '\0';
	}
}

static void show_rows(struct upload *u)
{
	for (int i = 0; i < u->nrows; i++) {
		int e = u->top + i;
		fbtk_widget_t *row = u->rows[i];
		char text[300];
		if (e < u->count) {
			snprintf(text, sizeof text, "%s%s", u->entries[e].name,
				 u->entries[e].is_dir ? "\\" : "");
		} else {
			text[0] = '\0';
		}
		row->bg = e == u->selected ? SELECTED_COLOUR : FB_COLOUR_WHITE;
		fbtk_set_text(row, text);
		fbtk_request_redraw(row);
	}
	fbtk_set_scroll_parameters(u->vscroll, 0, u->count, u->nrows, u->nrows);
	fbtk_set_scroll_position(u->vscroll, u->top);
}

/* Shown: the selected entry */
static void scroll_to_selected(struct upload *u)
{
	if (u->selected < u->top)
		u->top = u->selected;
	if (u->selected >= u->top + u->nrows)
		u->top = u->selected - u->nrows + 1;
	if (u->top > u->count - u->nrows)
		u->top = u->count - u->nrows;
	if (u->top < 0)
		u->top = 0;
}

static bool read_dir(struct upload *u, const char *dir)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	int capacity = 0;
	char shown[520], full[800];

	if (d == NULL)
		return false;
	free_entries(u);
	snprintf(u->dir, sizeof u->dir, "%s", dir);
	if (!is_drive_top(dir)) {
		u->entries = malloc(sizeof *u->entries * 16);
		capacity = u->entries != NULL ? 16 : 0;
		if (capacity > 0) {
			u->entries[0].name = strdup("..");
			u->entries[0].is_dir = true;
			u->count = u->entries[0].name != NULL;
		}
	}
	while ((e = readdir(d)) != NULL) {
		struct stat st;
		if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
			continue;
		if (u->count == capacity) {
			int more = capacity ? capacity * 2 : 64;
			struct entry *grown = realloc(u->entries, sizeof *grown * more);
			if (grown == NULL)
				break;
			u->entries = grown;
			capacity = more;
		}
		join(dir, e->d_name, full, sizeof full);
		u->entries[u->count].name = strdup(e->d_name);
		if (u->entries[u->count].name == NULL)
			break;
		u->entries[u->count].is_dir = stat(full, &st) == 0 && S_ISDIR(st.st_mode);
		u->count++;
	}
	closedir(d);
	qsort(u->entries, u->count, sizeof *u->entries, entry_order);
	u->top = 0;
	u->selected = u->count > 0 ? 0 : -1;
	/* the path as DOS shows it */
	snprintf(shown, sizeof shown, "%s", dir);
	for (char *c = shown; *c != '\0'; c++)
		if (*c == '/')
			*c = '\\';
	fbtk_set_text(u->path, shown);
	show_rows(u);
	return true;
}

static void upload_free(void *p)
{
	struct upload *u = p;
	close_window(u->window);
	free_entries(u);
	free(u);
}

/* Hidden now, gone later: fbtk may still use the widget whose
 * event closed it */
static void upload_close(struct upload *u)
{
	if (u->closing)
		return;
	u->closing = true;
	if (upload == u)
		upload = NULL;
	fbtk_set_mapping(u->window, false);
	guit->misc->schedule(0, upload_free, u);
}

static void upload_choose(struct upload *u, const char *path)
{
	if (browser_window_get_content(u->bw) == u->hl)
		browser_window_set_gadget_filename(u->bw, u->gadget, path);
	upload_close(u);
}

/* The parent folder, its entry of the one left selected */
static void go_up(struct upload *u)
{
	char was[512], dir[512];
	char *slash;

	if (is_drive_top(u->dir))
		return;
	snprintf(dir, sizeof dir, "%s", u->dir);
	slash = strrchr(dir, '/');
	if (slash == NULL)
		return;
	snprintf(was, sizeof was, "%s", slash + 1);
	if (slash == dir + 2 && dir[1] == ':')
		slash[1] = '\0';
	else
		*slash = '\0';
	if (!read_dir(u, dir))
		return;
	for (int i = 0; i < u->count; i++) {
		if (strcmp(u->entries[i].name, was) == 0) {
			u->selected = i;
			scroll_to_selected(u);
			show_rows(u);
			break;
		}
	}
}

/* The selected entry: a folder opened, a file chosen */
static void open_selected(struct upload *u)
{
	char full[800];
	struct entry *e;

	if (u->selected < 0 || u->selected >= u->count)
		return;
	e = &u->entries[u->selected];
	if (strcmp(e->name, "..") == 0) {
		go_up(u);
		return;
	}
	join(u->dir, e->name, full, sizeof full);
	if (e->is_dir)
		read_dir(u, full);
	else
		upload_choose(u, full);
}

static int upload_ok(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct upload *u = cbi->context;
	if (released(cbi) && !u->closing)
		open_selected(cbi->context);
	return 0;
}

static int upload_cancel(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct upload *u = cbi->context;
	if (released(cbi) && !u->closing)
		upload_close(cbi->context);
	return 0;
}

/* A path typed: a folder opened, a file chosen */
static int path_enter(void *pw, char *text)
{
	struct upload *u = pw;
	char path[512];
	struct stat st;

	if (u->closing)
		return 0;
	normalise(text, path, sizeof path);
	if (stat(path, &st) == 0 && !S_ISDIR(st.st_mode)) {
		upload_choose(u, path);
		return 0;
	}
	if (!read_dir(u, path))
		read_dir(u, u->dir); /* the path shown as it was */
	return 0;
}

static int row_click(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct upload *u = cbi->context;
	int row = 0;
	uint64_t now;

	if (u->closing || cbi->event == NULL ||
	    cbi->event->type != NSFB_EVENT_KEY_DOWN)
		return 0;
	switch (cbi->event->value.keycode) {
	case NSFB_KEY_MOUSE_4: /* the wheel */
	case NSFB_KEY_MOUSE_5:
		u->top += cbi->event->value.keycode == NSFB_KEY_MOUSE_4 ? -3 : 3;
		if (u->top > u->count - u->nrows)
			u->top = u->count - u->nrows;
		if (u->top < 0)
			u->top = 0;
		show_rows(u);
		return 0;
	case NSFB_KEY_MOUSE_1:
		break;
	default:
		return 0;
	}
	while (row < u->nrows && u->rows[row] != widget)
		row++;
	if (row == u->nrows || u->top + row >= u->count)
		return 0;
	nsu_getmonotonic_ms(&now);
	/* twice on the same entry, quickly: opened */
	if (u->top + row == u->selected && u->last_row == u->selected &&
	    now - u->last_click < 500) {
		u->last_click = 0;
		open_selected(u);
		return 0;
	}
	u->selected = u->top + row;
	u->last_row = u->selected;
	u->last_click = now;
	show_rows(u);
	return 0;
}

static int list_keys(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct upload *u = cbi->context;
	int move = 0;

	if (u->closing || cbi->event == NULL ||
	    cbi->event->type != NSFB_EVENT_KEY_DOWN)
		return 0;
	switch (cbi->event->value.keycode) {
	case NSFB_KEY_UP: move = -1; break;
	case NSFB_KEY_DOWN: move = 1; break;
	case NSFB_KEY_PAGEUP: move = -u->nrows; break;
	case NSFB_KEY_PAGEDOWN: move = u->nrows; break;
	case NSFB_KEY_HOME: move = -u->count; break;
	case NSFB_KEY_END: move = u->count; break;
	case NSFB_KEY_RETURN: open_selected(u); return 0;
	case NSFB_KEY_BACKSPACE: go_up(u); return 0;
	case NSFB_KEY_ESCAPE: upload_close(u); return 0;
	default: return 0;
	}
	if (u->count == 0)
		return 0;
	u->selected += move;
	if (u->selected < 0)
		u->selected = 0;
	if (u->selected >= u->count)
		u->selected = u->count - 1;
	scroll_to_selected(u);
	show_rows(u);
	return 0;
}

static int list_scroll(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
	struct upload *u = cbi->context;
	if (u->closing || cbi->type != FBTK_CBT_SCROLLY)
		return 0;
	u->top = cbi->y;
	if (u->top > u->count - u->nrows)
		u->top = u->count - u->nrows;
	if (u->top < 0)
		u->top = 0;
	show_rows(u);
	return 0;
}

/* The keys to the list: later, as NetSurf gives the page the focus
 * after the click that opened it */
static void upload_focus(void *p)
{
	if (upload == p)
		fbtk_set_focus(upload->rows[0]);
}

void zdos_file_gadget_open(struct gui_window *gw, struct hlcache_handle *hl,
			   struct form_control *gadget)
{
	struct upload *u;
	int h = row_height(), pad = h / 2, sw = nsoption_int(fb_furniture_size);
	int w, list_h, y, rh = fbtk_get_height(fbtk);
	const char *home = getenv("HOME");
	char start[512];

	if (upload != NULL)
		upload_close(upload);
	u = calloc(1, sizeof *u);
	if (u == NULL)
		return;
	u->bw = gw->bw;
	u->hl = hl;
	u->gadget = gadget;
	u->last_row = -1;

	/* the rows that fit, up to MAX_ROWS */
	u->nrows = (rh - 16 - h * 3 - pad * 4) / h;
	if (u->nrows > MAX_ROWS)
		u->nrows = MAX_ROWS;
	if (u->nrows < 3)
		u->nrows = 3;
	list_h = u->nrows * h + 2;
	u->window = open_window(h * 22, h * 3 + list_h + pad * 4);
	if (u->window == NULL) {
		free(u);
		return;
	}
	upload = u;
	w = fbtk_get_width(u->window);
	y = pad;
	label(u->window, pad, y, w - pad * 2, h, "Choose a file to upload");
	y += h + pad / 2;
	u->path = fbtk_create_writable_text(u->window, pad, y, w - pad * 2, h,
					    FB_COLOUR_WHITE, FB_COLOUR_BLACK, true,
					    path_enter, u);
	y += h + pad / 2;
	/* the list: a white outlined field, rows inside, a scroll bar */
	arrow_over(fbtk_create_text(u->window, pad, y, w - pad * 2, list_h,
				    FB_COLOUR_WHITE, FB_COLOUR_BLACK, true));
	for (int i = 0; i < u->nrows; i++) {
		fbtk_widget_t *row = fbtk_create_text(u->window, pad + 1, y + 1 + i * h,
						      w - pad * 2 - 2 - sw, h,
						      FB_COLOUR_WHITE, FB_COLOUR_BLACK,
						      false);
		fbtk_set_handler(row, FBTK_CBT_CLICK, row_click, u);
		fbtk_set_handler(row, FBTK_CBT_INPUT, list_keys, u);
		arrow_over(row);
		u->rows[i] = row;
	}
	u->vscroll = fbtk_create_vscroll(u->window, w - pad - 1 - sw, y + 1, sw,
					 list_h - 2, FB_SCROLL_COLOUR, FB_FRAME_COLOUR,
					 list_scroll, u);
	y += list_h + pad;
	button(u->window, w - pad - h * 4, y, h * 4, h, "Cancel", upload_cancel, u);
	button(u->window, w - pad * 2 - h * 8, y, h * 4, h, "OK", upload_ok, u);

	/* the start: HOME, else C:/ */
	normalise(home != NULL && *home != '\0' ? home : "C:/", start, sizeof start);
	if (!read_dir(u, start) && !read_dir(u, "C:/")) {
		upload_close(u);
		status(gw, "Upload: no folder to show");
		return;
	}
	guit->misc->schedule(0, upload_focus, u);
}
