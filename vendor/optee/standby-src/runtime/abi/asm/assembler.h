.syntax unified
/* shortcut: only this ARM runtime profile is supported, replace when adding other U-Boot units. */
#define CONFIG_IS_ENABLED(option) 0
/* The standalone SRAM image uses ARM-state returns, without interworking. */
.irp condition,,eq,ne,cs,cc,mi,pl,vs,vc,hi,ls,ge,lt,gt,le,hs,lo
.macro ret\condition, reg
mov\condition pc, \reg
.endm
.endr
