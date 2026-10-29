/* Recovered secure-world suspend caller. Data and calls use linkable symbols. */
.syntax unified
.arch armv7-a
.thumb
.section .text.standby_host_suspend,"ax",%progbits
.balign 4
.global standby_host_suspend
.type standby_host_suspend,%function
.thumb_func
standby_host_suspend:
    push {r0, r1, r2, r4, r5, lr}
    /* Copy and initialize the independently linked SRAM program. */
    bl standby_host_dcache_disable
    ldr r1, .Lword_1bc
    mov.w r4, #0x20000
    ldr r2, .Lword_1c0
    mov r0, r4
    subs r2, r2, r1
    bl memcpy
    ldr r3, .Lword_1c4
    ldrb r2, [r3]
    str.w r2, [r4, #0x98]
    ldr r2, [r3, #4]
    str.w r2, [r4, #0x84]
    ldr r2, [r3, #8]
    str.w r2, [r4, #0x88]
    ldr r3, [r3, #0xc]
    str.w r3, [r4, #0x94]
    ldr r3, .Lword_1c8
    str.w r3, [r4, #0x80]
    bl standby_host_get_type
    ldr r3, .Lword_1cc
    mov r5, r0
    str.w r0, [r4, #0x9c]
    ldr.w r2, [r3, #0xa0]
    adds r3, #0xc7
    str.w r2, [r4, #0xa0]
    ldr r2, [r3, #-0x23]
    str.w r2, [r4, #0xa4]
    ldr r2, [r3, #-0x1f]
    str.w r2, [r4, #0xa8]
    ldr r2, [r3, #-0x1b]
    str.w r2, [r4, #0xac]
    ldr r2, [r3, #-0x17]
    str.w r2, [r4, #0xb0]
    ldr r2, [r3, #-0xb]
    str.w r2, [r4, #0xbc]
    ldr r1, [r3, #-0x3]
    add r2, r4
    str.w r1, [r4, #0xc4]
    adds r2, #0xc7
    ldr r1, [r3, #-0x7]
    str.w r1, [r4, #0xc0]
    ldr r1, .Lword_1d0
.Lbranch_8a:
    cmp r1, r2
    beq .Lbranch_9c
    ldrb r0, [r3, #1]!
    strb r0, [r1, #1]!
    ldrb r0, [r3, #4]
    strb r0, [r1, #4]
    b .Lbranch_8a
.Lbranch_9c:
    /* The first 128 parameter bytes come from the secure-OS header. */
    ldr r1, .Lword_1d4
    mov.w r4, #0x20000
    movs r2, #0x80
    mov r0, r4
    bl memcpy
    ldr r3, .Lword_1d8
    movs r2, #3
    str r5, [sp, #4]
    movs r1, #0x97
    str r3, [sp]
    movs r3, #1
    ldr r0, .Lword_1dc
    bl trace_printf
    ldr.w r3, [r4, #0xa0]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x98
    str r3, [sp, #4]
    ldr r3, .Lword_1e0
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0xa4]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x99
    str r3, [sp, #4]
    ldr r3, .Lword_1e4
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0xa8]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9a
    str r3, [sp, #4]
    ldr r3, .Lword_1e8
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0xb0]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9b
    str r3, [sp, #4]
    ldr r3, .Lword_1ec
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0xac]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9c
    str r3, [sp, #4]
    ldr r3, .Lword_1f0
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0xc0]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9d
    str r3, [sp, #4]
    ldr r3, .Lword_1f4
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldrb.w r3, [r4, #0xcc]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9e
    str r3, [sp, #4]
    ldr r3, .Lword_1f8
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr.w r3, [r4, #0x94]
    movs r2, #3
    ldr r0, .Lword_1dc
    movs r1, #0x9f
    str r3, [sp, #4]
    ldr r3, .Lword_1fc
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    isb sy
    dsb sy
    ldr r0, .Lword_200
    movs r3, #0xf0
    str r3, [sp, #4]
    movs r2, #3
    ldr r3, .Lword_204
    movs r1, #0xb3
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    ldr r3, .Lword_208
    movs r2, #3
    str r4, [sp, #4]
    movs r1, #0xb4
    str r3, [sp]
    movs r3, #1
    ldr r0, .Lword_200
    bl trace_printf
    ldr r3, .Lword_20c
    /* Enter ARM SRAM at its hardware address, then retain the observed return order. */
    blx r3
    bl standby_host_mmu_enable
    bl standby_host_mmu_disable
    ldr r3, .Lword_210
    movs r2, #3
    ldr r0, .Lword_200
    movs r1, #0xba
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    add sp, #0xc
    pop {r4, r5, pc}
.size standby_host_suspend, .-standby_host_suspend
.balign 4
.Lword_1bc:
    .word sunxi_standby_wrapper_start
.Lword_1c0:
    .word sunxi_standby_wrapper_end
.Lword_1c4:
    .word standby_host_settings
.Lword_1c8:
    .word standby_host_resume_entry
.Lword_1cc:
    .word standby_host_configuration
.Lword_1d0:
    .word 0x200c7
.Lword_1d4:
    .word tee_spare_head + 44
.Lword_1d8:
    .word .Lstring_0
.Lword_1dc:
    .word .Lstring_1
.Lword_1e0:
    .word .Lstring_2
.Lword_1e4:
    .word .Lstring_3
.Lword_1e8:
    .word .Lstring_4
.Lword_1ec:
    .word .Lstring_5
.Lword_1f0:
    .word .Lstring_6
.Lword_1f4:
    .word .Lstring_7
.Lword_1f8:
    .word .Lstring_8
.Lword_1fc:
    .word .Lstring_9
.Lword_200:
    .word .Lstring_10
.Lword_204:
    .word .Lstring_11
.Lword_208:
    .word .Lstring_12
.Lword_20c:
    .word 0x200f0
.Lword_210:
    .word .Lstring_13
.section .rodata.standby_host_suspend,"a",%progbits
.Lstring_0:
    .asciz "standby_type: 0x%8.8x\n"
.Lstring_1:
    .asciz "sram_init_para"
.Lstring_2:
    .asciz "vdd_cpua: 0x%8.8x\n"
.Lstring_3:
    .asciz "vdd_cpub: 0x%8.8x\n"
.Lstring_4:
    .asciz "vdd_sys: 0x%8.8x\n"
.Lstring_5:
    .asciz "vcc_io: 0x%8.8x\n"
.Lstring_6:
    .asciz "vdd_pll: 0x%8.8x\n"
.Lstring_7:
    .asciz "pmu_port: 0x%8.8x\n"
.Lstring_8:
    .asciz "pmu_addr: 0x%8.8x\n"
.Lstring_9:
    .asciz "time_to_wakeup_ms: 0x%8.8x\n"
.Lstring_10:
    .asciz "suspend2ram"
.Lstring_11:
    .asciz "enter standby, head size:0x%x\n"
.Lstring_12:
    .asciz "enter standby, SRAM_BASE:0x%x\n"
.Lstring_13:
    .asciz "exit standby\n"
.section .note.GNU-stack,"",%progbits
