/* Original CPU1-only off wrapper; cache and interrupt helpers remain real calls. */
.syntax unified
.arch armv7-a
.thumb
.section .text.psci_cpu_off,"ax",%progbits
.balign 4
.global psci_cpu_off
.type psci_cpu_off,%function
.thumb_func
psci_cpu_off:
    .fnstart
    .save {lr}
    .pad #12
    push {r0, r1, r2, lr}
    bl standby_cpu_get_core
    cmp r0, #1
    mov r3, r0
    bne .Linvalid_core
    ldr r2, .Lmessage
    movs r1, #209
    str r0, [sp, #4]
    str r2, [sp]
    movs r2, #3
    ldr r0, .Lfunction_name
    bl trace_printf
    blx psci_armv7_cpu_off
    movs r0, #7
    bl thread_mask_exceptions
.Lwait_for_poweroff:
    wfi
    b .Lwait_for_poweroff
.Linvalid_core:
    mvn r0, #1
    add sp, #12
    ldr pc, [sp], #4
.size psci_cpu_off, .-psci_cpu_off
.balign 4
.Lmessage:
    .word .Lformat
.Lfunction_name:
    .word .Lfunction
    .fnend
.section .rodata.psci_cpu_off,"a",%progbits
.Lformat:
    .asciz "core_id: %u"
.Lfunction:
    .asciz "psci_cpu_off"
.section .note.GNU-stack,"",%progbits
