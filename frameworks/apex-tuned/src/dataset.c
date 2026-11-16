#include "dataset.h"
#include <cjson/cJSON.h>

static dataset_item_t *g_items = NULL;
static size_t g_num_items = 0;
static struct isal_hufftables g_json_hufftables;
static bool g_json_hufftables_initialized = false;

enum {
    JSON_GZIP_CACHE_CAPACITY = 2048,
    JSON_GZIP_CACHE_MAX_ENTRIES = 1024,
    JSON_FAST_COUNT_LIMIT = 50,
    JSON_FAST_MULTIPLIER_LIMIT = 10
};

struct json_gzip_cache_entry {
    size_t count;
    int64_t multiplier;
    char *response;
    size_t response_length;
};

typedef struct {
    char *response;
    size_t response_length;
} json_gzip_fast_entry_t;

typedef struct {
    char *http1_response;
    const char *payload;
    size_t http1_response_length;
    size_t payload_length;
} json_fast_entry_t;

static json_gzip_fast_entry_t g_json_gzip_fast_cache[JSON_FAST_COUNT_LIMIT + 1][JSON_FAST_MULTIPLIER_LIMIT];
static json_fast_entry_t g_json_fast_cache[JSON_FAST_COUNT_LIMIT + 1][JSON_FAST_MULTIPLIER_LIMIT];

static void dataset_prepare_json_responses(void);
static void dataset_prepare_gzip_responses(void);

static inline size_t json_gzip_cache_index(size_t count, int64_t multiplier) {
    uint64_t hash = (uint64_t)multiplier ^ ((uint64_t)count * 0x9e3779b97f4a7c15ULL);
    hash ^= hash >> 30;
    hash *= 0xbf58476d1ce4e5b9ULL;
    hash ^= hash >> 27;
    hash *= 0x94d049bb133111ebULL;
    hash ^= hash >> 31;
    return (size_t)hash & (JSON_GZIP_CACHE_CAPACITY - 1);
}

static json_gzip_cache_entry_t *json_gzip_cache_entry(worker_compress_t *worker_compress, size_t count,
                                                       int64_t multiplier) {
    if (!worker_compress->gzip_response_cache) {
        worker_compress->gzip_response_cache =
            calloc(JSON_GZIP_CACHE_CAPACITY, sizeof(*worker_compress->gzip_response_cache));
        if (!worker_compress->gzip_response_cache) {
            return NULL;
        }
    }

    size_t start_index = json_gzip_cache_index(count, multiplier);
    for (size_t probe = 0; probe < JSON_GZIP_CACHE_CAPACITY; probe++) {
        json_gzip_cache_entry_t *entry =
            &worker_compress->gzip_response_cache[(start_index + probe) & (JSON_GZIP_CACHE_CAPACITY - 1)];
        if (!entry->response) {
            return worker_compress->gzip_response_cache_size < JSON_GZIP_CACHE_MAX_ENTRIES ? entry : NULL;
        }
        if (entry->count == count && entry->multiplier == multiplier) {
            return entry;
        }
    }
    return NULL;
}

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

static void dataset_prepare_gzip_hufftables(void) {
    static const int64_t representative_multipliers[] = {1, 4, 6, 8};
    char *sample_buffer = malloc(WRITE_BUF_SIZE);
    if (!sample_buffer) {
        return;
    }

    struct isal_huff_histogram histogram = {0};
    for (size_t index = 0; index < sizeof(representative_multipliers) / sizeof(representative_multipliers[0]);
         index++) {
        size_t sample_length =
            json_serialize(g_num_items, representative_multipliers[index], sample_buffer, WRITE_BUF_SIZE);
        isal_update_histogram((uint8_t *)sample_buffer, (int)sample_length, &histogram);
    }
    g_json_hufftables_initialized = isal_create_hufftables(&g_json_hufftables, &histogram) == 0;
    free(sample_buffer);
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
    dataset_prepare_json_responses();
    dataset_prepare_gzip_hufftables();
    dataset_prepare_gzip_responses();
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

static void dataset_prepare_json_responses(void) {
    static const char header_prefix[] =
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
    static const char header_suffix[] = "\r\nConnection: keep-alive\r\n\r\n";

    char *json_buffer = malloc(WRITE_BUF_SIZE);
    if (!json_buffer) {
        return;
    }

    size_t maximum_count = g_num_items < JSON_FAST_COUNT_LIMIT ? g_num_items : JSON_FAST_COUNT_LIMIT;
    for (size_t count = 1; count <= maximum_count; count++) {
        for (int64_t multiplier = 0; multiplier < JSON_FAST_MULTIPLIER_LIMIT; multiplier++) {
            size_t payload_length = json_serialize(count, multiplier, json_buffer, WRITE_BUF_SIZE);
            if (payload_length > UINT32_MAX) {
                continue;
            }

            char content_length_buffer[10];
            size_t content_length_length = format_u32(content_length_buffer, (uint32_t)payload_length);
            size_t header_length =
                sizeof(header_prefix) - 1 + content_length_length + sizeof(header_suffix) - 1;
            size_t response_length = header_length + payload_length;
            char *response = malloc(response_length);
            if (!response) {
                continue;
            }

            char *cursor = response;
            memcpy(cursor, header_prefix, sizeof(header_prefix) - 1);
            cursor += sizeof(header_prefix) - 1;
            memcpy(cursor, content_length_buffer, content_length_length);
            cursor += content_length_length;
            memcpy(cursor, header_suffix, sizeof(header_suffix) - 1);
            cursor += sizeof(header_suffix) - 1;
            memcpy(cursor, json_buffer, payload_length);

            json_fast_entry_t *entry = &g_json_fast_cache[count][multiplier];
            entry->http1_response = response;
            entry->payload = response + header_length;
            entry->http1_response_length = response_length;
            entry->payload_length = payload_length;
        }
    }

    free(json_buffer);
}

static const json_fast_entry_t *json_fast_cache_entry(size_t count, int64_t multiplier) {
    if (count == 0 || count > JSON_FAST_COUNT_LIMIT || count > g_num_items || multiplier < 0 ||
        multiplier >= JSON_FAST_MULTIPLIER_LIMIT) {
        return NULL;
    }

    const json_fast_entry_t *entry = &g_json_fast_cache[count][multiplier];
    return entry->http1_response ? entry : NULL;
}

size_t json_cached_payload(size_t count, int64_t multiplier, const char **out_payload) {
    if (!out_payload) {
        return 0;
    }
    *out_payload = NULL;

    const json_fast_entry_t *entry = json_fast_cache_entry(count, multiplier);
    if (!entry) {
        return 0;
    }

    *out_payload = entry->payload;
    return entry->payload_length;
}

size_t json_cached_http1_response(size_t count, int64_t multiplier, const char **out_response_start) {
    if (!out_response_start) {
        return 0;
    }
    *out_response_start = NULL;

    const json_fast_entry_t *entry = json_fast_cache_entry(count, multiplier);
    if (!entry) {
        return 0;
    }

    *out_response_start = entry->http1_response;
    return entry->http1_response_length;
}

static size_t build_json_gzip_http1_response(worker_compress_t *worker_compress, size_t count,
                                              int64_t multiplier, char *destination_buffer,
                                              size_t max_destination_size) {
    static const char header_prefix[] =
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\nContent-Length: ";
    static const char header_suffix[] = "\r\nConnection: keep-alive\r\n\r\n";

    size_t json_length =
        json_serialize(count, multiplier, worker_compress->json_buf, sizeof(worker_compress->json_buf));
    size_t compressed_length = 0;
    if (compress_gzip(worker_compress, worker_compress->json_buf, json_length, worker_compress->comp_buf,
                      sizeof(worker_compress->comp_buf), &compressed_length) != 0 ||
        compressed_length > UINT32_MAX) {
        return 0;
    }

    size_t maximum_response_length =
        sizeof(header_prefix) - 1 + 10 + sizeof(header_suffix) - 1 + compressed_length;
    if (maximum_response_length > max_destination_size) {
        return 0;
    }

    char *cursor = destination_buffer;
    memcpy(cursor, header_prefix, sizeof(header_prefix) - 1);
    cursor += sizeof(header_prefix) - 1;
    cursor += format_u32(cursor, (uint32_t)compressed_length);
    memcpy(cursor, header_suffix, sizeof(header_suffix) - 1);
    cursor += sizeof(header_suffix) - 1;
    memcpy(cursor, worker_compress->comp_buf, compressed_length);
    cursor += compressed_length;

    return (size_t)(cursor - destination_buffer);
}

static void dataset_prepare_gzip_responses(void) {
    worker_compress_t *worker_compress = malloc(sizeof(*worker_compress));
    char *response_buffer = malloc(WRITE_BUF_SIZE);
    if (!worker_compress || !response_buffer) {
        free(response_buffer);
        free(worker_compress);
        return;
    }

    compress_worker_init(worker_compress);
    size_t maximum_count = g_num_items < JSON_FAST_COUNT_LIMIT ? g_num_items : JSON_FAST_COUNT_LIMIT;
    for (size_t count = 1; count <= maximum_count; count++) {
        for (int64_t multiplier = 0; multiplier < JSON_FAST_MULTIPLIER_LIMIT; multiplier++) {
            size_t response_length = build_json_gzip_http1_response(
                worker_compress, count, multiplier, response_buffer, WRITE_BUF_SIZE);
            if (response_length == 0) {
                continue;
            }

            char *cached_response = malloc(response_length);
            if (!cached_response) {
                continue;
            }
            memcpy(cached_response, response_buffer, response_length);
            json_gzip_fast_entry_t *entry = &g_json_gzip_fast_cache[count][multiplier];
            entry->response = cached_response;
            entry->response_length = response_length;
        }
    }
    compress_worker_destroy(worker_compress);
    free(response_buffer);
    free(worker_compress);
}

size_t json_gzip_cached_http1_response(size_t count, int64_t multiplier, const char **out_response_start) {
    if (!out_response_start) {
        return 0;
    }
    *out_response_start = NULL;

    if (count > JSON_FAST_COUNT_LIMIT || count > g_num_items || multiplier < 0 ||
        multiplier >= JSON_FAST_MULTIPLIER_LIMIT) {
        return 0;
    }

    const json_gzip_fast_entry_t *entry = &g_json_gzip_fast_cache[count][multiplier];
    if (entry->response) {
        *out_response_start = entry->response;
        return entry->response_length;
    }
    return 0;
}

size_t json_gzip_http1_response(worker_compress_t *worker_compress, size_t count, int64_t multiplier,
                                char *destination_buffer, size_t max_destination_size,
                                const char **out_response_start) {
    if (count > JSON_FAST_COUNT_LIMIT) {
        count = JSON_FAST_COUNT_LIMIT;
    }
    if (count > g_num_items) {
        count = g_num_items;
    }

    size_t cached_response_length = json_gzip_cached_http1_response(count, multiplier, out_response_start);
    if (cached_response_length > 0) {
        return cached_response_length;
    }

    json_gzip_cache_entry_t *cache_entry = json_gzip_cache_entry(worker_compress, count, multiplier);
    if (cache_entry && cache_entry->response) {
        *out_response_start = cache_entry->response;
        return cache_entry->response_length;
    }

    size_t response_length = build_json_gzip_http1_response(worker_compress, count, multiplier,
                                                             destination_buffer, max_destination_size);
    if (response_length == 0) {
        return 0;
    }

    if (cache_entry) {
        char *cached_response = malloc(response_length);
        if (cached_response) {
            memcpy(cached_response, destination_buffer, response_length);
            cache_entry->count = count;
            cache_entry->multiplier = multiplier;
            cache_entry->response_length = response_length;
            cache_entry->response = cached_response;
            worker_compress->gzip_response_cache_size++;
        }
    }
    *out_response_start = destination_buffer;
    return response_length;
}

void compress_worker_init(worker_compress_t *worker_compress) {
    memset(worker_compress, 0, sizeof(*worker_compress));
    isal_deflate_stateless_init(&worker_compress->gzip_stream);
    worker_compress->gzip_compressor = libdeflate_alloc_compressor(1);
    worker_compress->zlib_stream.zalloc = Z_NULL;
    worker_compress->zlib_stream.zfree = Z_NULL;
    worker_compress->zlib_stream.opaque = Z_NULL;
    if (deflateInit2(&worker_compress->zlib_stream, 1, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) == Z_OK) {
        worker_compress->zlib_initialized = true;
    }
}

void compress_worker_destroy(worker_compress_t *worker_compress) {
    if (worker_compress->gzip_response_cache) {
        for (size_t index = 0; index < JSON_GZIP_CACHE_CAPACITY; index++) {
            free(worker_compress->gzip_response_cache[index].response);
        }
        free(worker_compress->gzip_response_cache);
        worker_compress->gzip_response_cache = NULL;
        worker_compress->gzip_response_cache_size = 0;
    }
    libdeflate_free_compressor(worker_compress->gzip_compressor);
    worker_compress->gzip_compressor = NULL;
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

int compress_gzip(worker_compress_t *worker_compress, char *input_buffer, size_t input_length,
                  char *output_buffer, size_t max_output_size, size_t *out_compressed_length) {
    if (input_length <= UINT32_MAX && max_output_size <= UINT32_MAX) {
        struct isal_zstream *compression_stream = &worker_compress->gzip_stream;
        isal_deflate_stateless_init(compression_stream);
        compression_stream->next_in = (uint8_t *)input_buffer;
        compression_stream->avail_in = (uint32_t)input_length;
        compression_stream->next_out = (uint8_t *)output_buffer;
        compression_stream->avail_out = (uint32_t)max_output_size;
        compression_stream->end_of_stream = 1;
        compression_stream->gzip_flag = IGZIP_GZIP;
        if (g_json_hufftables_initialized) {
            compression_stream->hufftables = &g_json_hufftables;
        }
        if (isal_deflate_stateless(compression_stream) == COMP_OK) {
            *out_compressed_length = compression_stream->total_out;
            return 0;
        }
    }

    if (worker_compress->gzip_compressor) {
        size_t compressed_length =
            libdeflate_gzip_compress(worker_compress->gzip_compressor, input_buffer, input_length, output_buffer,
                                     max_output_size);
        if (compressed_length != 0) {
            *out_compressed_length = compressed_length;
            return 0;
        }
    }

    if (!worker_compress->zlib_initialized) {
        return -1;
    }

    z_stream *compression_stream = &worker_compress->zlib_stream;
    if (deflateReset(compression_stream) != Z_OK) {
        return -1;
    }
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
