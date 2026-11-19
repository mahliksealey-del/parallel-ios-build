#ifndef P3_ATOMIC_CONTROL_H
#define P3_ATOMIC_CONTROL_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Entirely private to the research DSP package. Native C11 atomics avoid
// reference-counted objects and Swift synchronization in an audio callback.
typedef struct p3_control_bus p3_control_bus;

typedef struct {
    uint32_t kind;
    double left_hz;
    double right_hz;
    double gain;
    uint32_t transition_frames;
} p3_control_command;

enum {
    P3_CONTROL_FREQUENCIES = 1,
    P3_CONTROL_GAIN = 2,
    P3_CONTROL_MODE = 3,
    P3_CONTROL_NOISE = 4,
    P3_CONTROL_CAPACITY = 64
};

// Allocation/deallocation must occur outside the real-time callback.
p3_control_bus *p3_control_create(void);
void p3_control_destroy(p3_control_bus *bus);

// SPSC only: exactly one producer thread and one consumer thread. Does not
// allocate, block, or silently overwrite on full; return false on overflow.
bool p3_control_send(p3_control_bus *bus, p3_control_command command);
bool p3_control_receive(p3_control_bus *bus, p3_control_command *out);

// Gate is independent of queue capacity. bit 0 is route permission; upper
// bits are a generation incremented on every disarm. These calls are atomic
// and safe from route-notification threads and control threads.
uint64_t p3_control_gate_snapshot(const p3_control_bus *bus);
void p3_control_arm(p3_control_bus *bus);
void p3_control_disarm(p3_control_bus *bus);

#ifdef __cplusplus
}
#endif
#endif
