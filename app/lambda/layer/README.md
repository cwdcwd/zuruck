# restic Lambda layer

This directory becomes a Lambda layer (`lib/recovery-ui-stack.ts`) that puts the
restic binary at `/opt/bin/restic` for the recovery API Lambda.

The binary itself (`bin/restic`, linux/arm64) is **not committed** — it's fetched
and SHA256-pinned by [`../fetch-restic.sh`](../fetch-restic.sh):

```sh
app/lambda/fetch-restic.sh 0.19.0 <sha256-from-github-releases>
```

`cdk synth` works without the binary (this README keeps the asset dir present);
`cdk deploy -c deployRecoveryUi=true` requires it, so run the fetch script first.
