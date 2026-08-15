# AGENTS.md

## Project purpose

This repository is a personal collection of Home Assistant YAML.

It may contain appliance monitoring, automations, scripts, template entities,
notifications, lighting experiments, and other miscellaneous Home Assistant
configuration.

There is no requirement for the contents to form a coherent application or
shared framework.

Keep the repository lightweight.

## Repository philosophy

Prefer straightforward Home Assistant YAML that is easy to read, inspect,
modify, and copy into a Home Assistant installation.

Do not introduce additional architecture merely because several files happen to
live in the same repository.

In particular, do not add custom integrations, Python applications, Node-RED
flows, reusable frameworks, generators, build systems, dependency management,
CI, CODEOWNERS, release tooling, or other project scaffolding unless explicitly
asked.

A slightly repetitive YAML file is often preferable to an abstraction that
makes a personal Home Assistant configuration harder to understand.

## Working with existing files

Before changing a YAML file, read the whole file.

Treat the file itself — especially its header comments and explanatory comments
— as the source of truth for its intended behaviour.

Preserve existing behaviour unless the requested change requires altering it.

Make the smallest coherent change needed.

Do not perform unrelated refactors, rename entities, change IDs, alter
thresholds, or reorganise files merely for stylistic consistency.

Different YAML files may intentionally use different approaches. Do not
prematurely generalise them into a common framework.

## Home Assistant conventions

Prefer normal Home Assistant entities and supported YAML configuration.

Preserve existing `unique_id` values unless changing entity identity is
explicitly intended.

Use readable, human-friendly names and sentence case where appropriate.

Where a configuration depends on installation-specific entity IDs, prefer a
clearly documented search-and-replace section near the top of the file rather
than clever YAML anchors or pseudo-variable systems.

If a new installation-specific dependency is introduced, add it to that
file's search-and-replace documentation.

## Comments

Comments are valuable in this repository.

Preserve useful existing comments and update them when behaviour changes.

For non-obvious automations or state machines, comments should explain why the
logic exists rather than merely restating the YAML.

Prefer explicit and readable YAML over compact or clever YAML.

## Notifications

Prefer the modern Home Assistant notification entity API:

    notify.send_message

Avoid introducing legacy notification actions in new work.

Where an existing file uses labels, areas, groups, or another abstraction to
select recipients, preserve that approach rather than hard-coding individual
phones or devices.

## Validation

When a Home Assistant environment with the `ha` CLI is available, validate
configuration changes with:

    ha core check

A generic YAML parser may be used to catch syntax errors, but that does not
prove that Home Assistant's schemas, templates, triggers, or actions are valid.

If full Home Assistant validation has not been performed, say so.

Do not deploy configuration to production or restart Home Assistant unless
explicitly asked.

## Git behaviour

Do not create branches, commits, tags, pushes, pull requests, or releases unless
the user explicitly asks for that Git operation.

It is fine to edit files, inspect diffs, run validation, and report working-tree
changes without committing them.
