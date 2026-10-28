MEMORY { SRAM (rwx) : ORIGIN = 0x20000, LENGTH = 0x8000 }
SECTIONS {
 .parameters : { *(.data.standby_parameters) } > SRAM
 .text : {
  *(.text.standby_entry)
  *(.text.standby_unused_return_0)
  *(.text.standby_unused_return_1)
  *(.text.standby_dram_master_enable)
  *(.text.standby_dram_master_disable)
  *(.text.standby_dram_restore_lanes)
  *(.text.standby_dram_configure_modulation)
  *(.text.standby_dram_program_pll)
  *(.text.standby_dram_restore_common_config)
  *(.text.standby_dram_configure_tpr5_6)
  *(.text.standby_dram_resume_core)
  *(.text.standby_dram_resume)
  *(.text.standby_dram_suspend)
  *(.text.standby_dram_resume_default)
  *(.text.standby_dram_suspend_all)
  *(.text.standby_dram_resume_all)
  *(.text.standby_dram_checksum)

  *(.text.standby_clock_select)
  *(.text.standby_clock_enter)
  *(.text.standby_clock_leave)
  *(.text.standby_delay_us)
  *(.text.standby_delay_ms)
  *(.text.standby_secure_wfi)
  *(.text.standby_pmic_prepare)
  *(.text.standby_pmic_group_control)
  *(.text.standby_pmic_read_id)
  *(.text.standby_pmic_initialize)
  *(.text.standby_find_descriptor)
  *(.text.standby_pmic_read)
  *(.text.standby_pmic_write)
  *(.text.standby_pmic_update)
  *(.text.standby_regulator_set_voltage)
  *(.text.standby_regulator_get_voltage)
  *(.text.standby_regulator_set_enabled)
  *(.text.standby_regulator_get_enabled)
  *(.text.standby_twi_stop)
  *(.text.standby_twi_init)
  *(.text.standby_twi_set_divider)
  *(.text.standby_twi_restore)
  *(.text.standby_twi_transfer)
  *(.text.standby_stack)
  *(.text.standby_delay_repeat17)
  *(.text.standby_delay_cycles)
  *(.text.Ldiv0)
  *(.text.__udivsi3)
  *(.text.__divsi3)
  *(.text.__aeabi_uidivmod)
 } > SRAM
 .data : {
  *(.rodata.standby_clock_registers)
  *(.rodata.standby_pmic_ranges_3)
  *(.rodata.standby_pmic_ranges_2)
  *(.rodata.standby_pmic_ranges_1)
  *twi.o(.rodata)
  *(.rodata.standby_sram_parameters_address)
  *(.data.standby_clock_contexts)
  *(.data.standby_pmic_device)
  *(.rodata.standby_pmic_entries)
 } > SRAM
 .bss (NOLOAD) : {
  __bss_start = .;
  *(.bss.standby_saved_sp)
  *(.bss.standby_dram_state)
  *(.bss.standby_clock_saved_aux)
  *(.bss*) *(COMMON)
  __bss_end = .;
 } > SRAM
 /DISCARD/ : { *(.text.__umodsi3) *(.text.__modsi3) }
}

ASSERT(SIZEOF(.parameters) == 240, "Observed parameter ABI size")
ASSERT(ADDR(.text) == ORIGIN(SRAM) + SIZEOF(.parameters), "Entry follows parameter ABI")
ASSERT(__bss_end < ORIGIN(SRAM) + LENGTH(SRAM) - 16, "BSS must not overlap SRAM stack")
