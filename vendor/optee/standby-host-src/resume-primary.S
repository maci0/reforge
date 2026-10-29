/* Primary resume initialization recovered from the diagnostic and caller ABI.
 * NSACR access is real; test execution models it through a SIGILL handler. */
.syntax unified
.arch armv7-a
.thumb
.section .text.generic_boot_resume_primary,"ax",%progbits
.balign 4
.global generic_boot_resume_primary
.type generic_boot_resume_primary,%function
.thumb_func
generic_boot_resume_primary:
    .fnstart
    .save {r4, lr}
    .pad #8
    push {r0, r1, r4, lr}
    movs r0, #7
    ldr r4, .Lns_entry
    bl thread_set_exceptions
    bl thread_init_per_cpu
    ldr r0, [r4]
    bl init_sec_mon
    bl main_init_gic
    mrc p15, 0, r3, c1, c1, 2
    orr r3, r3, #0xc00
    mcr p15, 0, r3, c1, c1, 2
    ldr r3, [r4]
    movs r2, #3
    ldr r0, .Lfunction_name
    mov.w r1, #1248
    str r3, [sp, #4]
    ldr r3, .Lmessage
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    bl standby_resume_hook_before_return
    add sp, #8
    pop.w {r4, lr}
    b.w standby_resume_hook_tail
.size generic_boot_resume_primary, .-generic_boot_resume_primary
.Lns_entry:
    .word standby_ns_resume_entry
.Lfunction_name:
    .word .Lfunction
.Lmessage:
    .word .Ldiagnostic
    .fnend
.section .rodata.generic_boot_resume_primary,"a",%progbits
.Lfunction:
    .asciz "generic_boot_resume_primary"
.Ldiagnostic:
    .asciz "Primary CPU switching to normal world boot, cpu_resume:0x%x\n"

/* Original call targets 0x41b2c172 and 0x41b2c176 are each exactly BX LR.
 * Their original symbol names and optional platform extension roles are unknown. */
.section .text.standby_resume_hook_before_return,"ax",%progbits
.weak standby_resume_hook_before_return
.type standby_resume_hook_before_return,%function
.thumb_func
standby_resume_hook_before_return:
    bx lr
.size standby_resume_hook_before_return, .-standby_resume_hook_before_return
.section .text.standby_resume_hook_tail,"ax",%progbits
.weak standby_resume_hook_tail
.type standby_resume_hook_tail,%function
.thumb_func
standby_resume_hook_tail:
    bx lr
.size standby_resume_hook_tail, .-standby_resume_hook_tail

.section .bss.standby_ns_resume_entry,"aw",%nobits
.balign 4
.global standby_ns_resume_entry
.type standby_ns_resume_entry,%object
standby_ns_resume_entry:
    .space 4
.size standby_ns_resume_entry, .-standby_ns_resume_entry
.section .note.GNU-stack,"",%progbits
