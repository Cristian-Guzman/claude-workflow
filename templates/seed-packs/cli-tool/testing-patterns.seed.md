### [Testing]: Test the CLI through its entry point
- **Rule**: Invoke the command with arguments and assert on captured stdout, stderr and the exit code — not on internal functions alone.
- **Why**: The argument parser, output formatting and exit codes are the product; unit tests of internals miss all three.
_Source: seed-pack:cli-tool_

### [Testing]: Golden files for help text and formatted output
- **Rule**: Keep expected `--help` and formatted outputs as files; update them deliberately when the output changes.
- **Why**: Output drift is the most common unreviewed change in a CLI.
_Source: seed-pack:cli-tool_

### [Testing]: Filesystem effects happen in a temp dir
- **Rule**: Tests that write run against a temporary directory created per test; never the repo tree or the user's home.
- **Why**: A test that writes into the tree leaves artifacts and makes order matter.
_Source: seed-pack:cli-tool_
