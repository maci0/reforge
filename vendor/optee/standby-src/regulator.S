/* Recovered regulator policy. Invalid selections retain the original null reads/traps. */
.syntax unified
.arm
.section .text.standby_regulator_set_voltage,"ax",%progbits
.balign 4
.global standby_regulator_set_voltage
.type standby_regulator_set_voltage,%function
standby_regulator_set_voltage:
    ands r3, r1, #1
    push {r4, r5, r6, r7, r8, r9, lr}
    ldr ip, [r0, #8]
    sub sp, sp, #12
    bne .Lset_voltage_0
    mov lr, #1
    b .Lset_voltage_1
.Lset_voltage_3:
    ands r4, r1, lr, lsl r3
    bne .Lset_voltage_2
.Lset_voltage_1:
    add r3, r3, #1
    cmp r3, ip
    bls .Lset_voltage_3
    mov r3, #0
    ldr r3, [r3, #16]
    udf #0
.Lset_voltage_2:
    add r3, r3, r3, lsl #1
    lsl r3, r3, #4
.Lset_voltage_11:
    mov r4, r0
    ldr r0, [r0, #12]
    add r5, r0, r3
    ldr ip, [r5, #36]
    ldr r6, [r5, #16]
    cmp ip, #0
    beq .Lset_voltage_4
    ldr r8, [r5, #40]
    cmp r8, #0
    ble .Lset_voltage_5
    ldr r0, [ip]
    ldr r7, [ip, #4]
    ldr r3, [ip, #8]
    ldr r1, [ip, #12]
    cmp r2, r0
    movcs lr, #0
    movcc lr, #1
    sub r3, r3, r7
    mla r3, r1, r3, r0
    cmp r2, r3
    movls r3, lr
    orrhi r3, lr, #1
    cmp r3, #0
    beq .Lset_voltage_6
    mov r3, ip
    mov lr, #0
.Lset_voltage_7:
    add lr, lr, #1
    cmp lr, r8
    beq .Lset_voltage_5
    ldr r0, [r3, #16]
    add r3, r3, #16
    ldr r7, [r3, #4]
    ldr ip, [r3, #8]
    ldr r1, [r3, #12]
    cmp r2, r0
    movcs r9, #0
    movcc r9, #1
    sub ip, ip, r7
    mla ip, r1, ip, r0
    cmp r2, ip
    movls ip, r9
    orrhi ip, r9, #1
    cmp ip, #0
    bne .Lset_voltage_7
.Lset_voltage_6:
    cmp r1, #0
    beq .Lset_voltage_8
    sub r0, r2, r0
    bl __aeabi_uidiv
    mov r1, r0
.Lset_voltage_8:
    add r7, r7, r1
    uxtb r7, r7
.Lset_voltage_10:
    ldrb r2, [r5, #12]
    add r3, sp, #7
    ldrb r1, [r4]
    mov r0, #0
    bl standby_twi_transfer
    cmp r0, #0
    bne .Lset_voltage_9
    mov ip, #1
    ldrb r2, [sp, #7]
    lsl r3, ip, r6
    sub r3, r3, #1
    uxtb r3, r3
    and r1, r3, r2
    cmp r1, r7
    beq .Lset_voltage_9
    bic r2, r2, r3
    ldrb r1, [r4]
    orr r7, r2, r7
    add r3, sp, #7
    ldrb r2, [r5, #12]
    mov r0, ip
    strb r7, [sp, #7]
    bl standby_twi_transfer
.Lset_voltage_9:
    add sp, sp, #12
    pop {r4, r5, r6, r7, r8, r9, pc}
.Lset_voltage_5:
    mvn r0, #0
    add sp, sp, #12
    pop {r4, r5, r6, r7, r8, r9, pc}
.Lset_voltage_4:
    ldr r1, [r5, #8]
    ldr r3, [r0, r3]
    sub r0, r1, #1
    sub r0, r0, r3
    add r0, r0, r2
    bl __aeabi_uidiv
    uxtb r7, r0
    b .Lset_voltage_10
.Lset_voltage_0:
    mov r3, #0
    b .Lset_voltage_11
.size standby_regulator_set_voltage, .-standby_regulator_set_voltage
.section .text.standby_regulator_get_voltage,"ax",%progbits
.balign 4
.global standby_regulator_get_voltage
.type standby_regulator_get_voltage,%function
standby_regulator_get_voltage:
    ands r3, r1, #1
    push {r4, lr}
    ldr r2, [r0, #8]
    sub sp, sp, #8
    bne .Lget_voltage_0
    mov ip, #1
    b .Lget_voltage_1
.Lget_voltage_3:
    ands lr, r1, ip, lsl r3
    bne .Lget_voltage_2
.Lget_voltage_1:
    add r3, r3, #1
    cmp r3, r2
    bls .Lget_voltage_3
    mov r3, #0
    ldr r3, [r3, #12]
    udf #0
.Lget_voltage_2:
    add r3, r3, r3, lsl #1
    lsl r2, r3, #4
.Lget_voltage_11:
    ldr r4, [r0, #12]
    add r3, sp, #7
    ldrb r1, [r0]
    mov r0, #0
    add r4, r4, r2
    ldrb r2, [r4, #12]
    bl standby_twi_transfer
    cmp r0, #0
    beq .Lget_voltage_4
.Lget_voltage_10:
    add sp, sp, #8
    pop {r4, pc}
.Lget_voltage_4:
    ldr r3, [r4, #36]
    mvn ip, #0
    ldr r1, [r4, #16]
    ldrb r2, [sp, #7]
    cmp r3, #0
    bic r2, r2, ip, lsl r1
    beq .Lget_voltage_5
    ldr ip, [r4, #40]
    cmp ip, #0
    ble .Lget_voltage_6
.Lget_voltage_9:
    ldr r1, [r3, #8]
    cmp r2, r1
    bhi .Lget_voltage_7
    ldr r1, [r3, #4]
    cmp r2, r1
    bcs .Lget_voltage_8
.Lget_voltage_7:
    add r0, r0, #1
    add r3, r3, #16
    cmp ip, r0
    bne .Lget_voltage_9
.Lget_voltage_6:
    mvn r0, #0
    b .Lget_voltage_10
.Lget_voltage_8:
    ldr r0, [r3, #12]
    sub r2, r2, r1
    ldr r3, [r3]
    mla r0, r0, r2, r3
    add sp, sp, #8
    pop {r4, pc}
.Lget_voltage_0:
    mov r2, #0
    b .Lget_voltage_11
.Lget_voltage_5:
    ldr r0, [r4, #8]
    ldr r3, [r4]
    mla r0, r0, r2, r3
    b .Lget_voltage_10
.size standby_regulator_get_voltage, .-standby_regulator_get_voltage
.section .text.standby_regulator_set_enabled,"ax",%progbits
.balign 4
.global standby_regulator_set_enabled
.type standby_regulator_set_enabled,%function
standby_regulator_set_enabled:
    ands r3, r1, #1
    push {r4, lr}
    ldr ip, [r0, #8]
    bne .Lset_enabled_0
    mov lr, #1
    b .Lset_enabled_1
.Lset_enabled_3:
    ands r4, r1, lr, lsl r3
    bne .Lset_enabled_2
.Lset_enabled_1:
    add r3, r3, #1
    cmp r3, ip
    bls .Lset_enabled_3
    mov r1, #0
.Lset_enabled_5:
    cmp r2, #0
    bne .Lset_enabled_4
    ldrb r2, [r1, #32]
    ldrb r3, [r1, #24]
    pop {r4, lr}
    cmp r2, #0
    mvneq r2, r3
    ldrb r1, [r1, #20]
    uxtbeq r2, r2
    b standby_pmic_update
.Lset_enabled_4:
    ldrb r2, [r1, #28]
    pop {r4, lr}
    cmp r2, #0
    ldrbeq r2, [r1, #24]
    ldrbne r3, [r1, #24]
    ldrb r1, [r1, #20]
    moveq r3, r2
    b standby_pmic_update
.Lset_enabled_2:
    add r3, r3, r3, lsl #1
    lsl r3, r3, #4
.Lset_enabled_6:
    ldr r1, [r0, #12]
    add r1, r1, r3
    b .Lset_enabled_5
.Lset_enabled_0:
    mov r3, #0
    b .Lset_enabled_6
.size standby_regulator_set_enabled, .-standby_regulator_set_enabled
.section .text.standby_regulator_get_enabled,"ax",%progbits
.balign 4
.global standby_regulator_get_enabled
.type standby_regulator_get_enabled,%function
standby_regulator_get_enabled:
    ands r3, r1, #1
    push {r4, lr}
    ldr r2, [r0, #8]
    sub sp, sp, #8
    bne .Lget_enabled_0
    mov ip, #1
    b .Lget_enabled_1
.Lget_enabled_3:
    ands lr, r1, ip, lsl r3
    bne .Lget_enabled_2
.Lget_enabled_1:
    add r3, r3, #1
    cmp r3, r2
    bls .Lget_enabled_3
    mov r3, #0
    ldr r3, [r3, #20]
    udf #0
.Lget_enabled_2:
    add r3, r3, r3, lsl #1
    lsl r2, r3, #4
.Lget_enabled_8:
    ldr r4, [r0, #12]
    add r3, sp, #7
    ldrb r1, [r0]
    mov r0, #0
    add r4, r4, r2
    ldrb r2, [r4, #20]
    bl standby_twi_transfer
    cmp r0, #0
    bne .Lget_enabled_4
    ldr r0, [r4, #28]
    cmp r0, #0
    beq .Lget_enabled_5
    ldrb r3, [sp, #7]
    sub r0, r3, r0
    clz r0, r0
    lsr r0, r0, #5
.Lget_enabled_4:
    add sp, sp, #8
    pop {r4, pc}
.Lget_enabled_5:
    ldr r3, [r4, #32]
    ldrb r2, [sp, #7]
    cmp r3, #0
    bne .Lget_enabled_6
.Lget_enabled_7:
    ldr r3, [r4, #24]
    tst r2, r3
    movne r0, #1
    moveq r0, #0
    add sp, sp, #8
    pop {r4, pc}
.Lget_enabled_6:
    cmp r3, r2
    beq .Lget_enabled_4
    b .Lget_enabled_7
.Lget_enabled_0:
    mov r2, #0
    b .Lget_enabled_8
.size standby_regulator_get_enabled, .-standby_regulator_get_enabled
.section .note.GNU-stack,"",%progbits
