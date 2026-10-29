"""Exercise the retained console C source with test-only UART and register access."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONSOLE = 'core/arch/arm/plat-sun8iw20p1/console.c'


@unittest.skipUnless(shutil.which('cc') and shutil.which('patch'), 'C compiler and patch required')
class ConsoleTests(unittest.TestCase):
    def test_port_selection_diagnostics_and_uart_arguments(self):
        initial = (ROOT / 'vendor/optee/stock-patches/0003-t113-reconstruction.patch').read_text()
        initial = initial.split('+++ b/' + CONSOLE + '\n', 1)[1].split('\ndiff --git ', 1)[0]
        initial = '\n'.join(line[1:] for line in initial.splitlines() if line.startswith('+')) + '\n'
        update = (ROOT / 'vendor/optee/stock-patches/0004-source-header-console-reset.patch').read_text()
        update = update.split('--- a/' + CONSOLE + '\n', 1)[1].split('\n--- ', 1)[0]
        update = '--- a/' + CONSOLE + '\n' + update + '\n'
        with tempfile.TemporaryDirectory() as folder:
            out = Path(folder)
            target = out / CONSOLE
            target.parent.mkdir(parents=True)
            target.write_text(initial)
            subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-d', out],
                           input=update, text=True, check=True, capture_output=True)
            headers = {
                'console.h': 'struct serial_chip { unsigned tag; };\nvoid register_serial_console(struct serial_chip *);\n',
                'drivers/serial8250_uart.h': '#include <stdint.h>\nstruct serial8250_uart_data { struct serial_chip chip; };\nvoid serial8250_uart_init(struct serial8250_uart_data *, uintptr_t, unsigned, unsigned);\n',
                'kernel/interrupt.h': '',
                'kernel/panic.h': 'void __do_panic(const char *, unsigned, const char *, const char *);\n',
                'io.h': '#include <stdint.h>\nuint32_t io_read32(uintptr_t);\n',
                'trace.h': '#define TRACE_ERROR 1\n#define TRACE_DEBUG 3\n#define true 1\nvoid trace_printf(const char *, int, int, int, const char *, ...);\n',
            }
            for name, text in headers.items():
                p = out / 'include' / name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            (out / 'test.c').write_text(r'''
#include <stdint.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <console.h>
#include <drivers/serial8250_uart.h>
extern void console_init(void);
static unsigned mask, reads, logs, inits, registrations;
static int expected_port;
static struct serial8250_uart_data *device;
static void require(int value) { if (!value) exit(90); }
uint32_t io_read32(uintptr_t address) { require(address == 0x0200190c); ++reads; return mask; }
void __do_panic(const char *file, unsigned line, const char *name, const char *message) {
    (void)file; (void)line; (void)name; (void)message; exit(91);
}
void trace_printf(const char *name, int line, int level, int prefix, const char *format, ...) {
    va_list args;
    require(prefix == 1);
    if (line == 270) {
        require(expected_port == -1 && logs == 0 && level == 1);
        require(!strcmp(name,"try_uart_port") && !strcmp(format,"try_uart_port failed\n"));
    } else {
        require(line == 279 && level == 3 && logs == (expected_port == -1 ? 1u : 0u));
        require(!strcmp(name,"console_init") && !strcmp(format,"uart port = %d\n"));
        va_start(args,format); require(va_arg(args,int) == expected_port); va_end(args);
    }
    ++logs;
}
void serial8250_uart_init(struct serial8250_uart_data *data, uintptr_t base, unsigned clock, unsigned baud) {
    require(reads == 1 && logs == (expected_port == -1 ? 2u : 1u) && !inits);
    require(base == (uintptr_t)((expected_port + 0x9400) << 10) && clock == 24000000 && baud == 115200);
    device = data; ++inits;
}
void register_serial_console(struct serial_chip *chip) {
    require(inits == 1 && chip == &device->chip); ++registrations;
}
int main(void) {
    unsigned i, high, bit;
    for (high = 0; high < 2; ++high) for (i = 0; i < 64; ++i) {
        mask = i | (high ? 0xffffffc0 : 0); expected_port = -1;
        for (bit = 0; bit < 6; ++bit) if (i & (1u << bit)) { expected_port = bit; break; }
        reads = logs = inits = registrations = 0;
        console_init();
        require(reads == 1 && inits == 1 && registrations == 1);
        require(logs == (expected_port == -1 ? 2u : 1u));
    }
    return 0;
}
''')
            subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                            '-I' + str(out / 'include'), target, out / 'test.c', '-o', out / 'test'], check=True)
            subprocess.run([out / 'test'], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
