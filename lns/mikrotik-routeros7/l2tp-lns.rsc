# MikroTik RouterOS 7: L2TP server as an LNS for data SIM sessions, with
# authentication, addressing and accounting from your own RADIUS server.
#
# NOT verified by execution (no RouterOS instance was available when this was
# written). Read through and adapt before pasting; check against the RouterOS
# documentation for your exact version.
#
# Addresses (documentation/shared ranges, replace with your own):
#   192.0.2.10        this router's address the provider's LACs send L2TP to
#   192.0.2.20        your FreeRADIUS server
#   198.51.100.0/28   the provider's LACs
#   100.64.0.1        LNS-side address of every PPP session
#   100.64.1.0/24     static per-SIM addresses handed out by RADIUS
#   100.64.2.0/24     pool "sims-pool"     (named by RADIUS Framed-Pool)
#   100.64.3.0/24     pool "fleet-c-pool"  (named by RADIUS Framed-Pool)

# --- Address pools. RADIUS Framed-Pool selects one of these by name. -------
/ip pool
add name=sims-pool ranges=100.64.2.1-100.64.2.254
add name=fleet-c-pool ranges=100.64.3.1-100.64.3.254

# --- PPP profile used by every L2TP session. --------------------------------
# local-address is the router's end of each PPP link. The remote address
# comes from RADIUS (Framed-IP-Address, or Framed-Pool naming a pool above).
# change-tcp-mss=yes clamps TCP MSS to the session MTU, which matters for
# tunnelled mobile data.
/ppp profile
add name=l2tp-sims local-address=100.64.0.1 change-tcp-mss=yes \
    use-encryption=no use-compression=no only-one=yes

# --- RADIUS. -----------------------------------------------------------------
# The secret must match freeradius/clients.conf. src-address pins the source
# address RADIUS sees, so it matches the clients.conf entry.
/radius
add service=ppp address=192.0.2.20 secret="testing123-CHANGE-ME" \
    src-address=192.0.2.10 authentication-port=1812 accounting-port=1813 \
    timeout=1s comment="SIM RADIUS"

# Accept Disconnect / CoA from RADIUS (UDP 3799).
/radius incoming
set accept=yes port=3799

# Use RADIUS for PPP authentication and accounting. interim-update is the
# default Interim-Update interval; RADIUS can override it per session with
# Acct-Interim-Interval.
/ppp aaa
set use-radius=yes accounting=yes interim-update=5m

# --- L2TP server (the LNS). ---------------------------------------------------
# authentication lists the PPP methods offered to the SIM sessions. Offer
# what your provider and devices use (often PAP and/or CHAP).
# max-mtu / max-mru keep PPP frames small enough to cross the tunnel without
# fragmentation; lower them further if the L2TP rides inside IPsec.
# use-ipsec=no: RouterOS's built-in L2TP/IPsec is for remote-access clients,
# not a LAC. L2TP itself does not encrypt; if the tunnel needs protecting,
# carry the whole L2TP path inside IPsec or over a private interconnect.
/interface l2tp-server server
set enabled=yes default-profile=l2tp-sims authentication=pap,chap \
    use-ipsec=no max-mtu=1400 max-mru=1400 keepalive-timeout=30

# Tunnel authentication secret, if the provider uses one for its LACs.
# Must match the LAC side. Remove if tunnel authentication is not used.
/ppp l2tp-secret
add address=198.51.100.0/28 secret="CHANGE-ME-tunnel-secret" \
    comment="Provider LACs"

# --- Firewall: only the provider's LACs may reach UDP 1701. -----------------
# Rules are added at the end of the input chain. Move them above any earlier
# rule that would accept or drop this traffic first.
/ip firewall address-list
add list=l2tp-lacs address=198.51.100.0/28 comment="Provider LACs"

/ip firewall filter
add chain=input protocol=udp dst-port=1701 src-address-list=l2tp-lacs \
    action=accept comment="L2TP from provider LACs"
add chain=input protocol=udp dst-port=1701 action=drop \
    comment="L2TP from anyone else"
