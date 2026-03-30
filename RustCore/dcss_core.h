#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DCSSSession DCSSSessionHandle;

DCSSSessionHandle* dcss_session_create(void);
void dcss_session_destroy(DCSSSessionHandle* handle);

void dcss_session_connect(
    DCSSSessionHandle* handle,
    const char* url,
    const char* client_version /* nullable */
);

void dcss_session_disconnect(DCSSSessionHandle* handle);

void dcss_session_send_input(DCSSSessionHandle* handle, const char* command);
void dcss_session_send_heartbeat(DCSSSessionHandle* handle);

void dcss_session_app_did_enter_background(DCSSSessionHandle* handle);
void dcss_session_app_will_enter_foreground(DCSSSessionHandle* handle);

// Returned string is owned by the core; must be freed via dcss_free_string().
char* dcss_session_get_snapshot_json(DCSSSessionHandle* handle);
void dcss_free_string(char* s);

#ifdef __cplusplus
}
#endif

