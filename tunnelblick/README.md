# tunnelblick

Tunnelblick client config for the home VPN: OpenVPN on ROMANO (Synology
VPN Server), split tunnel, with `.local` names resolved by ROMANO's DNS
Server. Background: [SSH Anywhere](https://projectinsomnia.com/blog/ssh-anywhere-home-lab-vpn/).

## What is tracked

Only files without secrets. `.gitignore` is a whitelist.

- `romano/connected.sh`: writes `/etc/resolver/local` on connect.
- `romano/disconnected.sh`: removes it on disconnect.
- `romano/build-tblk.sh`: builds `VPNConfig.tblk` from the pieces.
- `romano/VPNConfig.ovpn.example`: the DSM export, with secrets and host
  removed.

The real `VPNConfig.ovpn` stays untracked in
`~/.config/tunnelblick/romano/`. It holds the TLS auth key, the CA, the
hostname, and the port.

## Set up or rebuild

1. In DSM (QuickConnect works off-network): VPN Server > OpenVPN >
   Export configuration.
2. Save the `.ovpn` as `~/.config/tunnelblick/romano/VPNConfig.ovpn`.
   Set its `remote` line to the real hostname and port.
3. Run `~/.config/tunnelblick/romano/build-tblk.sh`.
4. Run `open ~/.config/tunnelblick/romano/VPNConfig.tblk` and choose
   **Replace** if asked.
5. In Tunnelblick, set **Set DNS/WINS** to **Do not set nameserver**.

## Known failures

- **Reconnect loop, `self-signed certificate in certificate chain`.** DSM's
  CA lasts one year and was regenerated. Re-export and replace the `<ca>`
  block. `build-tblk.sh` refuses an expired CA and warns 30 days ahead.
- **`AUTH_FAILED`.** Use the DSM username and password only. Do not type
  the MFA code into Tunnelblick's auth-code prompt.
- **Public names stop resolving.** Tunnelblick is setting ROMANO as the
  only nameserver. ROMANO answers `.local` only. Use "Do not set nameserver".
- **Ping works, SSH times out.** The `local` zone's A records on ROMANO are
  static and went stale. Find the real address from ROMANO with
  `avahi-browse -tpr _ssh._tcp` and update the zone.
- **"DNS server 8.8.8.8 is being used" warning.** A false alarm from other
  `/etc/resolver/*` files.
