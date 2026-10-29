/* Bit 3 of the request flags selects audio standby; other bits are ignored. */
.syntax unified
.arch armv7-a
.thumb
.section .text.standby_host_get_type,"ax",%progbits
.balign 4
.global standby_host_get_type
.type standby_host_get_type,%function
.thumb_func
standby_host_get_type:
    ldr r3, .Lrequest
    push {r0, r1, r2, lr}
    ldr r3, [r3, #4]
    lsls r3, r3, #28
    bpl .Lnormal
    ldr r3, .Laudio_message
    movs r2, #3
    ldr r0, .Lname
    movs r1, #72
    str r3, [sp]
    movs r3, #1
    bl trace_printf
    movs r0, #2
    b .Lreturn
.Lnormal:
    movs r0, #1
.Lreturn:
    add sp, #12
    ldr pc, [sp], #4
.size standby_host_get_type, .-standby_host_get_type
.balign 4
.Lrequest:
    .word standby_host_request
.Laudio_message:
    .word .Laudio
.Lname:
    .word .Lfunction
.section .rodata.standby_host_get_type,"a",%progbits
.Laudio:
    .asciz "AUDIO_STANDBY\n"
.Lfunction:
    .asciz "standby_type"
.section .note.GNU-stack,"",%progbits
