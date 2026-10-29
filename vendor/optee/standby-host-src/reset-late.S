/* Late reset hook: primary initializes counter/CCU; secondary restores CNTFRQ. */
.syntax unified
.arch armv7-a
.thumb
.section .text.plat_cpu_reset_late,"ax",%progbits
.balign 4
.global plat_cpu_reset_late
.type plat_cpu_reset_late,%function
.thumb_func
plat_cpu_reset_late:
    .fnstart
    .save {r4, lr}
    push {r4, lr}
    bl thread_get_exceptions
    lsls r3, r0, #0x1e
    bmi .Llate_1a
    ldr r3, .Llate_word_a4
    movs r2, #0x16
    ldr r1, .Llate_word_a8
    ldr r0, .Llate_word_ac
    bl _assert_log
    bl _assert_break
.Llate_1a:
    blx __get_core_pos
    ldr r3, .Llate_word_b0
    cmp r0, #0
    bne .Llate_9c
    mrc p15, #0, r2, c14, c0, #0
    cbz r2, .Llate_2e
    str r2, [r3]
    b .Llate_36
.Llate_2e:
    ldr r2, .Llate_word_b4
    str r2, [r3]
    mcr p15, #0, r2, c14, c0, #0
.Llate_36:
    ldr r3, .Llate_word_b8
    movs r0, #0x14
    ldr r2, .Llate_word_bc
    ldr r4, .Llate_word_c0
    str r2, [r3]
    ldr r2, .Llate_word_c4
    str r2, [r3, #0x40]
    ldr r2, .Llate_word_c8
    str r2, [r3, #0x60]
    ldr r2, .Llate_word_cc
    str.w r2, [r3, #0x80]
    add.w r2, r2, #-0x80000000
    sub.w r2, r2, #0x30c00
    str.w r2, [r3, #0xa0]
    ldr r2, .Llate_word_d0
    str.w r2, [r3, #0xb0]
    movs r3, #0x1f
    ldr r2, .Llate_word_d4
    str r3, [r2]
    str r3, [r2, #0x10]
    ldr r2, .Llate_word_d8
    ldr r3, .Llate_word_dc
    str r2, [r3]
    movs r2, #0xf
    ldr r3, .Llate_word_e0
    str r2, [r3]
    ldr r3, [r4]
    orr r3, r3, #0x10000
    str r3, [r4]
    bl udelay
    ldr r3, [r4]
    movs r2, #7
    orr r3, r3, #1
    str r3, [r4]
    ldr r3, .Llate_word_e4
    str r2, [r3]
    add.w r3, r3, #0x1000100
    adds r3, #0x20
    movw r2, #0xffff
    str r2, [r3]
    pop {r4, pc}
.Llate_9c:
    ldr r3, [r3]
    mcr p15, #0, r3, c14, c0, #0
    pop {r4, pc}
.size plat_cpu_reset_late, .-plat_cpu_reset_late
.balign 4
.Llate_word_a4:
    .word .Llate_string_0
.Llate_word_a8:
    .word .Llate_string_1
.Llate_word_ac:
    .word .Llate_string_2
.Llate_word_b0:
    .word standby_counter_frequency
.Llate_word_b4:
    .word 0x16e3600
.Llate_word_b8:
    .word 0x2000804
.Llate_word_bc:
    .word 0x2009a07f
.Llate_word_c0:
    .word 0x200170c
.Llate_word_c4:
    .word 0x51031d
.Llate_word_c8:
    .word 0x813f3a
.Llate_word_cc:
    .word 0x60f3f
.Llate_word_d0:
    .word 0x7ffffc5f
.Llate_word_d4:
    .word 0x20008c4
.Llate_word_d8:
    .word 0x3007e01
.Llate_word_dc:
    .word 0x7002004
.Llate_word_e0:
    .word 0x20008e0
.Llate_word_e4:
    .word 0x2001f00
    .fnend
.section .rodata.plat_cpu_reset_late,"a",%progbits
.Llate_string_0:
    .asciz "get_core_pos"
.Llate_string_1:
    .asciz "core/arch/arm/include/kernel/misc.h"
.Llate_string_2:
    .asciz "thread_get_exceptions() & THREAD_EXCP_FOREIGN_INTR"
.section .bss.standby_counter_frequency,"aw",%nobits
.balign 4
.global standby_counter_frequency
.type standby_counter_frequency,%object
standby_counter_frequency:
.space 4
.size standby_counter_frequency, .-standby_counter_frequency
.section .note.GNU-stack,"",%progbits
