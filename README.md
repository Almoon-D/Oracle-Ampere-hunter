# Oracle Ampere A1 hunter

Repeatedly asks Oracle Cloud for a free-tier `VM.Standard.A1.Flex` instance
until capacity frees up, then stops.

Ampere A1 capacity in the Always Free tier is genuinely scarce: `LaunchInstance`
returns `Out of host capacity.` most of the time, and the only way through is to
keep asking. The point of this repo is to keep asking *well* — rotating through
every placement, backing off when Oracle throttles, and refusing to launch past
the free allowance.

## How it works

| | |
|---|---|
| `.github/workflows/hunt_ampere.yml` | Schedules the hunt, wires up secrets, reports a win |
| `scripts/oci-setup.sh` | Builds `~/.oci/config` and proves the credentials work |
| `scripts/hunt.sh` | The hunt itself |
| `tests/test_hunt.sh` | Offline tests, run against a mock `oci` CLI |

Each run:

1. **Counts what you already have.** Every non-terminated A1 instance in the
   compartment is added up. If all 4 free OCPUs are allocated, the run stops
   without launching anything. This is the guard that keeps a successful hunt
   from quietly rolling on into a billable second instance.
2. **Narrows the sizes to what still fits.** With 2 OCPUs already in use, only
   2 and 1 are attempted — never 4.
3. **Rotates placements.** Every availability domain and every fault domain, in
   turn, largest size first at each one. Capacity frees up per host pool, so a
   miss in one fault domain says nothing about the next.
4. **Fits the request to the tenancy's service limits.** The A1 limits are read
   up front and the ladder is clamped to them, so it never spends attempts
   asking for more than the tenancy is allowed.
5. **Reads the error before reacting.** `Out of host capacity` means rotate and
   retry. `TooManyRequests` means back off exponentially. `NotAuthenticated`
   means stop — no retry fixes a wrong fingerprint. `LimitExceeded` means this
   *size* is too big, so the ladder drops a rung and keeps hunting; it is only
   fatal once even the smallest size is refused.
6. **Exits green when it simply did not win.** No capacity is the normal
   outcome, not a failure; failing the job on it would bury the real errors and
   fill your inbox.

## Setup

Create these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Where it comes from |
|---|---|
| `OCI_API_KEY` | The whole `.pem` private key, `BEGIN`/`END` lines included, no passphrase |
| `OCI_FINGERPRINT` | Shown next to the API key in the OCI console |
| `OCI_USER_OCID` | Profile → User settings (`ocid1.user...`) |
| `OCI_TENANCY_OCID` | Profile → Tenancy (`ocid1.tenancy...`) |
| `OCI_REGION` | Your **home** region, e.g. `eu-madrid-1` — Always Free A1 only exists there |
| `OCI_COMPARTMENT_OCID` | The compartment to launch into (the tenancy OCID works) |
| `OCI_SUBNET_OCID` | A subnet in a VCN that already has an internet gateway and route |
| `SSH_PUBLIC_KEY` | Contents of `id_ed25519.pub` — the **public** key, one line |

`scripts/oci-setup.sh` checks all of this before the first launch attempt: it
repairs CRLF-mangled and base64-wrapped keys, derives the fingerprint from the
key and refuses to continue if it disagrees with `OCI_FINGERPRINT`, and makes a
live API call to confirm the credentials are accepted.

## Running it

The schedule (`*/5 * * * *`) starts hunting on its own. Two things to know
about it:

- GitHub runs scheduled workflows on a shared pool and **delays them, often by
  10–30 minutes**, especially at the top of the hour. `*/5` is a request, not a
  promise.
- **Scheduled workflows are disabled after 60 days without repository
  activity.** If a long hunt goes quiet, check that the schedule is still on.

For a real hunt, dispatch a long run instead: Actions → *Hunt Oracle Ampere A1*
→ *Run workflow* → set `duration_minutes` to `350`. One ~5¾-hour run covers far
more of the day than 70 five-minute ones, and pays the ~40s of setup once.

`duration_minutes` is the whole job budget and doubles as the job timeout; the
hunt itself gets that minus six minutes, so a win still has time to be recorded
rather than being cut off by the runner.

### Cost

On a **public** repository, Actions minutes are free and this costs nothing. On
a **private** one, the 5-minute schedule burns roughly 600–900 minutes a day
against a 2,000-minute monthly allowance — it will run out in about three days.
Make the repo public, or hunt with dispatched long runs only.

## Tuning

Set these as `env:` on the *Hunt* step:

| Variable | Default | Meaning |
|---|---|---|
| `OCPU_LADDER` | `4 2 1` | Sizes tried at each placement, largest first |
| `TARGET_OCPUS` | `4` | Free-tier allowance to fill; the run stops at it |
| `GB_PER_OCPU` | `6` | Fixed by the free tier |
| `BOOT_VOLUME_GB` | `50` | Free tier gives 200 GB total block storage |
| `OS_NAME` / `OS_VERSION` | `Canonical Ubuntu` / `24.04` | Image to launch |
| `INTERVAL` | `20` | Base seconds between attempts |
| `JITTER` | `5` | Random 0–4s added, so parallel hunters desynchronise |

`INTERVAL` is the knob to be careful with. Attempts faster than ~15s get you
`TooManyRequests`, and time spent backing off is time not spent hunting.

## Tests

```
bash tests/test_hunt.sh      # 15 cases against tests/mock_oci.sh, no tenancy needed
shellcheck -x scripts/*.sh tests/*.sh
actionlint                   # workflow syntax; plain YAML parsing misses this
```

The mock lets the failure paths that matter — the free-tier guard, service
limit clamping and step-down, the capacity/throttle/auth classifier, placement
rotation, and stdout/stderr separation — be exercised
without waiting on real capacity. CI runs both on every push.

## When you win

The run opens a GitHub issue with the instance OCID and public IP, and writes
the same to the job summary. From then on every later run sees the allowance is
full and stops immediately, so it is safe to leave the schedule on — though
turning it off once you have what you wanted is tidier.
