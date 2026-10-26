#include "CAndroidMTP.h"
#include <libmtp.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

struct AMTPSession { LIBMTP_mtpdevice_t *device; };
struct AMTPCancellation { atomic_int cancelled; };
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static void initialize_library(void) { LIBMTP_Init(); }

static void set_error(char **error, const char *message) {
    if (error) *error = strdup(message ? message : "MTP operation failed.");
}

static void set_system_error(char **error, const char *message) {
    int saved_errno = errno;
    char buffer[768];
    snprintf(buffer, sizeof(buffer), "%s: %s", message, strerror(saved_errno));
    set_error(error, buffer);
}

static void device_error(LIBMTP_mtpdevice_t *device, char **error, const char *fallback) {
    LIBMTP_error_t *entry = LIBMTP_Get_Errorstack(device);
    size_t size = strlen(fallback) + 1;
    for (LIBMTP_error_t *p = entry; p; p = p->next) {
        if (p->error_text) size += strlen(p->error_text) + 2;
    }
    char *message = malloc(size);
    if (message) {
        strcpy(message, fallback);
        for (LIBMTP_error_t *p = entry; p; p = p->next) {
            if (p->error_text) { strcat(message, "\n"); strcat(message, p->error_text); }
        }
        if (error) *error = message; else free(message);
    } else {
        set_error(error, fallback);
    }
    LIBMTP_Clear_Errorstack(device);
}

static int require_session(AMTPSession *session, char **error) {
    if (!session || !session->device) {
        set_error(error, "Connect an Android device first.");
        return -1;
    }
    LIBMTP_Clear_Errorstack(session->device);
    return 0;
}

static int valid_name(const char *name) {
    return name && name[0] && strcmp(name, ".") && strcmp(name, "..") && !strchr(name, '/');
}

void amtp_free_error(char *error) { free(error); }

int amtp_scan(AMTPDevice **devices, size_t *count, char **error) {
    *devices = NULL; *count = 0;
    if (error) *error = NULL;
    pthread_once(&init_once, initialize_library);
    LIBMTP_raw_device_t *raw = NULL;
    int raw_count = 0;
    LIBMTP_error_number_t status = LIBMTP_Detect_Raw_Devices(&raw, &raw_count);
    if (status == LIBMTP_ERROR_NO_DEVICE_ATTACHED) { free(raw); return 0; }
    if (status != LIBMTP_ERROR_NONE) {
        free(raw);
        set_error(error, "Could not scan USB devices. Unlock your phone, choose File transfer, and close other MTP apps.");
        return -1;
    }
    if (raw_count < 1) { free(raw); return 0; }
    AMTPDevice *result = calloc((size_t)raw_count, sizeof(*result));
    if (!result) { free(raw); set_error(error, "Not enough memory to list devices."); return -1; }
    for (int i = 0; i < raw_count; i++) {
        result[i].bus = raw[i].bus_location;
        result[i].address = raw[i].devnum;
        const char *product = raw[i].device_entry.product;
        result[i].name = strdup(product && product[0] ? product : "Android device");
        if (!result[i].name) {
            amtp_free_devices(result, (size_t)raw_count); free(raw);
            set_error(error, "Not enough memory to list devices."); return -1;
        }
    }
    free(raw);
    *devices = result; *count = (size_t)raw_count;
    return 0;
}

void amtp_free_devices(AMTPDevice *devices, size_t count) {
    for (size_t i = 0; i < count; i++) free(devices[i].name);
    free(devices);
}

AMTPSession *amtp_connect(uint32_t bus, uint8_t address, char **error) {
    if (error) *error = NULL;
    pthread_once(&init_once, initialize_library);
    LIBMTP_raw_device_t *raw = NULL;
    int count = 0;
    LIBMTP_error_number_t status = LIBMTP_Detect_Raw_Devices(&raw, &count);
    if (status != LIBMTP_ERROR_NONE) {
        free(raw); set_error(error, "The device is unavailable. Reconnect it and choose File transfer."); return NULL;
    }
    LIBMTP_mtpdevice_t *device = NULL;
    for (int i = 0; i < count; i++) {
        if (raw[i].bus_location == bus && raw[i].devnum == address) {
            device = LIBMTP_Open_Raw_Device_Uncached(&raw[i]);
            break;
        }
    }
    free(raw);
    if (!device) {
        set_error(error, "Could not open the MTP device. Another app may own its USB connection. Quit Photos, Image Capture, other MTP apps, and cloud photo importers, then disconnect and reconnect the phone. Unlock it and choose File transfer."); return NULL;
    }
    AMTPSession *session = calloc(1, sizeof(*session));
    if (!session) {
        LIBMTP_Release_Device(device); set_error(error, "Not enough memory to connect."); return NULL;
    }
    session->device = device;
    return session;
}

void amtp_disconnect(AMTPSession *session) {
    if (session) {
        if (session->device) LIBMTP_Release_Device(session->device);
        free(session);
    }
}

int amtp_storages(AMTPSession *session, AMTPStorage **storages, size_t *count, char **error) {
    *storages = NULL; *count = 0;
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (LIBMTP_Get_Storage(session->device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        device_error(session->device, error, "Could not read storage. Unlock the phone and allow file access."); return -1;
    }
    size_t length = 0;
    for (LIBMTP_devicestorage_t *p = session->device->storage; p; p = p->next) length++;
    if (!length) { set_error(error, "The phone has not exposed any storage. Unlock it and choose File transfer."); return -1; }
    AMTPStorage *result = calloc(length, sizeof(*result));
    if (!result) { set_error(error, "Not enough memory to read storage."); return -1; }
    size_t i = 0;
    for (LIBMTP_devicestorage_t *p = session->device->storage; p; p = p->next, i++) {
        result[i].id = p->id;
        result[i].capacity = p->MaxCapacity;
        result[i].free_space = p->FreeSpaceInBytes;
        result[i].name = strdup(p->StorageDescription && p->StorageDescription[0] ? p->StorageDescription : "Storage");
        if (!result[i].name) {
            amtp_free_storages(result, length); set_error(error, "Not enough memory to read storage."); return -1;
        }
    }
    *storages = result; *count = length;
    return 0;
}

void amtp_free_storages(AMTPStorage *storages, size_t count) {
    for (size_t i = 0; i < count; i++) free(storages[i].name);
    free(storages);
}

static void free_file_list(LIBMTP_file_t *files) {
    while (files) {
        LIBMTP_file_t *next = files->next;
        files->next = NULL;
        LIBMTP_destroy_file_t(files);
        files = next;
    }
}

int amtp_list(AMTPSession *session, uint32_t storage_id, uint32_t parent_id,
              AMTPItem **items, size_t *count, char **error) {
    *items = NULL; *count = 0;
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(session->device, storage_id,
                                                     parent_id == 0 ? LIBMTP_FILES_AND_FOLDERS_ROOT : parent_id);
    if (LIBMTP_Get_Errorstack(session->device)) {
        free_file_list(files);
        device_error(session->device, error, "Could not read this folder."); return -1;
    }
    size_t length = 0;
    for (LIBMTP_file_t *p = files; p; p = p->next) length++;
    if (!length) return 0;
    AMTPItem *result = calloc(length, sizeof(*result));
    if (!result) { free_file_list(files); set_error(error, "Not enough memory to read this folder."); return -1; }
    size_t i = 0;
    for (LIBMTP_file_t *p = files; p; p = p->next, i++) {
        result[i].id = p->item_id;
        result[i].parent_id = p->parent_id == 0 ? UINT32_MAX : p->parent_id;
        result[i].storage_id = p->storage_id;
        result[i].name = strdup(p->filename ? p->filename : "");
        result[i].size = p->filesize;
        result[i].modified = (int64_t)p->modificationdate;
        result[i].is_directory = p->filetype == LIBMTP_FILETYPE_FOLDER;
        if (!result[i].name) {
            amtp_free_items(result, length); free_file_list(files);
            set_error(error, "Not enough memory to read this folder."); return -1;
        }
    }
    free_file_list(files);
    *items = result; *count = length;
    return 0;
}

void amtp_free_items(AMTPItem *items, size_t count) {
    for (size_t i = 0; i < count; i++) free(items[i].name);
    free(items);
}

int amtp_create_folder(AMTPSession *session, const char *name,
                       uint32_t storage_id, uint32_t parent_id,
                       uint32_t *created_id, char **error) {
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (!valid_name(name)) { set_error(error, "Invalid folder name."); return -1; }
    char *mutable_name = strdup(name);
    if (!mutable_name) { set_error(error, "Not enough memory to create a folder."); return -1; }
    uint32_t id = LIBMTP_Create_Folder(session->device, mutable_name,
                                      parent_id == UINT32_MAX ? 0 : parent_id, storage_id);
    free(mutable_name);
    if (!id) { device_error(session->device, error, "Could not create the folder."); return -1; }
    if (created_id) *created_id = id;
    return 0;
}

int amtp_rename(AMTPSession *session, uint32_t item_id, const char *name, char **error) {
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (!valid_name(name)) { set_error(error, "Invalid file name."); return -1; }
    char *mutable_name = strdup(name);
    if (!mutable_name) { set_error(error, "Not enough memory to rename."); return -1; }
    int status = LIBMTP_Set_Object_Filename(session->device, item_id, mutable_name);
    free(mutable_name);
    if (status != 0) { device_error(session->device, error, "Could not rename this item."); return -1; }
    return 0;
}

int amtp_delete(AMTPSession *session, uint32_t item_id, char **error) {
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (!item_id || item_id == UINT32_MAX) {
        set_error(error, "A storage root cannot be deleted."); return -1;
    }
    /* Recheck native metadata rather than relying on a possibly stale UI item type. */
    LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(session->device, item_id);
    if (!metadata) {
        device_error(session->device, error, "Could not verify this item before deletion."); return -1;
    }
    int is_folder = metadata->filetype == LIBMTP_FILETYPE_FOLDER;
    uint32_t storage_id = metadata->storage_id;
    LIBMTP_destroy_file_t(metadata);
    if (is_folder) {
        LIBMTP_Clear_Errorstack(session->device);
        LIBMTP_file_t *children = LIBMTP_Get_Files_And_Folders(session->device, storage_id, item_id);
        if (LIBMTP_Get_Errorstack(session->device)) {
            free_file_list(children);
            device_error(session->device, error, "Could not verify that this folder is empty."); return -1;
        }
        if (children) {
            free_file_list(children);
            set_error(error, "This folder is not empty. Delete its contents separately first."); return -1;
        }
    }
    if (LIBMTP_Delete_Object(session->device, item_id) != 0) {
        device_error(session->device, error, "Could not delete this item."); return -1;
    }
    return 0;
}

AMTPCancellation *amtp_cancellation_create(void) {
    AMTPCancellation *value = malloc(sizeof(*value));
    if (value) atomic_init(&value->cancelled, 0);
    return value;
}
void amtp_cancellation_free(AMTPCancellation *value) { free(value); }
void amtp_cancellation_reset(AMTPCancellation *value) { if (value) atomic_store(&value->cancelled, 0); }
void amtp_cancellation_cancel(AMTPCancellation *value) { if (value) atomic_store(&value->cancelled, 1); }
int amtp_cancellation_is_cancelled(AMTPCancellation *value) { return value ? atomic_load(&value->cancelled) : 0; }

typedef struct {
    AMTPCancellation *cancellation;
    AMTPProgress progress;
    void *context;
} TransferContext;

static int transfer_progress(uint64_t completed, uint64_t total, const void *opaque) {
    const TransferContext *context = opaque;
    if (amtp_cancellation_is_cancelled(context->cancellation)) return 1;
    if (context->progress) context->progress(completed, total, context->context);
    return amtp_cancellation_is_cancelled(context->cancellation) ? 1 : 0;
}

int amtp_upload(AMTPSession *session, const char *local_path, const char *remote_name,
                uint32_t storage_id, uint32_t parent_id,
                AMTPCancellation *cancellation, AMTPProgress progress,
                void *context, char **error) {
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (!valid_name(remote_name)) { set_error(error, "Invalid file name."); return -1; }
    if (amtp_cancellation_is_cancelled(cancellation)) { set_error(error, "Transfer cancelled."); return -1; }
    int fd = open(local_path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) { set_system_error(error, "Could not open the upload file"); return -1; }
    struct stat info;
    if (fstat(fd, &info) != 0) {
        set_system_error(error, "Could not inspect the upload file"); close(fd); return -1;
    }
    if (!S_ISREG(info.st_mode) || info.st_size < 0) {
        close(fd); set_error(error, "Only regular files can be uploaded. Symbolic links are not followed."); return -1;
    }
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (!file) { close(fd); set_error(error, "Not enough memory to upload."); return -1; }
    file->filename = strdup(remote_name);
    if (!file->filename) {
        LIBMTP_destroy_file_t(file); close(fd); set_error(error, "Not enough memory to upload."); return -1;
    }
    file->parent_id = parent_id == UINT32_MAX ? 0 : parent_id;
    file->storage_id = storage_id;
    file->filesize = (uint64_t)info.st_size;
    file->modificationdate = info.st_mtime;
    file->filetype = LIBMTP_FILETYPE_UNKNOWN;
    TransferContext transfer = {cancellation, progress, context};
    int status = LIBMTP_Send_File_From_File_Descriptor(session->device, fd, file, transfer_progress, &transfer);
    LIBMTP_destroy_file_t(file);
    close(fd);
    if (status != 0) {
        device_error(session->device, error,
                     amtp_cancellation_is_cancelled(cancellation) ? "Transfer cancelled. A partial upload may remain on the phone." : "Upload failed. A partial upload may remain on the phone.");
        return -1;
    }
    return 0;
}

int amtp_download(AMTPSession *session, uint32_t item_id, const char *local_path,
                  AMTPCancellation *cancellation, AMTPProgress progress,
                  void *context, char **error) {
    if (error) *error = NULL;
    if (require_session(session, error)) return -1;
    if (amtp_cancellation_is_cancelled(cancellation)) { set_error(error, "Transfer cancelled."); return -1; }
    int fd = open(local_path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { set_system_error(error, "Could not create the download file"); return -1; }
    TransferContext transfer = {cancellation, progress, context};
    int status = LIBMTP_Get_File_To_File_Descriptor(session->device, item_id, fd, transfer_progress, &transfer);
    if (status != 0) {
        device_error(session->device, error, amtp_cancellation_is_cancelled(cancellation) ? "Transfer cancelled." : "Download failed.");
        close(fd); unlink(local_path); return -1;
    }
    if (fsync(fd) != 0) {
        set_system_error(error, "Could not save the complete download"); close(fd); unlink(local_path); return -1;
    }
    if (close(fd) != 0) {
        set_system_error(error, "Could not close the download file"); unlink(local_path); return -1;
    }
    return 0;
}

int amtp_move_no_replace(const char *source, const char *destination, char **error) {
    if (error) *error = NULL;
    if (renamex_np(source, destination, RENAME_EXCL) != 0) {
        set_system_error(error, "Could not finish the download without replacing an existing item"); return -1;
    }
    return 0;
}
