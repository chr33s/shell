# Shell Integration Code

This is the shell-specific shell-integration code that is
used for the shell-integration feature set that Swiftty
supports.

This fork ships integration for Bash and Zsh only; the upstream
Elvish, Fish and Nushell scripts were removed along with the
shell presets that offered them (docs/specs/shell.md §2.2).

This README is meant as developer documentation and not as
user documentation. For user documentation, see the main
README or [swiftty.org](https://swiftty.org/docs)

## Implementation Details

### Bash

Automatic [Bash](https://www.gnu.org/software/bash/) shell integration works by
starting Bash in POSIX mode and using the `ENV` environment variable to load
our integration script (`bash/swiftty.bash`). This prevents Bash from loading
its normal startup files, which becomes our script's responsibility (along with
disabling POSIX mode).

Bash shell integration can also be sourced manually from `bash/swiftty.bash`.
This also works for older versions of Bash.

```bash
# Swiftty shell integration for Bash. This must be at the top of your bashrc!
if [ -n "${SWIFTTY_RESOURCES_DIR}" ]; then
    builtin source "${SWIFTTY_RESOURCES_DIR}/shell-integration/bash/swiftty.bash"
fi
```

> [!NOTE]
>
> The version of Bash distributed with macOS (`/bin/bash`) does not support
> automatic shell integration. You'll need to manually source the shell
> integration script (as shown above). You can also install a standard
> version of Bash from Homebrew or elsewhere and set it as your shell.

### Zsh

Automatic [Zsh](https://www.zsh.org/) integration works by temporarily setting
`ZDOTDIR` to our `zsh` directory. An existing `ZDOTDIR` environment variable
value will be retained and restored after our shell integration scripts are
run.

However, if `ZDOTDIR` is set in a system-wide file like `/etc/zshenv`, it will
override Swiftty's `ZDOTDIR` value, preventing the shell integration from being
loaded. In this case, the shell integration needs to be loaded manually.

To load the Zsh shell integration manually:

```zsh
if [[ -n $SWIFTTY_RESOURCES_DIR ]]; then
  source "$SWIFTTY_RESOURCES_DIR"/shell-integration/zsh/swiftty-integration
fi
```

Shell integration requires Zsh 5.1+.
