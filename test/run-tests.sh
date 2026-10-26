#!/usr/bin/env bash
# Runs FreeRADIUS 3.2 with the example configs in ../freeradius and checks the
# replies, using plain `docker` (no compose plugin needed).
#
# Two containers on a private Docker network:
#   radius  192.0.2.20  FreeRADIUS with the example configs mounted read-only
#   lns     192.0.2.10  stands in for the LNS: it only sends RADIUS packets
#                       (radtest/radclient), it does not run L2TP.
# The "lns" container has the address in clients.conf, so the unmodified
# clients.conf is what is under test.
#
# Usage: ./run-tests.sh [--keep]   (--keep leaves the containers running)
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)

IMAGE='freeradius/freeradius-server:3.2.7'
# Only amd64 images are published for 3.2.7; on arm64 hosts Docker emulates.
PLATFORM='linux/amd64'
NET='l2tp-lns-radius-test'
PREFIX='l2tp-lns-radius-test'
SECRET='testing123-CHANGE-ME'       # must match ../freeradius/clients.conf (lns1)
PASS='CHANGE-ME-sim-password'       # must match ../freeradius/mods-config/files/authorize
SERVER='192.0.2.20'

MOUNTS=(
	-v "$REPO/freeradius/clients.conf:/etc/freeradius/clients.conf:ro"
	-v "$REPO/freeradius/proxy.conf:/etc/freeradius/proxy.conf:ro"
	-v "$REPO/freeradius/mods-config/files/authorize:/etc/freeradius/mods-config/files/authorize:ro"
)

cleanup() {
	docker rm -f "$PREFIX-radius" "$PREFIX-lns" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
}
KEEP=${1:-}
cleanup
[[ "$KEEP" == "--keep" ]] || trap cleanup EXIT

pass=0
fail=0
ok() {
	echo "PASS  $1"
	pass=$((pass + 1))
}
bad() {
	echo "FAIL  $1"
	echo "$2" | sed 's/^/      | /'
	fail=$((fail + 1))
}
on_lns() { docker exec -i "$PREFIX-lns" "$@"; }
on_radius() { docker exec -i "$PREFIX-radius" "$@"; }

# expect_auth NAME METHOD USER PASSWORD RESULT [EXPECTED-LINE ...]
# RESULT is Access-Accept or Access-Reject. Each EXPECTED-LINE must appear in
# radtest's output (e.g. "Framed-IP-Address = 100.64.1.11").
expect_auth() {
	local name=$1 method=$2 user=$3 pw=$4 result=$5
	shift 5
	local out line
	out=$(on_lns radtest -t "$method" "$user" "$pw" "$SERVER" 0 "$SECRET" 2>&1 || true)
	if ! grep -q "Received $result" <<<"$out"; then
		bad "$name" "$out"
		return
	fi
	for line in "$@"; do
		if ! grep -qF "$line" <<<"$out"; then
			bad "$name (missing: $line)" "$out"
			return
		fi
	done
	ok "$name"
}

echo "== Config check (freeradius -XC)"
if out=$(docker run --rm --platform "$PLATFORM" "${MOUNTS[@]}" "$IMAGE" -XC 2>&1) &&
	grep -q "Configuration appears to be OK" <<<"$out"; then
	ok "freeradius -XC"
else
	bad "freeradius -XC" "$(tail -30 <<<"$out")"
	exit 1
fi

echo "== Starting FreeRADIUS"
docker network create --subnet 192.0.2.0/24 "$NET" >/dev/null
docker run -d --name "$PREFIX-radius" --platform "$PLATFORM" --network "$NET" --ip 192.0.2.20 \
	"${MOUNTS[@]}" "$IMAGE" -X >/dev/null
docker run -d --name "$PREFIX-lns" --platform "$PLATFORM" --network "$NET" --ip 192.0.2.10 \
	-v "$PWD/packets:/packets:ro" --entrypoint sleep "$IMAGE" infinity >/dev/null
for _ in $(seq 1 60); do
	docker logs "$PREFIX-radius" 2>&1 | grep -q "Ready to process requests" && break
	sleep 1
done
if ! docker logs "$PREFIX-radius" 2>&1 | grep -q "Ready to process requests"; then
	echo "FreeRADIUS did not start"
	docker logs "$PREFIX-radius" 2>&1 | tail -40
	exit 1
fi

echo "== (a) Static address per SIM"
expect_auth "static, ICCID username, PAP" pap 8944000000000000011 "$PASS" Access-Accept \
	"Framed-IP-Address = 100.64.1.11" "Framed-IP-Netmask = 255.255.255.255" "Acct-Interim-Interval = 300"
expect_auth "static, ICCID username, CHAP" chap 8944000000000000011 "$PASS" Access-Accept \
	"Framed-IP-Address = 100.64.1.11"
expect_auth "static, IMSI username" pap 001010000000012 "$PASS" Access-Accept \
	"Framed-IP-Address = 100.64.1.12"
expect_auth "static, MSISDN username" pap 447700900013 "$PASS" Access-Accept \
	"Framed-IP-Address = 100.64.1.13"
expect_auth "static + Framed-Route" pap 8944000000000000014 "$PASS" Access-Accept \
	"Framed-IP-Address = 100.64.1.14" 'Framed-Route = "100.64.200.0/29 0.0.0.0 1"'

echo "== (b) Pooled addressing"
expect_auth "pooled SIM 21" pap 8944000000000000021 "$PASS" Access-Accept 'Framed-Pool = "sims-pool"'
expect_auth "pooled SIM 22, CHAP" chap 8944000000000000022 "$PASS" Access-Accept 'Framed-Pool = "sims-pool"'

echo "== (c) Realm"
expect_auth "realm SIM" pap 8944000000000000031@fleet-c.example.net "$PASS" Access-Accept \
	'Framed-Pool = "fleet-c-pool"' "Session-Timeout = 86400"
expect_auth "realm SIM without its realm is rejected" pap 8944000000000000031 "$PASS" Access-Reject
expect_auth "unknown SIM in the realm is rejected" pap 8944000000000000099@fleet-c.example.net "$PASS" Access-Reject

echo "== Rejections"
expect_auth "unknown SIM" pap 8944000000000000099 "$PASS" Access-Reject 'Reply-Message = "Unknown SIM"'
expect_auth "known SIM, wrong password, PAP" pap 8944000000000000011 wrong-password Access-Reject
expect_auth "known SIM, wrong password, CHAP" chap 8944000000000000011 wrong-password Access-Reject

# A wrong shared secret: the request is rejected or dropped, depending on
# Message-Authenticator handling. Either way there must be no Access-Accept.
out=$(on_lns radtest -t pap 8944000000000000011 "$PASS" "$SERVER" 0 wrong-secret 2>&1 || true)
if grep -q "Received Access-Accept" <<<"$out"; then
	bad "wrong shared secret is not accepted" "$out"
else
	ok "wrong shared secret is not accepted"
fi

echo "== Accounting"
for kind in start interim stop; do
	out=$(on_lns radclient -x -r 1 -t 3 "$SERVER:1813" acct "$SECRET" <"packets/acct-$kind.txt" 2>&1 || true)
	if grep -q "Received Accounting-Response" <<<"$out"; then
		ok "accounting $kind"
	else
		bad "accounting $kind" "$out"
	fi
done
detail=$(on_radius sh -c 'cat /var/log/freeradius/radacct/192.0.2.10/detail-*' 2>&1 || true)
for line in 'Acct-Status-Type = Start' 'Acct-Status-Type = Interim-Update' \
	'Acct-Status-Type = Stop' 'Acct-Output-Octets = 765432'; do
	if grep -qF "$line" <<<"$detail"; then
		ok "detail file has: $line"
	else
		bad "detail file has: $line" "$detail"
	fi
done

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
