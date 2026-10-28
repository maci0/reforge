SECTIONS {
 .text : {
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
 }
 .rodata : { *(.rodata*) }
 .data : { *(.data*) }
 .bss : { *(.bss*) *(COMMON) }
 /DISCARD/ : { *(.text.__umodsi3) *(.text.__modsi3) }
}
