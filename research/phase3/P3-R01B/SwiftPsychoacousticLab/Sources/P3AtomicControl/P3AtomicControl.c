#include "P3AtomicControl.h"
#include <stdatomic.h>
#include <stdlib.h>

struct p3_control_bus {
    _Atomic uint32_t write_position;
    _Atomic uint32_t read_position;
    _Atomic uint64_t gate;
    p3_control_command commands[P3_CONTROL_CAPACITY];
};

p3_control_bus *p3_control_create(void) {
    p3_control_bus *bus = calloc(1, sizeof(*bus));
    if (!bus) return NULL;
    atomic_init(&bus->write_position, 0);
    atomic_init(&bus->read_position, 0);
    atomic_init(&bus->gate, 0); // safe by default: no active stereo permission
    return bus;
}

void p3_control_destroy(p3_control_bus *bus) { free(bus); }

bool p3_control_send(p3_control_bus *bus, p3_control_command command) {
    if (!bus) return false;
    uint32_t write = atomic_load_explicit(&bus->write_position, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&bus->read_position, memory_order_acquire);
    if ((uint32_t)(write - read) >= P3_CONTROL_CAPACITY) return false;
    bus->commands[write % P3_CONTROL_CAPACITY] = command;
    atomic_store_explicit(&bus->write_position, write + 1, memory_order_release);
    return true;
}

bool p3_control_receive(p3_control_bus *bus, p3_control_command *out) {
    if (!bus || !out) return false;
    uint32_t read = atomic_load_explicit(&bus->read_position, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&bus->write_position, memory_order_acquire);
    if (write == read) return false;
    *out = bus->commands[read % P3_CONTROL_CAPACITY];
    atomic_store_explicit(&bus->read_position, read + 1, memory_order_release);
    return true;
}

uint64_t p3_control_gate_snapshot(const p3_control_bus *bus) {
    return bus ? atomic_load_explicit(&bus->gate, memory_order_acquire) : 0;
}

void p3_control_arm(p3_control_bus *bus) {
    if (!bus) return;
    uint64_t previous = atomic_load_explicit(&bus->gate, memory_order_relaxed);
    for (;;) {
        uint64_t desired = previous | UINT64_C(1);
        if (atomic_compare_exchange_weak_explicit(&bus->gate, &previous, desired,
                memory_order_acq_rel, memory_order_relaxed)) return;
    }
}

void p3_control_disarm(p3_control_bus *bus) {
    if (!bus) return;
    uint64_t previous = atomic_load_explicit(&bus->gate, memory_order_relaxed);
    for (;;) {
        // Generation increments even if already disarmed, to invalidate
        // any in-flight stream. Route change always outranks queued commands.
        uint64_t desired = ((previous & ~UINT64_C(1)) + UINT64_C(2));
        if (atomic_compare_exchange_weak_explicit(&bus->gate, &previous, desired,
                memory_order_acq_rel, memory_order_relaxed)) return;
    }
}
