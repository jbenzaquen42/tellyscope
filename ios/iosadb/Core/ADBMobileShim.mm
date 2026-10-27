#import "ADBMobileShim.h"

#include <mutex>
#include <stdlib.h>
#include <string>
#include <string.h>

extern "C" {
#include "adb_public.h"
}

// Exported by the embedded AOSP ADB client. Declaring it here avoids
// duplicating Android's Montgomery/public-key encoding in Swift.
extern std::string adb_auth_get_userkey();

namespace {
std::mutex command_mutex;
bool initialized = false;
}

int32_t tvadb_adb_initialize(const char *home_directory, const char *server_port) {
    if (home_directory == nullptr || server_port == nullptr) {
        return -1;
    }

    std::lock_guard<std::mutex> lock(command_mutex);
    if (setenv("HOME", home_directory, 1) != 0 ||
        setenv("ANDROID_ADB_SERVER_PORT", server_port, 1) != 0) {
        return -1;
    }
    initialized = true;
    return 0;
}

TVADBCommandResult tvadb_adb_execute(int32_t argc, const char **argv) {
    TVADBCommandResult result = { .status = -1, .bytes = nullptr, .length = 0 };
    if (!initialized || argc <= 0 || argv == nullptr) {
        return result;
    }
    for (int32_t index = 0; index < argc; ++index) {
        if (argv[index] == nullptr) {
            return result;
        }
    }

    std::lock_guard<std::mutex> lock(command_mutex);
    char *output = nullptr;
    size_t output_size = 0;
    result.status = adb_commandline_porting(&output, &output_size, argc, argv);
    result.bytes = reinterpret_cast<uint8_t *>(output);
    result.length = output_size;
    return result;
}

TVADBCommandResult tvadb_adb_auth_public_key(void) {
    TVADBCommandResult result = { .status = -1, .bytes = nullptr, .length = 0 };
    std::lock_guard<std::mutex> lock(command_mutex);
    if (!initialized) {
        return result;
    }

    const std::string public_key = adb_auth_get_userkey();
    if (public_key.empty()) {
        return result;
    }

    auto *bytes = static_cast<uint8_t *>(malloc(public_key.size()));
    if (bytes == nullptr) {
        return result;
    }
    memcpy(bytes, public_key.data(), public_key.size());
    result.status = 0;
    result.bytes = bytes;
    result.length = public_key.size();
    return result;
}

void tvadb_adb_result_destroy(TVADBCommandResult result) {
    free(result.bytes);
}
