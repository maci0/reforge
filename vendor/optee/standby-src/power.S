/* Secure WFI transition. CP15/SCR and MMIO require privileged board context. */
.syntax unified
.arm
.section .text.standby_secure_wfi,"ax",%progbits
.balign 4
.global standby_secure_wfi
.type standby_secure_wfi,%function
standby_secure_wfi:
    mov r0, #0
    mov r1, #1
    push {lr}
    mov r3, #0x07000000
    movt r0, #0x16aa
    movt r1, #0x16aa
    mov lr, #0xff
    mov r2, #0
    mov ip, #0x10000
    str r0, [r3, #0x500]
    str r1, [r3, #0x500]
    str lr, [r3, #0x50c]
    str r2, [r3, #0x5c0]
    str ip, [r3, #0x6e0]
    mrc p15, 0, r2, c1, c1, 0
    mov r3, #2
    mcr p15, 0, r3, c1, c1, 0
    isb sy
    dsb sy
    wfi
    mcr p15, 0, r2, c1, c1, 0
    isb sy
    dsb sy
    pop {pc}
.size standby_secure_wfi, .-standby_secure_wfi
.section .note.GNU-stack,"",%progbits
