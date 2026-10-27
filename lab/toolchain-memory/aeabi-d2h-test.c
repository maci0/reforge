/* Check __aeabi_d2h (aeabi-d2h.c) against known IEEE half encodings.
 * Built and run under qemu-arm by build-oz.sh before any clang package build. */
#include <stdio.h>
#include <string.h>

static unsigned short half_bits(double d)
{
	volatile double v = d; /* keep the conversion at run time */
	_Float16 h = (_Float16)v;
	unsigned short b;
	memcpy(&b, &h, sizeof b);
	return b;
}

int main(void)
{
	static const struct { double in; unsigned short want; } c[] = {
		{ 1.0, 0x3c00 }, { -2.0, 0xc000 }, { 65504.0, 0x7bff },
		{ 65520.0, 0x7c00 },             /* rounds up to +inf */
		{ 1.0 + 1.0 / 2048, 0x3c00 },    /* tie, rounds to even */
		{ 1.0 + 3.0 / 2048, 0x3c02 },    /* tie, rounds to even */
		{ 5.960464477539063e-08, 0x0001 }, /* smallest subnormal */
		{ 0.0, 0x0000 }, { -0.0, 0x8000 }, { 1e300, 0x7c00 },
	};
	int bad = 0;
	for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
		unsigned short got = half_bits(c[i].in);
		if (got != c[i].want) {
			printf("d2h(%g) = %04x, want %04x\n", c[i].in, got, c[i].want);
			bad = 1;
		}
	}
	if (bad)
		return 1;
	puts("aeabi-d2h ok");
	return 0;
}
