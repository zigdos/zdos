#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "zdos.h"
#include "zdos_media.h"
#include "libnsfb.h"
#include "libnsfb_event.h"
#include "libnsfb_plot.h"
#include "nsfb.h"
#include "surface.h"
#include "cursor.h"
#include "plot.h"

static int pointer_x;
static int pointer_y;

/* Presenting converts the whole frame (on BIOS dithered pixel by pixel):
   updates and pointer moves only mark it, shown at most every
   PRESENT_MS and before the input loop waits */
#define PRESENT_MS 33
static nsfb_t *changed;
static uint64_t presented_at;

static void present(void)
{
	nsfb_t *nsfb = changed;
	changed = NULL;
	if (nsfb != NULL && nsfb->ptr != NULL) {
		zdos_display_present(nsfb->ptr, nsfb->linelen);
	}
	presented_at = zdos->time->millis();
}

static bool present_due(void)
{
	return zdos->time->millis() - presented_at >= PRESENT_MS;
}

static void mark_changed(nsfb_t *nsfb)
{
	changed = nsfb;
	if (present_due()) {
		present();
	}
}

static int zdos_cursor(nsfb_t *nsfb, struct nsfb_cursor_s *cursor)
{
	zdos_display_cursor(cursor->loc.x0, cursor->loc.y0, true);
	mark_changed(nsfb);
	return 0;
}

static int wheel_remaining;
static enum nsfb_key_code_e wheel_code;
static bool wheel_release;

static int zdos_ram_defaults(nsfb_t *nsfb)
{
	nsfb->width = 800;
	nsfb->height = 600;
	nsfb->format = NSFB_FMT_XRGB8888;
	select_plotters(nsfb);
	return 0;
}

/* The screen's size, so the picture fills it: half of one 2560 wide or more
   (zdos_display doubles it, the text stays readable); 640 x 480 in the BIOS
   edition's 16-color mode */
static void screen_size(nsfb_t *nsfb)
{
	zdos_screen_info s;
	int k;

	if (zdos == NULL || !zdos->gfx->screen(&s)) {
		return;
	}
	if (!s.true_color) {
		nsfb->width = 640;
		nsfb->height = 480;
		return;
	}
	if (s.width == 0 || s.height == 0) {
		return;
	}
	k = (s.width >= 2560 && s.width % 2 == 0 && s.height % 2 == 0) ? 2 : 1;
	nsfb->width = (int)s.width / k;
	nsfb->height = (int)s.height / k;
}

static int zdos_ram_initialise(nsfb_t *nsfb)
{
	size_t size;

	screen_size(nsfb);
	size = (size_t)nsfb->width * (size_t)nsfb->height * 4;

	nsfb->ptr = calloc(1, size);
	if (nsfb->ptr == NULL) {
		return -1;
	}
	nsfb->linelen = nsfb->width * 4;

	if (!zdos_display_open(nsfb->width, nsfb->height, ZDOS_PIXELS_XRGB8888)) {
		free(nsfb->ptr);
		nsfb->ptr = NULL;
		return -1;
	}
	zdos_input_area(nsfb->width, nsfb->height);
	pointer_x = nsfb->width / 2;
	pointer_y = nsfb->height / 2;
	zdos_display_cursor(pointer_x, pointer_y, true);
	return 0;
}

static int zdos_ram_finalise(nsfb_t *nsfb)
{
	changed = NULL;
	free(nsfb->ptr);
	nsfb->ptr = NULL;
	zdos_display_cursor(0, 0, false);
	zdos_display_close();
	return 0;
}

static int zdos_ram_geometry(nsfb_t *nsfb, int width, int height,
			     enum nsfb_format_e format)
{
	if (nsfb->ptr != NULL) {
		return -1;
	}
	if (format != NSFB_FMT_ANY && format != NSFB_FMT_XRGB8888) {
		return -1;
	}
	if (width > 0) {
		nsfb->width = width;
	}
	if (height > 0) {
		nsfb->height = height;
	}
	nsfb->format = NSFB_FMT_XRGB8888;
	select_plotters(nsfb);
	return 0;
}

static enum nsfb_key_code_e key_from_hid(uint16_t hid)
{
	if (hid >= 0x04 && hid <= 0x1d) {
		return (enum nsfb_key_code_e)(NSFB_KEY_a + hid - 0x04);
	}
	if (hid >= 0x1e && hid <= 0x26) {
		return (enum nsfb_key_code_e)(NSFB_KEY_1 + hid - 0x1e);
	}
	if (hid >= 0x3a && hid <= 0x45) {
		return (enum nsfb_key_code_e)(NSFB_KEY_F1 + hid - 0x3a);
	}
	switch (hid) {
	case 0x27: return NSFB_KEY_0;
	case 0x28: return NSFB_KEY_RETURN;
	case 0x29: return NSFB_KEY_ESCAPE;
	case 0x2a: return NSFB_KEY_BACKSPACE;
	case 0x2b: return NSFB_KEY_TAB;
	case 0x2c: return NSFB_KEY_SPACE;
	case 0x2d: return NSFB_KEY_MINUS;
	case 0x2e: return NSFB_KEY_EQUALS;
	case 0x2f: return NSFB_KEY_LEFTBRACKET;
	case 0x30: return NSFB_KEY_RIGHTBRACKET;
	case 0x31: return NSFB_KEY_BACKSLASH;
	case 0x33: return NSFB_KEY_SEMICOLON;
	case 0x34: return NSFB_KEY_QUOTE;
	case 0x35: return NSFB_KEY_BACKQUOTE;
	case 0x36: return NSFB_KEY_COMMA;
	case 0x37: return NSFB_KEY_PERIOD;
	case 0x38: return NSFB_KEY_SLASH;
	case 0x39: return NSFB_KEY_CAPSLOCK;
	case 0x49: return NSFB_KEY_INSERT;
	case 0x4a: return NSFB_KEY_HOME;
	case 0x4b: return NSFB_KEY_PAGEUP;
	case 0x4c: return NSFB_KEY_DELETE;
	case 0x4d: return NSFB_KEY_END;
	case 0x4e: return NSFB_KEY_PAGEDOWN;
	case 0x4f: return NSFB_KEY_RIGHT;
	case 0x50: return NSFB_KEY_LEFT;
	case 0x51: return NSFB_KEY_DOWN;
	case 0x52: return NSFB_KEY_UP;
	case 0xe0: return NSFB_KEY_LCTRL;
	case 0xe1: return NSFB_KEY_LSHIFT;
	case 0xe2: return NSFB_KEY_LALT;
	case 0xe3: return NSFB_KEY_LSUPER;
	case 0xe4: return NSFB_KEY_RCTRL;
	case 0xe5: return NSFB_KEY_RSHIFT;
	case 0xe6: return NSFB_KEY_RALT;
	case 0xe7: return NSFB_KEY_RSUPER;
	default: return NSFB_KEY_UNKNOWN;
	}
}

static bool zdos_ram_input(nsfb_t *nsfb, nsfb_event_t *event, int timeout)
{
	int waited = 0;

	for (;;) {
		zdos_input_event input;
		enum nsfb_key_code_e key;

		if (wheel_release) {
			wheel_release = false;
			event->type = NSFB_EVENT_KEY_UP;
			event->value.keycode = wheel_code;
			return true;
		}
		if (wheel_remaining > 0) {
			wheel_remaining--;
			wheel_release = true;
			event->type = NSFB_EVENT_KEY_DOWN;
			event->value.keycode = wheel_code;
			return true;
		}
		if (zdos_input_poll(&input)) {
			switch (input.type) {
			case ZDOS_EVENT_KEY_DOWN:
			case ZDOS_EVENT_KEY_UP:
				key = key_from_hid(input.scancode);
				if (key == NSFB_KEY_UNKNOWN) {
					continue;
				}
				event->type = input.type == ZDOS_EVENT_KEY_DOWN ?
					NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP;
				event->value.keycode = key;
				return true;
			case ZDOS_EVENT_TEXT:
				continue;
			case ZDOS_EVENT_MOUSE_MOTION:
				pointer_x += input.dx;
				pointer_y += input.dy;
				if (pointer_x < 0) pointer_x = 0;
				if (pointer_y < 0) pointer_y = 0;
				if (pointer_x >= nsfb->width) pointer_x = nsfb->width - 1;
				if (pointer_y >= nsfb->height) pointer_y = nsfb->height - 1;
				event->type = NSFB_EVENT_MOVE_ABSOLUTE;
				event->value.vector.x = pointer_x;
				event->value.vector.y = pointer_y;
				event->value.vector.z = 0;
				return true;
			case ZDOS_EVENT_MOUSE_DOWN:
			case ZDOS_EVENT_MOUSE_UP:
				if (input.button == ZDOS_MOUSE_LEFT)
					key = NSFB_KEY_MOUSE_1;
				else if (input.button == ZDOS_MOUSE_MIDDLE)
					key = NSFB_KEY_MOUSE_2;
				else if (input.button == ZDOS_MOUSE_RIGHT)
					key = NSFB_KEY_MOUSE_3;
				else
					continue;
				event->type = input.type == ZDOS_EVENT_MOUSE_DOWN ?
					NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP;
				event->value.keycode = key;
				return true;
			case ZDOS_EVENT_MOUSE_WHEEL:
				/* dy > 0: turned toward the user; NetSurf's
				 * 4 scrolls up, 5 down: */
#ifdef ZDOS_NATURAL_SCROLL
				wheel_code = input.dy > 0 ? NSFB_KEY_MOUSE_4 : NSFB_KEY_MOUSE_5;
#else
				wheel_code = input.dy > 0 ? NSFB_KEY_MOUSE_5 : NSFB_KEY_MOUSE_4;
#endif
				wheel_remaining = input.dy > 0 ? input.dy : -input.dy;
				continue;
			default:
				continue;
			}
		}

		/* Nothing to handle: a frame held back is shown before
		 * waiting (or when due, while redraws keep coming): */
		if (changed != NULL && (timeout != 0 || present_due())) {
			present();
		}
		if (timeout == 0 || (timeout > 0 && waited >= timeout)) {
			return false;
		}
		unsigned int delay = 10;
		if (timeout > 0 && timeout - waited < (int)delay) {
			delay = (unsigned int)(timeout - waited);
		}
		usleep(delay * 1000);
		waited += (int)delay;
	}
}

static int zdos_ram_update(nsfb_t *nsfb, nsfb_bbox_t *box)
{
	(void)box;
	mark_changed(nsfb);
	return 0;
}

const nsfb_surface_rtns_t zdos_rtns = {
	.defaults = zdos_ram_defaults,
	.initialise = zdos_ram_initialise,
	.finalise = zdos_ram_finalise,
	.geometry = zdos_ram_geometry,
	.input = zdos_ram_input,
	.update = zdos_ram_update,
	.cursor = zdos_cursor,
};

/* The screen as a surface of its own, "zdos": libnsfb's "ram" surface
   stays plain memory, which NetSurf also uses for every bitmap (each one
   closing the display when freed took the browser's tab away). Under SDL's
   number, unused here: the lowest, so the frontend picks it by default. */
NSFB_SURFACE_DEF(zdos, NSFB_SURFACE_SDL, &zdos_rtns)
