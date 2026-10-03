#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

bin_dir="$test_root/bin"
mkdir -p "$bin_dir"
cat > "$bin_dir/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"

case "$*" in
	*"maintenance:mode --on"*|*"maintenance:mode --off"*)
		exit 0
		;;
	*pg_dump*)
		if [ "${FAIL_BACKUP:-0}" = 1 ]; then
			exit 9
		fi
		printf database
		;;
	*"tar -czf -"*)
		printf archive
		;;
	*)
		echo "Unexpected mocked Docker command: $*" >&2
		exit 2
		;;
esac
MOCK_DOCKER
chmod +x "$bin_dir/docker"

export PATH="$bin_dir:$PATH"
export MOCK_DOCKER_LOG="$test_root/docker.log"

success_dir="$test_root/success"
bash "$repo_root/deployment/backup.sh" "$success_dir"
test "$(find "$success_dir" -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 5
shasum --check "$success_dir"/SHA256SUMS-*
grep --quiet 'maintenance:mode --on' "$MOCK_DOCKER_LOG"
grep --quiet 'maintenance:mode --off' "$MOCK_DOCKER_LOG"

: > "$MOCK_DOCKER_LOG"
failure_dir="$test_root/failure"
if FAIL_BACKUP=1 bash "$repo_root/deployment/backup.sh" "$failure_dir"; then
	echo "Expected backup script to fail when pg_dump fails" >&2
	exit 1
fi
if find "$failure_dir" -maxdepth 1 -type f | grep --quiet .; then
	echo "Failed backup left partial artifacts behind" >&2
	exit 1
fi
grep --quiet 'maintenance:mode --on' "$MOCK_DOCKER_LOG"
grep --quiet 'maintenance:mode --off' "$MOCK_DOCKER_LOG"

echo "Backup creation, checksum, failure cleanup, and maintenance recovery checks passed"
