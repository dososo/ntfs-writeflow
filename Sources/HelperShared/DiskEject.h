#pragma once
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/types.h>

static inline int writeflow_eject_descriptor(int descriptor) {
    return ioctl(descriptor, DKIOCEJECT, NULL);
}

static inline int writeflow_device_matches(dev_t device, unsigned int expected_major, unsigned int expected_minor) {
    return major(device) == expected_major && minor(device) == expected_minor;
}
