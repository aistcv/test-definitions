# SPDX-License-Identifier: GPL-2.0-only
"""Exercise perf artifact setup without accessing PMUs, apt or the network."""

import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


PERF = r"""#!/bin/sh
printf '%s\n' "$*" >> "$PERF_CALL_LOG"
if [ "$PERF_EXPECT_BUNDLE" = 1 ]; then
    test -f "$PERF_EXEC_PATH/tests/shell/fixture" || exit 45
    case "$LD_LIBRARY_PATH" in
        *perf-binaries.*/usr/lib/aarch64-linux-gnu*) ;;
        *) exit 46 ;;
    esac
fi
case "$1" in
    version)
        if [ "$PERF_LOAD_FAILURE" = 1 ]; then
            echo 'error while loading shared libraries: libdw.so.1' >&2
            exit 127
        fi
        echo 'perf version fixture'
        ;;
    record)
        touch perf-lava-test.data
        echo '3 samples'
        ;;
    report)
        printf ' 50.00%% first\n 50.00%% second\n'
        ;;
    stat) echo '3 cycles' ;;
    test) echo '1: fixture : Ok' ;;
    *) exit 2 ;;
esac
"""


class TestPerfBundle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = Path(__file__).resolve().parents[1]
        self.work = self.root / "automated/linux/perf"
        self.work.mkdir(parents=True)
        for name in ("perf.sh", "parse-output.py"):
            shutil.copy2(self.source / name, self.work / name)
        library = self.root / "automated/lib"
        library.mkdir()
        helper = self.source.parents[1] / "lib/sh-test-lib"
        (library / "sh-test-lib").write_text(
            helper.read_text()
            + '\ninstall_deps() { printf "%s\\n" "$1" >> "$PERF_PACKAGE_LOG"; }\n'
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self._executable(self.bin / "id", "#!/bin/sh\necho 0\n")
        self._executable(
            self.bin / "wget",
            "#!/bin/sh\n"
            '[ "$PERF_DOWNLOAD_FAILURE" != 1 ] || exit 1\n'
            '[ "$1" = -O ] || exit 2\n'
            'cp "$PERF_BUNDLE_FIXTURE" "$2"\n',
        )
        self._executable(
            self.bin / "perf",
            '#!/bin/sh\necho distro-perf >> "$PERF_CALL_LOG"\nexit 42\n',
        )
        self.archive = self.root / "perf.tar.xz"
        self.calls = self.root / "calls"
        self.packages = self.root / "packages"
        self.environment = os.environ.copy()
        self.environment.update(
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            PERF_CALL_LOG=str(self.calls),
            PERF_PACKAGE_LOG=str(self.packages),
            PERF_BUNDLE_FIXTURE=str(self.archive),
            PERF_EXPECT_BUNDLE="1",
            PERF_LOAD_FAILURE="0",
            PERF_DOWNLOAD_FAILURE="0",
        )

    @staticmethod
    def _executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def _archive(self, mode="w:xz", include_binary=True, broken_opencsd=False):
        source = self.root / "bundle"
        (source / "usr/bin").mkdir(parents=True, exist_ok=True)
        if include_binary:
            self._executable(source / "usr/bin/perf", PERF)
        support = source / "usr/libexec/perf-core/tests/shell"
        support.mkdir(parents=True, exist_ok=True)
        (support / "fixture").touch()
        library = source / "usr/lib/aarch64-linux-gnu"
        library.mkdir(parents=True, exist_ok=True)
        for name in ("libopencsd", "libopencsd_c_api"):
            (library / f"{name}.so.1.8.3").write_bytes(b"library fixture")
            link = library / f"{name}.so.1"
            if not link.exists():
                link.symlink_to(f"{name}.so.1.8.3")
        if broken_opencsd:
            (library / "libopencsd.so.1.8.3").unlink()
        with tarfile.open(self.archive, mode) as archive:
            archive.add(source / "usr", arcname="usr")

    def _run(self, url=True, install=False):
        command = ["sh", "perf.sh", "-s", "false" if install else "true"]
        if url:
            command.extend(["-u", "https://example.invalid/perf.tar.xz"])
        result = subprocess.run(
            command,
            cwd=self.work,
            env=self.environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return (self.work / "output/result.txt").read_text()

    def test_installed_bundle_and_support_files(self):
        for mode in ("w:xz", "w:gz"):
            with self.subTest(compression=mode):
                self._archive(mode)
                results = self._run()
                self.assertIn("perf-runtime-check pass", results)
                self.assertIn("perf_record_test pass", results)
                self.assertIn("perf_test pass", results)
                self.assertNotIn(" fail", results)
                self.assertNotIn("distro-perf", self.calls.read_text())
                self.assertFalse(self.packages.exists())

    def test_prebuilt_runtime_dependencies(self):
        self._archive()
        self._run(install=True)
        packages = self.packages.read_text().split()
        self.assertIn("python3", packages)
        self.assertIn("libdw1", packages)
        self.assertIn("libstdc++6", packages)
        self.assertFalse(any(name.startswith("linux-perf") for name in packages))
        self.assertFalse(any(name.startswith("libopencsd") for name in packages))

    def test_download_failure_stops_before_tests(self):
        self.environment["PERF_DOWNLOAD_FAILURE"] = "1"
        results = self._run()
        self.assertIn("perf-bundle-download fail", results)
        self.assertFalse(self.calls.exists())

    def test_corrupt_archive_stops_before_tests(self):
        self.archive.write_bytes(b"broken archive")
        results = self._run()
        self.assertIn("perf-bundle-extract fail", results)
        self.assertFalse(self.calls.exists())

    def test_missing_binary_cannot_fall_back_to_distro_perf(self):
        self._archive(include_binary=False)
        results = self._run()
        self.assertIn("perf-bundle-binary fail", results)
        self.assertFalse(self.calls.exists())

    def test_broken_bundled_library_cannot_fall_back_to_rootfs(self):
        self._archive(broken_opencsd=True)
        results = self._run()
        self.assertIn("perf-bundle-opencsd fail", results)
        self.assertFalse(self.calls.exists())

    def test_loader_failure_stops_before_functional_tests(self):
        self._archive()
        self.environment["PERF_LOAD_FAILURE"] = "1"
        results = self._run()
        self.assertIn("perf-runtime-check fail", results)
        self.assertNotIn("perf_test pass", results)
        self.assertEqual(self.calls.read_text(), "version --build-options\n")

    def test_existing_distro_perf_mode(self):
        self._executable(self.bin / "perf", PERF)
        self.environment["PERF_EXPECT_BUNDLE"] = "0"
        results = self._run(url=False, install=True)
        self.assertIn("python3", self.packages.read_text().split())
        self.assertIn("linux-perf-", self.packages.read_text())
        self.assertIn("perf-runtime-check pass", results)
        self.assertIn("perf_test pass", results)


if __name__ == "__main__":
    unittest.main()
