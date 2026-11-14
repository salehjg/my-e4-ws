// Tiny user-space cycle/instruction counter via perf_event_open (shared by the x60-lab tools).
#pragma once
#include <cstdint>
#include <cstring>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

struct Pmu {
   int cyc = -1, ins = -1;
   static int open1(uint64_t config, int group) {
      perf_event_attr a;
      std::memset(&a, 0, sizeof(a));
      a.type = PERF_TYPE_HARDWARE;
      a.size = sizeof(a);
      a.config = config;
      a.disabled = (group == -1);
      a.exclude_kernel = 1;
      a.exclude_hv = 1;
      int fd = (int) syscall(SYS_perf_event_open, &a, 0, -1, group, 0);
      if (fd < 0) { a.exclude_kernel = 0; a.exclude_hv = 0; fd = (int) syscall(SYS_perf_event_open, &a, 0, -1, group, 0); }
      return fd;
   }
   Pmu() { cyc = open1(PERF_COUNT_HW_CPU_CYCLES, -1); ins = cyc >= 0 ? open1(PERF_COUNT_HW_INSTRUCTIONS, cyc) : -1; }
   void start() { if (cyc >= 0) { ioctl(cyc, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP); ioctl(cyc, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP); } }
   void stop() { if (cyc >= 0) ioctl(cyc, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP); }
   static uint64_t rd(int fd) { uint64_t v = 0; if (fd < 0 || read(fd, &v, sizeof(v)) != (ssize_t) sizeof(v)) return 0; return v; }
   uint64_t cycles() const { return rd(cyc); }
   uint64_t insns() const { return rd(ins); }
};
