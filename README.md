<h1 align="center">
    <a href="https://github.com/adinapoli/threads-supervisor">
        Threads Supervisor
    </a>
</h1>

<p align="center">
    <a href="https://travis-ci.org/adinapoli/threads-supervisor">
        <img alt="Tests"
             src="https://img.shields.io/travis/adinapoli/threads-supervisor.svg?style=flat-square">
    </a>
    <a href='https://coveralls.io/github/adinapoli/threads-supervisor?branch=master'>
      <img src='https://coveralls.io/repos/github/adinapoli/threads-supervisor/badge.svg?branch=master' alt='Coverage Status' />
    </a>
    <a href="https://hackage.haskell.org/package/threads-supervisor">
        <img alt="Version"
             src="https://img.shields.io/hackage/v/threads-supervisor.svg?label=version&amp;style=flat-square">
    </a>
</p>

<p align="center">
    Simple, IO-based, forkIO-friendly threads supervision library.
</p>

<hr>

# Changelog

* 1.1.0.0
    - (**Breaking Change**) Support lts-5.1 and retry-0.7 (https://github.com/adinapoli/threads-supervisor/pull/9)

* 1.0.4.1
    - Export QueueLike (https://github.com/adinapoli/threads-supervisor/pull/8)

* 1.0.4.0
    - Split up modules into `Types`, `Bounded` and `Supervisor`
    - The `Bounded` module offers a `SupervisorSpec` variant which writes `SupervisionEvent` into a `TBQueue`
    - The `Supervisor` module offers a `SupervisorSpec` variant which writes `SupervisionEvent` into a `TQueue`.
      Programmers are expected to read from the `eventStream` queue to avoid space leaks.

* 1.0.3.0
    - Added restart throttling using `RetryPolicy` from the [retry](http://hackage.haskell.org/package/retry) package.

# Example

Start from `Control.concurrent.Supervisor.Tutorial`. Other example can be found inside `examples`.

# Installation

```
cabal install threads-supervisor
```

or

```
stack install threads-supervisor
```

If you have downloaded the latest master from Github:

```
cabal install
```

or

```
stack install
```

# Testing

```
cabal install --enable-tests
cabal test
```

or

```
stack test
```

# Contributions
This library scratches my own itches, but please fork away!
Pull requests are encouraged to implement the part of the API
you need.

## Contributors

- Alfredo Di Napoli (initial author)
- Sam Rijs (@srijs)
