/* PortableGL on ZDOS without SDL: a lit, spinning cube drawn by C shaders into
   PortableGL's back buffer, which goes to zdos_display_present as it is
   (PGL_ARGB32 is ZDOS's XRGB8888). PGLCUBE [width height]; Esc ends. */
#define PGL_ARGB32
#define PGL_EXCLUDE_STUBS
#define PORTABLEGL_IMPLEMENTATION
#include "portablegl.h"

#include <stdio.h>
#include <stdlib.h>

#include "zdos.h"
#include "zdos_media.h"

typedef struct {
    mat4 mvp, model;
    vec3 light;
} Uniforms;

/* Varyings: the normal (in the world) and the colour */
static void cube_vs(float *out, vec4 *attr, Shader_Builtins *b, void *uniforms)
{
    Uniforms *u = uniforms;
    vec4 n = mult_m4_v4(u->model, make_v4(attr[1].x, attr[1].y, attr[1].z, 0));
    out[0] = n.x, out[1] = n.y, out[2] = n.z;
    out[3] = attr[2].x, out[4] = attr[2].y, out[5] = attr[2].z;
    b->gl_Position = mult_m4_v4(u->mvp, attr[0]);
}

static void cube_fs(float *in, Shader_Builtins *b, void *uniforms)
{
    Uniforms *u = uniforms;
    vec3 n = norm_v3(make_v3(in[0], in[1], in[2]));
    float d = dot_v3s(n, u->light);
    float l = 0.25f + 0.75f * (d > 0 ? d : 0);
    b->gl_FragColor = make_v4(in[3] * l, in[4] * l, in[5] * l, 1);
}

/* 6 faces x 2 triangles: position, normal, colour */
static float cube[36 * 9];

static void make_cube(void)
{
    static const float n[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    static const float col[6][3] = {{1, .3f, .3f}, {.3f, 1, .3f}, {.3f, .3f, 1}, {1, 1, .3f}, {.3f, 1, 1}, {1, .3f, 1}};
    static const int quad[6][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, -1}, {1, 1}, {-1, 1}};
    float *p = cube;
    for (int f = 0; f < 6; f++) {
        int ax = f / 2, s = n[f][ax] > 0 ? 1 : -1;
        int a1 = (ax + 1) % 3, a2 = (ax + 2) % 3;
        for (int v = 0; v < 6; v++) {
            float pos[3];
            pos[ax] = (float)s;
            /* keep the winding counter-clockwise from outside */
            pos[a1] = (float)quad[v][0] * s;
            pos[a2] = (float)quad[v][1];
            for (int i = 0; i < 3; i++) *p++ = pos[i];
            for (int i = 0; i < 3; i++) *p++ = n[f][i];
            for (int i = 0; i < 3; i++) *p++ = col[f][i];
        }
    }
}

int main(int argc, char **argv)
{
    int w = argc > 2 ? atoi(argv[1]) : 640, h = argc > 2 ? atoi(argv[2]) : 480;
    glContext ctx;
    pix_t *backbuf = NULL;

    if (w <= 0 || h <= 0 || !init_glContext(&ctx, &backbuf, w, h)) {
        fprintf(stderr, "pglcube: no %dx%d context\n", w, h);
        return 1;
    }
    if (!zdos_display_open(w, h, ZDOS_PIXELS_XRGB8888)) {
        fprintf(stderr, "pglcube: no graphics: %s\n", zdos_error_message(zdos->programs->last_error()));
        return 1;
    }
    zdos->gfx->set_title("PGLCUBE", 7);

    make_cube();
    GLuint vao, vbo;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(cube), cube, GL_STATIC_DRAW);
    for (int i = 0; i < 3; i++) {
        glEnableVertexAttribArray(i);
        glVertexAttribPointer(i, 3, GL_FLOAT, GL_FALSE, 9 * sizeof(float), (void *)(i * 3 * sizeof(float)));
    }
    GLenum smooth[6] = {PGL_SMOOTH3, PGL_SMOOTH3};
    GLuint prog = pglCreateProgram(cube_vs, cube_fs, 6, smooth, GL_FALSE);
    glUseProgram(prog);
    Uniforms u;
    pglSetUniform(&u);
    u.light = norm_v3(make_v3(0.4f, 0.7f, 1.0f));

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glClearColor(0.08f, 0.08f, 0.15f, 1);
    mat4 proj, rx, ry, view;
    make_perspective_m4(proj, DEG_TO_RAD(45), (float)w / h, 1, 20);

    float yaw = 0, pitch = 25;
    int mx = w / 2, my = h / 2, drag = 0, frames = 0, spin = 1;
    uint64_t t0 = zdos->time->millis(), last = t0, fps_t = t0;
    for (;;) {
        zdos_input_event e;
        while (zdos_input_poll(&e)) {
            if (e.type == ZDOS_EVENT_KEY_DOWN && (e.scancode == 41 || e.scancode == 20)) goto out; /* Esc, Q */
            if (e.type == ZDOS_EVENT_KEY_DOWN && e.scancode == 44) spin = !spin;                  /* Space */
            if (e.type == ZDOS_EVENT_MOUSE_DOWN) drag = 1;
            if (e.type == ZDOS_EVENT_MOUSE_UP) drag = 0;
            if (e.type == ZDOS_EVENT_MOUSE_MOTION) {
                if (drag) yaw += e.dx * 0.5f, pitch += e.dy * 0.5f;
                mx = e.x, my = e.y;
            }
        }
        uint64_t now = zdos->time->millis();
        if (spin) yaw += (now - last) * 0.05f;
        last = now;

        load_rotation_m4(ry, make_v3(0, 1, 0), DEG_TO_RAD(yaw));
        load_rotation_m4(rx, make_v3(1, 0, 0), DEG_TO_RAD(pitch));
        mult_m4_m4(u.model, rx, ry);
        mult_m4_m4(view, proj, u.model);
        /* the camera 6 units back: translate after rotating */
        memcpy(u.mvp, view, sizeof(mat4));
        for (int i = 0; i < 4; i++) u.mvp[12 + i] = view[12 + i] + proj[8 + i] * -6.0f;

        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glDrawArrays(GL_TRIANGLES, 0, 36);
        zdos_display_cursor(mx, my, true);
        zdos_display_present(backbuf, w * sizeof(pix_t));

        frames++;
        if (now - fps_t >= 2000) {
            printf("%d frames in %.1f s: %.1f fps\n", frames, (now - fps_t) / 1000.0, frames * 1000.0 / (now - fps_t));
            fps_t = now, frames = 0;
        }
    }
out:
    glDeleteProgram(prog);
    glDeleteBuffers(1, &vbo);
    glDeleteVertexArrays(1, &vao);
    free_glContext(&ctx);
    zdos_display_close();
    return 0;
}
