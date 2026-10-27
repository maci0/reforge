/*
 * __aeabi_d2h for clang-built code linked against libgcc.
 *
 * clang lowers double -> _Float16 to the RTABI helper __aeabi_d2h, which
 * libgcc 15 does not provide; it has the same IEEE conversion as
 * __gnu_d2h_ieee (libgcc/config/arm/fp16.c). RTABI helpers use the base
 * AAPCS even on hard-float, so the double arrives in r0:r1, which is where
 * __gnu_d2h_ieee takes its unsigned long long. Hidden so no library exports
 * it. ponytail: one helper, the only one the rootfs is missing
 * (undefined-audit.sh); build compiler-rt builtins for armhf if more appear.
 */
unsigned short __gnu_d2h_ieee(unsigned long long a);

__attribute__((visibility("hidden")))
unsigned short __aeabi_d2h(unsigned long long a)
{
	return __gnu_d2h_ieee(a);
}
