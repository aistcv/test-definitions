# Perf tests

Set `TESTPROG_URL` to test a prebuilt perf archive, such as TuxMake's
`perf.tar.xz`. It must contain `usr/bin/perf` and `usr/libexec/perf-core`.
The runner uses these installed files from a private directory.

Bundled OpenCSD libraries under `usr/lib/<triplet>` are added to the library
search path. Both `libopencsd_c_api.so.1` and `libopencsd.so.1` must be present
with their versioned files. Other runtime packages are installed on Debian or
Ubuntu unless `SKIP_INSTALL=true`; in that case, provide them in the rootfs.

Without `TESTPROG_URL`, the existing distro perf path is used. A startup check
reports missing libraries before any functional tests run.
