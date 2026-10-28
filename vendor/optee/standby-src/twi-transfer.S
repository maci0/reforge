/* Recovered TWI polling and single-register transfer; MMIO state is source-linked. */
.syntax unified
.arm
.section .text.standby_twi_stop,"ax",%progbits
.balign 4
.global standby_twi_stop
.type standby_twi_stop,%function
standby_twi_stop:
    movw r3, #:lower16:standby_twi_state
    movw r2, #65535
    movt r3, #:upper16:standby_twi_state
    movt r2, #4
    ldr r3, [r3]
    ldr r1, [r3, #12]
    and r1, r1, #192
    orr r1, r1, #24
    str r1, [r3, #12]
    ldr r1, [r3, #12]
    b .Lstop_0
.Lstop_2:
    subs r2, r2, #1
    beq .Lstop_1
.Lstop_0:
    ldr r1, [r3, #12]
    tst r1, #16
    bne .Lstop_2
    movw r2, #65535
    movt r2, #4
    b .Lstop_3
.Lstop_4:
    subs r2, r2, #1
    beq .Lstop_1
.Lstop_3:
    ldr r1, [r3, #16]
    cmp r1, #248
    bne .Lstop_4
    movw r2, #65535
    movt r2, #4
    b .Lstop_5
.Lstop_6:
    subs r2, r2, #1
    beq .Lstop_1
.Lstop_5:
    ldr r1, [r3, #32]
    cmp r1, #58
    bne .Lstop_6
    mov r0, #0
    bx lr
.Lstop_1:
    mvn r0, #0
    bx lr
.size standby_twi_stop, .-standby_twi_stop
.section .text.standby_twi_transfer,"ax",%progbits
.balign 4
.global standby_twi_transfer
.type standby_twi_transfer,%function
standby_twi_transfer:
    push {r4, r5, r6, r7, r8, lr}
    mov r4, r1
    mov r7, r2
    mov r5, r3
    mov r6, r0
    bl standby_twi_stop
    movw r3, #:lower16:standby_twi_state
    mov r1, #0
    movt r3, #:upper16:standby_twi_state
    ldr r2, [r3]
    str r1, [r2, #28]
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #248
    movne r4, #248
    beq .Ltransfer_0
.Ltransfer_4:
    bl standby_twi_stop
    mov r0, r4
    pop {r4, r5, r6, r7, r8, pc}
.Ltransfer_0:
    ldr r1, [r2, #12]
    movw r3, #65535
    movt r3, #4
    orr r1, r1, #32
    str r1, [r2, #12]
    b .Ltransfer_1
.Ltransfer_3:
    subs r3, r3, #1
    beq .Ltransfer_2
.Ltransfer_1:
    ldr r1, [r2, #12]
    tst r1, #8
    beq .Ltransfer_3
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #8
    movne r4, #8
    bne .Ltransfer_4
    lsl r4, r4, #1
    movw r3, #65535
    movt r3, #4
    uxtb r1, r4
    str r1, [r2, #8]
    ldr r1, [r2, #12]
    and r1, r1, #207
    str r1, [r2, #12]
    b .Ltransfer_5
.Ltransfer_7:
    subs r3, r3, #1
    beq .Ltransfer_6
.Ltransfer_5:
    ldr r1, [r2, #12]
    tst r1, #8
    beq .Ltransfer_7
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #24
    movne r4, #24
    bne .Ltransfer_4
    str r7, [r2, #8]
    movw r3, #65535
    ldr r1, [r2, #12]
    movt r3, #4
    and r1, r1, #207
    str r1, [r2, #12]
    b .Ltransfer_8
.Ltransfer_10:
    subs r3, r3, #1
    beq .Ltransfer_9
.Ltransfer_8:
    ldr r1, [r2, #12]
    tst r1, #8
    beq .Ltransfer_10
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #40
    beq .Ltransfer_11
.Ltransfer_20:
    mov r4, #40
    b .Ltransfer_4
.Ltransfer_2:
    mov r4, #255
    b .Ltransfer_4
.Ltransfer_6:
    mov r4, #254
    b .Ltransfer_4
.Ltransfer_9:
    mov r4, #253
    b .Ltransfer_4
.Ltransfer_11:
    cmp r6, #1
    beq .Ltransfer_12
    ldr r3, [r2, #12]
    movw r1, #65535
    movt r1, #4
    and r3, r3, #192
    orr r3, r3, #40
    str r3, [r2, #12]
    b .Ltransfer_13
.Ltransfer_15:
    subs r1, r1, #1
    beq .Ltransfer_14
.Ltransfer_13:
    ldr r3, [r2, #12]
    tst r3, #8
    beq .Ltransfer_15
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #16
    movne r4, #16
    bne .Ltransfer_4
    orr r4, r4, #1
    movw r3, #65535
    str r4, [r2, #8]
    movt r3, #4
    ldr r1, [r2, #12]
    and r1, r1, #207
    str r1, [r2, #12]
.Ltransfer_17:
    ldr r1, [r2, #12]
    tst r1, #8
    bne .Ltransfer_16
    subs r3, r3, #1
    bne .Ltransfer_17
    mov r4, #250
    b .Ltransfer_4
.Ltransfer_12:
    ldrb r1, [r5]
    movw r3, #65535
    movt r3, #4
    str r1, [r2, #8]
    ldr r1, [r2, #12]
    and r1, r1, #207
    str r1, [r2, #12]
.Ltransfer_19:
    ldr r1, [r2, #12]
    tst r1, #8
    bne .Ltransfer_18
    subs r3, r3, #1
    bne .Ltransfer_19
    mov r4, #252
    b .Ltransfer_4
.Ltransfer_14:
    mov r4, #251
    b .Ltransfer_4
.Ltransfer_18:
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #40
    bne .Ltransfer_20
.Ltransfer_23:
    mov r4, #0
    b .Ltransfer_4
.Ltransfer_16:
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #64
    movne r4, #64
    bne .Ltransfer_4
    ldr r1, [r2, #12]
    movw r3, #65535
    movt r3, #4
    and r1, r1, #207
    str r1, [r2, #12]
.Ltransfer_22:
    ldr r1, [r2, #12]
    tst r1, #8
    bne .Ltransfer_21
    subs r3, r3, #1
    bne .Ltransfer_22
    mov r4, #249
    b .Ltransfer_4
.Ltransfer_21:
    ldr r3, [r2, #8]
    strb r3, [r5]
    ldr r3, [r2, #16]
    uxtb r3, r3
    cmp r3, #88
    movne r4, #88
    bne .Ltransfer_4
    b .Ltransfer_23
.size standby_twi_transfer, .-standby_twi_transfer
.section .note.GNU-stack,"",%progbits
