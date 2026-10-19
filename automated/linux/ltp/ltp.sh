#!/bin/bash

set -x

# shellcheck disable=SC1091
. ../../lib/sh-test-lib
OUTPUT="$(pwd)/output"
RESULT_FILE="${OUTPUT}/result.txt"
# Initialize before argument handling can fail, so LAVA never sends old results.
create_out_dir "${OUTPUT}"
: > "${RESULT_FILE}" || error_msg "Cannot initialize ${RESULT_FILE}"
# Absolute path to this script. /home/user/bin/foo.sh
SCRIPT="$(readlink -f "${0}")"
# Absolute path this script is in. /home/user/bin
SCRIPTPATH="$(dirname "${SCRIPT}")"
echo "Script path is: ${SCRIPTPATH}"
# List of test cases
TST_CMDFILES=""
# List of test cases to be skipped
SKIPFILE_PATH=""
# List of test cases to be skipped in yaml/skipgen format
SKIPFILE_YAML=""
BOARD=""
BRANCH=""
ENVIRONMENT=""
# LTP version
LTP_VERSION="20260130"
TEST_PROGRAM=ltp
# https://github.com/linux-test-project/ltp.git
TEST_GIT_URL=""
TEST_DIR="$(pwd)/${TEST_PROGRAM}"
BUILD_FROM_TAR="false"
SHARD_NUMBER=1
SHARD_INDEX=1

KIRK_PATH="kirk"
KIRK_WORKERS=1
EXTRA_KIRK_ARGS=""

LTP_TMPDIR=/ltp-tmp

LTP_INSTALL_PATH=/opt/ltp

usage() {
    echo "Usage: ${0} [-T mm,math,syscalls]
                      [-S skipfile-lsk-juno]
                      [-b board]
                      [-d temp directory]
                      [-g branch]
                      [-e environment]
                      [-i install path]
                      [-s True|False]
                      [-v LTP_VERSION]
                      [-M Timeout_Multiplier]
                      [-R root_password]
                      [-r path to kirk binary ]
                      [-u git url]
                      [-p build directory]
                      [-t build from tarfile ]
                      [-c sharding bucket to run ]
                      [-n number of shard buckets to create ]
                      [-k extra kirk arguments ]
" 1>&2
    exit 0
}

while getopts "M:T:S:b:d:g:e:i:s:v:R:r:u:p:t:c:n:w:k:" arg; do
   case "$arg" in
     T)
        TST_CMDFILES="${OPTARG}"
        # shellcheck disable=SC2001
        LOG_FILE=$(echo "${OPTARG}"| sed 's,\/,_,')
        ;;
     S)
        case "${OPTARG}" in
          *http*yaml*|*yaml*http*)
            SKIPFILE_YAML="http-skipfile.yaml"
            if ! wget "${OPTARG}" -O "${SKIPFILE_YAML}"; then
              error_msg "Failed to fetch ${OPTARG}"
            fi
            ;;
          *http*)
            SKIPFILE_PATH="http-skipfile"
            if ! wget "${OPTARG}" -O "${SKIPFILE_PATH}"; then
              error_msg "Failed to fetch ${OPTARG}"
            fi
            ;;
          *.yaml)
            SKIPFILE_YAML="${OPTARG}"
            ;;
          *)
            SKIPFILE_PATH="${OPTARG}"
            ;;
        esac
        ;;
     b)
        export BOARD="${OPTARG}"
        ;;
     d)
        export LTP_TMPDIR="${OPTARG}"
        ;;
     g)
        export BRANCH="${OPTARG}"
        ;;
     e)
        export ENVIRONMENT="${OPTARG}"
        ;;
     i)
        export LTP_INSTALL_PATH="${OPTARG}"
        ;;
     # SKIP_INSTALL is true in case of Open Embedded builds
     # SKIP_INSTALL is flase in case of Debian builds
     s) SKIP_INSTALL="${OPTARG}";;
     v) LTP_VERSION="${OPTARG}";;
     # Slow machines need more timeout Default is 5min and multiply * MINUTES
     M) export LTP_TIMEOUT_MUL="${OPTARG}";;
     R) export PASSWD="${OPTARG}";;
     r)
        if [[ "$OPTARG" != '' ]]; then
          KIRK_PATH="$OPTARG"
        fi
        ;;
     u)
        if [[ "$OPTARG" != '' ]]; then
          TEST_GIT_URL="$OPTARG"
          TEST_TARFILE=""
        fi
        ;;
     p)
        if [[ "$OPTARG" != '' ]]; then
          TEST_DIR="$OPTARG"
        fi
        ;;
     t)
        BUILD_FROM_TAR="$OPTARG"
        ;;
     c)
        SHARD_INDEX="$OPTARG"
        ;;
     n)
        SHARD_NUMBER="$OPTARG"
        ;;
     w)
        KIRK_WORKERS="$OPTARG"
        ;;
     k)
	EXTRA_KIRK_ARGS="$OPTARG"
        ;;
     *)
        usage
        error_msg "No flag ${OPTARG}"
        ;;
  esac
done

# A relative skipfile path is resolved against this script
case "${SKIPFILE_PATH}" in
  ""|/*) ;;
  *) SKIPFILE_PATH="${SCRIPTPATH}/${SKIPFILE_PATH}" ;;
esac
case "${SKIPFILE_YAML}" in
  ""|/*) ;;
  *) SKIPFILE_YAML="${SCRIPTPATH}/${SKIPFILE_YAML}" ;;
esac

TEST_TARFILE=https://github.com/linux-test-project/ltp/releases/download/"${LTP_VERSION}"/ltp-full-"${LTP_VERSION}".tar.xz

if [ -n "${SKIPFILE_YAML}" ]; then
    export SKIPFILE_PATH="${SCRIPTPATH}/generated_skipfile"
    generate_skipfile
fi

if [ -n "${SKIPFILE_PATH}" ] && [ ! -f "${SKIPFILE_PATH}" ]; then
    warn_msg "Skipfile ${SKIPFILE_PATH} does not exist, running without it"
    SKIPFILE_PATH=""
fi

parse_ltp_json_results() {
    jq -r '.results| .[]| "\(.test_fqn) \(.test.result)"'  "$1" \
        | sed 's/brok/fail/; s/conf/skip/'  >> "${RESULT_FILE}"
    for test_fqn in $(jq -r '.results| .[]| select(.test.result != "pass") | .test_fqn' "$1"); do
      jq -r '.results | .[] | select(.test_fqn == "'"${test_fqn}"'") | .test.log' "$1" > ${OUTPUT}/${test_fqn}.log
    done
}

# Report wrapper failures separately from individual LTP test failures.
ltp_error() {
    local test_case="$1"
    local message="$2"
    printf '%s\n' "${message}" | tee -a "${OUTPUT}/${test_case}.log" >&2
    report_fail "${test_case}"
    return 1
}

prepare_ltp_shard() {
    local file
    local -a suites

    if ! [[ "${SHARD_NUMBER}" =~ ^[1-9][0-9]*$ ]] \
        || ! [[ "${SHARD_INDEX}" =~ ^[1-9][0-9]*$ ]] \
        || ! [ "${SHARD_INDEX}" -le "${SHARD_NUMBER}" ]; then
        ltp_error ltp-setup "Shard index and count must be positive integers, with index <= count."
        return 1
    fi
    case "${TST_CMDFILES}" in
        ""|,*|*,|*,,*)
            ltp_error ltp-setup "TST_CMDFILES must contain a comma-separated list of suite names."
            return 1
            ;;
    esac
    # Preserve comma/whitespace-separated selections without pathname expansion.
    read -r -d '' -a suites <<< "${TST_CMDFILES//,/ }" || true

    # Keep a fresh manifest with the output, even after an interrupted run.
    : > "${OUTPUT}/alltests" || return 1
    for file in "${suites[@]}"; do
        if ! [[ "${file}" =~ ^[A-Za-z0-9_.-]+$ ]] \
            || [ ! -f "runtest/${file}" ] || [ ! -r "runtest/${file}" ]; then
            ltp_error ltp-setup "Cannot read requested suite runtest/${file}."
            return 1
        fi
        # awk terminates each record even if a source lacks its final newline.
        if ! awk '{ sub(/#.*/, ""); if ($0 ~ /[^[:space:]]/) print }' \
            "runtest/${file}" >> "${OUTPUT}/alltests"; then
            ltp_error ltp-setup "Cannot prepare requested suite ${file}."
            return 1
        fi
    done
    if [ ! -s "${OUTPUT}/alltests" ]; then
        ltp_error ltp-setup "The requested suites contain no tests."
        return 1
    fi
    if ! split -n "l/${SHARD_INDEX}/${SHARD_NUMBER}" "${OUTPUT}/alltests" > "${OUTPUT}/shardfile" \
        || ! cp "${OUTPUT}/shardfile" runtest/shardfile; then
        ltp_error ltp-setup "Could not create the requested shard."
        return 1
    fi
    info_msg "LTP manifest checksums (SHA-256):"
    sha256sum "${OUTPUT}/alltests" "${OUTPUT}/shardfile" || return 1
    info_msg "LTP shard ${SHARD_INDEX}/${SHARD_NUMBER}: $(wc -l < "${OUTPUT}/shardfile") of $(wc -l < "${OUTPUT}/alltests") test entries (before exclusions)."
    echo "============== Tests to run ==============="
    cat "${OUTPUT}/shardfile"
    echo "===========End Tests to run ==============="
}

# Run LTP test suite
run_ltp() {
    if ! cd "${LTP_INSTALL_PATH}"; then
        ltp_error ltp-setup "Cannot enter LTP installation ${LTP_INSTALL_PATH}."
        return 1
    fi
    prepare_ltp_shard || return 1
    # GNU split can produce empty shards when there are few or uneven lines.
    if [ ! -s "${OUTPUT}/shardfile" ]; then
        info_msg "The requested shard contains no tests; Kirk will not be run."
        report_skip ltp-shard
        return 0
    fi
    # shellcheck disable=SC2174
    if ! mkdir -m 777 -p "${LTP_TMPDIR}"; then
        ltp_error ltp-setup "Cannot create LTP temporary directory ${LTP_TMPDIR}."
        return 1
    fi

    local kirk_bin
    if ! kirk_bin="$(command -v "${KIRK_PATH}")"; then
        ltp_error ltp-runner "${KIRK_PATH} is not installed into the file system."
        return 1
    fi
    KIRK_PATH="${kirk_bin}"

    if ! "${KIRK_PATH}" --version; then
        ltp_error ltp-runner "${KIRK_PATH} does not run."
        return 1
    fi
    if [ "${KIRK_WORKERS}" = "max" ]; then
        KIRK_WORKERS=$(grep ^processor /proc/cpuinfo | wc -l)
    fi

    # Kirk refuses to overwrite reports. Never parse an earlier run's report.
    local report="${OUTPUT}/kirk-report.json"
    if ! rm -f "${report}"; then
        ltp_error ltp-report "Cannot remove the previous Kirk report."
        return 1
    fi
    local -a kirk_args=(--run-suite shardfile -d "${LTP_TMPDIR}")
    if [ -n "${SKIPFILE_PATH}" ]; then
        kirk_args+=(--skip-file "${SKIPFILE_PATH}")
    fi
    if [ -n "${KIRK_WORKERS}" ]; then
        kirk_args+=(--workers "${KIRK_WORKERS}")
    fi
    kirk_args+=(--no-colors --json-report "${report}")

    # pipe0_status evaluates shell commands; quote paths while retaining the
    # existing shell-argument interface for EXTRA_KIRK_ARGS.
    local kirk_command kirk_options log_command
    printf -v kirk_command '%q ' "${KIRK_PATH}"
    printf -v kirk_options '%q ' "${kirk_args[@]}"
    printf -v log_command 'tee -- %q' "${OUTPUT}/LTP_${LOG_FILE}.out"
    local runner_status=0
    local status=0
    export LTP_COLORIZE_OUTPUT=0
    pipe0_status "${kirk_command}${EXTRA_KIRK_ARGS} ${kirk_options}" \
        "${log_command}" || runner_status=$?
    if [ "${runner_status}" -ne 0 ]; then
        ltp_error ltp-runner "Kirk exited with status ${runner_status}; checking for partial results."
        status=1
    fi

    # Parse even after a runner error, and retain the original report for
    # diagnosis. Ordinary LTP fail/brok/conf results do not fail the wrapper.
    # Keep per-test parsing unchanged; require a nonempty results array first.
    if ! {
        jq -e '.results | type == "array" and length > 0' "${report}" > /dev/null &&
            parse_ltp_json_results "${report}"
    } 2> "${OUTPUT}/ltp-report.log"; then
        cat "${OUTPUT}/ltp-report.log" >&2
        ltp_error ltp-report "Kirk did not produce a usable report."
        status=1
    fi

    # Cleanup must not hide a runner or report failure.
    rm -rf "${LTP_TMPDIR}" || true
    return "${status}"
}

# Prepare system
prep_system() {
    # Stop systemd-timesyncd if running
    if systemctl is-active systemd-timesyncd 2>/dev/null; then
        info_msg "Stopping systemd-timesyncd"
        systemctl stop systemd-timesyncd
    fi
    # userns07 requires kernel.unprivileged_userns_clone
    if [ -f "/proc/sys/kernel/unprivileged_userns_clone" ]; then
        info_msg "Enabling kernel.unprivileged_userns_clone"
        sysctl -w kernel.unprivileged_userns_clone=1
    else
        info_msg "Kernel has no support of unprivileged_userns_clone"
    fi
}

get_tarfile() {
    local test_tarfile="$1"
    mkdir "${TEST_DIR}"
    pushd "${TEST_DIR}" || exit 1

    wget "${test_tarfile}"
    tar --strip-components=1 -Jxf "$(basename "${test_tarfile}")"
    popd || exit 1
}

build_install_tests() {
    rm -rf "${LTP_INSTALL_PATH}"
    pushd "${TEST_DIR}" || exit 1
    [[ -n "${TEST_GIT_URL}" ]] && make autotools
    ./configure
    make -j"$(proc)" all
    make SKIP_IDCHECK=1 install
    popd || exit 1
}

install() {
    dist=
    dist_name
    # shellcheck disable=SC2154
    case "${dist}" in
      debian|ubuntu)
        [[ -n "${TEST_GIT_URL}" ]] && pkgs="git"
        pkgs="${pkgs} xz-utils flex bison build-essential wget curl net-tools quota genisoimage sudo libaio-dev libattr1-dev libcap-dev expect automake acl autotools-dev autoconf m4 pkgconf python3"
        install_deps "${pkgs}" "${SKIP_INSTALL}"
        ;;
      centos|fedora)
        [[ -n "${TEST_GIT_URL}" ]] && pkgs="git-core"
        pkgs="${pkgs} xz flex bison make automake gcc gcc-c++ kernel-devel wget curl net-tools quota genisoimage sudo libaio-devel libattr-devel libcap-devel m4 expect acl pkgconf python3"
        install_deps "${pkgs}" "${SKIP_INSTALL}"
        ;;
      *)
        warn_msg "Unsupported distribution: package install skipped"
    esac

    # Check if mkisofs or genisoimage installed for isofs test.
    if echo "${TST_CMDFILES}" | grep 'fs'; then
        # link mkisofs to genisoimage on distributions that have replaced mkisofs with genisoimage.
        if ! which mkisofs; then
            if which genisoimage; then
                ln -s "$(which genisoimage)" /usr/bin/mkisofs
            else
                warn_msg "Neither mkisofs nor genisoimage found! Either of them is required by isofs test."
            fi
        fi
    fi
}

# Test run.
! check_root && error_msg "This script must be run as root"

info_msg "About to run ltp test..."
info_msg "Output directory: ${OUTPUT}"

if [ "${SKIP_INSTALL}" = "true" ] || [ "${SKIP_INSTALL}" = "True" ]; then
    info_msg "${TEST_PROGRAM} installation skipped altogether"
else
    install
fi

if [ ! -d "${LTP_INSTALL_PATH}" ]; then
    if [ "${BUILD_FROM_TAR}" = "true" ] || [ "${BUILD_FROM_TAR}" = "True" ]; then
        get_tarfile "${TEST_TARFILE}"
    elif [ -n "${TEST_GIT_URL}" ]; then
        get_test_program "${TEST_GIT_URL}" "${TEST_DIR}" "${LTP_VERSION}" "${TEST_PROGRAM}"
    else
        error_msg "I'm confused, get me out of here, can't fetch tar or test version."
    fi
    build_install_tests
fi
info_msg "Running prep_system"
prep_system
info_msg "Running run_ltp"
run_ltp
