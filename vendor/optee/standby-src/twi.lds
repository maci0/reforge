SECTIONS {
 .text : {
  *(.text.standby_twi_stop)
  *(.text.standby_twi_init)
  *(.text.standby_twi_set_divider)
  *(.text.standby_twi_restore)
  *(.text.standby_twi_transfer)
 }
 .rodata : { *(.rodata*) }
 .bss : { *(.bss*) *(COMMON) }
}
