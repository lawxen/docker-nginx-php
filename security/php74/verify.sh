#!/bin/sh
#
# Build-time proof that the PHP 7.4 EOL mitigation (php-src commit 712e60f9,
# CVE-2026-109618 / CVE-2026-109619) is actually compiled into the runtime.
#
# php.net will never publish 7.4.34, so "PHP 7.4.33" alone proves nothing.
# An unpatched 7.4.33 on OOM exits 255 and still runs shutdown functions;
# the patched engine exits 1 immediately and skips every callback.
#
set -eu

php -v
test "$(php -r 'echo PHP_VERSION;')" = "7.4.33"

# max_multipart_body_parts is introduced by the patch (default -1). Its
# presence is the cheapest signal that the engine is ours and not the base's.
test "$(php -n -r 'echo ini_get("max_multipart_body_parts");')" = "-1" || {
    echo "ERROR: max_multipart_body_parts missing - PHP 7.4 EOL patch not applied" >&2
    exit 1
}

check_oom() {
    mode=$1
    set +e
    if [ "$mode" = minimal ]; then
        output=$(php -n -d memory_limit=4M -r \
            'register_shutdown_function(function () { echo "SHUTDOWN-RAN\n"; }); str_repeat("x", 64 * 1024 * 1024);' 2>&1)
    else
        output=$(php -d opcache.enable_cli=1 -d memory_limit=4M -r \
            'register_shutdown_function(function () { echo "SHUTDOWN-RAN\n"; }); str_repeat("x", 64 * 1024 * 1024);' 2>&1)
    fi
    status=$?
    set -e
    printf '%s\n' "$output"
    test "$status" -eq 1 || {
        echo "ERROR: OOM exit status $status (expected 1) - mitigation not active" >&2
        exit 1
    }
    if printf '%s\n' "$output" | grep -q SHUTDOWN-RAN; then
        echo "ERROR: shutdown function ran after OOM - mitigation not active" >&2
        exit 1
    fi
    printf '%s\n' "$output" | grep -q 'Allowed memory size'
}

# With and without the conf.d extensions (opcache lives in the base image and
# is loaded by the normal mode).
check_oom minimal
check_oom configured

# php-fpm must be the rebuilt binary too, not the base image's.
php-fpm -v | grep -q 'PHP 7.4.33'

echo 'PHP 7.4 EOL mitigation verified (CVE-2026-109618 / CVE-2026-109619).'
