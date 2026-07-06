# svc/ — zurvan-svc, the babysitter (v2 milestone 2)

A declarative service supervisor in a few hundred lines of C, supervised by the
PID 1 exactly like the console shell — **PID 1 does not grow**, and this program
babysits everything else: start in dependency order, restart on death with
backoff (1s doubling to 30s, reset after a stable minute), log what happened.

Deliberately not here: socket activation, cgroups, parallel-start optimization,
and YAML. The system has **one** YAML parser (the provisioner); by the time
zurvan-svc runs, the shell layer has digested everything into flat files:

| File | Written by | Contents |
|------|-----------|----------|
| `/run/svc/enabled` | provisioner, from the YAML `services:` list | one name per line |
| `/etc/svc/NAME.def` | baked into the image (`rootfs/etc/svc/`) | built-ins, e.g. `ssh` |
| `/run/svc/NAME.def` | `zurvan-pkg`, from a manifest `service:` block | installed apps (wins over `/etc/svc`) |
| `/run/svc/NAME.pid` | zurvan-svc | the running pid, for humans and the future face |

A `.def` is three flat keys:

```
exec=/bin/dropbear -F -R    # split on spaces; services must run in FOREGROUND
after=networking            # names to wait for; unmanaged names count as satisfied
restart=yes                 # anything else: one shot, left dead if it dies
```

The enable story for a package is exactly the roadmap sentence: install it,
add its name to `services:` in the YAML, reboot (or start it by hand).
