//  Tiny probe: print the active vector register width (VLEN) in bits.
//  Used to confirm that `qemu-riscv64 -cpu rv64,v=true,vlen=N` actually overrides VLEN.
//  Build: g++ -march=rv64gcv -O2 vlenb_probe.cpp -o vlenb_probe
#include <riscv_vector.h>
#include <cstdio>

int main()
{
    printf("VLENB_BITS %lu\n", (unsigned long)__riscv_vlenb() * 8ul);
    return 0;
}
