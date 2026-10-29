/* Recovered CPU release/status operations. Base bindings are verified against the original platform initializer. */
.syntax unified
.arch armv7-a
.thumb
.section .text.psci_cpu_on,"ax",%progbits
.balign 4
.global psci_cpu_on
.type psci_cpu_on,%function
.thumb_func
psci_cpu_on:
    .fnstart
    .save {r4, r5, r6, lr}
    .pad #16
    push {r0, r1, r2, r3, r4, r5, r6, lr}
    uxtb r4, r0
    cmp r4, #1
    mov r5, r1
    mov r6, r2
    bne .Lpsci_cpu_on_5e
    ldr r3, .Lpsci_cpu_on_word_68
    str r2, [sp, #0xc]
    movs r2, #3
    str r1, [sp, #8]
    movs r1, #0xe3
    str r4, [sp, #4]
    str r3, [sp]
    mov r3, r4
    ldr r0, .Lpsci_cpu_on_word_6c
    bl trace_printf
    mov r0, r4
    mov r2, r6
    ldr r4, .Lpsci_cpu_on_word_70
    mov r1, r5
    bl generic_boot_set_core_ns_entry
    ldr r3, .Lpsci_cpu_on_word_74
    movs r0, #0x14
    ldr r2, .Lpsci_cpu_on_word_78
    ldr r3, [r3]
    str.w r2, [r3, #0x1c8]
    ldr r3, [r4]
    ldr r2, [r3]
    bic r2, r2, #2
    str r2, [r3]
    ldr r2, [r3, #0x10]
    bic r2, r2, #2
    str r2, [r3, #0x10]
    bl udelay
    ldr r2, [r4]
    movs r0, #0
    ldr r3, [r2]
    orr r3, r3, #2
    str r3, [r2]
    b .Lpsci_cpu_on_62
.Lpsci_cpu_on_5e:
    mvn r0, #1
.Lpsci_cpu_on_62:
    add sp, #0x10
    pop {r4, r5, r6, pc}
.size psci_cpu_on, .-psci_cpu_on
.balign 4
.Lpsci_cpu_on_word_68:
    .word .Lcpu_string_0
.Lpsci_cpu_on_word_6c:
    .word .Lcpu_string_1
.Lpsci_cpu_on_word_70:
    .word cpucfg_base
.Lpsci_cpu_on_word_74:
    .word rtc_base
.Lpsci_cpu_on_word_78:
    .word tee_spare_head
    .fnend
.section .text.psci_affinity_info,"ax",%progbits
.balign 4
.global psci_affinity_info
.type psci_affinity_info,%function
.thumb_func
psci_affinity_info:
    .fnstart
    .save {r4, lr}
    .pad #16
    push {r0, r1, r2, r3, r4, lr}
    mov r4, r0
    bl standby_cpu_get_core
    ldr r3, .Lpsci_affinity_info_word_44
    movs r2, #3
    str r0, [sp, #4]
    movs r1, #0xf2
    str r3, [sp]
    movs r3, #1
    ldr r0, .Lpsci_affinity_info_word_48
    str r4, [sp, #8]
    bl trace_printf
    ldr r3, .Lpsci_affinity_info_word_4c
    movs r2, #1
    ldr r1, [r3]
    add.w r3, r4, #0x10
    ldr.w r0, [r1, #0x80]
    lsl.w r3, r2, r3
    ands r0, r3
    beq .Lpsci_affinity_info_40
    ldr r3, [r1]
    mov r0, r2
    lsl.w r4, r2, r4
    bic.w r4, r3, r4
    str r4, [r1]
.Lpsci_affinity_info_40:
    add sp, #0x10
    pop {r4, pc}
.size psci_affinity_info, .-psci_affinity_info
.balign 4
.Lpsci_affinity_info_word_44:
    .word .Lcpu_string_2
.Lpsci_affinity_info_word_48:
    .word .Lcpu_string_3
.Lpsci_affinity_info_word_4c:
    .word cpucfg_base
    .fnend
.section .text.standby_cpu_get_core,"ax",%progbits
.balign 4
.global standby_cpu_get_core
.type standby_cpu_get_core,%function
.thumb_func
standby_cpu_get_core:
    .fnstart
    .save {r3, lr}
    push {r3, lr}
    bl thread_get_exceptions
    lsls r3, r0, #0x1e
    bmi .Lstandby_cpu_get_core_1a
    ldr r3, .Lstandby_cpu_get_core_word_24
    movs r2, #0x16
    ldr r1, .Lstandby_cpu_get_core_word_28
    ldr r0, .Lstandby_cpu_get_core_word_2c
    bl _assert_log
    bl _assert_break
.Lstandby_cpu_get_core_1a:
    pop.w {r3, lr}
    b.w __get_core_pos
.size standby_cpu_get_core, .-standby_cpu_get_core
.balign 4
.Lstandby_cpu_get_core_word_24:
    .word .Lcpu_string_4
.Lstandby_cpu_get_core_word_28:
    .word .Lcpu_string_5
.Lstandby_cpu_get_core_word_2c:
    .word .Lcpu_string_6
    .fnend
.section .rodata.standby_cpu_control,"a",%progbits
.Lcpu_string_0:
    .asciz "core_id: %d, entry 0x%x, context_id=0x%x"
.Lcpu_string_1:
    .asciz "psci_cpu_on"
.Lcpu_string_2:
    .asciz "core_id: %d, affinity %d"
.Lcpu_string_3:
    .asciz "psci_affinity_info"
.Lcpu_string_4:
    .asciz "get_core_pos"
.Lcpu_string_5:
    .asciz "core/arch/arm/include/kernel/misc.h"
.Lcpu_string_6:
    .asciz "thread_get_exceptions() & THREAD_EXCP_FOREIGN_INTR"
.section .note.GNU-stack,"",%progbits
