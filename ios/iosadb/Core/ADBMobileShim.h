#ifndef TVADB_ADB_MOBILE_SHIM_H
#define TVADB_ADB_MOBILE_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TVADBCommandResult {
    int32_t status;
    uint8_t *bytes;
    size_t length;
} TVADBCommandResult;

/// Configures the in-process ADB server. Call once before executing commands.
int32_t tvadb_adb_initialize(const char *home_directory, const char *server_port);

/// Runs one ADB command. argv starts with the command (for example, "pair"),
/// not an executable name. The returned buffer is owned by the caller.
TVADBCommandResult tvadb_adb_execute(int32_t argc, const char **argv);

/// Returns the canonical Android ADB public-key line derived by the embedded
/// AOSP implementation from HOME/.android/adbkey.
TVADBCommandResult tvadb_adb_auth_public_key(void);

void tvadb_adb_result_destroy(TVADBCommandResult result);

#ifdef __cplusplus
}
#endif

#endif
