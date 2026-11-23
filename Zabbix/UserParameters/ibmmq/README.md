# IBM MQ monitoring with Zabbix Agent 2 (UserParameter)

Read-only helper that turns `dspmq` and `runmqsc DISPLAY` into JSON for Zabbix low-level discovery: queue managers,
local queue depth (with the dead letter queue flagged) and channel status. No MQ client libraries, no extra plugin.

| File | Purpose |
|---|---|
| `mq_zbx.sh` | The helper. Sub-commands `qmgrs`, `queues <QMGR>`, `channels <QMGR>`. Prints one JSON array |
| `userparameter_ibmmq.conf` | The three agent keys: `ibmmq.qmgrs`, `ibmmq.queues[<QMGR>]`, `ibmmq.channels[<QMGR>]` |

## Install (on the MQ server)

```bash
sudo install -d /etc/zabbix/scripts
sudo install -m 0755 -o root -g root mq_zbx.sh /etc/zabbix/scripts/mq_zbx.sh
sudo install -m 0644 userparameter_ibmmq.conf /etc/zabbix/zabbix_agent2.d/userparameter_ibmmq.conf
sudo usermod -aG mqm zabbix            # runmqsc needs the mqm group; the agent must be restarted to pick it up
# Timeout=10 in zabbix_agent2.conf if runmqsc is slow on this host (default 3 s, maximum 30 s)
sudo systemctl restart zabbix-agent2
sudo -u zabbix /etc/zabbix/scripts/mq_zbx.sh qmgrs      # must print JSON
zabbix_agent2 -t 'ibmmq.queues[QM1]'                    # same through the agent
```

`MQ_INSTALL_PATH` (default `/opt/mqm`) and `MQ_ZBX_INCLUDE_SYSTEM=1` are environment variables of the script; set them in the
`UserParameter` line (`UserParameter=...,MQ_INSTALL_PATH=/opt/mqm91 /etc/zabbix/scripts/mq_zbx.sh ...`) if needed.

## JSON returned

```json
[{"qmgr":"QM1","status":"Running"}]
[{"queue":"APP.IN","curdepth":5,"maxdepth":5000,"dlq":0},{"queue":"SYSTEM.DEAD.LETTER.QUEUE","curdepth":2,"maxdepth":100,"dlq":1}]
[{"channel":"TO.B","type":"SDR","status":"RUNNING"},{"channel":"FROM.C","type":"RCVR","status":"INACTIVE"}]
```

## Zabbix side (build once as a template)

1. Item `ibmmq.qmgrs`, type Zabbix agent (active), 1 min, text. Discovery rule on it with LLD macro path `{#QMGR}` = `$.qmgr`, `{#QMSTATUS}` = `$.status`.
   Trigger prototype: `last(...qmgr.status[{#QMGR}])<>"Running"`.
2. Item prototypes (per `{#QMGR}`): master items `ibmmq.queues[{#QMGR}]` and `ibmmq.channels[{#QMGR}]` (text, 1 min).
3. Two nested discovery rules on those master items (item prototypes can be a discovery rule's master): `{#QUEUE}` = `$.queue`, `{#DLQ}` = `$.dlq`;
   `{#CHANNEL}` = `$.channel`, `{#CHTYPE}` = `$.type`. Dependent item prototypes use JSONPath
   `$[?(@.queue=="{#QUEUE}")].curdepth.first()` and `$[?(@.channel=="{#CHANNEL}")].status.first()`.
4. Triggers: DLQ `curdepth > 0` (High, `{#DLQ}=1` only), queue depth above 80 % of `maxdepth`
   (`last(depth) > 0.8*last(maxdepth)`), channel status not `RUNNING`, `INACTIVE` or `BINDING` for a sender or cluster-sender after N minutes
   (`INACTIVE` is normal for a receiver or a triggered sender; filter on `{#CHTYPE}`).

## Behaviour worth knowing

- **Errors are not hidden.** A stopped queue manager, a missing `mqm` group or a failed `runmqsc` prints the `AMQ` message to stderr and exits 1,
  so the item turns "not supported" and a "not supported" trigger fires. The older variants of this helper discarded stderr and returned `[]`,
  which looks like a healthy, empty broker.
- **`SYSTEM.*` queues are skipped, except the dead letter queue.** The DLQ is normally `SYSTEM.DEAD.LETTER.QUEUE`; the helper reads the queue
  manager's `DEADQ` attribute and flags it with `"dlq":1` whatever it is called.
- **Channels:** `DISPLAY CHSTATUS` only lists channels with a state, so a defined channel that is absent is reported `INACTIVE`. `SVRCONN`
  and `SYSTEM.*` channels are left out. `DISPLAY CHSTATUS(*)` with no active channel exits 10 (`AMQ8420`); that one case is tolerated.
- **Depth fields come from `DISPLAY QLOCAL ... CURDEPTH MAXDEPTH`**, which prints `CURDEPTH` before `MAXDEPTH`; the parser relies on that order.
- Standby queue managers show `STATUS(Running as standby)` in `dspmq`; the value is passed through as is.
- Queue manager names never reach a shell: the agent passes `$1` quoted, and MQ names are limited to letters, digits and `. _ / %`.
