# Draft issue for thedotmack/claude-mem

Search open issues for "version" before filing, in case it is already known.
Replace platform/version details with your own if they differ.

---

**Title:** 13.24.0 worker reports itself as 13.23.1 (version constant not bumped at build)

The version baked into the built `scripts/worker-service.cjs` was not bumped for
the 13.24.0 release, so a worker running from the 13.24.0 plugin cache reports the
previous version.

```
> node scripts/bun-runner.js scripts/worker-service.cjs status
Worker is running
  PID: 5804
  Port: 37778
  Version: 13.23.1
  Uptime: 28s
  Worker path: ...\plugins\cache\thedotmack\claude-mem\13.24.0\scripts\worker-service.cjs
```

`package.json` in that same directory reads `13.24.0`. The worker is freshly
restarted, not stale — restarting reproduces it every time. The literal `13.23.1`
appears four times in the minified bundle (as module-level constants alongside the
PostHog key and the hook-response builder); `package.json` and the cache directory
name are both correct, so this looks like the release build reusing a stale
version constant rather than reading it from `package.json`.

Harmless as far as I can tell — `checkWorkerVersion` compares the running worker's
reported version against the constant in the bundle that is about to spawn it, so
both sides read the same string and agree. It matters only for diagnosis: when a
worker is misbehaving, `status` showing a version other than the directory it is
running from reads exactly like a stale daemon surviving an update, and sends you
looking for the wrong problem. I lost time to it on a two-profile setup before
checking the bundle.

Windows 11, claude-mem 13.24.0, Bun 1.4.0, plugin installed from the github
marketplace source.
