/* Recovered PLL selection and low-power clock sequence; globals are source-linked. */
.syntax unified
.arm
.section .text.standby_clock_select,"ax",%progbits
.balign 4
.global standby_clock_select
.type standby_clock_select,%function
standby_clock_select:
    push {r4, r5, r6, lr}
    movw lr, #:lower16:standby_clock_registers
    movt lr, #:upper16:standby_clock_registers
    mov r6, r0
    sub sp, sp, #32
    lsl r4, r6, #31
    ldm lr!, {r0, r1, r2, r3}
    mov r5, sp
    orr r4, r4, r6, lsl #30
    sub ip, sp, #4
    orr r4, r4, r6, lsl #29
    add r6, sp, #28
    stmia r5!, {r0, r1, r2, r3}
    ldm lr, {r0, r1, r2, r3}
    stm r5, {r0, r1, r2, r3}
.Lclock_select_0:
    ldr r2, [ip, #4]!
    ldr r3, [r2]
    cmp ip, r6
    bic r3, r3, #-536870912
    orr r3, r3, r4
    str r3, [r2]
    bne .Lclock_select_0
    add sp, sp, #32
    pop {r4, r5, r6, pc}
.size standby_clock_select, .-standby_clock_select
.section .text.standby_clock_enter,"ax",%progbits
.balign 4
.global standby_clock_enter
.type standby_clock_enter,%function
standby_clock_enter:
    push {r4, r5, r6, r7, r8, lr}
    movw r4, #:lower16:standby_clock_contexts
    mov r5, #64512
    movt r4, #:upper16:standby_clock_contexts
    movt r5, #63743
    add r6, r4, #48
    mov r7, #1
.Lclock_enter_1:
    ldrb r3, [r4, #7]
    ldr r2, [r4]
    cmp r3, #0
    ldr r3, [r2]
    strb r7, [r4, #7]
    bne .Lclock_enter_0
    ubfx ip, r3, #24, #3
    ubfx r0, r3, #8, #2
    and r1, r3, #3
    strb ip, [r4, #4]
    strb r0, [r4, #5]
    strb r1, [r4, #6]
.Lclock_enter_0:
    bic r1, r3, #117440512
    and r3, r3, r5
    str r1, [r2]
    add r4, r4, #8
    mov r0, #20
    str r3, [r2]
    bl standby_delay_us
    cmp r4, r6
    bne .Lclock_enter_1
    mov r3, #4096
    mov r1, #16777216
    movt r3, #512
    movw r2, #:lower16:standby_clock_saved_aux
    str r1, [r3, #1312]
    movt r2, #:upper16:standby_clock_saved_aux
    ldr ip, [r3, #3896]
    mov r1, #-2147483648
    mov r0, #0
    str ip, [r2]
    str r1, [r3, #3896]
    ldr r2, [r3, #3900]
    bic r2, r2, #56
    orr r2, r2, #48
    str r2, [r3, #3900]
    bl standby_clock_select
    mov r2, #0
    movt r2, #1793
    ldr r3, [r2, #580]
    bic r3, r3, #1
    orr r3, r3, #-1493172224
    str r3, [r2, #580]
    str r3, [r2, #580]
    pop {r4, r5, r6, r7, r8, pc}
.size standby_clock_enter, .-standby_clock_enter
.section .text.standby_clock_leave,"ax",%progbits
.balign 4
.global standby_clock_leave
.type standby_clock_leave,%function
standby_clock_leave:
    mov r2, #0
    push {r4, lr}
    movt r2, #1793
    mov r0, #4
    ldr r3, [r2, #580]
    orr r3, r3, #-1493172224
    orr r3, r3, #1
    str r3, [r2, #580]
    str r3, [r2, #580]
    bl standby_delay_ms
    mov r0, #1
    bl standby_clock_select
    mov r0, #2
    bl standby_delay_ms
    movw r2, #:lower16:standby_clock_saved_aux
    mov r3, #4096
    movt r2, #:upper16:standby_clock_saved_aux
    movt r3, #512
    ldr r2, [r2]
    mov r1, #0
    ldr r0, [r3, #1312]
    str r1, [r3, #1312]
    str r2, [r3, #3896]
    ldr r2, [r3, #3900]
    bic r2, r2, #56
    orr r2, r2, #48
    str r2, [r3, #3900]
    pop {r4, pc}
.size standby_clock_leave, .-standby_clock_leave
.section .note.GNU-stack,"",%progbits
