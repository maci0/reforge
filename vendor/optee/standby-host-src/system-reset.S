/* Original watchdog reset programming followed by a non-returning wait loop. */
.syntax unified
.arch armv7-a
.thumb
.section .text.psci_system_reset,"ax",%progbits
.balign 4
.global psci_system_reset
.type psci_system_reset,%function
.thumb_func
psci_system_reset:
    .fnstart
    .save {r3, lr}
    push {r3, lr}
    ldr r0, .Lwatchdog_base
    bl phys_to_virt_io
    movw r3, #0x203
    str r3, [r0, #0x10]
    ldr r3, .Lwatchdog_mode
    str r3, [r0, #0x14]
.Lwait_for_reset:
    wfi
    b .Lwait_for_reset
.size psci_system_reset, .-psci_system_reset
.balign 4
.Lwatchdog_base:
    .word 0x07020800
.Lwatchdog_mode:
    .word 0x0d140001
    .fnend
.section .note.GNU-stack,"",%progbits
