# Zane compiler

This repository contains the Zane language compiler and CLI.

## Setup
To setup this project in a new environment or sandbox, run:

```sh
curl -fsSL https://get.jetify.com/devbox | bash
```

## Building

```sh
devbox shell
just init # initialize submodules, vcpkg dependencies, and meson
just build
```

## Usage

Checkout the `justfile` for all available commands.
