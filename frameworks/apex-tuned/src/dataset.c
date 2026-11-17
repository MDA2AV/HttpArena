#include "dataset.h"
#include <cjson/cJSON.h>

static dataset_item_t *g_items = NULL;
static size_t g_num_items = 0;

static inline void copy_json_prefix_tail(char *destination, const char *source, size_t length) {
    size_t offset = 0;
    if (length & 16) {
        memcpy(destination, source, 16);
        offset = 16;
    }
    if (length & 8) {
        memcpy(destination + offset, source + offset, 8);
        offset += 8;
    }
    if (length & 4) {
        memcpy(destination + offset, source + offset, 4);
        offset += 4;
    }
    if (length & 2) {
        memcpy(destination + offset, source + offset, 2);
        offset += 2;
    }
    if (length & 1) {
        destination[offset] = source[offset];
    }
}

static inline void copy_json_prefix(char *destination, const char *source, size_t length) {
    size_t full_blocks = length / 32;
    switch (full_blocks) {
    case 6:
        memcpy(destination + 160, source + 160, 32);
        [[fallthrough]];
    case 5:
        memcpy(destination + 128, source + 128, 32);
        [[fallthrough]];
    case 4:
        memcpy(destination + 96, source + 96, 32);
        [[fallthrough]];
    case 3:
        memcpy(destination + 64, source + 64, 32);
        [[fallthrough]];
    case 2:
        memcpy(destination + 32, source + 32, 32);
        [[fallthrough]];
    case 1:
        memcpy(destination, source, 32);
        break;
    case 0:
        break;
    default:
        memcpy(destination, source, length);
        return;
    }
    size_t copied_length = full_blocks * 32;
    copy_json_prefix_tail(destination + copied_length, source + copied_length, length - copied_length);
}

static int64_t cjson_int(const cJSON *object, const char *key) {
    const cJSON *value_node = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsNumber(value_node) ? (int64_t)value_node->valuedouble : 0;
}

static const char *cjson_str(const cJSON *object, const char *key) {
    const cJSON *value_node = cJSON_GetObjectItemCaseSensitive(object, key);
    return cJSON_IsString(value_node) ? value_node->valuestring : "";
}

bool dataset_load(const char *dataset_file_path) {
    FILE *file_handle = fopen(dataset_file_path, "rb");
    if (!file_handle) {
        return false;
    }

    fseek(file_handle, 0, SEEK_END);
    long file_size = ftell(file_handle);
    fseek(file_handle, 0, SEEK_SET);
    if (file_size <= 0) {
        fclose(file_handle);
        return false;
    }

    char *file_buffer = malloc((size_t)file_size + 1);
    if (!file_buffer) {
        fclose(file_handle);
        return false;
    }
    size_t bytes_read = fread(file_buffer, 1, (size_t)file_size, file_handle);
    fclose(file_handle);
    file_buffer[bytes_read] = '\0';

    cJSON *root_array = cJSON_ParseWithLength(file_buffer, bytes_read);
    free(file_buffer);
    if (!cJSON_IsArray(root_array)) {
        return false;
    }

    g_num_items = (size_t)cJSON_GetArraySize(root_array);
    g_items = calloc(g_num_items, sizeof(dataset_item_t));
    if (!g_items) {
        cJSON_Delete(root_array);
        return false;
    }

    size_t item_index = 0;
    const cJSON *item_node = NULL;
    cJSON_ArrayForEach(item_node, root_array) {
        size_t current_item_index = item_index++;
        dataset_item_t *item = &g_items[current_item_index];
        item->id = cjson_int(item_node, "id");
        item->price = cjson_int(item_node, "price");
        item->quantity = cjson_int(item_node, "quantity");
        item->base_total = item->price * item->quantity;
        item->name = strdup(cjson_str(item_node, "name"));
        item->category = strdup(cjson_str(item_node, "category"));

        const cJSON *active_node = cJSON_GetObjectItemCaseSensitive(item_node, "active");
        item->active = cJSON_IsTrue(active_node);

        const cJSON *rating_node = cJSON_GetObjectItemCaseSensitive(item_node, "rating");
        if (rating_node) {
            item->score = cjson_int(rating_node, "score");
            item->count = cjson_int(rating_node, "count");
        }

        const cJSON *tags_array = cJSON_GetObjectItemCaseSensitive(item_node, "tags");
        if (cJSON_IsArray(tags_array)) {
            item->num_tags = (size_t)cJSON_GetArraySize(tags_array);
            item->tags = calloc(item->num_tags, sizeof(char *));
            size_t tag_index = 0;
            const cJSON *tag_node = NULL;
            cJSON_ArrayForEach(tag_node, tags_array) {
                item->tags[tag_index++] = strdup(cJSON_GetStringValue(tag_node));
            }
        }

        char prefix_buffer[2048];
        char *prefix_cursor = prefix_buffer;
        if (current_item_index == 0) {
            memcpy(prefix_cursor, "{\"items\":[", sizeof("{\"items\":[") - 1);
            prefix_cursor += sizeof("{\"items\":[") - 1;
        } else {
            memcpy(prefix_cursor, "},", sizeof("},") - 1);
            prefix_cursor += sizeof("},") - 1;
        }

        memcpy(prefix_cursor, "{\"id\":", sizeof("{\"id\":") - 1);
        prefix_cursor += sizeof("{\"id\":") - 1;
        prefix_cursor += format_i64(prefix_cursor, item->id);
        memcpy(prefix_cursor, ",\"name\":\"", sizeof(",\"name\":\"") - 1);
        prefix_cursor += sizeof(",\"name\":\"") - 1;
        size_t name_length = strlen(item->name);
        memcpy(prefix_cursor, item->name, name_length);
        prefix_cursor += name_length;
        memcpy(prefix_cursor, "\",\"category\":\"", sizeof("\",\"category\":\"") - 1);
        prefix_cursor += sizeof("\",\"category\":\"") - 1;
        size_t category_length = strlen(item->category);
        memcpy(prefix_cursor, item->category, category_length);
        prefix_cursor += category_length;
        memcpy(prefix_cursor, "\",\"price\":", sizeof("\",\"price\":") - 1);
        prefix_cursor += sizeof("\",\"price\":") - 1;
        prefix_cursor += format_i64(prefix_cursor, item->price);
        memcpy(prefix_cursor, ",\"quantity\":", sizeof(",\"quantity\":") - 1);
        prefix_cursor += sizeof(",\"quantity\":") - 1;
        prefix_cursor += format_i64(prefix_cursor, item->quantity);
        if (item->active) {
            memcpy(prefix_cursor, ",\"active\":true,\"tags\":[", sizeof(",\"active\":true,\"tags\":[") - 1);
            prefix_cursor += sizeof(",\"active\":true,\"tags\":[") - 1;
        } else {
            memcpy(prefix_cursor, ",\"active\":false,\"tags\":[", sizeof(",\"active\":false,\"tags\":[") - 1);
            prefix_cursor += sizeof(",\"active\":false,\"tags\":[") - 1;
        }

        for (size_t tag_index = 0; tag_index < item->num_tags; tag_index++) {
            if (tag_index > 0) {
                *prefix_cursor++ = ',';
            }
            *prefix_cursor++ = '"';
            size_t tag_length = strlen(item->tags[tag_index]);
            memcpy(prefix_cursor, item->tags[tag_index], tag_length);
            prefix_cursor += tag_length;
            *prefix_cursor++ = '"';
        }

        memcpy(prefix_cursor, "],\"rating\":{\"score\":", sizeof("],\"rating\":{\"score\":") - 1);
        prefix_cursor += sizeof("],\"rating\":{\"score\":") - 1;
        prefix_cursor += format_i64(prefix_cursor, item->score);
        memcpy(prefix_cursor, ",\"count\":", sizeof(",\"count\":") - 1);
        prefix_cursor += sizeof(",\"count\":") - 1;
        prefix_cursor += format_i64(prefix_cursor, item->count);
        memcpy(prefix_cursor, "},\"total\":", sizeof("},\"total\":") - 1);
        prefix_cursor += sizeof("},\"total\":") - 1;

        item->prefix_len = (size_t)(prefix_cursor - prefix_buffer);
        item->prefix = malloc(item->prefix_len);
        if (!item->prefix) {
            cJSON_Delete(root_array);
            return false;
        }
        memcpy(item->prefix, prefix_buffer, item->prefix_len);
    }

    cJSON_Delete(root_array);
    return true;
}

size_t dataset_count(void) {
    return g_num_items;
}

size_t json_serialize(size_t count, int64_t multiplier, char *destination_buffer, size_t max_destination_size) {
    (void)max_destination_size;
    if (count > g_num_items) {
        count = g_num_items;
    }
    char *cursor = destination_buffer;

    if (count == 0) {
        memcpy(cursor, "{\"items\":[", 10);
        cursor += 10;
    }

    for (size_t item_index = 0; item_index < count; item_index++) {
        copy_json_prefix(cursor, g_items[item_index].prefix, g_items[item_index].prefix_len);
        cursor += g_items[item_index].prefix_len;
        int64_t total_price =
            (multiplier == 1) ? g_items[item_index].base_total : (g_items[item_index].base_total * multiplier);
        if (__builtin_expect((uint64_t)total_price <= UINT32_MAX, 1)) {
            cursor += format_u32(cursor, (uint32_t)total_price);
        } else {
            cursor += format_i64(cursor, total_price);
        }
    }
    if (count > 0) {
        *cursor++ = '}';
    }

    memcpy(cursor, "],\"count\":", 10);
    cursor += 10;
    if (__builtin_expect(count <= UINT32_MAX, 1)) {
        cursor += format_u32(cursor, (uint32_t)count);
    } else {
        cursor += format_i64(cursor, (int64_t)count);
    }
    *cursor++ = '}';

    return (size_t)(cursor - destination_buffer);
}

void compress_worker_init(worker_compress_t *worker_compress) {
    memset(worker_compress, 0, sizeof(*worker_compress));
    worker_compress->zlib_stream.zalloc = Z_NULL;
    worker_compress->zlib_stream.zfree = Z_NULL;
    worker_compress->zlib_stream.opaque = Z_NULL;
    if (deflateInit2(&worker_compress->zlib_stream, 1, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
        worker_compress->zlib_initialized = true;
    }
}

void compress_worker_destroy(worker_compress_t *worker_compress) {
    if (worker_compress->zlib_initialized) {
        deflateEnd(&worker_compress->zlib_stream);
        worker_compress->zlib_initialized = false;
    }
}

int compress_brotli(const char *input_buffer, size_t input_length, char *output_buffer, size_t max_output_size,
                    size_t *out_compressed_length) {
    size_t encoded_size = max_output_size;
    BROTLI_BOOL encode_result =
        BrotliEncoderCompress(1, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT, input_length, (const uint8_t *)input_buffer,
                              &encoded_size, (uint8_t *)output_buffer);

    if (!encode_result) {
        return -1;
    }
    *out_compressed_length = encoded_size;
    return 0;
}

int compress_gzip(worker_compress_t *worker_compress, const char *input_buffer, size_t input_length,
                  char *output_buffer, size_t max_output_size, size_t *out_compressed_length) {
    if (!worker_compress->zlib_initialized) {
        return -1;
    }

    z_stream *compression_stream = &worker_compress->zlib_stream;
    deflateReset(compression_stream);
    compression_stream->next_in = (Bytef *)input_buffer;
    compression_stream->avail_in = (uInt)input_length;
    compression_stream->next_out = (Bytef *)output_buffer;
    compression_stream->avail_out = (uInt)max_output_size;

    int deflate_result = deflate(compression_stream, Z_FINISH);
    if (deflate_result != Z_STREAM_END) {
        return -1;
    }

    *out_compressed_length = max_output_size - compression_stream->avail_out;
    return 0;
}
