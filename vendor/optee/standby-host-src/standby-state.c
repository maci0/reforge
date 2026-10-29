/* Original initialized settings and the complete handler-indexed wake bitmap. */
#include <stddef.h>
#include "standby-state.h"
struct standby_host_settings standby_host_settings = {1, 0x40000000, 0x100, 0};
uint32_t standby_host_request[32];
_Static_assert(sizeof(struct standby_host_settings) == 16, "Original settings ABI");
_Static_assert(offsetof(struct standby_host_settings, argument1) == 4, "Original argument1 slot");
_Static_assert(offsetof(struct standby_host_settings, wakeup_ms) == 12, "Original timeout slot");
