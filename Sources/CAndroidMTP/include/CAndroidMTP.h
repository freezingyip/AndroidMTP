#ifndef C_ANDROID_MTP_H
#define C_ANDROID_MTP_H

#include <stddef.h>
#include <stdint.h>

typedef struct AMTPSession AMTPSession;
typedef struct AMTPCancellation AMTPCancellation;

typedef struct {
    uint32_t bus;
    uint8_t address;
    char *name;
} AMTPDevice;

typedef struct {
    uint32_t id;
    char *name;
    uint64_t capacity;
    uint64_t free_space;
} AMTPStorage;

typedef struct {
    uint32_t id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *name;
    uint64_t size;
    int64_t modified;
    int is_directory;
} AMTPItem;

typedef void (*AMTPProgress)(uint64_t completed, uint64_t total, void *context);

/* Returned arrays, names, and error strings are owned by the caller. */
int amtp_scan(AMTPDevice **devices, size_t *count, char **error);
void amtp_free_devices(AMTPDevice *devices, size_t count);
AMTPSession *amtp_connect(uint32_t bus, uint8_t address, char **error);
void amtp_disconnect(AMTPSession *session);
int amtp_storages(AMTPSession *session, AMTPStorage **storages, size_t *count, char **error);
void amtp_free_storages(AMTPStorage *storages, size_t count);
int amtp_list(AMTPSession *session, uint32_t storage_id, uint32_t parent_id,
              AMTPItem **items, size_t *count, char **error);
void amtp_free_items(AMTPItem *items, size_t count);
int amtp_create_folder(AMTPSession *session, const char *name,
                       uint32_t storage_id, uint32_t parent_id,
                       uint32_t *created_id, char **error);
int amtp_rename(AMTPSession *session, uint32_t item_id, const char *name, char **error);
int amtp_delete(AMTPSession *session, uint32_t item_id, char **error);

AMTPCancellation *amtp_cancellation_create(void);
void amtp_cancellation_free(AMTPCancellation *cancellation);
void amtp_cancellation_reset(AMTPCancellation *cancellation);
void amtp_cancellation_cancel(AMTPCancellation *cancellation);
int amtp_cancellation_is_cancelled(AMTPCancellation *cancellation);

int amtp_upload(AMTPSession *session, const char *local_path, const char *remote_name,
                uint32_t storage_id, uint32_t parent_id,
                AMTPCancellation *cancellation, AMTPProgress progress,
                void *context, char **error);
/* Downloads create a new path exclusively. They never open an existing path. */
int amtp_download(AMTPSession *session, uint32_t item_id, const char *local_path,
                  AMTPCancellation *cancellation, AMTPProgress progress,
                  void *context, char **error);
/* Atomic same-volume move that refuses to replace an existing destination. */
int amtp_move_no_replace(const char *source, const char *destination, char **error);
void amtp_free_error(char *error);

#endif
