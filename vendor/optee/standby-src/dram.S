/* Recovered DRAM controller/PHY operations. State and calls use source symbols. */
.syntax unified
.arm
.section .text.standby_dram_restore_lanes,"ax",%progbits
.balign 4
.global standby_dram_restore_lanes
.type standby_dram_restore_lanes,%function
standby_dram_restore_lanes:
    mov r3, #12288
    ldr ip, .Lstandby_dram_restore_lanes_data_3
    movt r3, #784
    push {lr}
    ldr r2, [r3, #256]
    movw r0, #13116
    movw lr, #13628
    movt r0, #784
    movt lr, #784
    bic r2, r2, #67108864
    str r2, [r3, #256]
.Lstandby_dram_restore_lanes_1:
    sub r3, r0, #44
    mov r2, ip
.Lstandby_dram_restore_lanes_0:
    ldr r1, [r2], #4
    str r1, [r3], #4
    cmp r0, r3
    bne .Lstandby_dram_restore_lanes_0
    add r0, r0, #128
    add ip, ip, #44
    cmp r0, lr
    bne .Lstandby_dram_restore_lanes_1
    ldr r3, .Lstandby_dram_restore_lanes_data_4
    movw r0, #12580
    movt r0, #784
    sub lr, r3, #236
    add ip, r3, #124
    sub r0, r0, lr
.Lstandby_dram_restore_lanes_2:
    add r2, r0, r3
    ldr r1, [r3, #4]!
    cmp r3, ip
    str r1, [r2]
    bne .Lstandby_dram_restore_lanes_2
    ldr r2, [lr, #392]
    mov r3, #12288
    ldr ip, [lr, #380]
    movt r3, #784
    ldr r0, [lr, #384]
    ldr r1, [lr, #388]
    str ip, [r3, #828]
    str r0, [r3, #956]
    str r1, [r3, #1084]
    str r2, [r3, #1212]
    ldr r2, [r3, #256]
    orr r2, r2, #67108864
    str r2, [r3, #256]
    pop {pc}
.size standby_dram_restore_lanes, .-standby_dram_restore_lanes
.Lstandby_dram_restore_lanes_data_3:
    .word standby_dram_state + 60
.Lstandby_dram_restore_lanes_data_4:
    .word standby_dram_state + 236
.section .text.standby_dram_configure_modulation,"ax",%progbits
.balign 4
.global standby_dram_configure_modulation
.type standby_dram_configure_modulation,%function
standby_dram_configure_modulation:
    ldr r3, [r1]
    tst r3, #2
    ldrne r3, [r2]
    orrne r3, r3, #524288
    strne r3, [r2]
    ldr r3, [r0, #92]
    ubfx r3, r3, #20, #3
    cmp r3, #3
    beq .Lstandby_dram_configure_modulation_0
    bhi .Lstandby_dram_configure_modulation_1
    cmp r3, #1
    beq .Lstandby_dram_configure_modulation_2
    cmp r3, #2
    movweq r3, #39321
    movteq r3, #59654
    streq r3, [r2]
    bne .Lstandby_dram_configure_modulation_3
.Lstandby_dram_configure_modulation_4:
    ldr r3, [r1]
    mov r0, #0
    orr r3, r3, #16777216
    str r3, [r1]
    bx lr
.Lstandby_dram_configure_modulation_1:
    cmp r3, #4
    beq .Lstandby_dram_configure_modulation_3
    cmp r3, #5
    moveq r3, #0
    movteq r3, #62854
    streq r3, [r2]
    beq .Lstandby_dram_configure_modulation_4
.Lstandby_dram_configure_modulation_3:
    movw r3, #13107
    movt r3, #61958
    str r3, [r2]
    b .Lstandby_dram_configure_modulation_4
.Lstandby_dram_configure_modulation_2:
    movw r3, #52428
    movt r3, #58502
    str r3, [r2]
    b .Lstandby_dram_configure_modulation_4
.Lstandby_dram_configure_modulation_0:
    movw r3, #26214
    movt r3, #60806
    str r3, [r2]
    b .Lstandby_dram_configure_modulation_4
.size standby_dram_configure_modulation, .-standby_dram_configure_modulation
.section .text.standby_dram_program_pll,"ax",%progbits
.balign 4
.global standby_dram_program_pll
.type standby_dram_program_pll,%function
standby_dram_program_pll:
    ldr r3, [r1, #92]
    movw r2, #43691
    push {r4, r5}
    movt r2, #43690
    ubfx r3, r3, #6, #1
    cmp r3, r0
    mov r3, #4096
    ldreq r4, [r1]
    movt r3, #512
    ldrne r4, [r1, #76]
    mov r1, #252
    ldr r0, [r3, #16]
    movt r1, #65528
    lsl r4, r4, #1
    and r1, r1, r0
    orr r1, r1, #-1073741824
    umull r4, r5, r4, r2
    mov r2, r3
    lsr r0, r5, #4
    sub ip, r0, #1
    orr r1, r1, ip, lsl #8
    str r1, [r3, #16]
    ldr r1, [r3, #16]
    bic r1, r1, #536870912
    str r1, [r3, #16]
    ldr r1, [r3, #16]
    orr r1, r1, #536870912
    str r1, [r3, #16]
.Lstandby_dram_program_pll_0:
    ldr r3, [r2, #16]
    tst r3, #268435456
    beq .Lstandby_dram_program_pll_0
    ldr r1, [r2, #16]
    movw r3, #64764
    movt r3, #64767
    add r0, r0, r0, lsl #1
    pop {r4, r5}
    orr r1, r1, #134217728
    lsl r0, r0, #3
    str r1, [r2, #16]
    ldr r1, [r2, #2048]
    and r3, r3, r1
    orr r3, r3, #-2147483648
    str r3, [r2, #2048]
    bx lr
.size standby_dram_program_pll, .-standby_dram_program_pll
.section .text.standby_dram_restore_common_config,"ax",%progbits
.balign 4
.global standby_dram_restore_common_config
.type standby_dram_restore_common_config,%function
standby_dram_restore_common_config:
    movw r3, #:lower16:standby_dram_state
    mov r2, #8192
    movt r3, #:upper16:standby_dram_state
    movt r2, #784
    add r0, r3, #404
    ldr ip, [r3, #400]
    ldm r0, {r0, r1, r3}
    str ip, [r2, #1280]
    str r0, [r2, #1284]
    str r1, [r2, #1288]
    str r3, [r2, #1292]
    bx lr
.size standby_dram_restore_common_config, .-standby_dram_restore_common_config
.section .text.standby_dram_configure_tpr5_6,"ax",%progbits
.balign 4
.global standby_dram_configure_tpr5_6
.type standby_dram_configure_tpr5_6,%function
standby_dram_configure_tpr5_6:
    ldr r1, [r0, #92]
    tst r1, #131072
    bxne lr
    mov r3, #12288
    push {lr}
    movt r3, #784
    ldr ip, [r0, #60]
    movw r2, #32896
    tst r1, #65536
    ldr lr, [r3, #272]
    movt r2, #32896
    and r2, r2, lr
    orr r2, r2, ip
    str r2, [r3, #272]
    popne {pc}
    ldr r1, [r0, #64]
    ldr r2, [r3, #276]
    and r1, r1, #127
    bic r2, r2, #127
    orr r2, r1, r2
    str r2, [r3, #276]
    pop {pc}
.size standby_dram_configure_tpr5_6, .-standby_dram_configure_tpr5_6
.section .text.standby_dram_resume_core,"ax",%progbits
.balign 4
.global standby_dram_resume_core
.type standby_dram_resume_core,%function
standby_dram_resume_core:
    push {r4, r5, r6, r7, r8, lr}
    mov r4, #4096
    movt r4, #512
    mov r5, r0
    mov r1, r0
    mov r0, #0
    ldr r3, [r4, #1344]
    mov r8, r0
    mov r6, #8192
    mov r7, #12288
    movt r6, #784
    movt r7, #784
    bic r3, r3, #1073741824
    str r3, [r4, #1344]
    ldr r3, [r4, #2060]
    bic r3, r3, #1
    str r3, [r4, #2060]
    ldr r3, [r4, #2060]
    bic r3, r3, #65536
    str r3, [r4, #2060]
    ldr r3, [r4, #2048]
    bic r3, r3, #1073741824
    str r3, [r4, #2048]
    ldr r3, [r4, #2048]
    bic r3, r3, #-2147483648
    str r3, [r4, #2048]
    ldr r3, [r4, #2048]
    orr r3, r3, #134217728
    str r3, [r4, #2048]
    bl standby_dram_program_pll
    lsr r0, r0, #1
    mov r3, #1
    mov r2, #32768
    str r0, [r5]
    mov r0, r5
    str r3, [r6, #32]
    str r8, [r6, #36]
    str r8, [r6, #40]
    ldr r3, [r4, #2060]
    orr r3, r3, #65536
    str r3, [r4, #2060]
    ldr r3, [r4, #1344]
    orr r3, r3, #1073741824
    str r3, [r4, #1344]
    ldr r3, [r4, #2048]
    orr r3, r3, #1073741824
    str r3, [r4, #2048]
    ldr r3, [r4, #2060]
    orr r3, r3, #1
    str r3, [r4, #2060]
    ldr r3, [r4, #2048]
    orr r3, r3, #-2147483648
    str r3, [r4, #2048]
    ldr r3, [r4, #2048]
    orr r3, r3, #134217728
    str r3, [r4, #2048]
    str r2, [r7, #12]
    bl standby_dram_configure_tpr5_6
    movw r2, #:lower16:standby_dram_state
    ldr r1, [r5, #20]
    movt r2, #:upper16:standby_dram_state
    movw r3, #513
    ldr ip, [r2]
    ldr r0, [r2, #4]
    ldr lr, [r2, #400]
    str ip, [r6]
    str r0, [r6, #4]
    movw r0, #771
    ldr ip, [r6]
    ldr r4, [r2, #412]
    ldr r6, [r2, #408]
    tst ip, #1
    ldr ip, [r2, #404]
    movne r3, r0
    mov r0, #8192
    movt r0, #784
    tst r1, #1
    str r3, [r7, #288]
    mov r3, #12288
    strne r8, [r7, #964]
    movt r3, #784
    ldr r1, [r5, #12]
    str lr, [r0, #1280]
    str ip, [r0, #1284]
    ldrh ip, [r5, #24]
    ubfx lr, r1, #4, #2
    str r6, [r0, #1288]
    and r1, r1, #1
    ldrh r7, [r5, #28]
    eor r1, r1, #1
    str r4, [r0, #1292]
    lsl r1, r1, #5
    ldrh r6, [r5, #32]
    ldrh r4, [r5, #36]
    ldr r0, [r2, #12]
    str ip, [r3, #48]
    ldr ip, [r2, #8]
    str r7, [r3, #52]
    str r6, [r3, #56]
    ldr r6, [r2, #16]
    str r4, [r3, #60]
    ldr r4, [r2, #20]
    str lr, [r3, #44]
    ldr lr, [r2, #24]
    str ip, [r3, #88]
    ldr ip, [r2, #28]
    str r0, [r3, #92]
    ldr r0, [r2, #32]
    str r6, [r3, #96]
    str r4, [r3, #100]
    str lr, [r3, #104]
    ldr r4, [r2, #36]
    str ip, [r3, #108]
    ldr lr, [r2, #40]
    str r0, [r3, #120]
    ldr ip, [r2, #44]
    ldr r0, [r2, #416]
    ldr r2, [r2, #420]
    str r4, [r3, #128]
    str lr, [r3, #80]
    str ip, [r3, #84]
    str r0, [r3, #144]
    str r2, [r3, #148]
    ldr r2, [r3, #264]
    ldr r0, [r5]
    ldr r4, [r5, #92]
    bic r2, r2, #3840
    orr r2, r2, #768
    cmp r0, #672
    str r2, [r3, #264]
    ubfx r4, r4, #2, #2
    ldr r2, [r3, #836]
    bic r2, r2, #48
    orr r2, r2, r1
    bls .Lstandby_dram_resume_core_0
    movw r0, #2545
    movt r0, #65535
    and r2, r2, r0
    orr r2, r2, #1024
    str r2, [r3, #836]
    ldr r3, [r3, #964]
    bic r3, r3, #48
    orr r1, r1, r3
    and r1, r1, r0
    orr r1, r1, #1024
.Lstandby_dram_resume_core_10:
    mov r6, #12288
    mov r0, r5
    movt r6, #784
    str r1, [r6, #964]
    ldr r3, [r6, #520]
    bic r3, r3, #2048
    orr r3, r3, #2
    str r3, [r6, #520]
    bl standby_dram_restore_lanes
    cmp r4, #1
    beq .Lstandby_dram_resume_core_1
    cmp r4, #2
    beq .Lstandby_dram_resume_core_2
    ldr r3, [r6, #264]
    bic r3, r3, #64
    str r3, [r6, #264]
    ldr r3, [r6, #264]
    orr r3, r3, #192
    str r3, [r6, #264]
.Lstandby_dram_resume_core_12:
    ldr r3, [r5, #4]
    sub r3, r3, #6
    cmp r3, #1
    bls .Lstandby_dram_resume_core_3
.Lstandby_dram_resume_core_11:
    mov r2, #12288
    ldr r3, [r5, #20]
    movt r2, #784
    ldr r1, [r2, #192]
    tst r3, #4096
    movw r3, #12423
    movtne r3, #768
    movteq r3, #256
    and r1, r1, #-268435456
    cmp r4, #1
    orr r3, r1, r3
    mov r1, #0
    movt r1, #1793
    str r3, [r2, #192]
    ldr r0, [r1, #592]
    mov r2, #12288
    ldr r3, [r5, #8]
    movt r2, #784
    bic r0, r0, #2
    str r0, [r1, #592]
    bic r1, r3, #-16777216
    ldr r3, [r2, #320]
    movne r0, #98
    and r3, r3, #-67108864
    orr r3, r1, r3
    movne r1, #99
    orr r3, r3, #33554432
    str r3, [r2, #320]
    beq .Lstandby_dram_resume_core_4
.Lstandby_dram_resume_core_16:
    mov r3, #12288
    movt r3, #784
    mov r2, r3
    str r0, [r3]
    str r1, [r3]
.Lstandby_dram_resume_core_5:
    ldr r3, [r2, #16]
    tst r3, #1
    beq .Lstandby_dram_resume_core_5
    ldr r3, [r2, #268]
    mov r1, #12288
    movt r1, #784
    bic r3, r3, #100663296
    orr r3, r3, #67108864
    str r3, [r2, #268]
    ldr r3, [r2, #4]
    orr r3, r3, #1
    str r3, [r2, #4]
.Lstandby_dram_resume_core_6:
    ldr r3, [r1, #24]
    and r3, r3, #7
    cmp r3, #3
    bne .Lstandby_dram_resume_core_6
    mov r3, #0
    mov r2, #12288
    movt r3, #1793
    movt r2, #784
    ldr r0, [r3, #592]
    bic r0, r0, #1
    str r0, [r3, #592]
    ldr r3, [r1, #4]
    bic r3, r3, #1
    str r3, [r1, #4]
.Lstandby_dram_resume_core_7:
    ldr r3, [r2, #24]
    and r3, r3, #7
    cmp r3, #1
    bne .Lstandby_dram_resume_core_7
    cmp r4, #1
    beq .Lstandby_dram_resume_core_8
.Lstandby_dram_resume_core_14:
    mov r3, #12288
    movt r3, #784
    ldr r0, [r3, #16]
    ubfx r0, r0, #20, #8
    clz r0, r0
    lsr r0, r0, #5
.Lstandby_dram_resume_core_9:
    ldr r2, [r3, #24]
    tst r2, #1
    beq .Lstandby_dram_resume_core_9
    ldr r1, [r3, #140]
    mov r2, #8192
    movt r2, #784
    cmp r4, #1
    orr r1, r1, #-2147483648
    str r1, [r3, #140]
    ldr r1, [r3, #140]
    bic r1, r1, #-2147483648
    str r1, [r3, #140]
    ldr r1, [r2, #20]
    orr r1, r1, #-2147483648
    str r1, [r2, #20]
    ldr r2, [r3, #268]
    bic r2, r2, #100663296
    str r2, [r3, #268]
    ldreq r2, [r3, #284]
    biceq r2, r2, #192
    orreq r2, r2, #64
    streq r2, [r3, #284]
    pop {r4, r5, r6, r7, r8, pc}
.Lstandby_dram_resume_core_0:
    movw r0, #4081
    movt r0, #65535
    and r2, r2, r0
    str r2, [r3, #836]
    ldr r3, [r3, #964]
    bic r3, r3, #48
    orr r1, r3, r1
    and r1, r1, r0
    b .Lstandby_dram_resume_core_10
.Lstandby_dram_resume_core_2:
    ldr r3, [r6, #264]
    bic r3, r3, #192
    orr r3, r3, #128
    str r3, [r6, #264]
    ldr r2, [r6, #96]
    ldr r3, [r6, #188]
    ubfx r2, r2, #16, #5
    bic r3, r3, #260
    sub r2, r2, #2
    bic r3, r3, #3
    orr r3, r3, #256
    orr r3, r2, r3
    str r3, [r6, #188]
    ldr r3, [r6, #284]
    bic r3, r3, #-2147483648
    orr r3, r3, #134217728
    str r3, [r6, #284]
    ldr r3, [r5, #4]
    sub r3, r3, #6
    cmp r3, #1
    bhi .Lstandby_dram_resume_core_11
.Lstandby_dram_resume_core_3:
    mov r2, #12288
    movt r2, #784
    ldr r3, [r2, #284]
    bic r3, r3, #1996488704
    orr r3, r3, #570425344
    str r3, [r2, #284]
    b .Lstandby_dram_resume_core_11
.Lstandby_dram_resume_core_1:
    ldr r3, [r6, #264]
    bic r3, r3, #192
    str r3, [r6, #264]
    ldr r3, [r6, #188]
    bic r3, r3, #260
    bic r3, r3, #3
    str r3, [r6, #188]
    b .Lstandby_dram_resume_core_12
.Lstandby_dram_resume_core_8:
    ldr r3, [r2, #264]
    mov r1, #12288
    movt r1, #784
    movw r0, #1025
    bic r3, r3, #192
    str r3, [r2, #264]
    ldr r3, [r2, #268]
    bic r3, r3, #100663296
    orr r3, r3, #33554432
    str r3, [r2, #268]
    str r0, [r2]
.Lstandby_dram_resume_core_13:
    ldr r3, [r1, #16]
    tst r3, #1
    beq .Lstandby_dram_resume_core_13
    b .Lstandby_dram_resume_core_14
.Lstandby_dram_resume_core_4:
    mov r1, r2
    mov r0, #82
    mov r3, #83
    str r0, [r2]
    str r3, [r2]
.Lstandby_dram_resume_core_15:
    ldr r3, [r1, #16]
    tst r3, #1
    beq .Lstandby_dram_resume_core_15
    mov r1, #33
    mov r0, #32
    b .Lstandby_dram_resume_core_16
.size standby_dram_resume_core, .-standby_dram_resume_core
.section .text.standby_dram_resume,"ax",%progbits
.balign 4
.global standby_dram_resume
.type standby_dram_resume,%function
standby_dram_resume:
    ldr r3, [r1, #92]
    push {r4, lr}
    mov r4, r1
    ands r2, r3, #65536
    bne .Lstandby_dram_resume_0
    mov r1, #0
    mov r3, #50331648
    movt r1, #1793
    str r2, [r1, #596]
    ldr r2, [r3, #352]
    bic r2, r2, #3
    str r2, [r3, #352]
    ldr r2, [r3, #352]
    bic r2, r2, #264
    str r2, [r3, #352]
    ldr r2, [r3, #352]
    orr r2, r2, #2
    str r2, [r3, #352]
    ldr r2, [r3, #352]
    orr r2, r2, #1
    str r2, [r3, #352]
.Lstandby_dram_resume_3:
    mov r0, r4
    bl standby_dram_resume_core
    cmp r0, #0
    popeq {r4, pc}
    movw r1, #:lower16:standby_dram_state
    mov r3, #12288
    movt r1, #:upper16:standby_dram_state
    ldr r2, [r4, #92]
    ldr ip, [r1, #48]
    movt r3, #784
    ldr r1, [r1, #52]
    ldrh r0, [r4, #22]
    tst r2, #1073741824
    str ip, [r3, #156]
    str r1, [r3, #160]
    ldr r1, [r3, #4]
    ubfx r0, r0, #0, #15
    ldr ip, [r4, #4]
    orrne r1, r1, #1
    biceq r1, r1, #1
    tst r2, #512
    str r1, [r3, #4]
    beq .Lstandby_dram_resume_1
.Lstandby_dram_resume_4:
    mov r1, #12288
    movt r1, #784
    ldr r3, [r1, #256]
    bic r3, r3, #61440
    orr r3, r3, #20480
    str r3, [r1, #256]
.Lstandby_dram_resume_5:
    mov r3, #12288
    tst r2, #256
    movt r3, #784
    ldr r1, [r3, #320]
    orr r1, r1, #-2147483648
    str r1, [r3, #320]
    ldrne r1, [r3, #184]
    orrne r1, r1, #768
    strne r1, [r3, #184]
    mov r3, #12288
    movt r3, #784
    tst r2, #67108864
    ldr r2, [r3, #264]
    bicne r2, r2, #8192
    orreq r2, r2, #8192
    cmp ip, #7
    str r2, [r3, #264]
    beq .Lstandby_dram_resume_2
.Lstandby_dram_resume_6:
    mov r3, #8192
    mvn ip, #0
    movt r3, #784
    mov r1, #255
    movw r2, #65535
    str ip, [r3, #32]
    str r1, [r3, #36]
    str r2, [r3, #40]
    pop {r4, pc}
.Lstandby_dram_resume_0:
    mov r3, #50331648
    mov r1, #0
    ldr r2, [r3, #352]
    orr r2, r2, #256
    str r2, [r3, #352]
    str r1, [r3, #360]
    b .Lstandby_dram_resume_3
.Lstandby_dram_resume_1:
    cmp ip, #6
    beq .Lstandby_dram_resume_4
    mov r3, #12288
    movt r3, #784
    ldr r1, [r3, #256]
    bic r1, r1, #61440
    str r1, [r3, #256]
    b .Lstandby_dram_resume_5
.Lstandby_dram_resume_2:
    mov r2, #12288
    movt r2, #784
    ldr r3, [r2, #124]
    bic r3, r3, #983040
    orr r3, r3, #65536
    str r3, [r2, #124]
    b .Lstandby_dram_resume_6
.size standby_dram_resume, .-standby_dram_resume
.section .text.standby_dram_suspend,"ax",%progbits
.balign 4
.global standby_dram_suspend
.type standby_dram_suspend,%function
standby_dram_suspend:
    mov r2, #8192
    mov r3, #12288
    movt r3, #784
    movt r2, #784
    push {r4, r5, r6, lr}
    movw ip, #:lower16:standby_dram_state
    ldr r4, [r2]
    movt ip, #:upper16:standby_dram_state
    movw r0, #13116
    ldr r6, [r2, #4]
    movt r0, #784
    ldr lr, [r3, #88]
    mov r2, #0
    ldr r5, [r3, #92]
    ldr r1, [r3, #96]
    str r6, [ip, #4]
    ldr r6, [r3, #100]
    str lr, [ip, #8]
    ldr lr, [r3, #104]
    str r5, [ip, #12]
    ldr r5, [r3, #108]
    str r1, [ip, #16]
    ldr r1, [r3, #120]
    str r6, [ip, #20]
    ldr r6, [r3, #128]
    str lr, [ip, #24]
    ldr lr, [r3, #80]
    str r4, [ip]
    movw r4, #13628
    str r5, [ip, #28]
    movt r4, #784
    ldr r5, [r3, #84]
    str r1, [ip, #32]
    ldr r1, [r3, #156]
    ldr r3, [r3, #160]
    str lr, [ip, #40]
    add lr, ip, #60
    str r6, [ip, #36]
    str r5, [ip, #44]
    str r1, [ip, #48]
    str r3, [ip, #52]
    str r2, [ip, #56]
.Lstandby_dram_suspend_1:
    sub r3, r0, #44
    mov r2, lr
.Lstandby_dram_suspend_0:
    ldr r1, [r3], #4
    cmp r0, r3
    str r1, [r2], #4
    bne .Lstandby_dram_suspend_0
    add r0, r0, #128
    add lr, lr, #44
    cmp r0, r4
    bne .Lstandby_dram_suspend_1
    ldr r3, .Lstandby_dram_suspend_data_4
    movw r1, #12580
    movt r1, #784
    sub r1, r1, ip
    add r0, r3, #124
.Lstandby_dram_suspend_2:
    ldr r2, [r1, r3]
    str r2, [r3, #4]!
    cmp r3, r0
    bne .Lstandby_dram_suspend_2
    mov r3, #12288
    mov r1, #8192
    movt r3, #784
    movt r1, #784
    ldr r5, [r3, #828]
    mov lr, #1
    ldr r4, [r3, #956]
    mov r0, #0
    ldr r6, [r3, #1084]
    ldr r2, [r3, #1212]
    str r5, [ip, #380]
    ldr r5, [r1, #1280]
    str r4, [ip, #384]
    ldr r4, [r1, #1284]
    str r6, [ip, #388]
    ldr r6, [r1, #1288]
    str r2, [ip, #392]
    ldr r2, [r1, #1292]
    str r5, [ip, #400]
    ldr r5, [r3, #144]
    str r4, [ip, #404]
    ldr r4, [r3, #148]
    str r2, [ip, #412]
    mov r2, r3
    str r6, [ip, #408]
    str r5, [ip, #416]
    str r4, [ip, #420]
    str lr, [r1, #32]
    str r0, [r1, #36]
    str r0, [r1, #40]
    ldr r1, [r3, #4]
    orr r1, r1, #256
    orr r1, r1, lr
    str r1, [r3, #4]
.Lstandby_dram_suspend_3:
    ldr r3, [r2, #24]
    and r3, r3, #7
    cmp r3, #3
    bne .Lstandby_dram_suspend_3
    ldr r3, [r2, #268]
    movw ip, #4082
    movt ip, #65343
    movw r1, #20490
    movt r1, #64
    mov r4, #0
    bic r3, r3, #16711680
    movt r4, #1793
    str r3, [r2, #268]
    mov r3, #4096
    ldr lr, [r2, #836]
    movt r3, #512
    mov r5, #0
    mov r0, r5
    and lr, lr, ip
    orr lr, lr, r1
    str lr, [r2, #836]
    ldr lr, [r2, #964]
    and ip, ip, lr
    orr r1, ip, r1
    str r1, [r2, #964]
    ldr r1, [r2, #520]
    bic r1, r1, #200
    orr r1, r1, #784
    orr r1, r1, #3
    str r1, [r2, #520]
    ldr r1, [r4, #592]
    orr r1, r1, #3
    str r1, [r4, #592]
    str r5, [r2, #12]
    ldr r2, [r3, #1344]
    bic r2, r2, #1073741824
    str r2, [r3, #1344]
    ldr r2, [r3, #2060]
    bic r2, r2, #1
    str r2, [r3, #2060]
    ldr r2, [r3, #2060]
    bic r2, r2, #65536
    str r2, [r3, #2060]
    ldr r2, [r3, #16]
    bic r2, r2, #-2147483648
    str r2, [r3, #16]
    ldr r2, [r3, #2048]
    bic r2, r2, #1073741824
    str r2, [r3, #2048]
    ldr r2, [r3, #2048]
    bic r2, r2, #-2147483648
    str r2, [r3, #2048]
    ldr r2, [r3, #2048]
    orr r2, r2, #134217728
    str r2, [r3, #2048]
    pop {r4, r5, r6, pc}
.size standby_dram_suspend, .-standby_dram_suspend
.Lstandby_dram_suspend_data_4:
    .word standby_dram_state + 236
.section .text.standby_dram_resume_default,"ax",%progbits
.balign 4
.global standby_dram_resume_default
.type standby_dram_resume_default,%function
standby_dram_resume_default:
    mov r1, r0
    mov r0, #0
    b standby_dram_resume
.size standby_dram_resume_default, .-standby_dram_resume_default
.section .text.standby_dram_suspend_all,"ax",%progbits
.balign 4
.global standby_dram_suspend_all
.type standby_dram_suspend_all,%function
standby_dram_suspend_all:
    push {r4, lr}
    bl standby_dram_master_disable
    pop {r4, lr}
    b standby_dram_suspend
.size standby_dram_suspend_all, .-standby_dram_suspend_all
.section .text.standby_dram_resume_all,"ax",%progbits
.balign 4
.global standby_dram_resume_all
.type standby_dram_resume_all,%function
standby_dram_resume_all:
    push {r4, lr}
    bl standby_dram_resume_default
    bl standby_dram_master_enable
    mov r0, #0
    pop {r4, pc}
.size standby_dram_resume_all, .-standby_dram_resume_all
.section .note.GNU-stack,"",%progbits
