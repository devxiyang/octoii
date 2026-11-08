/*
 * The C beneath Siphon's images, one translation unit: Wuffs decodes PNG, JPEG, GIF's first frame, WebP, BMP and QOI
 * to RGBA, not premultiplied, memory-safely, as an image may come from anywhere; stb resizes RGBA in sRGB and writes it
 * as PNG or as JPEG. What these functions give back is malloc's, freed with siphon_image_free.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__VP8
#define WUFFS_CONFIG__MODULE__WEBP
#define WUFFS_CONFIG__MODULE__BMP
#define WUFFS_CONFIG__MODULE__QOI
#include "wuffs-v0.4.c"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STB_IMAGE_RESIZE_STATIC
#include "stb_image_resize2.h"

/* What a call comes to. */
enum { SIPHON_IMAGE_OK = 0, SIPHON_IMAGE_UNKNOWN_FORMAT = 1, SIPHON_IMAGE_MALFORMED = 2, SIPHON_IMAGE_TOO_LARGE = 3, SIPHON_IMAGE_OUT_OF_MEMORY = 4 };

/* The formats an image is decoded from, as the Zig side names them. */
enum { SIPHON_FORMAT_PNG = 0, SIPHON_FORMAT_JPEG = 1, SIPHON_FORMAT_GIF = 2, SIPHON_FORMAT_WEBP = 3, SIPHON_FORMAT_BMP = 4, SIPHON_FORMAT_QOI = 5 };

/* The decoder of the format its first bytes tell, and the format; none where they tell none Wuffs reads here. */
static wuffs_base__image_decoder *decoder_for(const uint8_t *data, size_t len, int *format) {
	int32_t fourcc = wuffs_base__magic_number_guess_fourcc(wuffs_base__make_slice_u8((uint8_t *)data, len), true);
	switch (fourcc) {
	case WUFFS_BASE__FOURCC__PNG: *format = SIPHON_FORMAT_PNG; return wuffs_png__decoder__alloc_as__wuffs_base__image_decoder();
	case WUFFS_BASE__FOURCC__JPEG: *format = SIPHON_FORMAT_JPEG; return wuffs_jpeg__decoder__alloc_as__wuffs_base__image_decoder();
	case WUFFS_BASE__FOURCC__GIF: *format = SIPHON_FORMAT_GIF; return wuffs_gif__decoder__alloc_as__wuffs_base__image_decoder();
	case WUFFS_BASE__FOURCC__WEBP: *format = SIPHON_FORMAT_WEBP; return wuffs_webp__decoder__alloc_as__wuffs_base__image_decoder();
	case WUFFS_BASE__FOURCC__BMP: *format = SIPHON_FORMAT_BMP; return wuffs_bmp__decoder__alloc_as__wuffs_base__image_decoder();
	case WUFFS_BASE__FOURCC__QOI: *format = SIPHON_FORMAT_QOI; return wuffs_qoi__decoder__alloc_as__wuffs_base__image_decoder();
	default: return NULL;
	}
}

/*
 * Decodes the image in data, its first frame: its width, height and format, and its pixels, RGBA not premultiplied,
 * malloc's, transparent where the frame draws nothing; refused past pixels_max before its pixels are taken.
 */
int siphon_image_decode(const uint8_t *data, size_t len, uint64_t pixels_max, uint32_t *width, uint32_t *height, int *format, uint8_t **pixels) {
	wuffs_base__image_decoder *decoder = decoder_for(data, len, format);
	if (decoder == NULL) return SIPHON_IMAGE_UNKNOWN_FORMAT;
	wuffs_base__io_buffer source = wuffs_base__ptr_u8__reader((uint8_t *)data, len, true);
	wuffs_base__image_config config = wuffs_base__null_image_config();
	wuffs_base__pixel_buffer buffer;
	uint8_t *work = NULL;
	uint8_t *decoded = NULL;
	uint64_t work_len = 0;
	uint32_t w = 0;
	uint32_t h = 0;
	int result = SIPHON_IMAGE_MALFORMED;
	if (wuffs_base__image_decoder__decode_image_config(decoder, &config, &source).repr != NULL) goto done;
	w = wuffs_base__pixel_config__width(&config.pixcfg);
	h = wuffs_base__pixel_config__height(&config.pixcfg);
	if (w == 0 || h == 0) goto done;
	if ((uint64_t)w * h > pixels_max) {
		result = SIPHON_IMAGE_TOO_LARGE;
		goto done;
	}
	wuffs_base__pixel_config__set(&config.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL, WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
	decoded = calloc((size_t)w * h, 4);
	work_len = wuffs_base__image_decoder__workbuf_len(decoder).max_incl;
	work = malloc(work_len > 0 ? work_len : 1);
	if (decoded == NULL || work == NULL) {
		result = SIPHON_IMAGE_OUT_OF_MEMORY;
		goto done;
	}
	if (wuffs_base__pixel_buffer__set_from_slice(&buffer, &config.pixcfg, wuffs_base__make_slice_u8(decoded, (size_t)w * h * 4)).repr != NULL) goto done;
	if (wuffs_base__image_decoder__decode_frame(decoder, &buffer, &source, WUFFS_BASE__PIXEL_BLEND__SRC, wuffs_base__make_slice_u8(work, work_len), NULL).repr != NULL) goto done;
	*width = w;
	*height = h;
	*pixels = decoded;
	decoded = NULL;
	result = SIPHON_IMAGE_OK;
done:
	free(work);
	free(decoded);
	free(decoder);
	return result;
}

/* Resizes width by height RGBA pixels into to_width by to_height, in sRGB, as an image's colours are meant. */
int siphon_image_resize(const uint8_t *pixels, uint32_t width, uint32_t height, uint8_t *into, uint32_t to_width, uint32_t to_height) {
	return stbir_resize_uint8_srgb(pixels, (int)width, (int)height, 0, into, (int)to_width, (int)to_height, 0, STBIR_RGBA) == NULL ? SIPHON_IMAGE_OUT_OF_MEMORY : SIPHON_IMAGE_OK;
}

/* Bytes written into memory as stb writes them, grown as they come. */
typedef struct { uint8_t *bytes; size_t len; size_t capacity; int failed; } written;

static void write_into(void *context, void *data, int size) {
	written *out = context;
	if (out->failed || size <= 0) return;
	if (out->len + (size_t)size > out->capacity) {
		size_t capacity = out->capacity == 0 ? 64 * 1024 : out->capacity;
		while (capacity < out->len + (size_t)size) capacity *= 2;
		uint8_t *grown = realloc(out->bytes, capacity);
		if (grown == NULL) { out->failed = 1; return; }
		out->bytes = grown;
		out->capacity = capacity;
	}
	memcpy(out->bytes + out->len, data, (size_t)size);
	out->len += (size_t)size;
}

/* What was written, given to the caller, or freed where it failed. */
static int given(written *out, int wrote, uint8_t **bytes, size_t *len) {
	if (!wrote || out->failed) { free(out->bytes); return SIPHON_IMAGE_OUT_OF_MEMORY; }
	*bytes = out->bytes;
	*len = out->len;
	return SIPHON_IMAGE_OK;
}

/* RGBA pixels written as a PNG. */
int siphon_image_write_png(const uint8_t *pixels, uint32_t width, uint32_t height, uint8_t **bytes, size_t *len) {
	written out = {0};
	int wrote = stbi_write_png_to_func(write_into, &out, (int)width, (int)height, 4, pixels, (int)width * 4);
	return given(&out, wrote, bytes, len);
}

/* RGBA pixels written as a JPEG of quality, their alpha left out as a JPEG holds none. */
int siphon_image_write_jpeg(const uint8_t *pixels, uint32_t width, uint32_t height, int quality, uint8_t **bytes, size_t *len) {
	written out = {0};
	int wrote = stbi_write_jpg_to_func(write_into, &out, (int)width, (int)height, 4, pixels, quality);
	return given(&out, wrote, bytes, len);
}

void siphon_image_free(void *bytes) {
	free(bytes);
}
