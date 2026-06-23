# References
See the following folders for the reference of what we use first instead of searching the web

Mostly at `../references/<hosting>/<user>/<repo>`

For example
- zig 0.16 std `../references/codeberg/ziglang/zig/lib/std`
- python tomlkit `../references/github.com/python-poetry/tomlkit`
- toml test `../references/github.com/toml-lang/toml-test`
- parser combinator library `../kbwinnow`
- diagnostic library `../kbdiagnostic`
- reference parser for kdl documents using kbwinnow `../kbkdl`

## Mise
This project uses mise see `mise.toml`

It is a
+ task runner
  +  for most of the tasks [docs - toml tasks](https://mise.jdx.dev/tasks/toml-tasks.html)
  +  if the task needs cli arguments or options [docs - tasks arguments](https://mise.jdx.dev/tasks/task-arguments.html)
  +  for tasks longer than 30 lines or so [docs - file tasks](https://mise.jdx.dev/tasks/file-tasks.html)
+ manage devtools [docs - dev-tools](https://mise.jdx.dev/dev-tools/)
+ environment variables [docs - environments](https://mise.jdx.dev/environments/)
+ shell aliases [docs - shell aliases](https://mise.jdx.dev/shell-aliases.html)
+ shell hooks [docs - shell hooks](https://mise.jdx.dev/hooks.html#watch-files-hook)

```sh
# set environment variables
mise set ENV_NAME=value
#  list available tasks
mise task ls
# get information about a task
mise task info <TASK>
# see how to create a tasks
mise task create -h
# run a task
mise run <TASK>
```


