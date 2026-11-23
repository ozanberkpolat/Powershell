# Monthly Zabbix reports: scoring rules

How the bundle written by `Get-ZabbixMonthlyBundle.ps1` is turned into a VM utilisation report and a website uptime
report. The collector only fetches and selects items; every rule below is applied by whatever reads the bundle
(a workbook, a script, a BI model). Keep the rules in one place so the report, the workbook and any CSV cannot disagree,
and so a stored bundle can be re-scored after a rule changes without collecting again.

The values below are the defaults that proved themselves in production reports. Treat them as settings of your report,
not as facts about Zabbix.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| Report time zone | the `-TimeZone` of the bundle | Months, business hours and dates are all in this zone. Use a real zone (DST aware), never a fixed UTC offset: a fixed offset mis-buckets every hour on the far side of a DST change |
| Business hours | 09 to 16, inclusive at both ends | 8 hourly buckets a day, **every day of the week**. Weekends are not excluded on purpose: a weekend batch window is exactly the load a capacity report should see |
| Breach threshold CPU / memory / disk | 90 % | An hour whose peak is at or above it is a breach hour |
| Utilisation bands | >= 85 bad, >= 70 warn, else good | Colour of a utilisation figure |
| Response time warn / critical | 2000 ms / 5000 ms | Web scenario response time bands |
| Availability "below SLA" | 99.0 % | A site under this counts as below SLA |
| Availability bands | >= 99.9 good, >= 99.0 ok, >= 95.0 warn, else bad | Use the SAME 99.0 as "below SLA", otherwise the colour and the count disagree |
| Coverage minimum | 95 % | A site-month whose trend records cover less of the month is not scored (see Availability) |
| Scale-up peak | 90 % | CPU or memory peak this high means the VM is out of room |
| Scale-down peaks | CPU < 40 % and memory < 50 % | Never reaching both means capacity is being paid for and not used |

Note the two band ladders run in opposite directions: for utilisation, under every threshold is good (a quiet server);
for availability, under every threshold is bad. A shared default gets one of them backwards.

## Inputs and their units

- Every `clock` and `value_*` in trend data arrives from Zabbix as a **string**. Cast on the way in.
- `clock` is the start of the hour (epoch seconds, UTC). Convert to the report zone before bucketing by month or hour.
- Item roles come from `items.csv` (`Role` column of `Get-ZabbixUtilizationItems.ps1`):
  `cpu_util` (percent), `mem_available` / `mem_free` (bytes, counts DOWN), `mem_util` (percent), `mem_total` (bytes,
  capacity), `disk_used` (bytes), `disk_free` (bytes, counts DOWN), `disk_pused` (percent), `disk_total` (bytes,
  capacity), `cores`.
- Web metrics come from `web.csv`: `fail` (0 = success, else the failed step number), `resp` (seconds), `speed`.
- **`web.test.in[...,bps]` is BYTES per second.** KB/s is value / 1024. Reading `bps` as bits (/8192) understates every
  download speed 8 times; if an older report did that, say so in the method section when the figure moves.

## Two passes over the same VM rows

| Pass | Hours used | Used for |
|---|---|---|
| Monthly tables | business hours only | average and peak per host, per month |
| Breach detection | all 24 hours | breach hours, breach days, sizing |

They are meant to disagree. A disk that fills at 03:00 is still full. Do not unify them.

## VM utilisation (monthly tables, business hours)

- **CPU**: average of `value_avg`, peak = max of `value_max`.
- **Memory from an available/free bytes item** (preferred): used = total - available. Average used from the mean of
  `value_avg`; **peak used from the minimum of `value_min`** (the counter counts down). Percent = used / total.
- **Memory from a percent item** (only when the host publishes no byte counter): average of `value_avg`, peak = max of
  `value_max`; used MB = total x percent / 100.
- **Disk**, per mount: `used` gives mean `value_avg` / max `value_max`; `free` gives total - mean `value_avg`, with the
  peak from the minimum `value_min`; `pused` is already a percentage.
- Aggregation is the mean of monthly means. Do not re-weight it by hours unless you also restate older reports.

## Breaches (24/7)

- The used percentage of an hour is read from `value_max` where the counter counts UP (cpu, mem_util, disk_used,
  disk_pused) and from `value_min` where it counts DOWN (mem_available, mem_free, disk_free).
- One record per breaching hour, collapsed per host, day, type and mount for display: the first and last breaching hour
  as a span, plus the hour count (the count says whether the span was solid).

## Sizing verdict (the question the report answers)

Judged on **peaks, never averages**: a VM that idles all month and pins at 100 % in the nightly batch is correctly sized,
and the average is exactly what hides that.

1. No CPU or no memory series for the host: **unknown**, "not enough measured data". Never recommend shrinking a machine
   that could not be measured.
2. Any CPU or memory breach hour, or a CPU or memory peak at or above the scale-up peak: **up**, with the reason
   ("12 hour(s) of CPU above 90 %", "memory peaked at 93 %").
3. CPU peak below 40 % and memory peak below 50 %: **down**.
4. Otherwise: **ok** (inside comfortable headroom).

Sort the host table up, down, ok, unknown, then by peak CPU descending. **Disk is not a sizing signal**: a full
filesystem means grow the disk, not resize the VM. Report "disk pressure" (any disk breach hour, or a disk peak at or
above the threshold) as its own recommendation.

## Website availability

- Per site and month: `recorded` = hours with a `fail` trend record, `down` = hours whose `value_avg` > 0 (any failed
  check in the hour), availability = (recorded - down) / recorded.
- Expected hours = the real elapsed hours of the month in the report zone (a DST month has 743 or 745 hours, not 744).
  Compute it from the two UTC instants, not by subtracting two local times.
- **Coverage** = recorded / expected. Below the coverage minimum the month is shown as incomplete and not scored: the
  denominator counts only hours that have a record, so a monitoring outage silently RAISES availability.
- **Never print 100.0 % while something was down.** 8,759 of 8,760 hours rounds to 100.0. When there are down hours and
  the raw rate is at or above 99.95, floor the RAW rate to one decimal (99.9). Flooring an already rounded 100.0 gives
  100.0 back.
- Site figure = mean of its monthly figures; fleet figure = mean of the site figures.

## Incidents

- Consecutive failing hours of one site, closed only by an explicit success record. A data gap does not split an
  incident: nothing observed the site coming back, so claiming it did would invent a recovery.
- The end time is the end of the last failing hour. An incident whose last failing hour is 23:00 ends at 00:00 of the
  next day, never at "24:00".
- Duration in hours = (last failing hour - first failing hour) / 3600 + 1.

## Response time and speed

All steps of a scenario collapse into one scenario-level mean per month (so a multi-step scenario reports the average
step, not the whole journey). Response time in ms = seconds x 1000. Speed in KB/s = bytes per second / 1024.

## Bugs not to reintroduce

- A label suffix on the host name in one table only (the host then reads differently across tables and in exports).
- "24:00" as an incident end time.
- Business hours parsed from a free-text field without a fallback: an empty field gave NaN and silently filtered out
  every hour, emptying every table. Keep business hours as fixed settings.
