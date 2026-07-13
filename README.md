# backbone-ai / bootstrap

Public, pre-clone bootstrap for provisioning a **macOS dev machine** for backbone.

A bare Mac has no git, no GitHub auth, and no checkout, so it can't reach the
provisioner that lives *inside* the (private) `backbone` repo. This one command gets
there — install Nix, authenticate GitHub once (device/web flow), clone `backbone`,
then hand off to its guided `provision_macos.py`:

```sh
curl -fsSL https://raw.githubusercontent.com/backbone-ai/bootstrap/main/flash.sh | bash
```

- Flow-through args: `… | bash -s -- --unattended`
- Read-only detection report: `… | bash -s -- --status`

It is **detection-first and idempotent** — it reuses any Nix / `gh` session / checkout
already on the machine and only installs what's missing. It carries **no secrets**
(device-flow auth only; nothing is written to disk here — the provisioner moves auth to
the 1Password SSH agent afterwards).

## Provenance

This repo is **public solely so the `curl` works before you have the private repo.**
`flash.sh` is a mirror — the source of truth is `provisioning/macos/flash.sh` in the
private `backbone` repo, where it is reviewed and versioned alongside the paths it
depends on. **Do not edit `flash.sh` here directly**; change it in `backbone` and it is
mirrored back.
