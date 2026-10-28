/* Recovered entry and return stubs. Privileged entry execution is not a userspace test. */
.syntax unified
.arm
.section .text.standby_entry,"ax",%progbits
.balign 4
.global standby_entry
.type standby_entry,%function
standby_entry:
    movw r3, #:lower16:__bss_start
    movw r2, #:lower16:__bss_end
    mov r0, #0
    movt r3, #:upper16:__bss_start
    movt r2, #:upper16:__bss_end
    mov r1, r0
    mov ip, #1
    movt r0, #1801
    str ip, [r0, #268]
.Lstandby_entry_0:
    strb r1, [r3], #1
    cmp r3, r2
    bls .Lstandby_entry_0
    push {r4, r5, r6, lr}
    movw r4, #:lower16:standby_sram_parameters_address
    movt r4, #:upper16:standby_sram_parameters_address
    movw r6, #:lower16:standby_saved_sp
    movt r6, #:upper16:standby_saved_sp
    bl standby_stack_switch
    ldr r5, [r4]
    mov r2, #0
    movt r2, #1801
    mov r1, #2
    str r0, [r6]
    ldr r3, [r5, #152]
    str r1, [r2, #268]
    cmp r3, #0
    bne .Lstandby_entry_1
.Lstandby_entry_6:
    movw r2, #12816
    ldr ip, [r5, #132]
    ldr r1, [r5, #136]
    and r3, r3, #15
    ldr r0, [r5, #140]
    movt r2, #30292
    orr r2, r3, r2
    mov r5, #0
    mov r3, #4096
    movt r5, #1801
    movt r3, #512
    str r0, [r5, #268]
    str r2, [r5, #256]
    mov r0, #10
    str ip, [r5, #280]
    str r1, [r5, #284]
    ldr r2, [r3, #1280]
    bic r2, r2, #117440512
    str r2, [r3, #1280]
    bl standby_delay_us
    ldr r0, [r4]
    bl standby_dram_suspend_all
    ldr r0, [r4]
    bl standby_clock_enter
    ldr r0, [r4]
    ldr r3, [r0, #156]
    cmp r3, #0
    beq .Lstandby_entry_2
    ldr r3, [r0, #148]
    cmp r3, #0
    bne .Lstandby_entry_3
    mrc p15, 0, r3, c1, c1, 0
    mov r2, #2
    mcr p15, 0, r2, c1, c1, 0
    isb sy
    dsb sy
    wfi
    mcr p15, 0, r3, c1, c1, 0
    isb sy
    dsb sy
.Lstandby_entry_5:
    bl standby_clock_leave
    ldr r0, [r4]
    bl standby_dram_resume_all
    ldr r4, [r4]
    ldr r3, [r4, #152]
    cmp r3, #0
    beq .Lstandby_entry_4
    mov r0, r4
    bl standby_dram_checksum
    str r0, [r4, #144]
.Lstandby_entry_4:
    mov r2, #4096
    mov r0, #10
    movt r2, #512
    ldr r3, [r2, #1280]
    bic r3, r3, #117440512
    orr r3, r3, #50331648
    str r3, [r2, #1280]
    bl standby_delay_us
    ldr r0, [r6]
    bl standby_stack_restore
    mov r0, #0
    pop {r4, r5, r6, pc}
.Lstandby_entry_2:
    ldr r3, [r0, #128]
    mov r2, #65536
    str r2, [r5, #504]
    str r3, [r5, #508]
    bl standby_secure_wfi
    ldr r0, [r4]
    b .Lstandby_entry_5
.Lstandby_entry_1:
    mov r0, r5
    bl standby_dram_checksum
    str r0, [r5, #140]
    ldr r5, [r4]
    ldr r3, [r5, #152]
    b .Lstandby_entry_6
.Lstandby_entry_3:
    lsl r0, r3, #4
    bl standby_delay_cycles
    ldr r0, [r4]
    b .Lstandby_entry_5
.size standby_entry, .-standby_entry
.section .text.standby_unused_return_0,"ax",%progbits
.balign 4
.global standby_unused_return_0
.type standby_unused_return_0,%function
standby_unused_return_0:
    bx lr
.size standby_unused_return_0, .-standby_unused_return_0
.section .text.standby_unused_return_1,"ax",%progbits
.balign 4
.global standby_unused_return_1
.type standby_unused_return_1,%function
standby_unused_return_1:
    bx lr
.size standby_unused_return_1, .-standby_unused_return_1
.section .note.GNU-stack,"",%progbits
