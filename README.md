# L2TP LNS + RADIUS examples for data SIMs

Configuration examples for terminating **L2TP data SIM** sessions on your own
LNS, with your own FreeRADIUS server deciding which SIMs may connect and what
address each one gets.

- `freeradius/`: FreeRADIUS 3.x client, users-file and realm examples
  (static address per SIM, pooled addressing, a realm), with accounting.
- `lns/accel-ppp/`: a Linux LNS using accel-ppp, plus nftables rules.
- `lns/mikrotik-routeros7/`: a MikroTik RouterOS 7 L2TP server as the LNS.
- `test/`: a script that runs FreeRADIUS in Docker with these exact files and
  checks the replies.

All addresses are documentation or shared ranges (RFC 5737, RFC 6598), every
SIM identity is fake, and every secret is a `CHANGE-ME` placeholder.

## How it fits together

The SIM provider's mobile core carries each SIM's data session as a PPP session
inside an L2TP tunnel. The provider runs the **LAC** (L2TP Access Concentrator).
You run the **LNS** (L2TP Network Server), which terminates the tunnel and the
PPP sessions, and a **RADIUS** server, which the LNS asks about every session.

```
        provider's side                    |            your side
                                           |
 device+SIM ~~~> mobile core ---> LAC =====|=====> LNS --------> RADIUS
   (radio)                           L2TP tunnel    |  Access-Request  ->
                                    (UDP 1701),     |  <- Access-Accept
                                   one PPP session  |     Framed-IP-Address
                                     per SIM        |     or Framed-Pool, ...
                                           |        |  Accounting
                                           |        |  Start/Interim/Stop ->
                                           |        v
                                           |   your network
```

1. The device attaches and opens a data session. The provider's LAC carries it
   to your LNS as a PPP session inside an L2TP tunnel (L2TPv2, UDP 1701). A
   tunnel can carry many sessions, and tunnels may arrive from more than one LAC.
2. Your LNS sends an **Access-Request** to your RADIUS with the session's
   `User-Name` and password (PAP or CHAP).
3. RADIUS replies **Access-Accept** with the address and policy for that SIM,
   or **Access-Reject** to refuse it. Typical reply attributes:
   - `Framed-IP-Address`: a static address for this SIM.
   - `Framed-Pool`: the name of an address pool on the LNS.
   - `Framed-Route`: a subnet behind the device (e.g. a router with a LAN).
   - `Session-Timeout`, `Acct-Interim-Interval`.
4. The LNS completes IPCP with that address and routes the session's traffic
   into your network.
5. The LNS sends **accounting** Start, Interim-Update and Stop records, with
   `Acct-Input-Octets`/`Acct-Output-Octets` for usage.

Because the static address comes from *your* RADIUS and is tied to the SIM's
identity, a SIM keeps it whichever tunnel or LAC its session arrives through.

L2TP itself does not encrypt. If the path between LAC and LNS needs protecting,
carry the tunnel over a private interconnect or inside IPsec.

## The examples

### FreeRADIUS (`freeradius/`)

Written for FreeRADIUS 3.0/3.2 and tested with 3.2.7. They drop into the stock
configuration; the stock `sites-enabled/default` already runs everything they
need (`suffix`, `files`, `chap`, `pap` in authorize; `detail` in accounting).

| File | Install as | Purpose |
|---|---|---|
| `clients.conf` | `raddb/clients.conf` | The LNS as a RADIUS client. The LAC is never a RADIUS client. |
| `mods-config/files/authorize` | `raddb/mods-config/files/authorize` (the `users` file) | Per-SIM authorisation and addressing. |
| `proxy.conf` | `raddb/proxy.conf` | Declares the example realm as local so `suffix` strips it. |

`raddb` is `/etc/raddb` on most builds and `/etc/freeradius/3.0` on
Debian/Ubuntu packages (`/etc/freeradius` in the official Docker image).

The users file shows:

- **(a) Static address per SIM** with `Framed-IP-Address`, keyed on the
  username. There is one entry each keyed on an ICCID, an IMSI and an MSISDN,
  because what arrives in `User-Name` depends on what is agreed with your SIM
  provider; which identity to key on is the operator's choice. A fourth entry
  adds a `Framed-Route` for a LAN behind the SIM.
- **(b) Pooled addressing** with `Framed-Pool`. RADIUS only names the pool; the
  LNS owns it and picks the address. The pool names (`sims-pool`,
  `fleet-c-pool`) exist in both LNS examples.
- **(c) A realm.** `8944000000000000031@fleet-c.example.net` is split by the
  `suffix` module; a `DEFAULT Realm == ...` entry applies fleet-wide policy and
  falls through to the per-SIM entry. A last `DEFAULT` rejects unknown SIMs.

**Accounting.** The stock `detail` module writes every accounting record to
`radacct/<LNS address>/detail-YYYYMMDD`, which is enough to prove records are
arriving. For usage reporting, enable `sql` in the accounting section and use
the `radacct` schema shipped in `mods-config/sql/main/<dialect>/`. The test
packets in `test/packets/` show what an LNS sends for Start, Interim-Update and
Stop.

**sqlippool (optional, not used here).** Instead of the LNS choosing from its
own pool, FreeRADIUS's `sqlippool` module can allocate an address from a pool
held in SQL and return it as `Framed-IP-Address`. That suits several LNSs
sharing one pool, or wanting a record of which SIM held which address when.
It needs accounting to reach FreeRADIUS so leases are renewed and released, and
its schema and queries live in `mods-config/sql/ippool/<dialect>/`. Follow the
comments in `mods-available/sqlippool` for your version; it is not covered by
the tests in this repository.

### accel-ppp (`lns/accel-ppp/`)

`accel-ppp.conf` runs accel-ppp as an L2TP LNS with RADIUS authentication,
accounting, Disconnect/CoA, and the two named pools that `Framed-Pool` selects.
`nftables.conf` accepts UDP 1701 only from the provider's LACs and clamps TCP
MSS, which accel-ppp does not do itself.

Note `[client-ip-range]`: accel-ppp rejects every incoming L2TP connection
until it lists the addresses tunnels may come from (the LACs).

### MikroTik RouterOS 7 (`lns/mikrotik-routeros7/`)

`l2tp-lns.rsc` sets up the L2TP server, a PPP profile with MSS clamping, the
RADIUS client, PPP AAA with accounting and interim updates, Disconnect/CoA,
the two named pools, a tunnel secret and a firewall filter for UDP 1701.
**This file has not been run on RouterOS**; check it against the documentation
for your version before use.

### Juniper MX

Not included. We would rather leave it out than publish subscriber-management
syntax we have not checked against a current Junos release.

## Testing (`test/`)

```
./test/run-tests.sh
```

Needs Docker (no compose plugin). It runs `freeradius -XC` against the files in
`freeradius/`, starts FreeRADIUS 3.2.7 (`freeradius/freeradius-server:3.2.7`)
on a private Docker network, and from a second container at the LNS address in
`clients.conf` uses `radtest` and `radclient` to check that:

- each static SIM (ICCID, IMSI and MSISDN usernames; PAP and CHAP) gets its
  `Framed-IP-Address`, and the router SIM also gets its `Framed-Route`;
- pooled SIMs get `Framed-Pool = "sims-pool"`;
- the realm SIM gets `Framed-Pool = "fleet-c-pool"` and its `Session-Timeout`,
  while the same identity without the realm is rejected;
- unknown SIMs, wrong passwords and a wrong shared secret are not accepted;
- accounting Start, Interim-Update and Stop get Accounting-Responses and land
  in the `detail` file.

The test covers the RADIUS side only. The LNS configurations are not exercised
end to end by it.

## MTU and MSS

Every packet to and from a SIM carries tunnel headers. Over IPv4 that is about
40 bytes: 20 outer IP, 8 UDP, 8 to 12 L2TP and 2 PPP. If the tunnel rides
inside IPsec, add typically another 50 to 70 bytes depending on the cipher.

If the PPP MTU is left at 1500, full-size packets have to be fragmented
somewhere, or are dropped where fragmentation is blocked. The usual symptom:
pings and small requests work, large downloads or TLS handshakes stall.

- Lower the PPP MRU/MTU on the LNS so a full-size PPP frame still fits through
  the tunnel without fragmentation. 1460 fits a 1500-byte path over plain
  IPv4. These examples use **1400** to leave room for IPsec or other overhead
  on the way; measure your own path and adjust.
- Clamp TCP MSS on traffic through the sessions (`nftables.conf` for accel-ppp;
  `change-tcp-mss=yes` in the RouterOS PPP profile).

## Common pitfalls

- **Shared secret mismatch.** The secret on the LNS must match `clients.conf`
  exactly. FreeRADIUS 3.2 drops such requests and logs
  `Received packet from <LNS> with invalid Message-Authenticator! (Shared secret is incorrect.)`;
  without Message-Authenticator, PAP passwords decrypt to garbage and every SIM
  is rejected for a "wrong password".
- **NAS address.** FreeRADIUS matches the client by the packet's *source IP*,
  not the `NAS-IP-Address` attribute. If the LNS has several addresses, pin
  its RADIUS source address (accel-ppp `bind=` in `[radius]`; RouterOS
  `src-address=`). An unmatched source shows up as
  `Ignoring request ... from unknown client`. Disconnect/CoA in the other
  direction is matched by the LNS against its own settings
  (accel-ppp `nas-ip-address`, `dae-server`, `dae-allowed`).
- **Username format.** Agree with your provider what the LNS will see in
  `User-Name`: ICCID, IMSI, MSISDN, with or without a realm, with or without a
  leading `+` or country code. Run `radiusd -X` (or `freeradius -X`) and look at
  the real Access-Request before writing hundreds of entries. Remember that
  `suffix` strips a recognised realm before the users file is searched.
- **Framed-IP-Address conflicts.** FreeRADIUS does not check that static
  addresses are unique, and a static range must not overlap any pool on the
  LNS. If a SIM reconnects before its old session is torn down, the LNS can
  briefly hold two sessions wanting one address; limit to one session per
  username (accel-ppp `single-session=replace`; RouterOS `only-one=yes`).
- **Pool name not on the LNS.** `Framed-Pool` names a pool that must exist,
  spelt identically, on every LNS the SIM can land on.
- **Accounting interim interval.** Agree it with whoever consumes the records.
  Too long and usage since the last update is lost if the LNS restarts without
  sending Stop; too short and a large fleet floods the accounting server. Set a
  default on the LNS and override per SIM with `Acct-Interim-Interval` if
  needed.
- **Tunnel reachability.** UDP 1701 must reach the LNS from every LAC address
  (and nothing else should). If a tunnel secret is used, it must match on both
  ends.

## About

Maintained by [Netavo](https://netavo.com), which delivers
[L2TP data SIMs](https://netavo.com/services/l2tp-data-sims) on all four UK
networks to customers' own LNS. For background on tunnels, sessions, RADIUS and
MTU, see
[How L2TP data SIMs work](https://netavo.com/insights/l2tp-data-sims-explained).

These are examples, not a supported product: review them against your own
network and software versions before use. Issues and pull requests welcome.

## Licence

MIT. See [LICENSE](LICENSE).
