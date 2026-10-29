/* Original PSCI wrapper: save the normal-world return entry before standby. */
#include <stddef.h>
#include <stdint.h>
#include <sm/psci.h>

extern uint32_t standby_ns_resume_entry;
void standby_host_suspend(void);
void standby_system_suspend_hook(void);

/* Original target at 0x41b2c174 is exactly BX LR; its original name is unknown. */
__attribute__((weak)) void standby_system_suspend_hook(void)
{
}

int psci_system_suspend(uintptr_t entry, uint32_t context_id, struct sm_nsec_ctx *nsec)
{
    (void)context_id;
    standby_system_suspend_hook();
    nsec->mon_lr = entry;
    standby_ns_resume_entry = entry;
    standby_host_suspend();
    return 0;
}

_Static_assert(offsetof(struct sm_nsec_ctx, mon_lr) == 0x7c, "Original ARM monitor return ABI");
