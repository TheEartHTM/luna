#!/bin/bash
# test_all_apis.sh - Comprehensive Luna OS Subsystem & API Test Suite
# All output strictly ASCII English for ComputerCraft compatibility.

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

pass() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    echo "[ PASS ] $1"
}

fail() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    echo "[ FAIL ] $1: $2"
}

echo "=================================================="
echo "          Luna OS API & System Test Suite        "
echo "=================================================="

# --------------------------------------------------
# 1. Virtual File System (VFS) & File Operations
# --------------------------------------------------
echo ":: [1/7] Testing VFS and File Operations..."

TEST_DIR="/tmp/luna_vfs_test"
rm -rf $TEST_DIR
mkdir -p $TEST_DIR/subdir

if [ -d "$TEST_DIR/subdir" ]; then
    pass "mkdir -p recursive directory creation"
else
    fail "mkdir -p" "Directory was not created"
fi

TEST_FILE="$TEST_DIR/test.txt"
echo "luna_os_kernel_verification" > $TEST_FILE

if [ -f "$TEST_FILE" ]; then
    pass "File creation and write redirect (>)"
else
    fail "File write" "File does not exist"
fi

echo "second_line_appended" >> $TEST_FILE
CONTENT=$(cat $TEST_FILE)

if [ -n "$CONTENT" ]; then
    pass "File append (>>) and cat read"
else
    fail "cat read" "File is empty or unreadable"
fi

cp $TEST_FILE $TEST_DIR/copy.txt
if [ -f "$TEST_DIR/copy.txt" ]; then
    pass "cp file copy operation"
else
    fail "cp" "Destination file not created"
fi

mv $TEST_DIR/copy.txt $TEST_DIR/renamed.txt
if [ -f "$TEST_DIR/renamed.txt" ] && [ ! -f "$TEST_DIR/copy.txt" ]; then
    pass "mv file rename operation"
else
    fail "mv" "File was not moved"
fi

rm -f $TEST_DIR/renamed.txt
if [ ! -f "$TEST_DIR/renamed.txt" ]; then
    pass "rm file deletion"
else
    fail "rm" "File still exists"
fi

# --------------------------------------------------
# 2. Permissions & DAC Security Layer
# --------------------------------------------------
echo ":: [2/7] Testing Security & Permissions (DAC)..."

chmod 755 $TEST_FILE
if [ $? -eq 0 ]; then
    pass "chmod 755 permission modification"
else
    fail "chmod 755" "Command returned non-zero exit code"
fi

chmod 600 $TEST_FILE
if [ $? -eq 0 ]; then
    pass "chmod 600 permission modification"
else
    fail "chmod 600" "Command returned non-zero exit code"
fi

# --------------------------------------------------
# 3. Text Processing & Core Utilities
# --------------------------------------------------
echo ":: [3/7] Testing Text Utilities (grep, head, wc)..."

echo "alpha" > $TEST_DIR/list.txt
echo "beta" >> $TEST_DIR/list.txt
echo "gamma" >> $TEST_DIR/list.txt

MATCH=$(grep beta $TEST_DIR/list.txt)
if [ "$MATCH" = "beta" ]; then
    pass "grep pattern matching"
else
    fail "grep" "Expected 'beta', got '$MATCH'"
fi

FIRST_LINE=$(head -n 1 $TEST_DIR/list.txt)
if [ "$FIRST_LINE" = "alpha" ]; then
    pass "head line extraction"
else
    fail "head" "Expected 'alpha', got '$FIRST_LINE'"
fi

# --------------------------------------------------
# 4. Kernel, Syscalls & Process Subsystem
# --------------------------------------------------
echo ":: [4/7] Testing Kernel & Process Management..."

UNAME_OUT=$(uname -s)
if [ -n "$UNAME_OUT" ]; then
    pass "uname kernel query ($UNAME_OUT)"
else
    fail "uname" "uname returned empty string"
fi

PS_OUT=$(ps)
if [ -n "$PS_OUT" ]; then
    pass "ps process table query"
else
    fail "ps" "ps returned empty process list"
fi

UPTIME_OUT=$(uptime)
if [ -n "$UPTIME_OUT" ]; then
    pass "uptime system timer query ($UPTIME_OUT)"
else
    fail "uptime" "uptime query failed"
fi

# --------------------------------------------------
# 5. Network Subsystem
# --------------------------------------------------
echo ":: [5/7] Testing Network Subsystem..."

HOST_OUT=$(hostname)
if [ -n "$HOST_OUT" ]; then
    pass "hostname query ($HOST_OUT)"
else
    fail "hostname" "hostname query returned empty"
fi

if [ -f "/etc/conf/network.conf" ]; then
    pass "Network configuration file /etc/conf/network.conf present"
else
    fail "network.conf" "File not found"
fi

# --------------------------------------------------
# 6. Service Management (systemctl)
# --------------------------------------------------
echo ":: [6/7] Testing Service Management (systemctl)..."

SVC_STATUS=$(systemctl status)
if [ $? -eq 0 ]; then
    pass "systemctl status query"
else
    fail "systemctl status" "Command failed"
fi

# --------------------------------------------------
# 7. Package Manager (dust)
# --------------------------------------------------
echo ":: [7/7] Testing Package Manager (dust)..."

DUST_VER=$(dust -V)
if [ -n "$DUST_VER" ]; then
    pass "dust -V version verification ($DUST_VER)"
else
    fail "dust -V" "dust version query failed"
fi

dust -Qi coreutils > /dev/null
if [ $? -eq 0 ]; then
    pass "dust -Qi coreutils package query"
else
    fail "dust -Qi" "coreutils package metadata query failed"
fi

# --------------------------------------------------
# Cleanup & Summary
# --------------------------------------------------
rm -rf $TEST_DIR

echo "=================================================="
echo "                   TEST RESULTS                   "
echo "=================================================="
echo "Total Tests Run : $TOTAL_TESTS"
echo "Passed Tests    : $PASSED_TESTS"
echo "Failed Tests    : $FAILED_TESTS"

if [ $FAILED_TESTS -eq 0 ]; then
    echo "Overall Status  : [ ALL TESTS PASSED ]"
    exit 0
else
    echo "Overall Status  : [ FAILURES DETECTED ]"
    exit 1
fi
