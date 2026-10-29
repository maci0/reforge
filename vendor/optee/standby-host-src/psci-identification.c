/* Original PSCI 1.0 response and advertised function set, not the upstream defaults. */
#include <stdint.h>
#include <sm/psci.h>

uint32_t psci_version(void)
{
    return PSCI_VERSION_1_0;
}

int psci_features(uint32_t function)
{
    switch (function) {
    case PSCI_VERSION:
    case PSCI_SYSTEM_RESET:
    case PSCI_PSCI_FEATURES:
    case PSCI_SYSTEM_SUSPEND:
        return 0;
    default:
        return PSCI_RET_NOT_SUPPORTED;
    }
}
