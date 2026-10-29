#ifndef REFORGE_STANDBY_STATE_H
#define REFORGE_STANDBY_STATE_H
#include <stdint.h>
struct standby_host_settings {
    uint8_t enabled;
    uint32_t argument1;
    uint32_t argument2;
    uint32_t wakeup_ms;
};
extern struct standby_host_settings standby_host_settings;
extern uint32_t standby_host_request[32]; /* 1024 wake IRQ bits; IRQ35 selects audio standby. */
#endif
