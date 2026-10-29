/* Secure-world Thumb helpers used around the separately linked ARM SRAM entry.
 * Retain the observed barriers and delay order; hardware execution is unverified. */
.syntax unified
.arch armv7-a
.thumb
.section .text.standby_host_mmu,"ax",%progbits
.balign 2
.global standby_host_delay
.type standby_host_delay,%function
.thumb_func
standby_host_delay:
    sub sp, #8
    movs r3, #0
.Ldelay_store:
    str r3, [sp, #4]
    ldr r3, [sp, #4]
    cmp r3, #99
    bgt .Ldelay_done
    mov r0, r0
    ldr r3, [sp, #4]
    adds r3, #1
    b .Ldelay_store
.Ldelay_done:
    add sp, #8
    bx lr
.size standby_host_delay, .-standby_host_delay

.global standby_host_disable_sctlr_bits
.type standby_host_disable_sctlr_bits,%function
.thumb_func
standby_host_disable_sctlr_bits:
    push {r3, r4, r5, lr}
    mov r4, r0
    bl standby_host_delay
    cmp r0, #4
    ite ne
    movne r4, r0
    moveq r4, #5
    bl standby_host_delay
    mrc p15, 0, r5, c1, c0, 0
    dmb sy
    movs r0, #1
    blx dcache_op_all
    dmb sy
    dsb sy
    isb sy
    bic.w r4, r5, r4
    mcr p15, 0, r4, c1, c0, 0
    isb sy
    dsb sy
    isb sy
    movs r0, #0
    blx dcache_op_all
    dsb sy
    isb sy
    pop {r3, r4, r5, pc}
.size standby_host_disable_sctlr_bits, .-standby_host_disable_sctlr_bits

.global standby_host_mmu_disable
.type standby_host_mmu_disable,%function
.thumb_func
standby_host_mmu_disable:
    movs r2, #0
    mrc p15, 0, r2, c1, c1, 0
    mrc p15, 0, r3, c1, c0, 0
    movs r1, #1
    mcr p15, 0, r1, c1, c1, 0
    isb sy
    dsb sy
    bic r3, r3, #4096
    bic r3, r3, #5
    mcr p15, 0, r3, c1, c0, 0
    isb sy
    isb sy
    dsb sy
    mcr p15, 0, r2, c1, c1, 0
    bx lr
.size standby_host_mmu_disable, .-standby_host_mmu_disable

.global standby_host_mmu_enable
.type standby_host_mmu_enable,%function
.thumb_func
standby_host_mmu_enable:
    push {r3, lr}
    mrc p15, 0, r2, c1, c0, 0
    bl standby_host_delay
    orr r2, r2, #5
    mcr p15, 0, r2, c1, c0, 0
    isb sy
    dsb sy
    isb sy
    pop {r3, pc}
.size standby_host_mmu_enable, .-standby_host_mmu_enable

.global standby_host_dcache_disable
.type standby_host_dcache_disable,%function
.thumb_func
standby_host_dcache_disable:
    movs r0, #4
    b.w standby_host_disable_sctlr_bits
.size standby_host_dcache_disable, .-standby_host_dcache_disable
.section .note.GNU-stack,"",%progbits
