extern int sunxi_soundcard_init(void);
extern void vUARTCommandConsoleStart(unsigned short stack_size, unsigned int priority);
extern void vTaskStartScheduler(void);
extern int printf(const char *format, ...);

// ADDRESS: DSP0 0x3200bb60
int main(void)
{
    sunxi_soundcard_init();
    vUARTCommandConsoleStart(0x1000, 1);
    vTaskStartScheduler();
    printf("vTaskStartScheduler FAILED!\n");
    return 1;
}
