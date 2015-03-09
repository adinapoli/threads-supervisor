[![Build Status](https://travis-ci.org/adinapoli/threads-supervisor.svg?branch=master)](https://travis-ci.org/adinapoli/threads-supervisor)

# Threads-Supervisor

This library implement a simple, IO-based, forkIO-friendly library for Erlang-style thread supervision.

# Changelog

* 0.1.3.0
    - Added restart throttling using `RetryPolicy` from the [retry](http://hackage.haskell.org/package/retry) package.

# Example

Start from `Control.concurrent.Supervisor.Tutorial`. Other example can be found inside `examples`.

# Installation

```
cabal install threads-supervisor
```

If you have downloaded the latest master from Github:

```
cabal install
```

# Testing

```
cabal install --enable-tests
cabal test
```

# Contributions
This library scratches my own itches, but please fork away!
Pull requests are encouraged to implement the part of the API
you need.
