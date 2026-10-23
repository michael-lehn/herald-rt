/* SPDX-License-Identifier: Apache-2.0 */
/* Stub for the libudev device enumeration that crashes under Rosetta.
 * Vivado only uses it for host-ID / telemetry; returning "no devices" is
 * harmless for batch synthesis and implementation. JTAG access to hardware
 * from inside the container is not supported anyway (program from macOS). */
struct udev_enumerate;
int udev_enumerate_scan_devices(struct udev_enumerate *e) { (void)e; return 0; }
