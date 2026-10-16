/*
 * Rombie's netplay engine: a minimal libretro frontend for WebAssembly, statically linked with
 * one core per build. It runs one frame at a time with given inputs and keeps a ring of save
 * states so a frame can be rolled back to and run again with corrected inputs. The page never
 * calls these functions itself: netplay-worker.js, built into the same file, owns the module and
 * talks to the page only through messages.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <emscripten.h>
#include "libretro.h"

#define PORTS 4
/* A power of two; the rollback window is one less, since the slot for the frame about to run
 * is overwritten when that frame is saved. */
#define RING_SLOTS 16
#define MAX_OPTIONS 256
#define AUDIO_CAPACITY (48000 * 2) /* about a second of stereo samples */
#define HASH_SEED 2166136261u

static struct {
  uint16_t buttons[PORTS];
  int16_t analog[PORTS][4]; /* left x, left y, right x, right y */
} input;

static enum retro_pixel_format pixel_format = RETRO_PIXEL_FORMAT_0RGB1555;
static uint32_t *frame_rgba;
static size_t frame_capacity;
static unsigned frame_width, frame_height;
static int frame_ready;
static int video_enabled = 1;
static int video_hashing;
static uint32_t video_hash;

static int16_t audio[AUDIO_CAPACITY];
static size_t audio_length;
static int audio_enabled = 1;

static struct {
  char *key;
  char *fallback; /* the core's own default, the first of its listed values */
  char *value;    /* set by the page, or NULL */
} options[MAX_OPTIONS];
static int option_count;
static int options_updated;

static struct retro_system_av_info av_info;
static struct retro_system_info system_info;
static void *game_data;
static int game_loaded;

static size_t state_size;
static uint8_t *ring;
static int32_t ring_frame[RING_SLOTS];
static int32_t frame_number; /* the frame about to run */

static double now_ms(void) { return emscripten_get_now(); }

static void log_message(enum retro_log_level level, const char *fmt, ...) {
  static const char *names[] = { "debug", "info", "warn", "error" };
  char line[1024];
  va_list args;
  va_start(args, fmt);
  vsnprintf(line, sizeof(line), fmt, args);
  va_end(args);
  if (level >= RETRO_LOG_INFO) printf("[core %s] %s", names[level & 3], line);
}

static char *copy_string(const char *s, size_t n) {
  char *out = malloc(n + 1);
  memcpy(out, s, n);
  out[n] = 0;
  return out;
}

static int find_option(const char *key) {
  for (int i = 0; i < option_count; i++)
    if (!strcmp(options[i].key, key)) return i;
  return -1;
}

static int add_option(const char *key) {
  int i = find_option(key);
  if (i >= 0 || option_count >= MAX_OPTIONS) return i;
  options[option_count].key = copy_string(key, strlen(key));
  options[option_count].fallback = NULL;
  options[option_count].value = NULL;
  return option_count++;
}

/* Legacy variables read "Description; first|second|...", and the first value is the default,
 * which is what RetroArch hands a core for any option nobody has set. */
static void define_variables(const struct retro_variable *vars) {
  for (; vars && vars->key; vars++) {
    int i = add_option(vars->key);
    if (i < 0 || !vars->value) continue;
    const char *list = strstr(vars->value, "; ");
    if (!list) continue;
    list += 2;
    const char *end = strchr(list, '|');
    free(options[i].fallback);
    options[i].fallback = copy_string(list, end ? (size_t)(end - list) : strlen(list));
  }
}

static bool environment(unsigned cmd, void *data) {
  switch (cmd) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE:
      *(bool *)data = true;
      return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      enum retro_pixel_format format = *(const enum retro_pixel_format *)data;
      if (format > RETRO_PIXEL_FORMAT_RGB565) return false;
      pixel_format = format;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
    case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
      *(const char **)data = "/system";
      return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      *(const char **)data = "/save";
      return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
      ((struct retro_log_callback *)data)->log = log_message;
      return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES:
      define_variables(data);
      return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      struct retro_variable *var = data;
      int i = find_option(var->key);
      var->value = i < 0 ? NULL : options[i].value ? options[i].value : options[i].fallback;
      return var->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
      *(bool *)data = options_updated;
      options_updated = 0;
      return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
      return true;
    case RETRO_ENVIRONMENT_GET_LANGUAGE:
      *(unsigned *)data = RETRO_LANGUAGE_ENGLISH;
      return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
      av_info.geometry = *(const struct retro_game_geometry *)data;
      return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO:
      av_info = *(const struct retro_system_av_info *)data;
      return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE:
      printf("[core message] %s\n", ((const struct retro_message *)data)->msg);
      return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
      printf("[core message] %s\n", ((const struct retro_message_ext *)data)->msg);
      return true;
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
    case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
    case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
    case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
      return true;
    default:
      /* Everything else, the core options v1/v2 interfaces included (so cores fall back to
       * legacy variables), is unsupported. */
      return false;
  }
}

static uint32_t hash_bytes(uint32_t h, const uint8_t *p, size_t n);

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
  if (!data) return; /* a duplicate of the last frame */
  frame_width = width;
  frame_height = height;
  frame_ready = 1;
  if (video_hashing) {
    size_t row_bytes = (size_t)width * (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888 ? 4 : 2);
    video_hash = HASH_SEED;
    for (unsigned y = 0; y < height; y++)
      video_hash = hash_bytes(video_hash, (const uint8_t *)data + y * pitch, row_bytes);
  }
  if (!video_enabled) return;
  if ((size_t)width * height > frame_capacity) {
    frame_capacity = (size_t)width * height;
    frame_rgba = realloc(frame_rgba, frame_capacity * 4);
  }
  uint32_t *out = frame_rgba;
  for (unsigned y = 0; y < height; y++) {
    const uint8_t *row = (const uint8_t *)data + y * pitch;
    if (pixel_format == RETRO_PIXEL_FORMAT_XRGB8888) {
      const uint32_t *in = (const uint32_t *)row;
      for (unsigned x = 0; x < width; x++) {
        uint32_t p = in[x];
        *out++ = 0xff000000u | ((p & 0xff) << 16) | (p & 0xff00) | ((p >> 16) & 0xff);
      }
    } else {
      const uint16_t *in = (const uint16_t *)row;
      int rgb565 = pixel_format == RETRO_PIXEL_FORMAT_RGB565;
      for (unsigned x = 0; x < width; x++) {
        uint16_t p = in[x];
        unsigned r, g, b;
        if (rgb565) {
          r = (p >> 11) & 31; g = (p >> 5) & 63; b = p & 31;
          g = (g << 2) | (g >> 4);
        } else {
          r = (p >> 10) & 31; g = (p >> 5) & 31; b = p & 31;
          g = (g << 3) | (g >> 2);
        }
        r = (r << 3) | (r >> 2);
        b = (b << 3) | (b >> 2);
        *out++ = 0xff000000u | (b << 16) | (g << 8) | r;
      }
    }
  }
}

static size_t audio_batch(const int16_t *data, size_t frames) {
  if (audio_enabled) {
    size_t samples = frames * 2;
    if (samples > AUDIO_CAPACITY - audio_length) samples = AUDIO_CAPACITY - audio_length;
    memcpy(audio + audio_length, data, samples * sizeof(int16_t));
    audio_length += samples;
  }
  return frames;
}

static void audio_sample(int16_t left, int16_t right) {
  int16_t pair[2] = { left, right };
  audio_batch(pair, 1);
}

static void input_poll(void) {}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
  if (port >= PORTS) return 0;
  switch (device & RETRO_DEVICE_MASK) {
    case RETRO_DEVICE_JOYPAD:
      if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return (int16_t)input.buttons[port];
      return id < 16 ? (input.buttons[port] >> id) & 1 : 0;
    case RETRO_DEVICE_ANALOG:
      if (index <= RETRO_DEVICE_INDEX_ANALOG_RIGHT && id <= RETRO_DEVICE_ID_ANALOG_Y)
        return input.analog[port][index * 2 + id];
      return 0;
    default:
      return 0;
  }
}

static uint32_t hash_bytes(uint32_t h, const uint8_t *p, size_t n) {
  size_t i = 0;
  for (; i + 4 <= n; i += 4) {
    uint32_t word;
    memcpy(&word, p + i, 4);
    h = (h ^ word) * 16777619u;
    h ^= h >> 15;
  }
  for (; i < n; i++) h = (h ^ p[i]) * 16777619u;
  return h;
}

static void clear_ring(void) {
  for (int i = 0; i < RING_SLOTS; i++) ring_frame[i] = -1;
}

EMSCRIPTEN_KEEPALIVE int np_init(void) {
  retro_set_environment(environment);
  retro_set_video_refresh(video_refresh);
  retro_set_audio_sample(audio_sample);
  retro_set_audio_sample_batch(audio_batch);
  retro_set_input_poll(input_poll);
  retro_set_input_state(input_state);
  retro_init();
  retro_get_system_info(&system_info);
  return RETRO_API_VERSION;
}

EMSCRIPTEN_KEEPALIVE const char *np_library_name(void) { return system_info.library_name; }
EMSCRIPTEN_KEEPALIVE const char *np_library_version(void) { return system_info.library_version; }

EMSCRIPTEN_KEEPALIVE void np_set_option(const char *key, const char *value) {
  int i = add_option(key);
  if (i < 0) return;
  free(options[i].value);
  options[i].value = value ? copy_string(value, strlen(value)) : NULL;
  options_updated = 1;
}

/* The game is read from the module's file system: cores that want a path get only the path (a
 * disc can be hundreds of MB, read as the core needs it), and cores that want the data get that. */
EMSCRIPTEN_KEEPALIVE int np_load_game(const char *path) {
  struct retro_game_info info = { path, NULL, 0, NULL };
  if (!system_info.need_fullpath) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    game_data = malloc(size > 0 ? size : 1);
    info.data = game_data;
    info.size = fread(game_data, 1, size, f);
    fclose(f);
  }
  if (!retro_load_game(&info)) return 0;
  game_loaded = 1;
  /* The core has just read the options it was loaded with. Left pending, they would be read again at its first
   * frame, which only this engine runs that way (pcsx_rearmed reopens its GPU on it). */
  options_updated = 0;
  retro_get_system_av_info(&av_info);
  state_size = retro_serialize_size();
  ring = malloc(state_size * RING_SLOTS);
  clear_ring();
  frame_number = 0;
  return 1;
}

EMSCRIPTEN_KEEPALIVE void np_unload(void) {
  if (game_loaded) retro_unload_game();
  retro_deinit();
  game_loaded = 0;
  free(game_data);
  free(ring);
  game_data = NULL;
  ring = NULL;
}

EMSCRIPTEN_KEEPALIVE void np_set_port_device(unsigned port, unsigned device) {
  retro_set_controller_port_device(port, device);
}

EMSCRIPTEN_KEEPALIVE void np_reset(void) {
  retro_reset();
  clear_ring();
}

EMSCRIPTEN_KEEPALIVE double np_fps(void) { return av_info.timing.fps; }
EMSCRIPTEN_KEEPALIVE double np_sample_rate(void) { return av_info.timing.sample_rate; }
EMSCRIPTEN_KEEPALIVE unsigned np_base_width(void) { return av_info.geometry.base_width; }
EMSCRIPTEN_KEEPALIVE unsigned np_base_height(void) { return av_info.geometry.base_height; }
EMSCRIPTEN_KEEPALIVE double np_aspect_ratio(void) { return av_info.geometry.aspect_ratio; }

EMSCRIPTEN_KEEPALIVE void np_set_input(unsigned port, unsigned buttons, int lx, int ly, int rx, int ry) {
  if (port >= PORTS) return;
  input.buttons[port] = (uint16_t)buttons;
  input.analog[port][0] = (int16_t)lx;
  input.analog[port][1] = (int16_t)ly;
  input.analog[port][2] = (int16_t)rx;
  input.analog[port][3] = (int16_t)ry;
}

EMSCRIPTEN_KEEPALIVE void np_set_av_enabled(int video, int sound) {
  video_enabled = video;
  audio_enabled = sound;
}

/* Saves the state before the frame into the ring, then runs it. */
EMSCRIPTEN_KEEPALIVE int np_run_frame(void) {
  int slot = frame_number & (RING_SLOTS - 1);
  if (!retro_serialize(ring + (size_t)slot * state_size, state_size)) return 0;
  ring_frame[slot] = frame_number;
  /* A frame that shows no new picture (a 30 fps game, every other frame) hashes as 0, not as the
   * last picture shown, which after a rollback was drawn by frames since undone. */
  video_hash = 0;
  retro_run();
  frame_number++;
  return 1;
}

EMSCRIPTEN_KEEPALIVE int32_t np_frame_number(void) { return frame_number; }

/* Back to the state before `frame`, if the ring still holds it. */
EMSCRIPTEN_KEEPALIVE int np_rollback(int32_t frame) {
  int slot = frame & (RING_SLOTS - 1);
  if (frame < 0 || ring_frame[slot] != frame) return 0;
  if (!retro_unserialize(ring + (size_t)slot * state_size, state_size)) return 0;
  frame_number = frame;
  for (int i = 0; i < RING_SLOTS; i++)
    if (ring_frame[i] > frame) ring_frame[i] = -1;
  return 1;
}

/* A hash of the state before `frame`, from the ring; 0 when it is no longer there. */
EMSCRIPTEN_KEEPALIVE uint32_t np_ring_hash(int32_t frame) {
  int slot = frame & (RING_SLOTS - 1);
  if (frame < 0 || ring_frame[slot] != frame) return 0;
  return hash_bytes(HASH_SEED, ring + (size_t)slot * state_size, state_size);
}

/* A hash of the game's own memory (system RAM, video RAM, save RAM, as far as the core exposes
 * them): what the game itself sees, without the frontend-side state a core may not restore
 * exactly on load (fceumm's sound filter, for one). */
EMSCRIPTEN_KEEPALIVE uint32_t np_memory_hash(void) {
  static const unsigned types[] = { RETRO_MEMORY_SYSTEM_RAM, RETRO_MEMORY_VIDEO_RAM, RETRO_MEMORY_SAVE_RAM };
  uint32_t h = HASH_SEED;
  for (int i = 0; i < 3; i++) {
    const uint8_t *data = retro_get_memory_data(types[i]);
    size_t size = data ? retro_get_memory_size(types[i]) : 0;
    if (size) h = hash_bytes(h, data, size);
  }
  return h;
}

/* With hashing on, each frame's picture is hashed as the core hands it over, drawn or not. */
EMSCRIPTEN_KEEPALIVE void np_set_video_hashing(int on) { video_hashing = on; }
EMSCRIPTEN_KEEPALIVE uint32_t np_video_hash(void) { return video_hash; }

EMSCRIPTEN_KEEPALIVE size_t np_state_size(void) { return state_size; }

EMSCRIPTEN_KEEPALIVE int np_save_state(uint8_t *out) {
  return retro_serialize(out, state_size);
}

/* Loads a full state, which becomes the state before `frame`; the ring starts over. */
EMSCRIPTEN_KEEPALIVE int np_load_state(const uint8_t *data, size_t size, int32_t frame) {
  if (size != state_size || !retro_unserialize(data, size)) return 0;
  frame_number = frame;
  clear_ring();
  return 1;
}

/* A libretro memory id: RETRO_MEMORY_SAVE_RAM (0) unless the core has more than one, as Gearsystem's link does,
 * where the second console's save RAM is (2 << 8) | RETRO_MEMORY_SAVE_RAM. */
EMSCRIPTEN_KEEPALIVE uint8_t *np_sram_data(unsigned id) {
  return retro_get_memory_data(id);
}

EMSCRIPTEN_KEEPALIVE size_t np_sram_size(unsigned id) {
  return retro_get_memory_data(id) ? retro_get_memory_size(id) : 0;
}

EMSCRIPTEN_KEEPALIVE uint32_t *np_frame_pixels(void) { return frame_rgba; }
EMSCRIPTEN_KEEPALIVE unsigned np_frame_width(void) { return frame_width; }
EMSCRIPTEN_KEEPALIVE unsigned np_frame_height(void) { return frame_height; }

EMSCRIPTEN_KEEPALIVE int np_take_frame_ready(void) {
  int ready = frame_ready && frame_rgba;
  frame_ready = 0;
  return ready;
}

EMSCRIPTEN_KEEPALIVE int16_t *np_audio_samples(void) { return audio; }
EMSCRIPTEN_KEEPALIVE size_t np_audio_length(void) { return audio_length; }
EMSCRIPTEN_KEEPALIVE void np_audio_clear(void) { audio_length = 0; }

/* Average milliseconds for a save, a load and a frame, measured inside the engine. */
EMSCRIPTEN_KEEPALIVE double np_bench(int iterations, int which) {
  uint8_t *scratch = malloc(state_size);
  retro_serialize(scratch, state_size);
  double start = now_ms();
  for (int i = 0; i < iterations; i++) {
    if (which == 0) retro_serialize(scratch, state_size);
    else if (which == 1) retro_unserialize(scratch, state_size);
    else retro_run();
  }
  double elapsed = now_ms() - start;
  retro_unserialize(scratch, state_size);
  free(scratch);
  return elapsed / iterations;
}
