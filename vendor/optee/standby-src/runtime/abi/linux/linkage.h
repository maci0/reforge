#define ENTRY(name) .global name; .type name, %function; .balign 4; name:
#define ENDPROC(name) .size name, .-name
