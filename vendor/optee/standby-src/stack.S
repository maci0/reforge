/* 32-KiB SRAM at 0x20000; keep the original 16-byte top-of-stack reservation. */
.syntax unified
.arm
.section .text.standby_stack,"ax",%progbits
.balign 4
.global standby_stack_switch
.type standby_stack_switch,%function
standby_stack_switch:
    mov r0, sp
    ldr sp, .Lstack_top
    mov pc, lr
.size standby_stack_switch, .-standby_stack_switch
.global standby_stack_restore
.type standby_stack_restore,%function
standby_stack_restore:
    mov sp, r0
    mov pc, lr
.size standby_stack_restore, .-standby_stack_restore
.Lstack_top:
    .word 0x20000 + 0x8000 - 16
.section .note.GNU-stack,"",%progbits
