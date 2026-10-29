/* Test-only wrapper: entry calls a recorder instead of touching DRAM/CP15. */
.syntax unified
.section .text.test_wrapper,"ax",%progbits
.balign 4
.global sunxi_standby_wrapper_start, sunxi_standby_wrapper_end
sunxi_standby_wrapper_start:
    .space 240
.arm
    ldr pc, [pc, #-4]
    .word test_sram_entry
    .space 16384 - (. - sunxi_standby_wrapper_start)
sunxi_standby_wrapper_end:
.section .note.GNU-stack,"",%progbits
