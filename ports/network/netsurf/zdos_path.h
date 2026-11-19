/* Paths (SVG's shapes) for the framebuffer frontend (zdos_path.c) */
#ifndef NETSURF_FB_ZDOS_PATH_H
#define NETSURF_FB_ZDOS_PATH_H

#include <libnsfb.h>

#include "utils/errors.h"
#include "netsurf/plot_style.h"

nserror zdos_plot_path(nsfb_t *nsfb, const plot_style_t *style, const float *p, unsigned int n,
		       const float transform[6]);

#endif
