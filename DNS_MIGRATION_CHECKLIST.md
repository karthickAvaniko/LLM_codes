# avaniko.com → Cloudflare DNS migration

Goal: move DNS from GoDaddy (ns49/ns50.domaincontrol.com) to Cloudflare so a
Cloudflare Tunnel can serve `llm.avaniko.com` from the RunPod gateway (7778).

`api.avaniko.com` (20.84.161.202, Azure/IIS) STAYS AS IS — it is a live service.

Captured from live DNS on 2026-09-21 before any change.

## Records to verify in Cloudflare BEFORE switching nameservers

| Type  | Name                          | Value                                              | Proxy |
|-------|-------------------------------|----------------------------------------------------|-------|
| A     | avaniko.com                   | 52.255.172.253                                      | grey* |
| CNAME | www                           | avaniko.com                                         | grey* |
| A     | api                           | 20.84.161.202                                       | GREY  |
| A     | crm                           | 49.206.200.9                                        | GREY  |
| A     | sap                           | 14.195.182.34                                       | GREY  |
| MX    | avaniko.com (pri 0)           | avaniko-com.mail.protection.outlook.com             | n/a   |
| TXT   | avaniko.com                   | v=spf1 include:spf.mailjet.com include:one.zoho.com include:spf.protection.outlook.com include:sendgrid.net -all | n/a |
| TXT   | avaniko.com                   | linkedin-site-verification=381c8c48-bb3b-4c79-bdf4-331a3870e2fb | n/a |
| TXT   | _dmarc                        | v=DMARC1; p=none;                                   | n/a   |
| CNAME | selector1._domainkey          | selector1-avaniko-com._domainkey.avanikotechnology.onmicrosoft.com | GREY |
| CNAME | selector2._domainkey          | selector2-avaniko-com._domainkey.avanikotechnology.onmicrosoft.com | GREY |
| CNAME | autodiscover                  | autodiscover.outlook.com                            | GREY  |
| CNAME | lyncdiscover                  | webdir.online.lync.com                              | GREY  |
| CNAME | sip                           | sipdir.online.lync.com                              | GREY  |

*apex/www may be proxied if they are plain websites — confirm they are HTTP-only first.

### CRITICAL: proxy (orange cloud) rules
Cloudflare's proxy passes ONLY HTTP/HTTPS on standard ports. Anything else is
dropped. `sap` and `crm` are on-prem IPs almost certainly using non-HTTP ports
(SAP B1 client, RDP, custom). Proxying them breaks those services instantly.
Leave every record above GREY except the tunnel hostname.

## Order of operations

1. Add avaniko.com to Cloudflare. Let it auto-import, then diff every row
   against the table above. Auto-import commonly misses TXT records and
   multi-value entries.
2. Lower TTLs at GoDaddy to 300s and wait for the old TTL to expire. This makes
   rollback fast if something is wrong.
3. Set proxy status per the table. Default is ORANGE — you must change them.
4. Only then change nameservers at GoDaddy to the two Cloudflare NS assigned.
5. Propagation is usually <1h, up to 48h.

## Verify after the switch (must all still work)

- [ ] Send AND receive email on @avaniko.com
- [ ] Outlook autodiscover on a fresh profile
- [ ] Teams / Skype sign-in
- [ ] https://avaniko.com and https://www.avaniko.com
- [ ] https://api.avaniko.com  (must still hit 20.84.161.202)
- [ ] SAP Business One client via sap.avaniko.com
- [ ] CRM via crm.avaniko.com
- [ ] Check mail headers for DKIM=pass, SPF=pass

## Then (on the pod, I run these)

    cloudflared tunnel login
    cloudflared tunnel create avaniko-gateway
    cloudflared tunnel route dns avaniko-gateway llm.avaniko.com
    # ~/.cloudflared/config.yml → llm.avaniko.com → http://127.0.0.1:7778
    # add cloudflared + watchdog to start_all.sh

## Rollback

Point nameservers back to ns49/ns50.domaincontrol.com at GoDaddy. GoDaddy keeps
the old zone, so this restores the previous state once TTLs expire.
