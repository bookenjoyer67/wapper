/* wallfx-gpu — the character-draw wallpaper transition, drawn over awww.
 *
 * One fullscreen wlr-layer-shell surface per output, on the Bottom layer above
 * awww and below the windows, click-through. It draws the OUTLINE transition
 * only: a thin quiet line in the wallpaper's lightest tone draws the
 * character's silhouette (two pens from the top), the character fills in from
 * that outline, and then the rest of the world spreads out of it in crisp
 * 4 px cells.
 *
 * The maps come from `wallfx perfil IMG` (~/.cache/wallfx/perfil):
 *   campo : R = distance outside the silhouette (wide, for the glow)
 *           G = depth inside the character (0 on its outline)
 *           B = signed distance (-sdRange..+sdRange map px)
 *   linea : R = where along each contour a point is (0..1, 0 = no line)
 *           G/B = the order the outside arrives, as a 16-bit surface
 *
 * Hand-over with awww (what makes it seamless):
 *   1. decode both images and the maps;
 *   2. start the animation and, at the same time, fade in over awww: at t=0
 *      the animation IS the old wallpaper, so the fade is between two renders
 *      of the same picture and nobody sees it;
 *   3. once fully covered, switch awww instantly (--transition-type none);
 *   4. finish on the new image, which awww now shows too;
 *   5. fade out and exit.
 * If anything fails within 2.5 s, awww changes with a plain fade: the
 * wallpaper must change even if the effect cannot be shown.
 *
 * Usage: wallfx-gpu OLD NEW CAMPO LINEA [DURATION_MS]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <math.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include <wayland-client.h>
#include <wayland-egl.h>
#include "wlr-layer-shell-unstable-v1-client-protocol.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>

#define IMG_MAX 2560          /* longest side an image is decoded at          */

static int cfg_verbose;
static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...)
{
    if (!cfg_verbose) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

/* ---------------------------------------------------------------- wayland */

static struct wl_display *wl_dpy;
static struct wl_registry *wl_reg;
static struct wl_compositor *wl_comp;
static struct zwlr_layer_shell_v1 *wl_shell;

static EGLDisplay egl_dpy;
static EGLContext egl_ctx;
static EGLConfig  egl_cfg;

static GLuint prog, vao;
static GLuint tex_campo, tex_linea;
static int    maps_w, maps_h;
static GLint  u_old, u_new, u_campo, u_linea, u_t, u_sw, u_sh, u_fw, u_fh,
              u_lw, u_lh, u_lineW, u_sdRange, u_cropOld, u_cropNew, u_ink, u_fade;

struct output {
    struct wl_output *wl;
    char name[64];
    int32_t x, y, w, h;
    struct wl_surface *surf;
    struct zwlr_layer_surface_v1 *ls;
    struct wl_egl_window *win;
    EGLSurface esurf;
    struct wl_callback *frame_cb;
    int configured;
    GLuint tex_old, tex_new;
    float crop_old[4], crop_new[4];
    struct output *next;
};

static struct output *outputs;
static int n_outputs, n_ready;

static float g_ink[3] = { 1.f, 1.f, 1.f };   /* the outline's line colour */
static float g_fade = 0.f;                   /* surface opacity, 0..1      */

/* ------------------------------------------------------------------ shader */

static const char *VS_SRC =
    "#version 300 es\n"
    "void main() {\n"
    "  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
    "  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

static const char *FS_SRC =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform sampler2D oldTex;\n"
    "uniform sampler2D newTex;\n"
    "uniform sampler2D fieldTex;   // campo\n"
    "uniform sampler2D lineTex;    // linea\n"
    "uniform float t;              // 0..1, linear in time\n"
    "uniform float sw, sh;         // screen, px\n"
    "uniform float fw, fh;         // field texels\n"
    "uniform float lw, lh;         // line texels\n"
    "uniform float lineW;          // outline width, px\n"
    "uniform float sdRange;        // campo B spans +-sdRange map px\n"
    "uniform float fade;           // 0..1 surface opacity\n"
    "uniform vec3  ink;            // the wallpaper's lightest tone\n"
    "uniform vec4  cropOld;        // image uv = xy + screen uv * zw\n"
    "uniform vec4  cropNew;\n"
    "out vec4 fragColor;\n"
    "\n"
    "const float CELL = 4.0;\n"
    "float escena(float x) { x = clamp(x, 0.0, 1.0); return x * x * (3.0 - 2.0 * x); }\n"
    "float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }\n"
    "vec2 cam(vec2 uv, float z) { return 0.5 + (uv - 0.5) / z; }\n"
    "vec3 oldAt(vec2 uv) { return texture(oldTex, cropOld.xy + uv * cropOld.zw).rgb; }\n"
    "vec2 newUv(vec2 uv, float z) { return cropNew.xy + cam(uv, z) * cropNew.zw; }\n"
    "\n"
    "// 16-bit surface in lineTex's G (high) and B (low), interpolated by hand:\n"
    "// the sampler's bilinear filter would blend the two bytes separately.\n"
    "float s16(vec2 texel) {\n"
    "  texel = clamp(texel, vec2(0.0), vec2(lw, lh) - 1.0);\n"
    "  vec4 f = texture(lineTex, (texel + 0.5) / vec2(lw, lh));\n"
    "  return (floor(f.g * 255.0 + 0.5) * 256.0 + floor(f.b * 255.0 + 0.5)) / 65535.0;\n"
    "}\n"
    "float surface(vec2 tuv) {\n"
    "  vec2 p = tuv * vec2(lw, lh) - 0.5;\n"
    "  vec2 i = floor(p), f = p - i;\n"
    "  return mix(mix(s16(i), s16(i + vec2(1.0, 0.0)), f.x),\n"
    "             mix(s16(i + vec2(0.0, 1.0)), s16(i + vec2(1.0, 1.0)), f.x), f.y);\n"
    "}\n"
    "\n"
    "void main() {\n"
    "  // gl_FragCoord is bottom-up; the textures (and the maps) are top-down.\n"
    "  vec2 uv = vec2(gl_FragCoord.x / sw, 1.0 - gl_FragCoord.y / sh);\n"
    "\n"
    "  // Two cameras, barely: the character settles from a touch closer than\n"
    "  // its background, which is enough to give it a little depth.\n"
    "  float zCh = 1.0 + 0.03 * (1.0 - escena(t));\n"
    "  float zBg = 1.0 + 0.015 * (1.0 - escena(t));\n"
    "  vec4 f = texture(fieldTex, newUv(uv, zCh));\n"
    "  float sdPx = (f.b * 2.0 - 1.0) * sdRange * sw * zCh / (fw * cropNew.z);\n"
    "  float inside = clamp(0.5 - sdPx / max(fwidth(sdPx), 1e-3), 0.0, 1.0);\n"
    "\n"
    "  // The stage steps back, a little: a fifth darker, a quarter greyer.\n"
    "  float back = escena(t / 0.18);\n"
    "  vec3 st = oldAt(uv);\n"
    "  st = mix(st, vec3(luma(st)), 0.25 * back) * (1.0 - 0.2 * back);\n"
    "\n"
    "  // The same 4 px cells: each decides by its centre, so the fronts are\n"
    "  // crisp and stepped; the silhouette itself stays smooth.\n"
    "  vec2 grid = vec2(sw, sh) / CELL;\n"
    "  vec2 cuv = (floor(uv * grid) + 0.5) / grid;\n"
    "\n"
    "  // The character fills in from its outline...\n"
    "  float Ti = escena((t - 0.32) / 0.32) * 1.02 - 0.01;\n"
    "  vec3 cIn = texture(fieldTex, newUv(cuv, zCh)).g <= Ti\n"
    "             ? texture(newTex, newUv(uv, zCh)).rgb : st;\n"
    "  // ...and then the world spreads out of it.\n"
    "  float To = escena((t - 0.45) / 0.50) * 1.02 - 0.01;\n"
    "  vec3 cOut = surface(newUv(cuv, zBg)) <= To\n"
    "              ? texture(newTex, newUv(uv, zBg)).rgb : st;\n"
    "  vec3 c = mix(cOut, cIn, inside);\n"
    "\n"
    "  // The line: thin and quiet, in the wallpaper's lightest tone, drawn by\n"
    "  // two pens from the top of every contour; it leaves once the character\n"
    "  // is in.\n"
    "  float drawP = escena((t - 0.02) / 0.33);\n"
    "  float lp = texture(lineTex, newUv(uv, zCh)).r;\n"
    "  float lfade = 1.0 - escena((t - 0.45) / 0.25);\n"
    "  if (lp > 0.0 && lp <= drawP && lfade > 0.0) {\n"
    "    float d = abs(sdPx) - lineW * 0.5;\n"
    "    float core = clamp(0.5 - d / max(fwidth(sdPx), 1e-3), 0.0, 1.0);\n"
    "    c = mix(c, ink, core * 0.75 * lfade);\n"
    "  }\n"
    "  fragColor = vec4(clamp(c, 0.0, 1.0), 1.0) * fade;\n"
    "}\n";

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetShaderInfoLog(s, sizeof buf, NULL, buf);
        fprintf(stderr, "wallfx-gpu: shader compile failed: %s\n", buf);
        exit(1);
    }
    return s;
}

static void gpu_init(void)
{
    GLuint vs = compile(GL_VERTEX_SHADER, VS_SRC);
    GLuint fs = compile(GL_FRAGMENT_SHADER, FS_SRC);
    prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glLinkProgram(prog);
    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char buf[4096];
        glGetProgramInfoLog(prog, sizeof buf, NULL, buf);
        fprintf(stderr, "wallfx-gpu: program link failed: %s\n", buf);
        exit(1);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);
    glGenVertexArrays(1, &vao);

    u_old    = glGetUniformLocation(prog, "oldTex");
    u_new    = glGetUniformLocation(prog, "newTex");
    u_campo  = glGetUniformLocation(prog, "fieldTex");
    u_linea  = glGetUniformLocation(prog, "lineTex");
    u_t      = glGetUniformLocation(prog, "t");
    u_sw     = glGetUniformLocation(prog, "sw");
    u_sh     = glGetUniformLocation(prog, "sh");
    u_fw     = glGetUniformLocation(prog, "fw");
    u_fh     = glGetUniformLocation(prog, "fh");
    u_lw     = glGetUniformLocation(prog, "lw");
    u_lh     = glGetUniformLocation(prog, "lh");
    u_lineW  = glGetUniformLocation(prog, "lineW");
    u_sdRange= glGetUniformLocation(prog, "sdRange");
    u_cropOld= glGetUniformLocation(prog, "cropOld");
    u_cropNew= glGetUniformLocation(prog, "cropNew");
    u_ink    = glGetUniformLocation(prog, "ink");
    u_fade   = glGetUniformLocation(prog, "fade");
}

/* ------------------------------------------------------------------ images */

static int read_fd_all(int fd, unsigned char **out, size_t *outlen)
{
    size_t cap = 1 << 20, len = 0;
    unsigned char *buf = malloc(cap);
    if (!buf) return -1;
    for (;;) {
        if (len == cap) {
            cap *= 2;
            unsigned char *nb = realloc(buf, cap);
            if (!nb) { free(buf); return -1; }
            buf = nb;
        }
        ssize_t n = read(fd, buf + len, cap - len);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(buf);
            return -1;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    *out = buf;
    *outlen = len;
    return 0;
}

/* magick <args...> to stdout; returns bytes read or -1 */
static int magick_pipe(char *const argv[], unsigned char **out, size_t *outlen)
{
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) dup2(dn, STDERR_FILENO);
        execvp(argv[0], argv);
        _exit(127);
    }
    close(pf[1]);
    int rc = read_fd_all(pf[0], out, outlen);
    close(pf[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (rc != 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (*out) { free(*out); *out = NULL; }
        *outlen = 0;
        return -1;
    }
    return (int)*outlen;
}

static void image_dims(const char *path, int *w, int *h)
{
    *w = *h = 0;
    int pf[2];
    if (pipe(pf) != 0) return;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) dup2(dn, STDERR_FILENO);
        execlp("magick", "magick", "identify", "-format", "%w %h", path, (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    char buf[64] = {0};
    ssize_t n = read(pf[0], buf, sizeof buf - 1);
    close(pf[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    if (n <= 0) return;
    if (sscanf(buf, "%d %d", w, h) != 2) *w = *h = 0;
}

static GLuint upload_rgba(const unsigned char *buf, int w, int h)
{
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, buf);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return tex;
}

/* decode an image (shrunk to IMG_MAX on the long side) into a new texture */
static GLuint load_image(const char *path, int *ow, int *oh)
{
    int iw = 0, ih = 0;
    image_dims(path, &iw, &ih);
    if (iw <= 0 || ih <= 0) return 0;
    char fit[64];
    snprintf(fit, sizeof fit, "%dx%d>", IMG_MAX, IMG_MAX);
    char *av[] = { "magick", (char *)path, "-depth", "8", "-resize", fit,
                   "rgba:-", NULL };
    unsigned char *buf = NULL;
    size_t len = 0;
    if (magick_pipe(av, &buf, &len) < 0) return 0;
    /* magick reports the size AFTER -resize only through the pixel count:
     * derive the decoded size from the ratio we asked for. */
    double s = 1.0;
    if (iw > IMG_MAX || ih > IMG_MAX)
        s = (iw >= ih) ? (double)IMG_MAX / iw : (double)IMG_MAX / ih;
    int dw = (int)lround(iw * s), dh = (int)lround(ih * s);
    size_t want = (size_t)dw * dh * 4;
    if (dw <= 0 || dh <= 0 || len < want) {
        fprintf(stderr, "wallfx-gpu: decode failed (%zu/%zu bytes): %s\n", len, want, path);
        free(buf);
        return 0;
    }
    GLuint tex = upload_rgba(buf, dw, dh);
    free(buf);
    *ow = dw; *oh = dh;
    return tex;
}

/* cover-crop rect (x, y, w, h in image uv) for this screen, like awww's crop */
static void crop_for(int iw, int ih, int sw, int sh, float out[4])
{
    double s = fmax((double)sw / iw, (double)sh / ih);
    double vw = sw / ((double)iw * s);
    double vh = sh / ((double)ih * s);
    out[0] = (float)((1.0 - vw) / 2.0);
    out[1] = (float)((1.0 - vh) / 2.0);
    out[2] = (float)vw;
    out[3] = (float)vh;
}

static void load_maps(const char *campo, const char *linea)
{
    int cw = 0, ch = 0, lw = 0, lh = 0;
    unsigned char *cbuf = NULL, *lbuf = NULL;
    size_t clen = 0, llen = 0;
    char *cav[] = { "magick", (char *)campo, "-depth", "8", "rgba:-", NULL };
    char *lav[] = { "magick", (char *)linea, "-depth", "8", "rgba:-", NULL };
    image_dims(campo, &cw, &ch);
    image_dims(linea, &lw, &lh);
    if (cw <= 0 || ch <= 0 || lw <= 0 || lh <= 0) return;
    if (magick_pipe(cav, &cbuf, &clen) < 0 || magick_pipe(lav, &lbuf, &llen) < 0) {
        free(cbuf); free(lbuf);
        return;
    }
    if (clen < (size_t)cw * ch * 4 || llen < (size_t)lw * lh * 4) {
        free(cbuf); free(lbuf);
        return;
    }
    tex_campo = upload_rgba(cbuf, cw, ch);
    tex_linea = upload_rgba(lbuf, lw, lh);
    maps_w = cw; maps_h = ch;
    free(cbuf); free(lbuf);
}

/* ---------------------------------------------------------------- surfaces */

static void render(struct output *o);
static int  started;
static double started_ms;

static void frame_done(void *data, struct wl_callback *cb, uint32_t t)
{
    (void)t;
    struct output *o = data;
    wl_callback_destroy(cb);
    o->frame_cb = NULL;
}

static const struct wl_callback_listener frame_cb_listener = { .done = frame_done };

static void render(struct output *o)
{
    if (!o->configured || !o->esurf || o->frame_cb) return;
    if (eglMakeCurrent(egl_dpy, o->esurf, o->esurf, egl_ctx) == EGL_FALSE) return;

    int32_t w = o->w, h = o->h;
    if (w <= 0 || h <= 0) return;

    double t = started ? (now_ms() - started_ms) / 2000.0 : 0.0;
    if (t > 1.0) t = 1.0;

    glViewport(0, 0, w, h);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(0.f, 0.f, 0.f, 0.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(prog);
    glBindVertexArray(vao);

    glUniform1f(u_t, (float)t);
    glUniform1f(u_sw, (float)w);
    glUniform1f(u_sh, (float)h);
    glUniform1f(u_fw, (float)maps_w);
    glUniform1f(u_fh, (float)maps_h);
    glUniform1f(u_lw, (float)maps_w);
    glUniform1f(u_lh, (float)maps_h);
    glUniform1f(u_lineW, 1.5f);
    glUniform1f(u_sdRange, 16.0f);
    glUniform1f(u_fade, g_fade);
    glUniform3fv(u_ink, 1, g_ink);
    glUniform4fv(u_cropOld, 1, o->crop_old);
    glUniform4fv(u_cropNew, 1, o->crop_new);

    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, o->tex_old);
    glUniform1i(u_old, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, o->tex_new);
    glUniform1i(u_new, 1);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, tex_campo);
    glUniform1i(u_campo, 2);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, tex_linea);
    glUniform1i(u_linea, 3);

    glDrawArrays(GL_TRIANGLES, 0, 3);

    o->frame_cb = wl_surface_frame(o->surf);
    wl_callback_add_listener(o->frame_cb, &frame_cb_listener, o);
    eglSwapBuffers(egl_dpy, o->esurf);
}

static void render_all(void)
{
    for (struct output *o = outputs; o; o = o->next)
        render(o);
}

static void ls_configure(void *data, struct zwlr_layer_surface_v1 *ls,
                         uint32_t serial, uint32_t w, uint32_t h)
{
    struct output *o = data;
    zwlr_layer_surface_v1_ack_configure(ls, serial);
    if (w == 0 || h == 0) return;
    if (!o->win) {
        o->win = wl_egl_window_create(o->surf, (int)w, (int)h);
        if (!o->win) return;
        o->esurf = eglCreateWindowSurface(egl_dpy, egl_cfg, (EGLNativeWindowType)o->win, NULL);
        if (o->esurf == EGL_NO_SURFACE) return;
    } else {
        wl_egl_window_resize(o->win, (int)w, (int)h, 0, 0);
    }
    o->w = (int32_t)w;
    o->h = (int32_t)h;
    if (!o->configured) { o->configured = 1; n_ready++; }
    logmsg("%s: %dx%d", o->name, o->w, o->h);
    render(o);
}

static void ls_closed(void *data, struct zwlr_layer_surface_v1 *ls)
{
    (void)data; (void)ls;
    _exit(0);
}

static const struct zwlr_layer_surface_v1_listener ls_listener = {
    .configure = ls_configure,
    .closed = ls_closed,
};

static void create_surface(struct output *o)
{
    o->surf = wl_compositor_create_surface(wl_comp);
    if (!o->surf) return;
    struct wl_region *empty = wl_compositor_create_region(wl_comp);
    wl_surface_set_input_region(o->surf, empty);
    wl_region_destroy(empty);

    o->ls = zwlr_layer_shell_v1_get_layer_surface(wl_shell, o->surf, o->wl,
                                                  ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
                                                  "wallfx-gpu");
    zwlr_layer_surface_v1_set_anchor(o->ls, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                                             ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);
    zwlr_layer_surface_v1_set_size(o->ls, o->w > 0 ? (uint32_t)o->w : 0,
                                   o->h > 0 ? (uint32_t)o->h : 0);
    /* -1: do not let another layer's exclusive zone (the Noctalia bar) shrink
     * this surface — the transition has to cover the whole output. */
    zwlr_layer_surface_v1_set_exclusive_zone(o->ls, -1);
    zwlr_layer_surface_v1_set_keyboard_interactivity(o->ls, 0);
    zwlr_layer_surface_v1_add_listener(o->ls, &ls_listener, o);
    wl_surface_commit(o->surf);
}

/* ----------------------------------------------------------------- outputs */

static void out_geometry(void *data, struct wl_output *wl, int32_t x, int32_t y,
                         int32_t pw, int32_t ph, int32_t subpixel,
                         const char *make, const char *model, int32_t transform)
{
    (void)wl; (void)pw; (void)ph; (void)subpixel; (void)make; (void)model; (void)transform;
    struct output *o = data;
    o->x = x; o->y = y;
}

static void out_mode(void *data, struct wl_output *wl, uint32_t flags,
                     int32_t w, int32_t h, int32_t refresh)
{
    (void)wl; (void)flags; (void)refresh;
    struct output *o = data;
    if (w > 0 && h > 0) { o->w = w; o->h = h; }
}

static void out_done(void *data, struct wl_output *wl) { (void)data; (void)wl; }
static void out_scale(void *data, struct wl_output *wl, int32_t f) { (void)data; (void)wl; (void)f; }
static void out_name(void *data, struct wl_output *wl, const char *name)
{
    (void)wl;
    struct output *o = data;
    snprintf(o->name, sizeof o->name, "%s", name);
}
static void out_desc(void *data, struct wl_output *wl, const char *d) { (void)data; (void)wl; (void)d; }

static const struct wl_output_listener out_listener = {
    .geometry = out_geometry, .mode = out_mode, .done = out_done,
    .scale = out_scale, .name = out_name, .description = out_desc,
};

static void reg_global(void *data, struct wl_registry *reg, uint32_t name,
                       const char *iface, uint32_t ver)
{
    (void)data;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        wl_comp = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    } else if (strcmp(iface, zwlr_layer_shell_v1_interface.name) == 0) {
        wl_shell = wl_registry_bind(reg, name, &zwlr_layer_shell_v1_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0) {
        uint32_t v = ver < 4 ? ver : 4;
        struct output *o = calloc(1, sizeof *o);
        o->wl = wl_registry_bind(reg, name, &wl_output_interface, v);
        o->next = outputs;
        outputs = o;
        n_outputs++;
        wl_output_add_listener(o->wl, &out_listener, o);
    }
}

static void reg_remove(void *data, struct wl_registry *reg, uint32_t name)
{ (void)data; (void)reg; (void)name; }

static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* -------------------------------------------------------------------- egl */

static void egl_boot(void)
{
    egl_dpy = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wl_dpy, NULL);
    if (egl_dpy == EGL_NO_DISPLAY) { fprintf(stderr, "wallfx-gpu: no EGL display\n"); exit(1); }
    EGLint major = 0, minor = 0;
    if (!eglInitialize(egl_dpy, &major, &minor)) { fprintf(stderr, "wallfx-gpu: eglInitialize failed\n"); exit(1); }
    if (!eglBindAPI(EGL_OPENGL_ES_API)) { fprintf(stderr, "wallfx-gpu: eglBindAPI failed\n"); exit(1); }
    const EGLint cfg_attr[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint n = 0;
    if (!eglChooseConfig(egl_dpy, cfg_attr, &egl_cfg, 1, &n) || n < 1) {
        fprintf(stderr, "wallfx-gpu: no matching EGL config\n");
        exit(1);
    }
    const EGLint ctx_attr[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    egl_ctx = eglCreateContext(egl_dpy, egl_cfg, EGL_NO_CONTEXT, ctx_attr);
    if (egl_ctx == EGL_NO_CONTEXT) { fprintf(stderr, "wallfx-gpu: eglCreateContext failed\n"); exit(1); }
    if (!eglMakeCurrent(egl_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, egl_ctx)) {
        const EGLint pb[] = { EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE };
        EGLSurface tmp = eglCreatePbufferSurface(egl_dpy, egl_cfg, pb);
        if (tmp == EGL_NO_SURFACE || !eglMakeCurrent(egl_dpy, tmp, tmp, egl_ctx)) {
            fprintf(stderr, "wallfx-gpu: cannot make an EGL context current\n");
            exit(1);
        }
    }
}

/* ------------------------------------------------------------------- main */

/* Offscreen render of the effect at chosen instants, for verification without
 * a window on screen: WALLFX_GPU_SELFTEST=/tmp/dir wallfx-gpu OLD NEW C L */
static void selftest(const char *dir, const char *oldimg, const char *newimg,
                     int w, int h)
{
    int ow = 0, oh = 0, nw = 0, nh = 0;
    GLuint otex = load_image(oldimg, &ow, &oh);
    GLuint ntex = load_image(newimg, &nw, &nh);
    if (!otex || !ntex || !tex_campo || !tex_linea) return;

    const EGLint pb[] = { EGL_WIDTH, w, EGL_HEIGHT, h, EGL_NONE };
    EGLSurface surf = eglCreatePbufferSurface(egl_dpy, egl_cfg, pb);
    if (surf == EGL_NO_SURFACE || !eglMakeCurrent(egl_dpy, surf, surf, egl_ctx)) return;
    glViewport(0, 0, w, h);
    if (cfg_verbose) {
        EGLint ew = 0, eh = 0;
        GLint vp[4] = { 0 };
        eglQuerySurface(egl_dpy, surf, EGL_WIDTH, &ew);
        eglQuerySurface(egl_dpy, surf, EGL_HEIGHT, &eh);
        glGetIntegerv(GL_VIEWPORT, vp);
        logmsg("selftest: pbuffer=%dx%d viewport=%d,%d %dx%d", ew, eh, vp[0], vp[1], vp[2], vp[3]);
    }

    float co[4], cn[4];
    crop_for(ow, oh, w, h, co);
    crop_for(nw, nh, w, h, cn);
    if (cfg_verbose)
        logmsg("selftest: old=%dx%d crop=[%g %g %g %g]  new=%dx%d crop=[%g %g %g %g]",
               ow, oh, co[0], co[1], co[2], co[3], nw, nh, cn[0], cn[1], cn[2], cn[3]);

    const double ts[] = { 0.02, 0.15, 0.33, 0.45, 0.62, 0.85, 1.0 };
    unsigned char *px = malloc((size_t)w * h * 4);
    for (int i = 0; i < (int)(sizeof ts / sizeof ts[0]) && px; i++) {
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(prog);
        glBindVertexArray(vao);
        glUniform1f(u_t, (float)ts[i]);
        glUniform1f(u_sw, (float)w);
        glUniform1f(u_sh, (float)h);
        glUniform1f(u_fw, (float)maps_w);
        glUniform1f(u_fh, (float)maps_h);
        glUniform1f(u_lw, (float)maps_w);
        glUniform1f(u_lh, (float)maps_h);
        glUniform1f(u_lineW, 1.5f);
        glUniform1f(u_sdRange, 16.0f);
        glUniform1f(u_fade, 1.0f);
        glUniform3fv(u_ink, 1, g_ink);
        glUniform4fv(u_cropOld, 1, co);
        glUniform4fv(u_cropNew, 1, cn);
        glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, otex); glUniform1i(u_old, 0);
        glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, ntex); glUniform1i(u_new, 1);
        glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, tex_campo); glUniform1i(u_campo, 2);
        glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, tex_linea); glUniform1i(u_linea, 3);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/t-%02d.ppm", dir, (int)(ts[i] * 100));
        FILE *f = fopen(path, "wb");
        if (!f) continue;
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        /* glReadPixels is bottom-up; PPM is top-down. Copy channel by channel
         * (a strided fwrite of the RGBA buffer as RGB silently interleaves). */
        unsigned char *rowbuf = malloc((size_t)w * 3);
        for (int y = h - 1; y >= 0 && rowbuf; y--) {
            const unsigned char *src = px + (size_t)y * w * 4;
            for (int x = 0; x < w; x++) {
                rowbuf[x * 3 + 0] = src[x * 4 + 0];
                rowbuf[x * 3 + 1] = src[x * 4 + 1];
                rowbuf[x * 3 + 2] = src[x * 4 + 2];
            }
            fwrite(rowbuf, 1, (size_t)w * 3, f);
        }
        free(rowbuf);
        fclose(f);
        logmsg("selftest frame t=%.2f -> %s", ts[i], path);
    }
    free(px);
}

static void fallback(const char *newimg)
{
    /* the wallpaper must change even if the effect cannot be shown */
    pid_t pid = fork();
    if (pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDOUT_FILENO); dup2(dn, STDERR_FILENO); }
        execlp("awww", "awww", "img", newimg,
               "--transition-type", "fade", "--transition-duration", "0.5", (char *)NULL);
        _exit(127);
    }
    if (pid > 0) waitpid(pid, NULL, 0);
}

static pid_t swap_pid;

static void swap_awww(const char *newimg)
{
    swap_pid = fork();
    if (swap_pid == 0) {
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDOUT_FILENO); dup2(dn, STDERR_FILENO); }
        execlp("awww", "awww", "img", newimg, "--transition-type", "none", (char *)NULL);
        _exit(127);
    }
}

/* the wallpaper's lightest tone, sampled from the decoded new image */
static void ink_from_buffer(const unsigned char *buf, size_t len, float out[3])
{
    /* coarse scan: every 997th pixel is plenty for a tone */
    unsigned best = 0;
    double br = 1, bg = 1, bb = 1;
    int seen = 0;
    for (size_t i = 0; i + 3 < len; i += 4 * 997) {
        unsigned r = buf[i], g = buf[i + 1], b = buf[i + 2];
        unsigned l = (unsigned)(0.299 * r + 0.587 * g + 0.114 * b);
        if (l > best) { best = l; br = r; bg = g; bb = b; }
        seen++;
    }
    (void)seen;
    if (best < 150) {           /* too dark to read on: lift towards white */
        br = br + (255 - br) * 0.7;
        bg = bg + (255 - bg) * 0.7;
        bb = bb + (255 - bb) * 0.7;
    }
    out[0] = (float)(br / 255.0);
    out[1] = (float)(bg / 255.0);
    out[2] = (float)(bb / 255.0);
}

int main(int argc, char **argv)
{
    cfg_verbose = getenv("WALLFX_GPU_DEBUG") != NULL;
    if (argc < 5) {
        fprintf(stderr, "usage: wallfx-gpu OLD NEW CAMPO LINEA [DURATION_MS]\n");
        return 2;
    }
    const char *oldimg = argv[1], *newimg = argv[2];
    const char *campo = argv[3], *linea = argv[4];

    signal(SIGPIPE, SIG_IGN);

    wl_dpy = wl_display_connect(NULL);
    if (!wl_dpy) { fallback(newimg); return 1; }
    wl_reg = wl_display_get_registry(wl_dpy);
    wl_registry_add_listener(wl_reg, &reg_listener, NULL);
    wl_display_roundtrip(wl_dpy);
    wl_display_roundtrip(wl_dpy);
    if (!wl_comp || !wl_shell || !outputs) { fallback(newimg); return 1; }

    egl_boot();
    gpu_init();

    int old_w = 0, old_h = 0, new_w = 0, new_h = 0;
    GLuint old_tex = load_image(oldimg, &old_w, &old_h);
    int new_iw = 0, new_ih = 0;
    GLuint new_tex = 0;
    {
        /* keep the decoded new-image bytes for the ink tone */
        image_dims(newimg, &new_iw, &new_ih);
        if (new_iw > 0 && new_ih > 0) {
            char fit[64];
            snprintf(fit, sizeof fit, "%dx%d>", IMG_MAX, IMG_MAX);
            char *av[] = { "magick", (char *)newimg, "-depth", "8", "-resize", fit,
                           "rgba:-", NULL };
            unsigned char *buf = NULL;
            size_t len = 0;
            if (magick_pipe(av, &buf, &len) > 0) {
                double s = 1.0;
                if (new_iw > IMG_MAX || new_ih > IMG_MAX)
                    s = (new_iw >= new_ih) ? (double)IMG_MAX / new_iw : (double)IMG_MAX / new_ih;
                int dw = (int)lround(new_iw * s), dh = (int)lround(new_ih * s);
                if (dw > 0 && dh > 0 && len >= (size_t)dw * dh * 4) {
                    new_tex = upload_rgba(buf, dw, dh);
                    new_w = dw; new_h = dh;
                    ink_from_buffer(buf, len, g_ink);
                }
                free(buf);
            }
        }
    }
    load_maps(campo, linea);
    if (!old_tex || !new_tex || !tex_campo || !tex_linea) {
        fallback(newimg);
        return 1;
    }

    const char *st = getenv("WALLFX_GPU_SELFTEST");
    if (st && *st) {
        selftest(st, oldimg, newimg, 1280, 720);
        return 0;
    }

    for (struct output *o = outputs; o; o = o->next) {
        int ow = o->w > 0 ? o->w : 1920, oh = o->h > 0 ? o->h : 1080;
        o->tex_old = old_tex;
        o->tex_new = new_tex;
        crop_for(old_w, old_h, ow, oh, o->crop_old);
        crop_for(new_w, new_h, ow, oh, o->crop_new);
        create_surface(o);
    }
    wl_display_roundtrip(wl_dpy);

    /* watchdog: if the surfaces do not come up, the wallpaper still changes */
    double boot = now_ms();
    while (n_ready < n_outputs && now_ms() - boot < 2500) {
        wl_display_dispatch_pending(wl_dpy);
        struct pollfd pf = { .fd = wl_display_get_fd(wl_dpy), .events = POLLIN };
        if (poll(&pf, 1, 20) > 0) wl_display_dispatch(wl_dpy);
    }
    if (n_ready == 0) { fallback(newimg); return 1; }

    started = 1;
    started_ms = now_ms();
    int swapped = 0;
    double last = started_ms;

    for (;;) {
        double now = now_ms();
        double el = now - started_ms;

        if (!swapped && el >= 130) {
            swap_awww(newimg);
            swapped = 1;
        }
        double t = el / 2000.0;
        if (t > 1.0) t = 1.0;
        double fade;
        if (el < 130) fade = el / 130.0;                 /* in: over identical old */
        else if (t < 1.0) fade = 1.0;
        else {
            fade = 1.0 - (el - 2000.0) / 130.0;          /* out: over the new */
            if (fade <= 0.0) break;
        }

        /* the globals render() reads */
        g_fade = (float)fade;

        render_all();
        wl_display_flush(wl_dpy);

        struct pollfd pf = { .fd = wl_display_get_fd(wl_dpy), .events = POLLIN };
        int pr = poll(&pf, 1, 8);
        if (pr > 0) wl_display_dispatch(wl_dpy);
        else wl_display_dispatch_pending(wl_dpy);

        if (now - last > 60000) break;
        last = now;
    }

    if (swap_pid > 0) waitpid(swap_pid, NULL, 0);
    return 0;
}
