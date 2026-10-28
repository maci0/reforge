/* Collect selected entry masks for one control register, preserving signed-byte loads. */
.syntax unified
.arm
.section .text.standby_pmic_group_control,"ax",%progbits
.balign 4
.global standby_pmic_group_control
.type standby_pmic_group_control,%function
standby_pmic_group_control:
    push {r4, r5, r6, r7, r8, r9, sl, lr}
    mov r4, #0
    movw r7, #:lower16:standby_pmic_device
    mov r9, r0
    mov r6, r1
    mov r8, r4
    movt r7, #:upper16:standby_pmic_device
    mov sl, #15
    mov r5, #1
    b .Lgroup_0
.Lgroup_2:
    cmp r4, #16
    beq .Lgroup_1
.Lgroup_0:
    lsl r1, r5, r4
    add r4, r4, #1
    tst r1, r6
    beq .Lgroup_2
    mov r0, r7
    bl standby_find_descriptor
    ldr r3, [r0, #20]
    cmp r9, r3
    ldrsbeq r3, [r0, #24]
    orreq r8, r3, r8
    biceq sl, sl, r3
    uxtbeq r8, r8
    cmp r4, #16
    bne .Lgroup_0
.Lgroup_1:
    movw r0, #:lower16:standby_pmic_device
    mov r3, r8
    mov r2, sl
    mov r1, r9
    movt r0, #:upper16:standby_pmic_device
    pop {r4, r5, r6, r7, r8, r9, sl, lr}
    b standby_pmic_update
.size standby_pmic_group_control, .-standby_pmic_group_control
.section .note.GNU-stack,"",%progbits
