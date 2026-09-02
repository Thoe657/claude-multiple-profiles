# Draft comment for anthropics/claude-code

Paste into an existing thread rather than opening a duplicate. Best fit is
[#57998](https://github.com/anthropics/claude-code/issues/57998) (relocating the
desktop data dir); [#30565](https://github.com/anthropics/claude-code/issues/30565)
and [#36821](https://github.com/anthropics/claude-code/issues/36821) are the
multi-account desktop requests.

Replace the version and package-family values with your own from
`Get-ClaudeProfileStatus` and `Get-AppxPackage *Claude*`.

---

Adding a working data point from Windows, in case it's useful for scoping this.

**CLI is already solved.** `CLAUDE_CONFIG_DIR` relocates the entire `~/.claude`
tree including credentials, so two accounts coexist cleanly today — separate
settings, skills, plugins, sessions and logins. It just isn't documented as the
multi-account mechanism, so people don't find it. Documenting it would close most
of the CLI half of these requests on its own.

**Desktop has no equivalent**, and on MSIX builds the data path is undocumented.
On Claude desktop `1.40609.0` (Store/MSIX install), user data is at:

```
%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude
```

`%APPDATA%\Claude` — the path most third-party guides cite — does not exist on
these builds, which sends people down the wrong path when debugging MCP config.

**The finding that might matter:** a directory junction placed at that location,
pointing *out* of the package container to a normal folder, is followed correctly
by the app. Profile switching works today by swapping that link:

```
%LOCALAPPDATA%\Packages\...\LocalCache\Roaming\Claude   ->  junction
%LOCALAPPDATA%\Claude-profiles\personal                 ->  real data
%LOCALAPPDATA%\Claude-profiles\work                      ->  real data
```

Verified with a full round trip: switch to profile B, sign in, close, switch back
to A, and A's session and history are intact. Keeping profile data outside the
container means a package reset destroys the link rather than the data.

That suggests the app doesn't hard-depend on its data being inside the sandbox,
so a `CLAUDE_DATA_DIR` env var — or a native profile picker — looks feasible
without deeper changes.

**One rough edge worth separating out:** plugin caches are per-profile, but
`enabledPlugins` and `extraKnownMarketplaces` live in `settings.json`. Copying a
`settings.json` between profiles makes the new profile auto-install plugins it has
no cache for, and plugins with hooks then fail in ways that block prompts. Some
signal that plugin enablement is profile-scoped state would help.

Script and full write-up: https://github.com/Thoe657/claude-multiple-profiles
