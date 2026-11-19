/* Paths (SVG's shapes) for the framebuffer frontend, which plotted
 * none of them. Curves are made lines; filled by the non-zero rule
 * across all the subpaths (holes stay holes); stroked as a
 * quadrilateral a segment and a disc a join. */
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

#include <libnsfb.h>
#include <libnsfb_plot.h>

#include "utils/errors.h"
#include "netsurf/plot_style.h"
#include "netsurf/plotters.h"

#include "framebuffer/zdos_path.h"

struct pt {
	float x, y;
};

/* The path as points, subpaths by where they start */
struct shape {
	struct pt *p;
	int n, cap;
	int *start;
	bool *closed;
	int subs, subcap;
	bool ok;
};

static void add(struct shape *s, float x, float y)
{
	if (!s->ok)
		return;
	if (s->n == s->cap) {
		int more = s->cap ? s->cap * 2 : 64;
		struct pt *grown = realloc(s->p, sizeof(*grown) * more);
		if (grown == NULL) {
			s->ok = false;
			return;
		}
		s->p = grown;
		s->cap = more;
	}
	s->p[s->n].x = x;
	s->p[s->n].y = y;
	s->n++;
}

static void begin(struct shape *s)
{
	if (!s->ok)
		return;
	if (s->subs == s->subcap) {
		int more = s->subcap ? s->subcap * 2 : 8;
		int *start = realloc(s->start, sizeof(int) * more);
		bool *closed = start ? realloc(s->closed, sizeof(bool) * more) : NULL;
		if (start != NULL)
			s->start = start;
		if (closed == NULL) {
			s->ok = false;
			return;
		}
		s->closed = closed;
		s->subcap = more;
	}
	s->start[s->subs] = s->n;
	s->closed[s->subs] = false;
	s->subs++;
}

/* Points of subpath k: from, to (exclusive) */
static int sub_end(const struct shape *s, int k)
{
	return k + 1 < s->subs ? s->start[k + 1] : s->n;
}

static bool flatten(struct shape *s, const float *p, unsigned int n, const float t[6])
{
	float cx = 0, cy = 0; /* the pen, untransformed */
	float sx = 0, sy = 0; /* the subpath's start */
	unsigned int i = 0;
#define TX(x, y) (t[0] * (x) + t[2] * (y) + t[4])
#define TY(x, y) (t[1] * (x) + t[3] * (y) + t[5])
	while (i < n && s->ok) {
		switch ((int)p[i]) {
		case PLOTTER_PATH_MOVE:
			if (i + 3 > n)
				return false;
			cx = sx = p[i + 1];
			cy = sy = p[i + 2];
			begin(s);
			add(s, TX(cx, cy), TY(cx, cy));
			i += 3;
			break;
		case PLOTTER_PATH_LINE:
			if (i + 3 > n)
				return false;
			if (s->subs == 0) {
				begin(s);
				add(s, TX(cx, cy), TY(cx, cy));
			}
			cx = p[i + 1];
			cy = p[i + 2];
			add(s, TX(cx, cy), TY(cx, cy));
			i += 3;
			break;
		case PLOTTER_PATH_BEZIER: {
			float x1, y1, x2, y2, x3, y3, len;
			int steps;
			if (i + 7 > n)
				return false;
			if (s->subs == 0) {
				begin(s);
				add(s, TX(cx, cy), TY(cx, cy));
			}
			x1 = p[i + 1]; y1 = p[i + 2];
			x2 = p[i + 3]; y2 = p[i + 4];
			x3 = p[i + 5]; y3 = p[i + 6];
			/* segments: by the control polygon's length on screen */
			len = hypotf(TX(x1, y1) - TX(cx, cy), TY(x1, y1) - TY(cx, cy)) +
				hypotf(TX(x2, y2) - TX(x1, y1), TY(x2, y2) - TY(x1, y1)) +
				hypotf(TX(x3, y3) - TX(x2, y2), TY(x3, y3) - TY(x2, y2));
			steps = (int)(len / 3);
			if (steps < 2)
				steps = 2;
			if (steps > 64)
				steps = 64;
			for (int k = 1; k <= steps; k++) {
				float u = (float)k / steps, v = 1 - u;
				float a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u;
				float x = a * cx + b * x1 + c * x2 + d * x3;
				float y = a * cy + b * y1 + c * y2 + d * y3;
				add(s, TX(x, y), TY(x, y));
			}
			cx = x3;
			cy = y3;
			i += 7;
			break;
		}
		case PLOTTER_PATH_CLOSE:
			if (s->subs > 0)
				s->closed[s->subs - 1] = true;
			cx = sx;
			cy = sy;
			i += 1;
			break;
		default:
			return false;
		}
	}
#undef TX
#undef TY
	return s->ok;
}

struct cross {
	float x;
	int dir;
};

static int by_x(const void *a, const void *b)
{
	float d = ((const struct cross *)a)->x - ((const struct cross *)b)->x;
	return d < 0 ? -1 : d > 0;
}

/* Filled: scanline by scanline, spans where the winding isn't 0 */
static void fill(nsfb_t *nsfb, const struct shape *s, nsfb_colour_t c)
{
	nsfb_bbox_t clip, span;
	float ymin = s->p[0].y, ymax = s->p[0].y;
	struct cross *xs;
	int y0, y1;

	for (int i = 1; i < s->n; i++) {
		if (s->p[i].y < ymin)
			ymin = s->p[i].y;
		if (s->p[i].y > ymax)
			ymax = s->p[i].y;
	}
	nsfb_plot_get_clip(nsfb, &clip);
	y0 = (int)floorf(ymin);
	y1 = (int)ceilf(ymax);
	if (y0 < clip.y0)
		y0 = clip.y0;
	if (y1 > clip.y1)
		y1 = clip.y1;
	if (y0 >= y1)
		return;
	xs = malloc(sizeof(*xs) * (size_t)s->n);
	if (xs == NULL)
		return;
	for (int y = y0; y < y1; y++) {
		float sy = y + 0.5f;
		int m = 0, wind = 0;
		for (int k = 0; k < s->subs; k++) {
			int from = s->start[k], to = sub_end(s, k);
			for (int i = from; i < to; i++) {
				/* every subpath closed, for filling */
				const struct pt *a = &s->p[i];
				const struct pt *b = &s->p[i + 1 < to ? i + 1 : from];
				if ((a->y <= sy && b->y > sy) || (b->y <= sy && a->y > sy)) {
					xs[m].x = a->x + (sy - a->y) * (b->x - a->x) / (b->y - a->y);
					xs[m].dir = b->y > a->y ? 1 : -1;
					m++;
				}
			}
		}
		qsort(xs, (size_t)m, sizeof(*xs), by_x);
		for (int i = 0; i < m; i++) {
			int before = wind;
			wind += xs[i].dir;
			if (before != 0 && i > 0) {
				span.x0 = (int)ceilf(xs[i - 1].x - 0.5f);
				span.x1 = (int)ceilf(xs[i].x - 0.5f);
				span.y0 = y;
				span.y1 = y + 1;
				if (span.x1 > span.x0)
					nsfb_plot_rectangle_fill(nsfb, &span, c);
			}
		}
	}
	free(xs);
}

static void segment(nsfb_t *nsfb, struct pt a, struct pt b, float w, nsfb_colour_t c)
{
	float dx = b.x - a.x, dy = b.y - a.y, len = hypotf(dx, dy);
	if (w < 1.5f || len == 0) {
		nsfb_bbox_t line = { (int)a.x, (int)a.y, (int)b.x, (int)b.y };
		nsfb_plot_pen_t pen = {
			.stroke_type = NFSB_PLOT_OPTYPE_SOLID,
			.stroke_width = 1,
			.stroke_colour = c,
		};
		nsfb_plot_line(nsfb, &line, &pen);
		return;
	}
	float nx = -dy / len * w / 2, ny = dx / len * w / 2;
	int q[8] = {
		(int)lroundf(a.x + nx), (int)lroundf(a.y + ny),
		(int)lroundf(b.x + nx), (int)lroundf(b.y + ny),
		(int)lroundf(b.x - nx), (int)lroundf(b.y - ny),
		(int)lroundf(a.x - nx), (int)lroundf(a.y - ny),
	};
	nsfb_plot_polygon(nsfb, q, 4, c);
}

static void join(nsfb_t *nsfb, struct pt a, float w, nsfb_colour_t c)
{
	if (w < 3)
		return;
	nsfb_bbox_t disc = {
		(int)lroundf(a.x - w / 2), (int)lroundf(a.y - w / 2),
		(int)lroundf(a.x + w / 2), (int)lroundf(a.y + w / 2),
	};
	nsfb_plot_ellipse_fill(nsfb, &disc, c);
}

static void stroke(nsfb_t *nsfb, const struct shape *s, float w, nsfb_colour_t c)
{
	for (int k = 0; k < s->subs; k++) {
		int from = s->start[k], to = sub_end(s, k);
		for (int i = from; i + 1 < to; i++) {
			segment(nsfb, s->p[i], s->p[i + 1], w, c);
			join(nsfb, s->p[i + 1], w, c);
		}
		if (s->closed[k] && to - from > 1)
			segment(nsfb, s->p[to - 1], s->p[from], w, c);
		if (!s->closed[k] || to - from == 1)
			join(nsfb, s->p[from], w, c);
	}
}

nserror zdos_plot_path(nsfb_t *nsfb, const plot_style_t *style, const float *p, unsigned int n,
		       const float transform[6])
{
	struct shape s = { .ok = true };
	/* the stroke's width on screen: scaled as the shape */
	float scale = sqrtf(fabsf(transform[0] * transform[3] - transform[1] * transform[2]));
	float w = plot_style_fixed_to_float(style->stroke_width) * scale;

	if (flatten(&s, p, n, transform) && s.n > 1) {
		if (!(style->fill_colour & NS_TRANSPARENT))
			fill(nsfb, &s, style->fill_colour);
		if (!(style->stroke_colour & NS_TRANSPARENT) && w > 0)
			stroke(nsfb, &s, w, style->stroke_colour);
	}
	free(s.p);
	free(s.start);
	free(s.closed);
	return NSERROR_OK;
}
