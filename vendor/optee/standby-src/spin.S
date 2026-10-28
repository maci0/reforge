/* Original ARM counted loops. The repeated loop preserves r0-r3. */
.syntax unified
.arm
.section .text.standby_delay_repeat17,"ax",%progbits
.balign 4
.global standby_delay_repeat17
.type standby_delay_repeat17,%function
standby_delay_repeat17:
    push {r0-r3}
    mov r1, #17
    mov r3, r0
.Lrepeat:
    subs r0, r0, #1
    bhi .Lrepeat
    mov r0, r3
    subs r1, r1, #1
    bhi .Lrepeat
    pop {r0-r3}
    mov pc, lr
.size standby_delay_repeat17, .-standby_delay_repeat17

.section .text.standby_delay_cycles,"ax",%progbits
.balign 4
.global standby_delay_cycles
.type standby_delay_cycles,%function
standby_delay_cycles:
.Lcount:
    subs r0, r0, #1
    bhi .Lcount
    mov pc, lr
.size standby_delay_cycles, .-standby_delay_cycles
.section .note.GNU-stack,"",%progbits
