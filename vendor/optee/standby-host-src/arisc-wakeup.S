/* Owner-3 wake IRQ, timeout and standby-setting commands. */
.syntax unified
.arch armv7-a
.thumb
.section .text.sunxi_arisc_handler,"ax",%progbits
.balign 4
.global sunxi_arisc_handler
.type sunxi_arisc_handler,%function
.thumb_func
sunxi_arisc_handler:
    .fnstart
    .save {r4, r5, r6, lr}
    .pad #8
    ldr r3, [r0]
    ldr r2, .Larisc_word_b4
    push {r0, r1, r4, r5, r6, lr}
    mov r4, r0
    cmp r3, r2
    beq .Larisc_62
    adds r2, #0x3e
    cmp r3, r2
    beq .Larisc_1a
    subs r2, #0x3f
    cmp r3, r2
    bne .Larisc_aa
    b .Larisc_30
.Larisc_1a:
    ldr r2, [r0, #4]
    ldr r3, .Larisc_word_b8
    adds r2, #0
    it ne
    movne r2, #1
    strb r2, [r3]
    ldr r2, [r0, #8]
    str r2, [r3, #4]
    ldr r2, [r0, #0xc]
    str r2, [r3, #8]
    b .Larisc_5e
.Larisc_30:
    ldr r3, [r0, #4]
    lsrs r2, r3, #0x1e
    cmp r2, #3
    bne .Larisc_40
    ldr r3, .Larisc_word_b8
    movs r2, #0
    str r2, [r3, #0xc]
    b .Larisc_5e
.Larisc_40:
    lsrs r2, r3, #0xa
    bne .Larisc_5e
    lsrs r0, r3, #5
    movs r2, #1
    ldr r1, .Larisc_word_bc
    and r3, r3, #0x1f
    lsl.w r3, r2, r3
    ldr.w r2, [r1, r0, lsl #2]
    bic.w r2, r2, r3
    str.w r2, [r1, r0, lsl #2]
.Larisc_5e:
    movs r3, #0
    b .Larisc_ae
.Larisc_62:
    ldr r6, [r0, #4]
    movs r2, #3
    ldr r3, .Larisc_word_c0
    movs r1, #0x63
    ubfx r5, r6, #0, #0xa
    str r3, [sp]
    movs r3, #1
    str r5, [sp, #4]
    ldr r0, .Larisc_word_c4
    bl trace_printf
    ldr r3, [r4, #4]
    lsrs r2, r3, #0x1e
    cmp r2, #3
    bne .Larisc_8c
    ldr r2, .Larisc_word_b8
    bic r3, r3, #0xc0000000
    str r3, [r2, #0xc]
    b .Larisc_5e
.Larisc_8c:
    lsrs r3, r3, #0xa
    bne .Larisc_5e
    lsrs r5, r5, #5
    movs r3, #1
    ldr r2, .Larisc_word_bc
    and r6, r6, #0x1f
    lsl.w r6, r3, r6
    ldr.w r3, [r2, r5, lsl #2]
    orrs r3, r6
    str.w r3, [r2, r5, lsl #2]
    b .Larisc_5e
.Larisc_aa:
    mov.w r3, #-1
.Larisc_ae:
    str r3, [r4]
    add sp, #8
    pop {r4, r5, r6, pc}
.size sunxi_arisc_handler, .-sunxi_arisc_handler
.Larisc_word_b4:
    .word 0x83000026
.Larisc_word_b8:
    .word standby_host_settings
.Larisc_word_bc:
    .word standby_host_request
.Larisc_word_c0:
    .word .Larisc_format
.Larisc_word_c4:
    .word .Larisc_function
    .fnend
.section .rodata.sunxi_arisc_handler,"a",%progbits
.Larisc_format:
    .asciz "root_irq:%d\n"
.Larisc_function:
    .asciz "sunxi_arisc_handler"
.section .note.GNU-stack,"",%progbits
