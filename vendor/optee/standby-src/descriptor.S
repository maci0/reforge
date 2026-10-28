/* Descriptor selection: bit zero is special; other indices are bounded inclusively. */
.syntax unified
.arm
.section .text.standby_find_descriptor,"ax",%progbits
.balign 4
.global standby_find_descriptor
.type standby_find_descriptor,%function
standby_find_descriptor:
    ands r3, r1, #1
    ldr r2, [r0, #8]
    bne .Lfirst
    push {lr}
    mov ip, #1
    b .Lnext
.Ltest:
    ands lr, r1, ip, lsl r3
    bne .Lfound
.Lnext:
    add r3, r3, #1
    cmp r3, r2
    bls .Ltest
    mov r0, #0
    pop {pc}
.Lfound:
    add r3, r3, r3, lsl #1
    ldr r0, [r0, #12]
    lsl r3, r3, #4
    add r0, r0, r3
    pop {pc}
.Lfirst:
    ldr r0, [r0, #12]
    mov r3, #0
    add r0, r0, r3
    bx lr
.size standby_find_descriptor, .-standby_find_descriptor
.section .note.GNU-stack,"",%progbits
