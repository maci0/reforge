/* Legacy delay scaling. These names do not certify physical elapsed time. */
.syntax unified
.arm
.section .text.standby_delay_us,"ax",%progbits
.balign 4
.global standby_delay_us
.type standby_delay_us,%function
standby_delay_us:
    lsl r0, r0, #2
    b standby_delay_cycles
.size standby_delay_us, .-standby_delay_us

.section .text.standby_delay_ms,"ax",%progbits
.balign 4
.global standby_delay_ms
.type standby_delay_ms,%function
standby_delay_ms:
    cmp r0, #10
    push {r4, lr}
    mov r4, r0
    bls .Ltail
.Lchunk:
    sub r4, r4, #10
    movw r0, #40000
    bl standby_delay_cycles
    cmp r4, #10
    bhi .Lchunk
.Ltail:
    mov r0, #1000
    mul r0, r0, r4
    pop {r4, lr}
    lsl r0, r0, #2
    b standby_delay_cycles
.size standby_delay_ms, .-standby_delay_ms
.section .note.GNU-stack,"",%progbits
