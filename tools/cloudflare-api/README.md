# cloudflare-api: Cloudflare client for Claude Code

Two modules, two tokens:

- `CloudflareApi.psm1` (phase 1) reads the Cloudflare API. It shows the traffic, the security
  events and the DNS records of a zone. It cannot change anything.
- `CloudflareDnsWrite.psm1` (phase 2) creates, changes and deletes DNS records of one zone. It is
  a separate module, so Claude loads it only when a change must happen.

## Scope of phase 1

- The module sends only GET requests and GraphQL queries. `Invoke-CloudflareApi` accepts only
  the method GET. `Invoke-CloudflareGraphQl` refuses a mutation.
- The token can only read. If the module had a bug, Cloudflare would still refuse a write.

## Credentials

The tokens are in `%USERPROFILE%\.config\cloudflare-claude\credentials.json`. The file has the
key `readToken` (phase 1) and, from phase 2, the key `writeToken`. The file is outside the repo.
Faginux writes the file with `Read-Host`. Claude never asks for a value, and never reads the file
directly. Only the modules read it.

Do not use the token of Caddy on the-grid (`CLOUDFLARE_API_TOKEN`). It has the permission to edit
DNS. This module has its own token.

To create the token, in the Cloudflare dashboard (My Profile, API Tokens, Create Token, custom
token) add these permissions:

| Group | Item | Access | Source |
|---|---|---|---|
| Account | Account Analytics | Read | Documentation of the GraphQL Analytics API |
| Zone | Analytics | Read | Not in the documentation. Needed for the zone datasets, to be checked at the first run |
| Zone | Zone | Read | Needed to find the zone by its name |
| Zone | DNS | Read | Needed to list the DNS records |

Limit the zone resources to one specific zone. Do not set a Client IP Address Filtering: the
home IP address changes.

To rotate the token: create a new token, write the new file, then delete the old token.

## Use

```powershell
Import-Module S:\github\homelab\tools\cloudflare-api\CloudflareApi.psm1

Test-CloudflareToken                                        # the token is active?
Get-CloudflareZone -Name example.com                        # id, status and plan
Get-CloudflareTraffic -ZoneName example.com -Days 1         # totals, peak, median, top countries
Get-CloudflareSecurityEvent -ZoneName example.com -Hours 24 # count by action, source and country
Get-CloudflareDnsRecord -ZoneName example.com               # name, type, content, proxy flag
Get-CloudflareGraphQlType -Name <type name>                 # fields of a GraphQL type
```

A peak that is far above the median in `Get-CloudflareTraffic` can be an attack. The source
`l7ddos` in `Get-CloudflareSecurityEvent` is the HTTP DDoS protection of Cloudflare.

The security query does not ask for URIs or client IP addresses. The output of
`Get-CloudflareDnsRecord` has the content of each record, and some records hold the public IP
address of the home. Do not commit that output.

## Phase 2: change DNS records

Phase 2 needs a second token with only the permission *Zone, DNS, Edit*. Limit its zone
resources to the one zone. Give it another name than the read token (for example
`claude-dns-edit`). Faginux adds it to `credentials.json` as the key `writeToken`, and the key
`readToken` stays. Do not use the token of Caddy on the-grid.

```powershell
Import-Module S:\github\homelab\tools\cloudflare-api\CloudflareDnsWrite.psm1

Test-CloudflareWriteToken                                                   # the token is active?
New-CloudflareDnsRecord -ZoneName example.com -Name test -Type A -Content 192.0.2.10
Set-CloudflareDnsRecord -ZoneName example.com -Name test -Type A -Content 192.0.2.20
Remove-CloudflareDnsRecord -ZoneName example.com -Name test -Type A
```

Each command is a **dry run**. It sends nothing. It shows the record before, the request after,
and a plan id. To apply the change, Claude shows the plan to Faginux, waits for his OK in the chat,
and then repeats the command with `-Apply -PlanId <the id of the dry run>`. A plan id belongs to
one exact request, so a change that nobody showed to Faginux cannot run.

The guards:

- The private function sends POST, PATCH and DELETE only, and only on the path of a DNS record
  of a zone. The token of phase 2 cannot change any other setting.
- The guard blocks the apex, a wildcard and the types other than A, AAAA and CNAME. `-Force` lifts
  the block, and it needs the explicit OK of Faginux. Caddy (`dynamic_dns`) updates the apex and the
  record `immich`: a change there is overwritten at the next update. Caddy (DNS-01) writes the TXT
  records of the certificate.
- A create needs a record that does not exist. An update and a delete need exactly one match.
- Every read of the phase 2 modules (lookup of the zone and of the record) uses the read token.
  Only the write request uses the write token.

Not covered: zone settings (for example the security level), WAF rules, page rules and the
Cloudflare notifications. The token of phase 2 has no permission for them.

Checked on 2026-10-27, with the record `zz-claude-test` (A to `192.0.2.10`, DNS only): the
dry run, the create, the read with the read token and the delete all worked, each with its own
plan id and the OK of Faginux. The authoritative name servers lag behind the API. After the create
and after the delete, they showed the new state about 40 seconds later. Before the check of a
change, wait for that time. The read token sees the new state at once.

To rotate the write token: create a new token, update the key `writeToken`, then delete the old
token.

## What Cloudflare does not see

- A name with DNS only (grey cloud) does not pass through Cloudflare. Its traffic is not in this
  data, and Cloudflare does not protect it. Immich is in this group since 2026-10-27. For Immich,
  read CrowdSec and the Caddy logs on the-grid.
- DDoS protection is automatic on all plans. The documentation says that the Free plan has
  sampled logs only for the security events. The counts can be lower than the real events.
- The alert *HTTP DDoS Attack* exists on all plans. Faginux sets it in the dashboard. The module
  does not set it.

## Checked on 2026-10-27

The first run with the real token (zone on the Free plan) checked these facts:

- The token works with the four permissions of the table. `Test-CloudflareToken` gives `active`.
- The datasets `httpRequests1hGroups` and `httpRequests1dGroups` answer with the fields that the
  module asks for, sub-fields of `responseStatusMap` and `countryMap` included.
- The raw dataset `firewallEventsAdaptive` answers (30 days of history, 10000 rows per query).
- The grouped dataset `firewallEventsAdaptiveGroups` is not available on the Free plan. The
  settings node gives `maxDuration` 0, and a query gives "does not have access to the path". For
  this reason `Get-CloudflareSecurityEvent` counts the raw rows in the module.

## Not checked yet

- The value `l7ddos` for the field `source`. The zone had no DDoS event in the first run, so the
  counts show only `firewallManaged`, the managed rules of Cloudflare.
- If the permission *Zone, Analytics, Read* is necessary. The token has it, so the test cannot
  tell.

If a query fails, use `Get-CloudflareGraphQlType` to read the real field names, then correct the
query in the module.

## Test

`Test-CloudflareApi.ps1` and `Test-CloudflareDnsWrite.ps1` run offline: no network call, no real
token. The first checks the read-only guards, that the token is not in an error text, the paging
of the DNS records, and the queries. The second checks the dry run, the plan id, the guards, the
restriction of the path, and which token each request uses.

```powershell
pwsh -NoProfile -File .\Test-CloudflareApi.ps1
pwsh -NoProfile -File .\Test-CloudflareDnsWrite.ps1
```
