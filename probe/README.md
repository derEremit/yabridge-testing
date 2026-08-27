# Windows coordinate probe

This directory builds a no-op CLAP plugin and a pure-Wine baseline host used
only by the test harness. The plugin connects to the loopback endpoint in
`YABRIDGE_PROBE_ENDPOINT` and authenticates every JSONL event with the random
token in `YABRIDGE_PROBE_TOKEN`.

The CLAP headers are pinned immutably to upstream
[`free-audio/clap`](https://github.com/free-audio/clap), tag `1.1.9`, commit
`094bb76c85366a13cc6c49292226d8608d6ae50c`, under the MIT license.

Build the Windows artifacts with:

```sh
meson setup --cross-file cross/mingw-w64-x86_64.ini build-win .
meson compile -C build-win
```

The outputs are `coordprobe.clap-win` and `coordprobe-selftest.exe`. Build
directories are disposable and must not be committed.
