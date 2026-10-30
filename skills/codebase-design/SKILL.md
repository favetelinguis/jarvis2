---
name: codebase-design
description: "Shared vocabulary and principles for deep modules. Use when designing or changing a module's interface, deciding where a seam goes, planning or reviewing a refactor, finding deepening opportunities, or making code more testable."
---

# Codebase design

Design **deep modules**: a lot of behaviour behind a small interface, placed at a clean seam, testable through that interface. Use these terms exactly; do not substitute "component", "service", "API" or "boundary". Domain names come from `GLOSSARY.md`; ADRs record decisions you must not re-litigate without real friction.

## Glossary

**Module**: anything with an interface and an implementation, at any scale: a function, a file, a package, a slice across tiers. _Avoid_: unit, component, service.

**Interface**: everything a caller must know to use the module correctly: signature, invariants, ordering, error modes, required configuration, performance. _Avoid_: API, signature (too narrow).

**Implementation**: what is inside a module. Not the same as an **adapter**: a small adapter can have a large implementation (a database repo) and the reverse (an in-memory fake).

**Depth**: leverage at the interface: the behaviour a caller or test can exercise per unit of interface it must learn. **Deep** = much behaviour behind a small interface. **Shallow** = interface nearly as complex as the implementation.

**Seam** (Michael Feathers): a place where behaviour can change without editing in that place; the location of a module's interface. Where to put it is its own design decision. _Avoid_: boundary (overloaded by DDD).

**Adapter**: a concrete thing that satisfies an interface at a seam; it names a role, not content.

**Leverage**: what callers get from depth: one implementation pays off across N call sites and M tests.

**Locality**: what maintainers get from depth: change, bugs and verification concentrate in one place.

## Principles

- **Depth belongs to the interface, not the implementation.** A deep module may be built from small parts; they just are not part of the interface. It may have internal seams (private, used by its own tests) besides its external seam.
- **The deletion test.** Imagine deleting the module. If complexity vanishes, it was a pass-through. If it reappears across N callers, the module was earning its keep.
- **The interface is the test surface.** Callers and tests cross the same seam. Wanting to test past the interface means the module is the wrong shape.
- **One adapter is a hypothetical seam; two are a real one.** Add a seam only where something varies across it.

## Designing for testability

1. Accept dependencies instead of creating them.
2. Return results instead of mutating or producing side effects.
3. Keep the surface small: fewer functions and parameters mean fewer tests and simpler setup.

## Going deeper

Deepening a cluster given its dependencies (dependency categories, seam discipline, replace-don't-layer testing): [DEEPENING.md](DEEPENING.md).
