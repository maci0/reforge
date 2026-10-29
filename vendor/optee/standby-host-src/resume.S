/* ARM resume vector and reset-style path; no privileged runtime validation yet.
 * All setup calls now use their recovered source identities. */
.syntax unified
.arch armv7-a
.arch_extension sec
.arm
.section .text.standby_host_resume_entry,"ax",%progbits
.balign 4
.global standby_host_resume_entry
.type standby_host_resume_entry,%function
standby_host_resume_entry:
    b standby_host_resume
.size standby_host_resume_entry, .-standby_host_resume_entry

.section .text.standby_host_resume,"ax",%progbits
.balign 4
.global standby_host_resume
.type standby_host_resume,%function
standby_host_resume:
    bl plat_cpu_reset_early
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #5
    bic r0, r0, #4096
    bic r0, r0, #0x40000000
    bic r0, r0, #2
    orr r0, r0, #0x180000
    mcr p15, 0, r0, c1, c0, 0
    isb sy
    ldr r0, .Lvector_base
    mcr p15, 0, r0, c12, c0, 0
    bl __get_core_pos
    cmp r0, #2
    bge unhandled_cpu
    ldr r1, .Lstack_stride
    ldr r1, [r1]
    mul r1, r0, r1
    ldr r0, .Lstack_top
    ldr r0, [r0]
    add sp, r1, r0
    blx plat_cpu_reset_late
    blx console_init
    mov r0, #0
    bl dcache_op_level1
    blx core_init_mmu_regs
    bl cpu_mmu_enable
    bl cpu_mmu_enable_icache
    bl cpu_mmu_enable_dcache
    blx generic_boot_resume_primary
    mov r0, #0xbe000000
    mov r1, #0
    mov r2, #0
    mov r3, #0
    mov r4, #0
    smc #0
.Lreturned_from_monitor:
    b .Lreturned_from_monitor
.size standby_host_resume, .-standby_host_resume
.Lvector_base:
    .word reset_vect_table
.Lstack_stride:
    .word stack_tmp_stride
.Lstack_top:
    .word stack_tmp_export
.section .note.GNU-stack,"",%progbits
