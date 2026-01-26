# Runner Examples

These examples show how to implement runners that comply with SAAR's JSONL contract.

## Included

- `runtime/runners/generic_uvx_unified.py`: unified CLI/server runner for uvx-based tools.

## Notes

- Runners must emit JSONL events on STDOUT.
- Dotfiles/dotdirs are ignored by default when collecting artifacts unless explicitly included.

See `docs/runner_protocol.md` for the full contract.
