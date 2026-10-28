SECTIONS {
 .text : {
  *(.text.standby_delay_repeat17)
  *(.text.standby_delay_cycles)
  *(.text.Ldiv0)
  *(.text.__udivsi3)
  *(.text.__divsi3)
  *(.text.__aeabi_uidivmod)
 }
 /DISCARD/ : { *(.text.__umodsi3) *(.text.__modsi3) }
}
