/* Original CPU suspend handshake and terminal sequence; no physical validation. */
.syntax unified
.arch armv7-a
.thumb
.section .text.psci_cpu_suspend,"ax",%progbits
.balign 4
.global psci_cpu_suspend
.type psci_cpu_suspend,%function
.thumb_func
psci_cpu_suspend:
    .fnstart
    .save {r4, r5, r6, r7, r8, lr}
    .pad #16
    push.w {r0, r1, r2, r3, r4, r5, r6, r7, r8, lr}
    mov r6, r0
    ubfx r5, r6, #0x18, #2
    mov r7, r1
    mov r8, r2
    bl standby_cpu_get_core
    ldr r3, .Lsuspend_word_b0
    movs r2, #3
    str r0, [sp, #4]
    movs r1, #0x9e
    str r3, [sp]
    mov r4, r0
    str r5, [sp, #8]
    movs r3, #1
    ldr r0, .Lsuspend_word_b4
    uxth r6, r6
    bl trace_printf
    ldr r3, .Lsuspend_word_b8
    movs r2, #3
    str r7, [sp, #4]
    movs r1, #0xa5
    str r3, [sp]
    movs r3, #1
    ldr r0, .Lsuspend_word_b4
    bl trace_printf
    cbnz r6, .Lsuspend_a4
    ldr r6, .Lsuspend_word_bc
    cbnz r4, .Lsuspend_4e
    cmp r5, #1
    ittt ls
    ldrls r3, [r6]
    ldrls r2, .Lsuspend_word_c0
    strls.w r2, [r3, #0x1c0]
.Lsuspend_4e:
    mov r2, r8
    mov r1, r7
    ldr.w r8, .Lsuspend_word_c8
    mov r0, r4
    add.w r7, r4, #0x71
    bl generic_boot_set_core_ns_entry
    ldr r3, [r6]
    adds r4, #0xb8
    ldr r0, .Lsuspend_word_c4
    str.w r8, [r3, r7, lsl #2]
    lsls r5, r5, #4
    bl phys_to_virt_io
    bl standby_gic_cpuif_disable
    blx psci_armv7_cpu_off
    movs r0, #7
    bl thread_mask_exceptions
    ldr r3, [r6]
    movs r1, #1
    str.w r8, [r3, r7, lsl #2]
    ldr.w r2, [r3, r4, lsl #2]
    lsl.w r5, r1, r5
    orrs r5, r2
    str.w r5, [r3, r4, lsl #2]
    isb sy
    dsb sy
    clrex 
.Lsuspend_a0:
    wfi 
    b .Lsuspend_a0
.Lsuspend_a4:
    mvn r0, #1
    add sp, #0x10
    pop.w {r4, r5, r6, r7, r8, pc}
.size psci_cpu_suspend, .-psci_cpu_suspend
.balign 4
.Lsuspend_word_b0:
    .word .Lsuspend_string_0
.Lsuspend_word_b4:
    .word .Lsuspend_string_1
.Lsuspend_word_b8:
    .word .Lsuspend_string_2
.Lsuspend_word_bc:
    .word rtc_base
.Lsuspend_word_c0:
    .word 0xfa50392f
.Lsuspend_word_c4:
    .word 0x3022000
.Lsuspend_word_c8:
    .word tee_spare_head
    .fnend
.section .text.standby_gic_cpuif_disable,"ax",%progbits
.balign 2
.global standby_gic_cpuif_disable
.type standby_gic_cpuif_disable,%function
.thumb_func
standby_gic_cpuif_disable:
    .fnstart
    ldr r3, [r0]
    bic r3, r3, #3
    orr r3, r3, #0x1e0
    str r3, [r0]
    bx lr
.size standby_gic_cpuif_disable, .-standby_gic_cpuif_disable
    .fnend
.section .rodata.psci_cpu_suspend,"a",%progbits
.Lsuspend_string_0:
    .asciz "core%d affinity_level=%d\n"
.Lsuspend_string_1:
    .asciz "psci_cpu_suspend"
.Lsuspend_string_2:
    .asciz "cpu_resume:0x%x\n"
.section .note.GNU-stack,"",%progbits
